// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2RouterLikeV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IWBNB {
    function deposit() external payable;
}

/**
 * @title TartFeeConverterV2
 * @notice Semi-automatic fee converter that can handle ERC20 fees and native BNB fees.
 * @dev Native BNB is wrapped to WBNB before routing through the owner-approved path.
 */
contract TartFeeConverterV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2RouterLikeV2 public router;
    address public immutable WBNB;
    address public rewardToken;
    address public rewardReceiver;
    uint256 public maxSlippageBps = 100;
    uint256 public minConvertAmount;

    mapping(address => bool) public allowedInputToken;
    mapping(bytes32 => bool) public allowedPath;

    event RouterUpdated(address indexed router);
    event RewardConfigUpdated(address indexed rewardToken, address indexed rewardReceiver);
    event AllowedInputTokenUpdated(address indexed token, bool allowed);
    event AllowedPathUpdated(bytes32 indexed pathHash, address indexed inputToken, bool allowed);
    event RiskConfigUpdated(uint256 maxSlippageBps, uint256 minConvertAmount);
    event Converted(address indexed inputToken, uint256 amountIn, uint256 minOut, address indexed rewardReceiver);
    event NativeConverted(uint256 amountIn, uint256 minOut, address indexed rewardReceiver);
    event RewardForwarded(uint256 amount, address indexed rewardReceiver);
    event NativeRescued(address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address router_,
        address wbnb_,
        address rewardToken_,
        address rewardReceiver_
    ) Ownable(initialOwner) {
        require(router_ != address(0) && wbnb_ != address(0) && rewardToken_ != address(0) && rewardReceiver_ != address(0), "Zero address");
        router = IUniswapV2RouterLikeV2(router_);
        WBNB = wbnb_;
        rewardToken = rewardToken_;
        rewardReceiver = rewardReceiver_;
    }

    receive() external payable {}

    function setRouter(address router_) external onlyOwner {
        require(router_ != address(0), "Zero router");
        router = IUniswapV2RouterLikeV2(router_);
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
        minOut = _minOut(expectedOut);
    }

    function convert(address inputToken, uint256 amountIn, uint256 minOut, address[] calldata path, uint256 deadline) external onlyOwner nonReentrant whenNotPaused {
        require(allowedInputToken[inputToken], "Input not allowed");
        require(amountIn >= minConvertAmount, "Below threshold");
        _validatePath(inputToken, path);
        _swapToken(inputToken, amountIn, minOut, path, deadline);
        emit Converted(inputToken, amountIn, minOut, rewardReceiver);
    }

    function convertWithConfiguredSlippage(address inputToken, uint256 amountIn, address[] calldata path, uint256 deadline) external nonReentrant whenNotPaused {
        require(allowedInputToken[inputToken], "Input not allowed");
        require(amountIn >= minConvertAmount, "Below threshold");
        _validatePath(inputToken, path);
        require(allowedPath[getPathHash(path)], "Path not allowed");
        uint[] memory amounts = router.getAmountsOut(amountIn, path);
        uint256 minOut = _minOut(amounts[amounts.length - 1]);
        _swapToken(inputToken, amountIn, minOut, path, deadline);
        emit Converted(inputToken, amountIn, minOut, rewardReceiver);
    }

    function convertNativeWithConfiguredSlippage(uint256 amountIn, address[] calldata path, uint256 deadline) external nonReentrant whenNotPaused {
        require(allowedInputToken[WBNB], "Input not allowed");
        require(amountIn > 0 && amountIn <= address(this).balance, "Bad amount");
        require(amountIn >= minConvertAmount, "Below threshold");
        _validatePath(WBNB, path);
        require(allowedPath[getPathHash(path)], "Path not allowed");

        IWBNB(WBNB).deposit{value: amountIn}();
        uint[] memory amounts = router.getAmountsOut(amountIn, path);
        uint256 minOut = _minOut(amounts[amounts.length - 1]);
        _swapToken(WBNB, amountIn, minOut, path, deadline);
        emit NativeConverted(amountIn, minOut, rewardReceiver);
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

    function rescueNative(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero receiver");
        require(amount <= address(this).balance, "Insufficient native");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Native transfer failed");
        emit NativeRescued(to, amount);
    }

    function getPathHash(address[] calldata path) public pure returns (bytes32) {
        return keccak256(abi.encode(path));
    }

    function _swapToken(address inputToken, uint256 amountIn, uint256 minOut, address[] calldata path, uint256 deadline) internal {
        IERC20(inputToken).forceApprove(address(router), 0);
        IERC20(inputToken).forceApprove(address(router), amountIn);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, minOut, path, rewardReceiver, deadline);
    }

    function _minOut(uint256 expectedOut) internal view returns (uint256) {
        return expectedOut * (10_000 - maxSlippageBps) / 10_000;
    }

    function _validatePath(address inputToken, address[] calldata path) internal view {
        require(path.length >= 2 && path[0] == inputToken && path[path.length - 1] == rewardToken, "Bad path");
    }
}
