// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TartFeeDistributor
 * @notice Receives TartSwap protocol fees and splits them between treasury,
 * farm rewards, staking rewards and reserve/buyback wallets.
 * @dev This contract does not custody user principal. It only holds protocol fees
 * until anyone calls distributeToken/distributeNative.
 */
contract TartFeeDistributor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct SplitConfig {
        address treasury;
        address farmRewards;
        address stakingRewards;
        address reserve;
        uint16 treasuryBps;
        uint16 farmBps;
        uint16 stakingBps;
        uint16 reserveBps;
    }

    SplitConfig public split;

    event SplitUpdated(
        address indexed treasury,
        address indexed farmRewards,
        address indexed stakingRewards,
        address reserve,
        uint16 treasuryBps,
        uint16 farmBps,
        uint16 stakingBps,
        uint16 reserveBps
    );
    event TokenDistributed(address indexed token, uint256 amount, uint256 treasuryAmount, uint256 farmAmount, uint256 stakingAmount, uint256 reserveAmount);
    event NativeDistributed(uint256 amount, uint256 treasuryAmount, uint256 farmAmount, uint256 stakingAmount, uint256 reserveAmount);
    event FeesDistributed(address indexed token, uint256 amount, uint256 treasuryAmount, uint256 farmAmount, uint256 stakingAmount, uint256 reserveAmount);

    constructor(
        address initialOwner,
        address treasury_,
        address farmRewards_,
        address stakingRewards_,
        address reserve_
    ) Ownable(initialOwner) {
        _setSplit(treasury_, farmRewards_, stakingRewards_, reserve_, 4000, 3000, 2000, 1000);
    }

    receive() external payable {}

    function setSplit(
        address treasury_,
        address farmRewards_,
        address stakingRewards_,
        address reserve_,
        uint16 treasuryBps_,
        uint16 farmBps_,
        uint16 stakingBps_,
        uint16 reserveBps_
    ) external onlyOwner {
        _setSplit(treasury_, farmRewards_, stakingRewards_, reserve_, treasuryBps_, farmBps_, stakingBps_, reserveBps_);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function distributeToken(address token) external nonReentrant whenNotPaused {
        uint256 amount = IERC20(token).balanceOf(address(this));
        require(amount > 0, "No token fees");
        (uint256 t, uint256 f, uint256 s, uint256 r) = _splitAmounts(amount);
        if (t > 0) IERC20(token).safeTransfer(split.treasury, t);
        if (f > 0) IERC20(token).safeTransfer(split.farmRewards, f);
        if (s > 0) IERC20(token).safeTransfer(split.stakingRewards, s);
        if (r > 0) IERC20(token).safeTransfer(split.reserve, r);
        emit TokenDistributed(token, amount, t, f, s, r);
        emit FeesDistributed(token, amount, t, f, s, r);
    }

    function distributeNative() external nonReentrant whenNotPaused {
        uint256 amount = address(this).balance;
        require(amount > 0, "No native fees");
        (uint256 t, uint256 f, uint256 s, uint256 r) = _splitAmounts(amount);
        _sendNative(split.treasury, t);
        _sendNative(split.farmRewards, f);
        _sendNative(split.stakingRewards, s);
        _sendNative(split.reserve, r);
        emit NativeDistributed(amount, t, f, s, r);
        emit FeesDistributed(address(0), amount, t, f, s, r);
    }

    function _setSplit(
        address treasury_,
        address farmRewards_,
        address stakingRewards_,
        address reserve_,
        uint16 treasuryBps_,
        uint16 farmBps_,
        uint16 stakingBps_,
        uint16 reserveBps_
    ) internal {
        require(treasury_ != address(0) && farmRewards_ != address(0) && stakingRewards_ != address(0) && reserve_ != address(0), "Zero recipient");
        require(uint256(treasuryBps_) + farmBps_ + stakingBps_ + reserveBps_ == BPS_DENOMINATOR, "Bad split");
        split = SplitConfig(treasury_, farmRewards_, stakingRewards_, reserve_, treasuryBps_, farmBps_, stakingBps_, reserveBps_);
        emit SplitUpdated(treasury_, farmRewards_, stakingRewards_, reserve_, treasuryBps_, farmBps_, stakingBps_, reserveBps_);
    }

    function _splitAmounts(uint256 amount) internal view returns (uint256 t, uint256 f, uint256 s, uint256 r) {
        t = amount * split.treasuryBps / BPS_DENOMINATOR;
        f = amount * split.farmBps / BPS_DENOMINATOR;
        s = amount * split.stakingBps / BPS_DENOMINATOR;
        r = amount - t - f - s;
    }

    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Native transfer failed");
    }
}
