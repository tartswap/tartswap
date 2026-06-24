// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2RouterLike {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

/**
 * @title TartFeeConverter
 * @notice Semi-automatic reward converter for TartSwap fees.
 * @dev Designed for admin-safe UX: allowlisted input tokens only, owner-approved
 *      keeper paths, slippage guard, preview via getAmountsOut, manual execution,
 *      and emergency pause.
 */
contract TartFeeConverter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2RouterLike public router;
    address public rewardToken;
    address public rewardReceiver;
    uint256 public maxSlippageBps = 100; // 1%
    uint256 public minConvertAmount;

    mapping(address => bool) public allowedInputToken;
    mapping(bytes32 => bool) public allowedPath;

    event RouterUpdated(address indexed router);
    event RewardConfigUpdated(address indexed rewardToken, address indexed rewardReceiver);
    event AllowedInputTokenUpdated(address indexed token, bool allowed);
    event AllowedPathUpdated(bytes32 indexed pathHash, address indexed inputToken, bool allowed);
    event RiskConfigUpdated(uint256 maxSlippageBps, uint256 minConvertAmount);
    event Converted(address indexed inputToken, uint256 amountIn, uint256 minOut, address indexed rewardReceiver);
    event RewardForwarded(uint256 amount, address indexed rewardReceiver);

    constructor(address initialOwner, address router_, address rewardToken_, address rewardReceiver_) Ownable(initialOwner) {
        require(router_ != address(0) && rewardToken_ != address(0) && rewardReceiver_ != address(0), "Zero address");
        router = IUniswapV2RouterLike(router_);
        rewardToken = rewardToken_;
        rewardReceiver = rewardReceiver_;
    }

    function setRouter(address router_) external onlyOwner {
        require(router_ != address(0), "Zero router");
        router = IUniswapV2RouterLike(router_);
        emit RouterUpdated(router_);
    }

    function setRewardConfig(address rewardToken_, address rewardReceiver_) external onlyOwner {
        require(rewardToken_ != address(0) && rewardReceiver_ != address(0), "Zero address");
        rewardToken = rewardToken_;
        rewardReceiver = rewardReceiver_;
        emit RewardConfigUpdated(rewardToken_, rewardReceiver_);
    }

    function setAllowedInputToken(address token, bool allowed) external onlyOwner {
        require(token != address(0), "Zero token");
        allowedInputToken[token] = allowed;
        emit AllowedInputTokenUpdated(token, allowed);
    }

    function setAllowedPath(address[] calldata path, bool allowed) external onlyOwner {
        require(path.length >= 2, "Bad path");
        _validatePath(path[0], path);
        bytes32 pathHash = getPathHash(path);
        allowedPath[pathHash] = allowed;
        emit AllowedPathUpdated(pathHash, path[0], allowed);
    }

    function setRiskConfig(uint256 maxSlippageBps_, uint256 minConvertAmount_) external onlyOwner {
        require(maxSlippageBps_ <= 500, "Slippage too high");
        maxSlippageBps = maxSlippageBps_;
        minConvertAmount = minConvertAmount_;
        emit RiskConfigUpdated(maxSlippageBps_, minConvertAmount_);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function preview(address inputToken, uint256 amountIn, address[] calldata path) external view returns (uint256 expectedOut, uint256 minOut) {
        _validatePath(inputToken, path);
        uint[] memory amounts = router.getAmountsOut(amountIn, path);
        expectedOut = amounts[amounts.length - 1];
        minOut = expectedOut * (10_000 - maxSlippageBps) / 10_000;
    }

    function convert(address inputToken, uint256 amountIn, uint256 minOut, address[] calldata path, uint256 deadline) external onlyOwner nonReentrant whenNotPaused {
        require(allowedInputToken[inputToken], "Input not allowed");
        require(amountIn >= minConvertAmount, "Below threshold");
        _validatePath(inputToken, path);
        IERC20(inputToken).forceApprove(address(router), 0);
        IERC20(inputToken).forceApprove(address(router), amountIn);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, minOut, path, rewardReceiver, deadline);
        emit Converted(inputToken, amountIn, minOut, rewardReceiver);
    }

    function convertWithConfiguredSlippage(address inputToken, uint256 amountIn, address[] calldata path, uint256 deadline) external nonReentrant whenNotPaused {
        require(allowedInputToken[inputToken], "Input not allowed");
        require(amountIn >= minConvertAmount, "Below threshold");
        _validatePath(inputToken, path);
        require(allowedPath[getPathHash(path)], "Path not allowed");
        uint[] memory amounts = router.getAmountsOut(amountIn, path);
        uint256 minOut = amounts[amounts.length - 1] * (10_000 - maxSlippageBps) / 10_000;
        IERC20(inputToken).forceApprove(address(router), 0);
        IERC20(inputToken).forceApprove(address(router), amountIn);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, minOut, path, rewardReceiver, deadline);
        emit Converted(inputToken, amountIn, minOut, rewardReceiver);
    }

    function forwardRewardToken(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        require(amount >= minConvertAmount, "Below threshold");
        IERC20(rewardToken).safeTransfer(rewardReceiver, amount);
        emit RewardForwarded(amount, rewardReceiver);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero receiver");
        IERC20(token).safeTransfer(to, amount);
    }

    function getPathHash(address[] calldata path) public pure returns (bytes32) {
        return keccak256(abi.encode(path));
    }

    function _validatePath(address inputToken, address[] calldata path) internal view {
        require(path.length >= 2 && path[0] == inputToken && path[path.length - 1] == rewardToken, "Bad path");
    }
}
