// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TartPartnerStakingVault
 * @notice Dual-token partner staking pool: stake token A, earn token B (e.g. stake SHIB, earn TART).
 * @dev Derived from TartStakingVault (same tiers, fee schedule, harvest rules and reward stream),
 *      with two changes: rewards are paid in a separate `rewardToken`, and every fee (deposit,
 *      flexible exit, emergency penalty) is taken in the staking token and sent to a single
 *      `feeCollector` (the partner's wallet). Rewards are funded by the owner or a whitelisted
 *      notifier and streamed linearly over `rewardDuration`; unpaid rewards carry forward.
 */
contract TartPartnerStakingVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant LOCK_FLEXIBLE = 0;
    uint8 public constant LOCK_TIER_1 = 1;
    uint8 public constant LOCK_TIER_2 = 2;
    uint8 public constant LOCK_TIER_3 = 3;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_DEPOSIT_FEE_BPS = 100;
    uint16 public constant MAX_FLEXIBLE_EXIT_FEE_BPS = 500;
    uint16 public constant MAX_LOCKED_PENALTY_BPS = 1_500;
    uint256 public constant MULTIPLIER_PRECISION = 1e18;
    uint256 public constant ACC_REWARD_PRECISION = 1e24;
    uint256 public constant MAX_MULTIPLIER = 3e18;
    uint256 public constant MIN_REWARD_DURATION = 1 days;
    uint256 public constant MAX_REWARD_DURATION = 90 days;
    uint256 public constant MAX_LOCK_DURATION = 365 days;
    uint256 public constant MAX_HARVEST_COOLDOWN = 7 days;
    uint256 public constant MAX_FLEXIBLE_MIN_STAKE_AGE = 7 days;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    struct TierConfig {
        uint64 lockDuration;
        uint256 multiplier;
        uint16 depositFeeBps;
        uint16 maxPenaltyBps;
        bool active;
    }

    struct Position {
        uint256 amount;
        uint256 weightedAmount;
        uint256 rewardDebt;
        uint256 unpaidReward;
        uint64 startTime;
        uint64 lockEndTime;
        uint64 lastHarvestTime;
        uint8 lockType;
        uint16 maxPenaltyBps; // snapshot at stake time; a later tier re-tune never raises it
        bool withdrawn;
    }

    mapping(uint8 => TierConfig) public tierConfigs;
    mapping(address => Position[]) private positions;
    mapping(address => bool) public rewardNotifiers;

    uint256 public totalStaked;
    uint256 public totalWeightedStaked;
    uint256 public accRewardPerWeight;

    uint256 public rewardReserve;
    uint256 public queuedRewards;
    uint256 public rewardRate;
    uint256 public rewardDuration = 30 days;
    uint256 public rewardPeriodFinish;
    uint256 public lastRewardTime;

    uint256 public flexibleHarvestCooldown = 1 days;
    uint256 public flexibleMinStakeAge = 2 days;
    uint16[5] public flexibleExitFeeBps = [uint16(500), uint16(300), uint16(200), uint16(100), uint16(0)];

    /// Every fee is paid in the staking token to this address (the partner's wallet).
    address public feeCollector;

    event Staked(address indexed user, uint256 indexed positionId, uint8 indexed lockType, uint256 amount, uint256 fee, uint256 weightedAmount, uint256 lockEndTime);
    event Harvested(address indexed user, uint256 indexed positionId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed positionId, uint256 principal, uint256 reward, uint256 fee);
    event EmergencyWithdrawn(address indexed user, uint256 indexed positionId, uint256 principal, uint256 fee, uint256 forfeitedReward);
    event RewardNotified(address indexed notifier, uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event FeeTaken(address indexed user, uint256 indexed positionId, uint256 amount, address indexed receiver, string feeType);
    event TierUpdated(uint8 indexed lockType, uint64 lockDuration, uint256 multiplier, uint16 depositFeeBps, uint16 maxPenaltyBps, bool active);
    event RewardNotifierUpdated(address indexed notifier, bool active);
    event FeeCollectorUpdated(address feeCollector);
    event RewardDurationUpdated(uint256 duration);
    event HarvestCooldownUpdated(uint256 cooldown);
    event FlexibleMinStakeAgeUpdated(uint256 minStakeAge);
    event FlexibleExitFeesUpdated(uint16 fee0To24h, uint16 fee1To3d, uint16 fee3To7d, uint16 fee7To14d, uint16 fee14dPlus);
    event RewardCarriedForward(address indexed user, uint256 indexed positionId, uint256 unpaidAmount);
    event UnusedRewardsWithdrawn(address indexed to, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    modifier onlyRewardNotifier() {
        require(owner() == msg.sender || rewardNotifiers[msg.sender], "Not reward notifier");
        _;
    }

    /**
     * @param initialOwner   Owner (team key or Safe).
     * @param stakingToken_  Token users stake (e.g. SHIB).
     * @param rewardToken_   Token users earn (e.g. TART).
     * @param feeCollector_  Receives every fee, in the staking token (partner wallet).
     * @param tierLocks      Lock durations for tiers 1..3 (seconds), each > 0 and <= 365 days.
     * @param tierMultipliers Multipliers for tiers 0..3 (1e18 = 1x, max 3x).
     */
    constructor(
        address initialOwner,
        address stakingToken_,
        address rewardToken_,
        address feeCollector_,
        uint64[3] memory tierLocks,
        uint256[4] memory tierMultipliers
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "Zero owner");
        require(stakingToken_ != address(0) && rewardToken_ != address(0), "Zero token");
        require(feeCollector_ != address(0), "Zero fee collector");

        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
        feeCollector = feeCollector_;
        lastRewardTime = block.timestamp;
        emit FeeCollectorUpdated(feeCollector_);

        _setTierConfig(LOCK_FLEXIBLE, 0, tierMultipliers[0], 50, 0, true);
        _setTierConfig(LOCK_TIER_1, tierLocks[0], tierMultipliers[1], 0, 500, true);
        _setTierConfig(LOCK_TIER_2, tierLocks[1], tierMultipliers[2], 0, 800, true);
        _setTierConfig(LOCK_TIER_3, tierLocks[2], tierMultipliers[3], 0, 1_200, true);
    }

    // ----------------------------------------------------------------- Views
    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function getUserPositions(address user) external view returns (Position[] memory) {
        return positions[user];
    }

    function currentRewardRate() external view returns (uint256) {
        return block.timestamp < rewardPeriodFinish ? rewardRate : 0;
    }

    /// Reward-token units per year per 1e18 of weighted stake; the UI turns this into an APR with prices.
    function annualRewardPerWeight() external view returns (uint256) {
        if (totalWeightedStaked == 0 || block.timestamp >= rewardPeriodFinish) return 0;
        return (rewardRate * 365 days * MULTIPLIER_PRECISION) / totalWeightedStaked;
    }

    function pendingReward(address user, uint256 positionId) public view returns (uint256) {
        require(positionId < positions[user].length, "Bad position");
        Position memory position = positions[user][positionId];
        if (position.withdrawn || position.weightedAmount == 0) return 0;

        uint256 acc = accRewardPerWeight;
        uint256 applicableTime = _lastTimeRewardApplicable();
        if (applicableTime > lastRewardTime && totalWeightedStaked > 0) {
            uint256 reward = (applicableTime - lastRewardTime) * rewardRate;
            acc += (reward * ACC_REWARD_PRECISION) / totalWeightedStaked;
        }
        return ((position.weightedAmount * acc) / ACC_REWARD_PRECISION) - position.rewardDebt + position.unpaidReward;
    }

    // ------------------------------------------------------------------ Users
    function stake(uint256 amount, uint8 lockType) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        TierConfig memory tier = tierConfigs[lockType];
        require(tier.active, "Tier inactive");
        require(tier.multiplier > 0, "Bad tier");

        _updateRewardPerWeight();

        uint256 received = _pullStakeToken(msg.sender, amount);
        require(received > 0, "No tokens received");
        uint256 fee = (received * tier.depositFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = received - fee;
        require(netAmount > 0, "Stake too small");
        if (fee > 0) _routeFee(msg.sender, 0, fee, "deposit");

        uint256 weightedAmount = (netAmount * tier.multiplier) / MULTIPLIER_PRECISION;
        require(weightedAmount > 0, "Weight too small");

        uint256 lockEndTime = tier.lockDuration == 0 ? 0 : block.timestamp + uint256(tier.lockDuration);
        uint256 positionId = positions[msg.sender].length;
        positions[msg.sender].push(
            Position({
                amount: netAmount,
                weightedAmount: weightedAmount,
                rewardDebt: (weightedAmount * accRewardPerWeight) / ACC_REWARD_PRECISION,
                unpaidReward: 0,
                startTime: uint64(block.timestamp),
                lockEndTime: uint64(lockEndTime),
                lastHarvestTime: uint64(block.timestamp),
                lockType: lockType,
                maxPenaltyBps: tier.maxPenaltyBps,
                withdrawn: false
            })
        );

        totalStaked += netAmount;
        totalWeightedStaked += weightedAmount;
        emit Staked(msg.sender, positionId, lockType, netAmount, fee, weightedAmount, lockEndTime);
    }

    function harvest(uint256 positionId) external nonReentrant {
        Position storage position = _activePosition(msg.sender, positionId);
        if (position.lockType == LOCK_FLEXIBLE) {
            require(block.timestamp >= uint256(position.startTime) + flexibleMinStakeAge, "Stake age too low");
            require(block.timestamp >= uint256(position.lastHarvestTime) + flexibleHarvestCooldown, "Harvest cooldown");
        } else {
            require(block.timestamp >= uint256(position.lockEndTime), "Lock active");
        }

        _updateRewardPerWeight();
        uint256 paid = _harvest(msg.sender, positionId, position);
        position.lastHarvestTime = uint64(block.timestamp);
        emit Harvested(msg.sender, positionId, paid);
    }

    function withdraw(uint256 positionId) external nonReentrant {
        Position storage position = _activePosition(msg.sender, positionId);
        if (position.lockType != LOCK_FLEXIBLE) {
            require(block.timestamp >= uint256(position.lockEndTime), "Lock active");
        }

        _updateRewardPerWeight();
        uint256 reward;
        uint256 pending = _pending(position);
        if (pending > 0) {
            if (position.lockType == LOCK_FLEXIBLE && block.timestamp < uint256(position.startTime) + flexibleMinStakeAge) {
                _queueForfeitedReward(pending);
            } else {
                reward = _payRewardCapped(msg.sender, pending);
            }
        }

        uint256 principal = position.amount;
        uint256 fee = 0;
        if (position.lockType == LOCK_FLEXIBLE) {
            fee = (principal * _flexibleExitFeeBps(position.startTime)) / BPS_DENOMINATOR;
        }
        uint256 payout = principal - fee;

        _closePosition(position);
        stakingToken.safeTransfer(msg.sender, payout);
        if (fee > 0) _routeFee(msg.sender, positionId, fee, "exit");
        emit Withdrawn(msg.sender, positionId, principal, reward, fee);
    }

    function emergencyWithdraw(uint256 positionId) external nonReentrant {
        Position storage position = _activePosition(msg.sender, positionId);
        _updateRewardPerWeight();

        uint256 forfeitedReward = _pending(position);
        if (forfeitedReward > 0) _queueForfeitedReward(forfeitedReward);

        uint256 principal = position.amount;
        uint256 fee = position.lockType == LOCK_FLEXIBLE
            ? (principal * _flexibleExitFeeBps(position.startTime)) / BPS_DENOMINATOR
            : _lockedEmergencyPenalty(principal, position.startTime, position.lockEndTime, position.maxPenaltyBps);
        uint256 payout = principal - fee;

        _closePosition(position);
        stakingToken.safeTransfer(msg.sender, payout);
        if (fee > 0) _routeFee(msg.sender, positionId, fee, "emergency");
        emit EmergencyWithdrawn(msg.sender, positionId, principal, fee, forfeitedReward);
    }

    // ---------------------------------------------------------------- Rewards
    /// Pull `amount` of the reward token from the caller and stream it (plus anything queued
    /// and the unstreamed remainder of the current period) over `rewardDuration` from now.
    function notifyRewardAmount(uint256 amount) external nonReentrant whenNotPaused onlyRewardNotifier {
        require(amount > 0, "Zero amount");
        uint256 received = _pullRewardToken(msg.sender, amount);
        require(received > 0, "No tokens received");
        _startOrExtendRewardStream(received);
    }

    /// Stream reward tokens that were transferred to the vault directly (no pull).
    function notifyRewardAmountFromBalance(uint256 amount) external nonReentrant whenNotPaused onlyRewardNotifier {
        require(amount > 0, "Zero amount");
        require(_unreservedRewardBalance() >= amount, "Insufficient unreserved reward");
        _startOrExtendRewardStream(amount);
    }

    /// After the stream has ended, rewards that never found a staker (queued) can be returned.
    function withdrawUnusedRewards(address to) external onlyOwner nonReentrant {
        require(to != address(0), "Zero receiver");
        require(block.timestamp >= rewardPeriodFinish, "Stream active");
        _updateRewardPerWeight();
        uint256 amount = queuedRewards;
        require(amount > 0, "Nothing queued");
        queuedRewards = 0;
        rewardReserve -= amount;
        rewardToken.safeTransfer(to, amount);
        emit UnusedRewardsWithdrawn(to, amount);
    }

    // ------------------------------------------------------------------ Owner
    function setRewardNotifier(address notifier, bool active) external onlyOwner {
        require(notifier != address(0), "Zero notifier");
        rewardNotifiers[notifier] = active;
        emit RewardNotifierUpdated(notifier, active);
    }

    function setFeeCollector(address feeCollector_) external onlyOwner {
        require(feeCollector_ != address(0), "Zero fee collector");
        feeCollector = feeCollector_;
        emit FeeCollectorUpdated(feeCollector_);
    }

    function setRewardDuration(uint256 duration) external onlyOwner {
        require(duration >= MIN_REWARD_DURATION && duration <= MAX_REWARD_DURATION, "Bad reward duration");
        _updateRewardPerWeight();
        rewardDuration = duration;
        emit RewardDurationUpdated(duration);
    }

    function setHarvestCooldown(uint256 cooldown) external onlyOwner {
        require(cooldown <= MAX_HARVEST_COOLDOWN, "Harvest cooldown cap");
        flexibleHarvestCooldown = cooldown;
        emit HarvestCooldownUpdated(cooldown);
    }

    function setFlexibleMinStakeAge(uint256 minStakeAge) external onlyOwner {
        require(minStakeAge <= MAX_FLEXIBLE_MIN_STAKE_AGE, "Stake age cap");
        flexibleMinStakeAge = minStakeAge;
        emit FlexibleMinStakeAgeUpdated(minStakeAge);
    }

    function setFlexibleExitFeeBps(uint16 fee0To24h, uint16 fee1To3d, uint16 fee3To7d, uint16 fee7To14d, uint16 fee14dPlus) external onlyOwner {
        require(
            fee0To24h <= MAX_FLEXIBLE_EXIT_FEE_BPS && fee1To3d <= MAX_FLEXIBLE_EXIT_FEE_BPS && fee3To7d <= MAX_FLEXIBLE_EXIT_FEE_BPS &&
                fee7To14d <= MAX_FLEXIBLE_EXIT_FEE_BPS && fee14dPlus <= MAX_FLEXIBLE_EXIT_FEE_BPS,
            "Exit fee cap"
        );
        flexibleExitFeeBps = [fee0To24h, fee1To3d, fee3To7d, fee7To14d, fee14dPlus];
        emit FlexibleExitFeesUpdated(fee0To24h, fee1To3d, fee3To7d, fee7To14d, fee14dPlus);
    }

    function setTierConfig(uint8 lockType, uint64 lockDuration, uint256 multiplier, uint16 depositFeeBps, uint16 maxPenaltyBps, bool active) external onlyOwner {
        _setTierConfig(lockType, lockDuration, multiplier, depositFeeBps, maxPenaltyBps, active);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// Rescue tokens sent here by mistake. Staked principal and the reward reserve are protected.
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
        if (token == address(stakingToken)) require(amount <= _unreservedStakeBalance(), "Stake token protected");
        if (token == address(rewardToken)) require(amount <= _unreservedRewardBalance(), "Reward token protected");
        IERC20(token).safeTransfer(to, amount);
        emit RescueToken(token, to, amount);
    }

    function updateReward() external {
        _updateRewardPerWeight();
    }

    // -------------------------------------------------------------- Internals
    function _setTierConfig(uint8 lockType, uint64 lockDuration, uint256 multiplier, uint16 depositFeeBps, uint16 maxPenaltyBps, bool active) internal {
        require(lockType <= LOCK_TIER_3, "Bad lock type");
        require(multiplier >= MULTIPLIER_PRECISION && multiplier <= MAX_MULTIPLIER, "Bad multiplier");
        require(depositFeeBps <= MAX_DEPOSIT_FEE_BPS, "Deposit fee cap");
        require(maxPenaltyBps <= MAX_LOCKED_PENALTY_BPS, "Penalty cap");
        if (lockType == LOCK_FLEXIBLE) {
            require(lockDuration == 0 && maxPenaltyBps == 0, "Bad flexible config");
        } else {
            require(lockDuration > 0 && lockDuration <= MAX_LOCK_DURATION, "Bad lock duration");
        }
        tierConfigs[lockType] = TierConfig({ lockDuration: lockDuration, multiplier: multiplier, depositFeeBps: depositFeeBps, maxPenaltyBps: maxPenaltyBps, active: active });
        emit TierUpdated(lockType, lockDuration, multiplier, depositFeeBps, maxPenaltyBps, active);
    }

    function _activePosition(address user, uint256 positionId) internal view returns (Position storage position) {
        require(positionId < positions[user].length, "Bad position");
        position = positions[user][positionId];
        require(!position.withdrawn && position.amount > 0, "Position closed");
    }

    function _closePosition(Position storage position) internal {
        totalStaked -= position.amount;
        totalWeightedStaked -= position.weightedAmount;
        position.amount = 0;
        position.weightedAmount = 0;
        position.rewardDebt = 0;
        position.unpaidReward = 0;
        position.withdrawn = true;
    }

    function _harvest(address user, uint256 positionId, Position storage position) internal returns (uint256 paid) {
        uint256 pending = _pending(position);
        if (pending == 0) {
            position.rewardDebt = (position.weightedAmount * accRewardPerWeight) / ACC_REWARD_PRECISION;
            position.unpaidReward = 0;
            return 0;
        }
        paid = _payRewardCapped(user, pending);
        position.unpaidReward = pending - paid;
        position.rewardDebt = (position.weightedAmount * accRewardPerWeight) / ACC_REWARD_PRECISION;
        if (position.unpaidReward > 0) emit RewardCarriedForward(user, positionId, position.unpaidReward);
    }

    /// Pays up to what the reserve actually holds; the shortfall stays owed to the position.
    function _payRewardCapped(address to, uint256 amount) internal returns (uint256 paid) {
        uint256 available = _availableRewardBalance();
        paid = amount > available ? available : amount;
        if (paid > 0) {
            rewardReserve -= paid;
            rewardToken.safeTransfer(to, paid);
        }
    }

    function _pending(Position storage position) internal view returns (uint256) {
        return ((position.weightedAmount * accRewardPerWeight) / ACC_REWARD_PRECISION) - position.rewardDebt + position.unpaidReward;
    }

    function _queueForfeitedReward(uint256 amount) internal {
        uint256 q = amount > rewardReserve ? rewardReserve : amount;
        if (q > 0) queuedRewards += q;
    }

    function _routeFee(address user, uint256 positionId, uint256 amount, string memory feeType) internal {
        if (amount == 0) return;
        stakingToken.safeTransfer(feeCollector, amount);
        emit FeeTaken(user, positionId, amount, feeCollector, feeType);
    }

    function _lockedEmergencyPenalty(uint256 principal, uint64 startTime, uint64 lockEndTime, uint16 maxPenaltyBps) internal view returns (uint256) {
        if (block.timestamp >= uint256(lockEndTime)) return 0;
        uint256 lockDuration = uint256(lockEndTime) - uint256(startTime);
        if (lockDuration == 0) return 0;
        uint256 remaining = uint256(lockEndTime) - block.timestamp;
        if (remaining > lockDuration) remaining = lockDuration;
        uint256 fee = (principal * uint256(maxPenaltyBps) * remaining) / (lockDuration * BPS_DENOMINATOR);
        uint256 cap = (principal * MAX_LOCKED_PENALTY_BPS) / BPS_DENOMINATOR;
        return fee > cap ? cap : fee;
    }

    function _flexibleExitFeeBps(uint64 startTime) internal view returns (uint16) {
        uint256 age = block.timestamp - uint256(startTime);
        if (age < 1 days) return flexibleExitFeeBps[0];
        if (age < 3 days) return flexibleExitFeeBps[1];
        if (age < 7 days) return flexibleExitFeeBps[2];
        if (age < 14 days) return flexibleExitFeeBps[3];
        return flexibleExitFeeBps[4];
    }

    function _startOrExtendRewardStream(uint256 amount) internal {
        _updateRewardPerWeight();
        rewardReserve += amount;

        uint256 totalReward = amount + queuedRewards;
        queuedRewards = 0;
        if (block.timestamp < rewardPeriodFinish) {
            totalReward += (rewardPeriodFinish - block.timestamp) * rewardRate;
        }

        rewardRate = totalReward / rewardDuration;
        if (rewardRate == 0) {
            queuedRewards = totalReward;
            return;
        }
        queuedRewards = totalReward - (rewardRate * rewardDuration);
        lastRewardTime = block.timestamp;
        rewardPeriodFinish = block.timestamp + rewardDuration;
        emit RewardNotified(msg.sender, amount, rewardRate, rewardPeriodFinish);
    }

    function _updateRewardPerWeight() internal {
        uint256 applicableTime = _lastTimeRewardApplicable();
        if (applicableTime <= lastRewardTime) return;
        uint256 reward = (applicableTime - lastRewardTime) * rewardRate;
        if (totalWeightedStaked == 0) {
            queuedRewards += reward;
            lastRewardTime = applicableTime;
            return;
        }
        accRewardPerWeight += (reward * ACC_REWARD_PRECISION) / totalWeightedStaked;
        lastRewardTime = applicableTime;
    }

    function _lastTimeRewardApplicable() internal view returns (uint256) {
        return block.timestamp < rewardPeriodFinish ? block.timestamp : rewardPeriodFinish;
    }

    function _pullStakeToken(address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBalance = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = stakingToken.balanceOf(address(this));
        require(afterBalance >= beforeBalance, "Bad token balance");
        received = afterBalance - beforeBalance;
    }

    function _pullRewardToken(address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = rewardToken.balanceOf(address(this));
        require(afterBalance >= beforeBalance, "Bad token balance");
        received = afterBalance - beforeBalance;
    }

    /// Principal held in the staking token (only relevant when both tokens are the same asset).
    function _stakePrincipalInRewardToken() internal view returns (uint256) {
        return address(stakingToken) == address(rewardToken) ? totalStaked : 0;
    }

    function _availableRewardBalance() internal view returns (uint256) {
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 principal = _stakePrincipalInRewardToken();
        if (balance <= principal) return 0;
        uint256 available = balance - principal;
        return available > rewardReserve ? rewardReserve : available;
    }

    function _unreservedRewardBalance() internal view returns (uint256) {
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 protectedBalance = _stakePrincipalInRewardToken() + rewardReserve;
        return balance > protectedBalance ? balance - protectedBalance : 0;
    }

    function _unreservedStakeBalance() internal view returns (uint256) {
        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 protectedBalance = totalStaked + (address(stakingToken) == address(rewardToken) ? rewardReserve : 0);
        return balance > protectedBalance ? balance - protectedBalance : 0;
    }
}
