// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal UniswapV2/PancakeSwap-compatible router surface used by BuybackDistributor.
interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
