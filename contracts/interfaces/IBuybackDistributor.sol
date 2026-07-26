// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBuybackDistributor {
    /// @notice Pulls `amount` of `token` from the caller and books it for a future buyback+burn.
    /// @dev Caller must have approved this contract for at least `amount`.
    function accrue(address token, uint256 amount) external;

    /// @notice Permissionless daily buyback: swaps accrued `collateral` into the target token and burns it.
    function executeDailyBuyback(address collateral) external;

    function targetToken() external view returns (address);

    function accruedTotal(address token) external view returns (uint256);

    function isCollateral(address token) external view returns (bool);
}
