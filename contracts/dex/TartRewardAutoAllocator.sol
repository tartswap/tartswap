// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITartRewardFundable {
    function fundRewards(uint256 pid, uint256 amount) external;
}

/**
 * @title TartRewardAutoAllocator
 * @notice Routes protocol-owned reward tokens into TartSwap farm/staking reward pools.
 * @dev The allocator is intentionally triggerable by anyone. It never mints rewards;
 *      it only forwards reward tokens already received from fees, converters or treasury.
 */
contract TartRewardAutoAllocator is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct Lane {
        address target;
        uint256 pid;
        uint16 bps;
        bool active;
    }

    IERC20 public immutable rewardToken;
    uint256 public minAllocationAmount;
    Lane[] public lanes;

    event LaneAdded(uint256 indexed laneId, address indexed target, uint256 indexed pid, uint16 bps, bool active);
    event LaneUpdated(uint256 indexed laneId, address indexed target, uint256 indexed pid, uint16 bps, bool active);
    event MinAllocationAmountUpdated(uint256 amount);
    event RewardsAllocated(address indexed caller, uint256 totalAmount, uint256 activeBps);
    event LaneFunded(uint256 indexed laneId, address indexed target, uint256 indexed pid, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    constructor(address initialOwner, address rewardToken_, uint256 minAllocationAmount_) Ownable(initialOwner) {
        require(rewardToken_ != address(0), "Zero reward token");
        rewardToken = IERC20(rewardToken_);
        minAllocationAmount = minAllocationAmount_;
    }

    function laneLength() external view returns (uint256) {
        return lanes.length;
    }

    function addLane(address target, uint256 pid, uint16 bps, bool active) external onlyOwner {
        _validateLane(target, bps);
        lanes.push(Lane({target: target, pid: pid, bps: bps, active: active}));
        emit LaneAdded(lanes.length - 1, target, pid, bps, active);
        _requireActiveBpsNotOver();
    }

    function setLane(uint256 laneId, address target, uint256 pid, uint16 bps, bool active) external onlyOwner {
        require(laneId < lanes.length, "Bad lane");
        _validateLane(target, bps);
        lanes[laneId] = Lane({target: target, pid: pid, bps: bps, active: active});
        emit LaneUpdated(laneId, target, pid, bps, active);
        _requireActiveBpsNotOver();
    }

    function setMinAllocationAmount(uint256 amount) external onlyOwner {
        minAllocationAmount = amount;
        emit MinAllocationAmountUpdated(amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function activeBps() public view returns (uint256 total) {
        for (uint256 i = 0; i < lanes.length; i++) {
            if (lanes[i].active) total += lanes[i].bps;
        }
    }

    function pendingAllocation() external view returns (uint256 balance, uint256 totalActiveBps) {
        balance = rewardToken.balanceOf(address(this));
        totalActiveBps = activeBps();
    }

    function allocate() external nonReentrant whenNotPaused {
        uint256 total = rewardToken.balanceOf(address(this));
        require(total >= minAllocationAmount && total > 0, "Below allocation threshold");

        uint256 totalActiveBps = activeBps();
        require(totalActiveBps == BPS_DENOMINATOR, "Bad active bps");

        uint256 allocated;
        uint256 lastActiveLane = _lastActiveLane();
        for (uint256 i = 0; i < lanes.length; i++) {
            Lane memory lane = lanes[i];
            if (!lane.active) continue;

            uint256 amount = i == lastActiveLane
                ? total - allocated
                : (total * lane.bps) / BPS_DENOMINATOR;
            if (amount == 0) continue;

            allocated += amount;
            rewardToken.forceApprove(lane.target, 0);
            rewardToken.forceApprove(lane.target, amount);
            ITartRewardFundable(lane.target).fundRewards(lane.pid, amount);
            emit LaneFunded(i, lane.target, lane.pid, amount);
        }

        emit RewardsAllocated(msg.sender, allocated, totalActiveBps);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
        IERC20(token).safeTransfer(to, amount);
        emit RescueToken(token, to, amount);
    }

    function _validateLane(address target, uint16 bps) internal pure {
        require(target != address(0), "Zero target");
        require(bps <= BPS_DENOMINATOR, "Bps too high");
    }

    function _requireActiveBpsNotOver() internal view {
        uint256 total = activeBps();
        require(total <= BPS_DENOMINATOR, "Active bps over 10000");
    }

    function _lastActiveLane() internal view returns (uint256 laneId) {
        bool found;
        for (uint256 i = 0; i < lanes.length; i++) {
            if (lanes[i].active) {
                laneId = i;
                found = true;
            }
        }
        require(found, "No active lanes");
    }
}
