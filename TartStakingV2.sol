// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TartStakingV2
 * @notice Multi-pool single-token staking contract for TartSwap staking products.
 * @dev Safety model:
 *      - User principal is tracked globally per token and is never counted as rewards.
 *      - Fee-on-transfer stake tokens are credited by actual amount received.
 *      - Underfunded rewards are carried forward instead of silently disappearing.
 *      - Owner cannot rescue any token that is configured as a stake or reward token.
 */
contract TartStakingV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant ACC_PRECISION = 1e24;

    struct PoolInfo {
        IERC20 stakeToken;
        IERC20 rewardToken;
        uint256 rewardPerSecond;
        uint64 startTime;
        uint64 endTime;
        uint64 lockDuration;
        uint64 lastRewardTime;
        uint256 accRewardPerShare;
        uint256 totalStaked;
        bool active;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 unpaidRewards;
        uint64 lastDepositTime;
        /// @notice Deposit-time unlock timestamp. Later pool lock changes do not extend existing users.
        uint64 unlockAt;
    }

    PoolInfo[] public pools;
    mapping(uint256 => mapping(address => UserInfo)) public users;

    /// @notice Total user principal held by this contract for each stake token.
    mapping(address => uint256) public totalStakedByToken;

    /// @dev Token use counter protects stake and reward tokens from owner rescue.
    mapping(address => uint256) public poolTokenUseCount;

    event PoolAdded(
        uint256 indexed pid,
        address indexed stakeToken,
        address indexed rewardToken,
        uint256 rewardPerSecond,
        uint64 startTime,
        uint64 endTime,
        uint64 lockDuration
    );
    event PoolUpdated(uint256 indexed pid, uint256 rewardPerSecond, uint64 startTime, uint64 endTime, uint64 lockDuration, bool active);
    event RewardsFunded(uint256 indexed pid, address indexed funder, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event DepositAccounted(address indexed user, uint256 indexed pid, uint256 requestedAmount, uint256 receivedAmount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardCarriedForward(address indexed user, uint256 indexed pid, uint256 unpaidAmount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function poolLength() external view returns (uint256) {
        return pools.length;
    }

    function addPool(
        address stakeToken,
        address rewardToken,
        uint256 rewardPerSecond,
        uint64 startTime,
        uint64 endTime,
        uint64 lockDuration,
        bool active
    ) external onlyOwner {
        require(stakeToken != address(0) && rewardToken != address(0), "Zero token");
        require(endTime > startTime, "Bad time");

        uint64 lastRewardTime = uint64(block.timestamp > startTime ? block.timestamp : startTime);
        pools.push(
            PoolInfo({
                stakeToken: IERC20(stakeToken),
                rewardToken: IERC20(rewardToken),
                rewardPerSecond: rewardPerSecond,
                startTime: startTime,
                endTime: endTime,
                lockDuration: lockDuration,
                lastRewardTime: lastRewardTime,
                accRewardPerShare: 0,
                totalStaked: 0,
                active: active
            })
        );
        poolTokenUseCount[stakeToken] += 1;
        poolTokenUseCount[rewardToken] += 1;
        emit PoolAdded(pools.length - 1, stakeToken, rewardToken, rewardPerSecond, startTime, endTime, lockDuration);
    }

    function setPool(
        uint256 pid,
        uint256 rewardPerSecond,
        uint64 startTime,
        uint64 endTime,
        uint64 lockDuration,
        bool active
    ) external onlyOwner {
        require(pid < pools.length, "Bad pid");
        require(endTime > startTime, "Bad time");

        updatePool(pid);
        PoolInfo storage pool = pools[pid];
        if (pool.totalStaked > 0 && lockDuration > pool.lockDuration) {
            revert("Lock increase blocked");
        }
        pool.rewardPerSecond = rewardPerSecond;
        pool.startTime = startTime;
        pool.endTime = endTime;
        pool.lockDuration = lockDuration;
        pool.active = active;
        if (pool.lastRewardTime < startTime) pool.lastRewardTime = startTime;
        if (pool.lastRewardTime > endTime) pool.lastRewardTime = endTime;

        emit PoolUpdated(pid, rewardPerSecond, startTime, endTime, lockDuration, active);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function fundRewards(uint256 pid, uint256 amount) external nonReentrant {
        require(pid < pools.length, "Bad pid");
        require(amount > 0, "Zero amount");
        PoolInfo storage pool = pools[pid];
        uint256 received = _pullToken(pool.rewardToken, msg.sender, amount);
        emit RewardsFunded(pid, msg.sender, received);
    }

    function unlockTime(uint256 pid, address account) external view returns (uint256) {
        require(pid < pools.length, "Bad pid");
        UserInfo memory user = users[pid][account];
        if (user.amount == 0) return 0;
        return uint256(user.unlockAt);
    }

    function pendingReward(uint256 pid, address account) external view returns (uint256) {
        require(pid < pools.length, "Bad pid");
        PoolInfo memory pool = pools[pid];
        UserInfo memory user = users[pid][account];
        uint256 acc = pool.accRewardPerShare;
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
            uint256 toTime = _effectiveTime(pool);
            if (toTime > pool.lastRewardTime) {
                uint256 reward = (toTime - pool.lastRewardTime) * pool.rewardPerSecond;
                acc += (reward * ACC_PRECISION) / pool.totalStaked;
            }
        }
        return ((user.amount * acc) / ACC_PRECISION) - user.rewardDebt + user.unpaidRewards;
    }

    function deposit(uint256 pid, uint256 amount) external nonReentrant whenNotPaused {
        require(pid < pools.length, "Bad pid");
        require(amount > 0, "Zero amount");
        PoolInfo storage pool = pools[pid];
        require(pool.active, "Pool inactive");

        updatePool(pid);
        UserInfo storage user = users[pid][msg.sender];
        _claim(pid, msg.sender, pool, user);

        uint256 received = _pullToken(pool.stakeToken, msg.sender, amount);
        require(received > 0, "No tokens received");

        user.amount += received;
        user.lastDepositTime = uint64(block.timestamp);
        uint64 newUnlockAt = uint64(block.timestamp + pool.lockDuration);
        if (newUnlockAt > user.unlockAt) user.unlockAt = newUnlockAt;
        pool.totalStaked += received;
        totalStakedByToken[address(pool.stakeToken)] += received;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;

        emit Deposit(msg.sender, pid, received);
        emit DepositAccounted(msg.sender, pid, amount, received);
    }

    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        require(pid < pools.length, "Bad pid");
        PoolInfo storage pool = pools[pid];
        UserInfo storage user = users[pid][msg.sender];
        require(user.amount >= amount, "Insufficient stake");
        require(block.timestamp >= uint256(user.unlockAt), "Locked");

        updatePool(pid);
        _claim(pid, msg.sender, pool, user);

        if (amount > 0) {
            user.amount -= amount;
            pool.totalStaked -= amount;
            totalStakedByToken[address(pool.stakeToken)] -= amount;
            pool.stakeToken.safeTransfer(msg.sender, amount);
            emit Withdraw(msg.sender, pid, amount);
        }
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;
    }

    function claim(uint256 pid) external nonReentrant {
        require(pid < pools.length, "Bad pid");
        PoolInfo storage pool = pools[pid];
        UserInfo storage user = users[pid][msg.sender];
        updatePool(pid);
        _claim(pid, msg.sender, pool, user);
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;
    }

    function emergencyWithdraw(uint256 pid) external nonReentrant {
        require(pid < pools.length, "Bad pid");
        PoolInfo storage pool = pools[pid];
        UserInfo storage user = users[pid][msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "Nothing staked");

        user.amount = 0;
        user.rewardDebt = 0;
        user.unpaidRewards = 0;
        user.lastDepositTime = 0;
        user.unlockAt = 0;
        pool.totalStaked -= amount;
        totalStakedByToken[address(pool.stakeToken)] -= amount;
        pool.stakeToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, pid, amount);
    }

    function updatePool(uint256 pid) public {
        require(pid < pools.length, "Bad pid");
        PoolInfo storage pool = pools[pid];
        uint256 toTime = _effectiveTime(pool);
        if (toTime <= pool.lastRewardTime) return;
        if (pool.totalStaked == 0) {
            pool.lastRewardTime = uint64(toTime);
            return;
        }

        uint256 reward = (toTime - pool.lastRewardTime) * pool.rewardPerSecond;
        pool.accRewardPerShare += (reward * ACC_PRECISION) / pool.totalStaked;
        pool.lastRewardTime = uint64(toTime);
    }

    function rewardAvailable(uint256 pid) public view returns (uint256) {
        require(pid < pools.length, "Bad pid");
        PoolInfo memory pool = pools[pid];
        address rewardToken = address(pool.rewardToken);
        uint256 balance = pool.rewardToken.balanceOf(address(this));
        uint256 reservedPrincipal = totalStakedByToken[rewardToken];
        if (balance <= reservedPrincipal) return 0;
        return balance - reservedPrincipal;
    }

    function recoverWrongToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
        require(poolTokenUseCount[token] == 0, "Pool token protected");
        IERC20(token).safeTransfer(to, amount);
        emit RescueToken(token, to, amount);
    }

    function _claim(uint256 pid, address account, PoolInfo storage pool, UserInfo storage user) internal {
        uint256 accrued = ((user.amount * pool.accRewardPerShare) / ACC_PRECISION) - user.rewardDebt;
        uint256 totalDue = accrued + user.unpaidRewards;
        if (totalDue == 0) return;

        uint256 available = rewardAvailable(pid);
        uint256 pay = totalDue > available ? available : totalDue;
        user.unpaidRewards = totalDue - pay;

        if (pay > 0) {
            pool.rewardToken.safeTransfer(account, pay);
            emit Claim(account, pid, pay);
        }
        if (user.unpaidRewards > 0) {
            emit RewardCarriedForward(account, pid, user.unpaidRewards);
        }
    }

    function _pullToken(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        require(afterBalance >= beforeBalance, "Bad token balance");
        received = afterBalance - beforeBalance;
    }

    function _effectiveTime(PoolInfo memory pool) internal view returns (uint256) {
        if (block.timestamp < pool.startTime) return pool.startTime;
        return block.timestamp < pool.endTime ? block.timestamp : pool.endTime;
    }
}
