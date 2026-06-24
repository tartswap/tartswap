// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPancakeRouterV2 {
    function WETH() external pure returns (address);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

/**
 * @title TartSwapRouterV2
 * @notice PancakeSwap V2 wrapper for swaps and liquidity operations with transparent TartSwap fee routing.
 * @dev The wrapper never stores user principal intentionally. Swap fees are taken from the actual input amount received,
 *      which makes the accounting safer for fee-on-transfer input tokens. Dedicated supporting-fee-on-transfer swap
 *      functions are included for taxed BSC tokens.
 */
contract TartSwapRouterV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_SWAP_FEE_BPS = 300; // 3% hard cap

    IPancakeRouterV2 public immutable pancakeRouter;
    address public immutable WBNB;
    address public feeDistributor;
    uint16 public swapFeeBps;

    mapping(address => bool) public customFeeEnabled;
    mapping(address => uint16) public customFeeBps;

    // Fee type: 0 default/legacy, 1 aggregator, 2 market maker, 3 whale, 4 partner.
    // expiresAt = 0 means no expiry. Existing legacy mappings remain for backwards compatibility.
    struct CustomFeeInfo {
        bool enabled;
        uint16 feeBps;
        uint8 feeType;
        uint64 expiresAt;
    }

    mapping(address => CustomFeeInfo) public customFeeInfo;

    struct LiquidityAddCache {
        uint256 beforeA;
        uint256 beforeB;
        uint256 receivedA;
        uint256 receivedB;
    }

    struct SwapExecutionLog {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountInAfterFee;
        uint256 amountOut;
        uint256 feeAmount;
        bool feeOnTransferSupporting;
    }


    event FeeDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event SwapFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event CustomFeeUpdated(address indexed account, bool enabled, uint16 feeBps);
    event CustomFeeUpdatedV2(address indexed account, bool enabled, uint16 feeBps, uint8 feeType, uint64 expiresAt, string reason);
    event FeeTaken(address indexed payer, address indexed token, uint256 feeAmount);
    event FeeTransferAccounted(address indexed payer, address indexed token, uint256 feeAmount, uint256 actualReceivedByDistributor);
    event RouterSwap(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountInAfterFee);
    event RouterSwapAccounted(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountInReceived, uint256 amountInAfterFee, bool feeOnTransferSupporting);
    event TartSwapExecuted(address indexed user, address indexed caller, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountInAfterFee, uint256 amountOut, uint256 feeAmount, uint16 feeBpsApplied, uint8 feeTier, bool feeOnTransferSupporting);
    event LiquidityAdded(address indexed user, address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB, uint256 liquidity, address to);
    event LiquidityRemoved(address indexed user, address indexed tokenA, address indexed tokenB, uint256 liquidity, address to);
    event DustRecovered(address indexed token, address indexed to, uint256 amount);

    constructor(address initialOwner, address pancakeRouter_, address feeDistributor_, uint16 swapFeeBps_) Ownable(initialOwner) {
        require(pancakeRouter_ != address(0) && feeDistributor_ != address(0), "Zero address");
        require(swapFeeBps_ <= MAX_SWAP_FEE_BPS, "Fee too high");
        pancakeRouter = IPancakeRouterV2(pancakeRouter_);
        WBNB = IPancakeRouterV2(pancakeRouter_).WETH();
        feeDistributor = feeDistributor_;
        swapFeeBps = swapFeeBps_;
    }

    receive() external payable {}

    function setFeeDistributor(address newDistributor) external onlyOwner {
        require(newDistributor != address(0), "Zero distributor");
        emit FeeDistributorUpdated(feeDistributor, newDistributor);
        feeDistributor = newDistributor;
    }

    function setSwapFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_SWAP_FEE_BPS, "Fee too high");
        emit SwapFeeUpdated(swapFeeBps, newFeeBps);
        swapFeeBps = newFeeBps;
    }

    /**
     * @notice Sets a custom fee for trusted integrations.
     * @dev Backwards-compatible setter. Use setCustomFeeWithExpiry for aggregator/MM/partner expiry metadata.
     */
    function setCustomFee(address account, bool enabled, uint16 feeBps) external onlyOwner {
        _setLegacyCustomFee(account, enabled, feeBps);
    }

    /**
     * @notice Sets a custom fee with type and expiry for aggregators, market makers, whales and partners.
     * @param feeType 1=aggregator, 2=market maker, 3=whale, 4=partner, 0=legacy/default metadata.
     * @param expiresAt Unix timestamp. 0 means no automatic expiry.
     */
    function setCustomFeeWithExpiry(address account, bool enabled, uint16 feeBps, uint8 feeType, uint64 expiresAt, string calldata reason) external onlyOwner {
        require(feeType <= 4, "Bad fee type");
        _setCustomFeeInfo(account, enabled, feeBps, feeType, expiresAt, reason);
    }

    function _setLegacyCustomFee(address account, bool enabled, uint16 feeBps) internal {
        require(account != address(0), "Zero account");
        require(feeBps <= MAX_SWAP_FEE_BPS, "Fee too high");
        customFeeEnabled[account] = enabled;
        customFeeBps[account] = feeBps;
        customFeeInfo[account] = CustomFeeInfo(enabled, feeBps, 0, 0);
        emit CustomFeeUpdated(account, enabled, feeBps);
        emit CustomFeeUpdatedV2(account, enabled, feeBps, 0, 0, "legacy");
    }

    function _setCustomFeeInfo(address account, bool enabled, uint16 feeBps, uint8 feeType, uint64 expiresAt, string memory reason) internal {
        require(account != address(0), "Zero account");
        require(feeBps <= MAX_SWAP_FEE_BPS, "Fee too high");
        if (!enabled) {
            customFeeEnabled[account] = false;
            customFeeBps[account] = 0;
        }
        customFeeInfo[account] = CustomFeeInfo(enabled, feeBps, feeType, expiresAt);
        emit CustomFeeUpdatedV2(account, enabled, feeBps, feeType, expiresAt, reason);
    }

    function _isCustomFeeInfoConfigured(CustomFeeInfo memory info) internal pure returns (bool) {
        return info.enabled || info.feeBps != 0 || info.feeType != 0 || info.expiresAt != 0;
    }

    function _isCustomFeeActive(CustomFeeInfo memory info) internal view returns (bool) {
        return info.enabled && (info.expiresAt == 0 || block.timestamp < uint256(info.expiresAt));
    }

    function effectiveFeeBps(address account) public view returns (uint16) {
        CustomFeeInfo memory info = customFeeInfo[account];
        if (_isCustomFeeActive(info)) return info.feeBps;
        if (_isCustomFeeInfoConfigured(info)) return swapFeeBps;
        if (customFeeEnabled[account]) return customFeeBps[account];
        return swapFeeBps;
    }

    function effectiveFeeType(address account) public view returns (uint8) {
        CustomFeeInfo memory info = customFeeInfo[account];
        if (_isCustomFeeActive(info)) return info.feeType;
        if (_isCustomFeeInfoConfigured(info)) return 0;
        return 0;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint[] memory amounts) {
        _validatePath(path, to);
        uint256 received = _pullToken(IERC20(path[0]), msg.sender, amountIn);
        (uint256 fee, uint256 net) = _takeTokenFee(path[0], received, msg.sender);
        _approveRouter(path[0], net);
        amounts = pancakeRouter.swapExactTokensForTokens(net, amountOutMin, path, to, deadline);
        uint256 amountOut = amounts.length > 0 ? amounts[amounts.length - 1] : 0;
        emit RouterSwap(msg.sender, path[0], path[path.length - 1], net);
        emit RouterSwapAccounted(msg.sender, path[0], path[path.length - 1], received, net, false);
        _emitTartSwapExecuted(SwapExecutionLog({
            user: msg.sender,
            tokenIn: path[0],
            tokenOut: path[path.length - 1],
            amountIn: received,
            amountInAfterFee: net,
            amountOut: amountOut,
            feeAmount: fee,
            feeOnTransferSupporting: false
        }));
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint[] memory amounts) {
        require(path.length >= 2 && path[0] == WBNB, "Bad path");
        require(to != address(0), "Zero receiver");
        (uint256 fee, uint256 net) = _splitFee(msg.value, msg.sender);
        require(net > 0, "Amount too small");
        if (fee > 0) {
            _sendNative(feeDistributor, fee);
            emit FeeTaken(msg.sender, address(0), fee);
            emit FeeTransferAccounted(msg.sender, address(0), fee, fee);
        }
        amounts = pancakeRouter.swapExactETHForTokens{value: net}(amountOutMin, path, to, deadline);
        uint256 amountOut = amounts.length > 0 ? amounts[amounts.length - 1] : 0;
        emit RouterSwap(msg.sender, address(0), path[path.length - 1], net);
        emit RouterSwapAccounted(msg.sender, address(0), path[path.length - 1], msg.value, net, false);
        _emitTartSwapExecuted(SwapExecutionLog({
            user: msg.sender,
            tokenIn: address(0),
            tokenOut: path[path.length - 1],
            amountIn: msg.value,
            amountInAfterFee: net,
            amountOut: amountOut,
            feeAmount: fee,
            feeOnTransferSupporting: false
        }));
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint[] memory amounts) {
        require(path.length >= 2 && path[path.length - 1] == WBNB, "Bad path");
        require(to != address(0), "Zero receiver");
        uint256 received = _pullToken(IERC20(path[0]), msg.sender, amountIn);
        (uint256 fee, uint256 net) = _takeTokenFee(path[0], received, msg.sender);
        _approveRouter(path[0], net);
        amounts = pancakeRouter.swapExactTokensForETH(net, amountOutMin, path, to, deadline);
        uint256 amountOut = amounts.length > 0 ? amounts[amounts.length - 1] : 0;
        emit RouterSwap(msg.sender, path[0], address(0), net);
        emit RouterSwapAccounted(msg.sender, path[0], address(0), received, net, false);
        _emitTartSwapExecuted(SwapExecutionLog({
            user: msg.sender,
            tokenIn: path[0],
            tokenOut: address(0),
            amountIn: received,
            amountInAfterFee: net,
            amountOut: amountOut,
            feeAmount: fee,
            feeOnTransferSupporting: false
        }));
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        _validatePath(path, to);
        uint256 received = _pullToken(IERC20(path[0]), msg.sender, amountIn);
        (uint256 fee, uint256 net) = _takeTokenFee(path[0], received, msg.sender);
        _approveRouter(path[0], net);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(net, amountOutMin, path, to, deadline);
        emit RouterSwap(msg.sender, path[0], path[path.length - 1], net);
        emit RouterSwapAccounted(msg.sender, path[0], path[path.length - 1], received, net, true);
        _emitTartSwapExecuted(SwapExecutionLog({
            user: msg.sender,
            tokenIn: path[0],
            tokenOut: path[path.length - 1],
            amountIn: received,
            amountInAfterFee: net,
            amountOut: 0,
            feeAmount: fee,
            feeOnTransferSupporting: true
        }));
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused {
        require(path.length >= 2 && path[0] == WBNB, "Bad path");
        require(to != address(0), "Zero receiver");
        (uint256 fee, uint256 net) = _splitFee(msg.value, msg.sender);
        require(net > 0, "Amount too small");
        if (fee > 0) {
            _sendNative(feeDistributor, fee);
            emit FeeTaken(msg.sender, address(0), fee);
            emit FeeTransferAccounted(msg.sender, address(0), fee, fee);
        }
        pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: net}(amountOutMin, path, to, deadline);
        emit RouterSwap(msg.sender, address(0), path[path.length - 1], net);
        emit RouterSwapAccounted(msg.sender, address(0), path[path.length - 1], msg.value, net, true);
        _emitTartSwapExecuted(SwapExecutionLog({
            user: msg.sender,
            tokenIn: address(0),
            tokenOut: path[path.length - 1],
            amountIn: msg.value,
            amountInAfterFee: net,
            amountOut: 0,
            feeAmount: fee,
            feeOnTransferSupporting: true
        }));
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(path.length >= 2 && path[path.length - 1] == WBNB, "Bad path");
        require(to != address(0), "Zero receiver");
        uint256 received = _pullToken(IERC20(path[0]), msg.sender, amountIn);
        (uint256 fee, uint256 net) = _takeTokenFee(path[0], received, msg.sender);
        _approveRouter(path[0], net);
        pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(net, amountOutMin, path, to, deadline);
        emit RouterSwap(msg.sender, path[0], address(0), net);
        emit RouterSwapAccounted(msg.sender, path[0], address(0), received, net, true);
        _emitTartSwapExecuted(SwapExecutionLog({
            user: msg.sender,
            tokenIn: path[0],
            tokenOut: address(0),
            amountIn: received,
            amountInAfterFee: net,
            amountOut: 0,
            feeAmount: fee,
            feeOnTransferSupporting: true
        }));
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external nonReentrant whenNotPaused returns (uint amountA, uint amountB, uint liquidity) {
        require(tokenA != address(0) && tokenB != address(0), "Zero token");
        require(tokenA != tokenB, "Same token");
        require(to != address(0), "Zero receiver");
        LiquidityAddCache memory cache;
        cache.beforeA = IERC20(tokenA).balanceOf(address(this));
        cache.beforeB = IERC20(tokenB).balanceOf(address(this));
        cache.receivedA = _pullToken(IERC20(tokenA), msg.sender, amountADesired);
        cache.receivedB = _pullToken(IERC20(tokenB), msg.sender, amountBDesired);
        _approveRouter(tokenA, cache.receivedA);
        _approveRouter(tokenB, cache.receivedB);
        (amountA, amountB, liquidity) = pancakeRouter.addLiquidity(tokenA, tokenB, cache.receivedA, cache.receivedB, amountAMin, amountBMin, to, deadline);
        _refundTokenDelta(tokenA, cache.beforeA);
        _refundTokenDelta(tokenB, cache.beforeB);
        emit LiquidityAdded(msg.sender, tokenA, tokenB, amountA, amountB, liquidity, to);
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable nonReentrant whenNotPaused returns (uint amountToken, uint amountETH, uint liquidity) {
        require(token != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
        uint256 beforeToken = IERC20(token).balanceOf(address(this));
        uint256 receivedToken = _pullToken(IERC20(token), msg.sender, amountTokenDesired);
        _approveRouter(token, receivedToken);
        (amountToken, amountETH, liquidity) = pancakeRouter.addLiquidityETH{value: msg.value}(token, receivedToken, amountTokenMin, amountETHMin, to, deadline);
        _refundTokenDelta(token, beforeToken);
        if (msg.value > amountETH) _sendNative(msg.sender, msg.value - amountETH);
        emit LiquidityAdded(msg.sender, token, WBNB, amountToken, amountETH, liquidity, to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        address lpToken,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external nonReentrant whenNotPaused returns (uint amountA, uint amountB) {
        require(tokenA != address(0) && tokenB != address(0) && lpToken != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
        uint256 receivedLiquidity = _pullToken(IERC20(lpToken), msg.sender, liquidity);
        _approveRouter(lpToken, receivedLiquidity);
        (amountA, amountB) = pancakeRouter.removeLiquidity(tokenA, tokenB, receivedLiquidity, amountAMin, amountBMin, to, deadline);
        emit LiquidityRemoved(msg.sender, tokenA, tokenB, receivedLiquidity, to);
    }

    function removeLiquidityETH(
        address token,
        address lpToken,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external nonReentrant whenNotPaused returns (uint amountToken, uint amountETH) {
        require(token != address(0) && lpToken != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
        uint256 receivedLiquidity = _pullToken(IERC20(lpToken), msg.sender, liquidity);
        _approveRouter(lpToken, receivedLiquidity);
        (amountToken, amountETH) = pancakeRouter.removeLiquidityETH(token, receivedLiquidity, amountTokenMin, amountETHMin, to, deadline);
        emit LiquidityRemoved(msg.sender, token, WBNB, receivedLiquidity, to);
    }

    function recoverDust(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero receiver");
        if (token == address(0)) {
            _sendNative(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit DustRecovered(token, to, amount);
    }

    function _validatePath(address[] calldata path, address to) internal pure {
        require(path.length >= 2, "Bad path");
        require(path[0] != address(0) && path[path.length - 1] != address(0), "Zero token");
        require(to != address(0), "Zero receiver");
    }

    function _pullToken(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        require(amount > 0, "Zero amount");
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        require(afterBalance >= beforeBalance, "Bad token balance");
        received = afterBalance - beforeBalance;
        require(received > 0, "No tokens received");
    }

    function _takeTokenFee(address token, uint256 received, address payer) internal returns (uint256 fee, uint256 net) {
        (fee, net) = _splitFee(received, payer);
        require(net > 0, "Amount too small");
        if (fee > 0) {
            IERC20 feeToken = IERC20(token);
            uint256 beforeBalance = feeToken.balanceOf(feeDistributor);
            feeToken.safeTransfer(feeDistributor, fee);
            uint256 afterBalance = feeToken.balanceOf(feeDistributor);
            uint256 actualReceived = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
            emit FeeTaken(payer, token, fee);
            emit FeeTransferAccounted(payer, token, fee, actualReceived);
        }
    }

    function _splitFee(uint256 amount, address payer) internal view returns (uint256 fee, uint256 net) {
        fee = (amount * effectiveFeeBps(payer)) / BPS_DENOMINATOR;
        net = amount - fee;
    }

    function _approveRouter(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(pancakeRouter), amount);
    }

    function _refundToken(address token, uint256 amount) internal {
        if (amount > 0) IERC20(token).safeTransfer(msg.sender, amount);
    }

    function _refundTokenDelta(address token, uint256 beforeBalance) internal {
        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        if (currentBalance > beforeBalance) {
            _refundToken(token, currentBalance - beforeBalance);
        }
    }

    function _emitTartSwapExecuted(SwapExecutionLog memory log) internal {
        uint16 feeBpsApplied = effectiveFeeBps(log.user);
        uint8 feeTier = effectiveFeeType(log.user);

        emit TartSwapExecuted(
            log.user,
            msg.sender,
            log.tokenIn,
            log.tokenOut,
            log.amountIn,
            log.amountInAfterFee,
            log.amountOut,
            log.feeAmount,
            feeBpsApplied,
            feeTier,
            log.feeOnTransferSupporting
        );
    }

    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Native transfer failed");
    }
}
