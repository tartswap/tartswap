// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TartStakingVault
 * @notice TartSwap single-token staking vault with streamed, fee-funded rewards.
 * @dev The staking token and reward token are the same asset, so principal and reward reserves
 *      are accounted separately. Existing TartSwap router/factory/pair logic is untouched.
 */
contract TartStakingVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant LOCK_FLEXIBLE = 0;
    uint8 public constant LOCK_7_DAYS = 1;
    uint8 public constant LOCK_14_DAYS = 2;
    uint8 public constant LOCK_30_DAYS = 3;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_DEPOSIT_FEE_BPS = 100;
    uint16 public constant MAX_FLEXIBLE_EXIT_FEE_BPS = 500;
    uint16 public constant MAX_LOCKED_PENALTY_BPS = 1_500;
    uint256 public constant MULTIPLIER_PRECISION = 1e18;
    uint256 public constant ACC_REWARD_PRECISION = 1e24;
    uint256 public constant MAX_MULTIPLIER = 3e18;
    uint256 public constant MIN_REWARD_DURATION = 1 days;
    uint256 public constant MAX_REWARD_DURATION = 30 days;
    uint256 public constant MAX_HARVEST_COOLDOWN = 7 days;
    uint256 public constant MAX_FLEXIBLE_MIN_STAKE_AGE = 7 days;

    IERC20 public immutable stakingToken;

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
        // Snapshot of tierConfigs[lockType].maxPenaltyBps taken at stake time so a later
        // owner re-tune of the tier can never retroactively raise (or, combined with a
        // shorter lockDuration, overflow) an existing position's emergency penalty.
        uint16 maxPenaltyBps;
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
    uint256 public rewardDuration = 7 days;
    uint256 public rewardPeriodFinish;
    uint256 public lastRewardTime;

    uint256 public flexibleHarvestCooldown = 1 days;
    uint256 public flexibleMinStakeAge = 2 days;
    uint16[5] public flexibleExitFeeBps = [uint16(500), uint16(300), uint16(200), uint16(100), uint16(0)];

    address public feeCollector;
    address public stakingFeeReceiver;
    address public liquidityReceiver;
    address public treasuryReceiver;
    uint16 public stakingFeeBps = 6_000;
    uint16 public liquidityFeeBps = 3_000;
    uint16 public treasuryFeeBps = 1_000;

    event Staked(
        address indexed user,
        uint256 indexed positionId,
        uint8 indexed lockType,
        uint256 amount,
        uint256 fee,
        uint256 weightedAmount,
        uint256 lockEndTime
    );
    event Harvested(address indexed user, uint256 indexed positionId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed positionId, uint256 principal, uint256 reward, uint256 fee);
    event EmergencyWithdrawn(address indexed user, uint256 indexed positionId, uint256 principal, uint256 fee, uint256 forfeitedReward);
    event RewardNotified(address indexed notifier, uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event FeeTaken(address indexed user, uint256 indexed positionId, uint256 amount, address indexed receiver, string feeType);
    event TierUpdated(uint8 indexed lockType, uint64 lockDuration, uint256 multiplier, uint16 depositFeeBps, uint16 maxPenaltyBps, bool active);
    event RewardNotifierUpdated(address indexed notifier, bool active);
    event FeeReceiverUpdated(address feeCollector, address stakingFeeReceiver, address liquidityReceiver, address treasuryReceiver);
    event FeeSplitUpdated(uint16 stakingFeeBps, uint16 liquidityFeeBps, uint16 treasuryFeeBps);
    event RewardDurationUpdated(uint256 duration);
    event HarvestCooldownUpdated(uint256 cooldown);
    event FlexibleMinStakeAgeUpdated(uint256 minStakeAge);
    event FlexibleExitFeesUpdated(uint16 fee0To24h, uint16 fee1To3d, uint16 fee3To7d, uint16 fee7To14d, uint16 fee14dPlus);
    event RewardCarriedForward(address indexed user, uint256 indexed positionId, uint256 unpaidAmount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    modifier onlyRewardNotifier() {
        require(owner() == msg.sender || rewardNotifiers[msg.sender], "Not reward notifier");
        _;
    }

    constructor(
        address initialOwner,
        address stakingToken_,
        address feeCollector_,
        address liquidityReceiver_,
        address treasuryReceiver_
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "Zero owner");
        require(stakingToken_ != address(0), "Zero staking token");
        require(liquidityReceiver_ != address(0) && treasuryReceiver_ != address(0), "Zero fee receiver");

        stakingToken = IERC20(stakingToken_);
        feeCollector = feeCollector_;
        stakingFeeReceiver = address(this);
        liquidityReceiver = liquidityReceiver_;
        treasuryReceiver = treasuryReceiver_;
        lastRewardTime = block.timestamp;

        _setTierConfig(LOCK_FLEXIBLE, 0, 1e18, 50, 0, true);
        _setTierConfig(LOCK_7_DAYS, 7 days, 1.25e18, 0, 500, true);
        _setTierConfig(LOCK_14_DAYS, 14 days, 1.60e18, 0, 800, true);
        _setTierConfig(LOCK_30_DAYS, 30 days, 2e18, 0, 1_200, true);
    }

    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function getUserPositions(address user) external view returns (Position[] memory) {
        return positions[user];
    }

    function currentRewardRate() external view returns (uint256) {
        return block.timestamp < rewardPeriodFinish ? rewardRate : 0;
    }

    function estimateAprBps(uint8 lockType) external view returns (uint256) {
        TierConfig memory tier = tierConfigs[lockType];
        if (totalWeightedStaked == 0 || block.timestamp >= rewardPeriodFinish || tier.multiplier == 0) return 0;
        uint256 annualRewardPerWeight = (rewardRate * 365 days * MULTIPLIER_PRECISION) / totalWeightedStaked;
        return (annualRewardPerWeight * tier.multiplier * BPS_DENOMINATOR) / (MULTIPLIER_PRECISION * MULTIPLIER_PRECISION);
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
                _payReward(msg.sender, pending);
                reward = pending;
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

    function notifyRewardAmount(uint256 amount) external nonReentrant whenNotPaused onlyRewardNotifier {
        require(amount > 0, "Zero amount");
        uint256 received = _pullStakeToken(msg.sender, amount);
        require(received > 0, "No tokens received");
        _startOrExtendRewardStream(received);
    }

    function notifyRewardAmountFromBalance(uint256 amount) external nonReentrant whenNotPaused onlyRewardNotifier {
        require(amount > 0, "Zero amount");
        require(_unreservedTokenBalance() >= amount, "Insufficient unreserved token");
        _startOrExtendRewardStream(amount);
    }

    function setRewardNotifier(address notifier, bool active) external onlyOwner {
        require(notifier != address(0), "Zero notifier");
        rewardNotifiers[notifier] = active;
        emit RewardNotifierUpdated(notifier, active);
    }

    function setFeeReceivers(
        address feeCollector_,
        address stakingFeeReceiver_,
        address liquidityReceiver_,
        address treasuryReceiver_
    ) external onlyOwner {
        require(stakingFeeReceiver_ != address(0) && liquidityReceiver_ != address(0) && treasuryReceiver_ != address(0), "Zero fee receiver");
        feeCollector = feeCollector_;
        stakingFeeReceiver = stakingFeeReceiver_;
        liquidityReceiver = liquidityReceiver_;
        treasuryReceiver = treasuryReceiver_;
        emit FeeReceiverUpdated(feeCollector_, stakingFeeReceiver_, liquidityReceiver_, treasuryReceiver_);
    }

    function setFeeSplit(uint16 stakingFeeBps_, uint16 liquidityFeeBps_, uint16 treasuryFeeBps_) external onlyOwner {
        require(uint256(stakingFeeBps_) + liquidityFeeBps_ + treasuryFeeBps_ == BPS_DENOMINATOR, "Bad fee split");
        stakingFeeBps = stakingFeeBps_;
        liquidityFeeBps = liquidityFeeBps_;
        treasuryFeeBps = treasuryFeeBps_;
        emit FeeSplitUpdated(stakingFeeBps_, liquidityFeeBps_, treasuryFeeBps_);
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
            fee0To24h <= MAX_FLEXIBLE_EXIT_FEE_BPS &&
                fee1To3d <= MAX_FLEXIBLE_EXIT_FEE_BPS &&
                fee3To7d <= MAX_FLEXIBLE_EXIT_FEE_BPS &&
                fee7To14d <= MAX_FLEXIBLE_EXIT_FEE_BPS &&
                fee14dPlus <= MAX_FLEXIBLE_EXIT_FEE_BPS,
            "Exit fee cap"
        );
        flexibleExitFeeBps = [fee0To24h, fee1To3d, fee3To7d, fee7To14d, fee14dPlus];
        emit FlexibleExitFeesUpdated(fee0To24h, fee1To3d, fee3To7d, fee7To14d, fee14dPlus);
    }

    function setTierConfig(
        uint8 lockType,
        uint64 lockDuration,
        uint256 multiplier,
        uint16 depositFeeBps,
        uint16 maxPenaltyBps,
        bool active
    ) external onlyOwner {
        _setTierConfig(lockType, lockDuration, multiplier, depositFeeBps, maxPenaltyBps, active);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
        if (token == address(stakingToken)) {
            require(amount <= _unreservedTokenBalance(), "Stake token protected");
        }
        IERC20(token).safeTransfer(to, amount);
        emit RescueToken(token, to, amount);
    }

    function updateReward() external {
        _updateRewardPerWeight();
    }

    function _setTierConfig(
        uint8 lockType,
        uint64 lockDuration,
        uint256 multiplier,
        uint16 depositFeeBps,
        uint16 maxPenaltyBps,
        bool active
    ) internal {
        require(lockType <= LOCK_30_DAYS, "Bad lock type");
        require(multiplier >= MULTIPLIER_PRECISION && multiplier <= MAX_MULTIPLIER, "Bad multiplier");
        require(depositFeeBps <= MAX_DEPOSIT_FEE_BPS, "Deposit fee cap");
        require(maxPenaltyBps <= MAX_LOCKED_PENALTY_BPS, "Penalty cap");
        if (lockType == LOCK_FLEXIBLE) {
            require(lockDuration == 0 && maxPenaltyBps == 0, "Bad flexible config");
        } else {
            require(lockDuration > 0, "Bad lock duration");
        }

        tierConfigs[lockType] = TierConfig({
            lockDuration: lockDuration,
            multiplier: multiplier,
            depositFeeBps: depositFeeBps,
            maxPenaltyBps: maxPenaltyBps,
            active: active
        });
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

        uint256 available = _availableRewardBalance();
        paid = pending > available ? available : pending;
        if (paid > 0) {
            rewardReserve -= paid;
            stakingToken.safeTransfer(user, paid);
        }
        position.unpaidReward = pending - paid;
        position.rewardDebt = (position.weightedAmount * accRewardPerWeight) / ACC_REWARD_PRECISION;

        if (position.unpaidReward > 0) {
            emit RewardCarriedForward(user, positionId, position.unpaidReward);
        }
    }

    function _payReward(address to, uint256 amount) internal {
        require(rewardReserve >= amount, "Reward reserve low");
        require(_availableRewardBalance() >= amount, "Reward balance low");
        rewardReserve -= amount;
        stakingToken.safeTransfer(to, amount);
    }

    function _pending(Position storage position) internal view returns (uint256) {
        return ((position.weightedAmount * accRewardPerWeight) / ACC_REWARD_PRECISION) - position.rewardDebt + position.unpaidReward;
    }

    function _queueForfeitedReward(uint256 amount) internal {
        // Never revert: an emergency exit must ALWAYS return the user's principal.
        // Forfeiting a reward is a courtesy re-queue; cap it at what the reserve
        // actually holds so a badly-underfunded reserve can't block the exit.
        uint256 q = amount > rewardReserve ? rewardReserve : amount;
        if (q > 0) queuedRewards += q;
    }

    function _routeFee(address user, uint256 positionId, uint256 amount, string memory feeType) internal {
        if (amount == 0) return;
        if (feeCollector != address(0)) {
            stakingToken.safeTransfer(feeCollector, amount);
            emit FeeTaken(user, positionId, amount, feeCollector, feeType);
            return;
        }

        uint256 stakingAmount = (amount * stakingFeeBps) / BPS_DENOMINATOR;
        uint256 liquidityAmount = (amount * liquidityFeeBps) / BPS_DENOMINATOR;
        uint256 treasuryAmount = amount - stakingAmount - liquidityAmount;

        if (stakingAmount > 0) {
            if (stakingFeeReceiver == address(this)) {
                _startOrExtendRewardStream(stakingAmount);
            } else {
                stakingToken.safeTransfer(stakingFeeReceiver, stakingAmount);
            }
        }
        if (liquidityAmount > 0) stakingToken.safeTransfer(liquidityReceiver, liquidityAmount);
        if (treasuryAmount > 0) stakingToken.safeTransfer(treasuryReceiver, treasuryAmount);

        emit FeeTaken(user, positionId, amount, address(0), feeType);
    }

    function _lockedEmergencyPenalty(
        uint256 principal,
        uint64 startTime,
        uint64 lockEndTime,
        uint16 maxPenaltyBps
    ) internal view returns (uint256) {
        if (block.timestamp >= uint256(lockEndTime)) return 0;
        // Use the stake-time snapshots exclusively; never read the (mutable) live tier
        // config here. lockDuration is derived from the position's own timestamps so it
        // always matches maxPenaltyBps as it was at stake time.
        uint256 lockDuration = uint256(lockEndTime) - uint256(startTime);
        if (lockDuration == 0) return 0;
        uint256 remaining = uint256(lockEndTime) - block.timestamp;
        if (remaining > lockDuration) remaining = lockDuration;
        uint256 fee = (principal * uint256(maxPenaltyBps) * remaining) / (lockDuration * BPS_DENOMINATOR);
        // Defensive clamp: the emergency penalty can never exceed the protocol cap of the
        // principal, so payout = principal - fee can never underflow.
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
        // Dust-safe: if the batch is too small to yield a non-zero per-second
        // rate, do NOT revert (that would brick a stake() whose recycled fee is
        // this batch, in feeCollector==0 mode). Park it in queuedRewards until a
        // later notify accumulates enough to start the stream.
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

    function _availableRewardBalance() internal view returns (uint256) {
        uint256 balance = stakingToken.balanceOf(address(this));
        if (balance <= totalStaked) return 0;
        uint256 available = balance - totalStaked;
        return available > rewardReserve ? rewardReserve : available;
    }

    function _unreservedTokenBalance() internal view returns (uint256) {
        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 protectedBalance = totalStaked + rewardReserve;
        return balance > protectedBalance ? balance - protectedBalance : 0;
    }
}
