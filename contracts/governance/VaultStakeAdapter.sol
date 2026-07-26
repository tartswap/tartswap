// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStakeAdapter} from "./IStakeAdapter.sol";

/// @notice The subset of TartStakingVault this adapter reads. The vault (see
///         repo-root `contracts/TartStakingVault.sol`, solc 0.8.20) lives
///         OUTSIDE this Hardhat project's source tree, so its position model is
///         re-declared here rather than imported. Only the field LAYOUT matters
///         for ABI-decoding `getUserPositions`; the names are cosmetic.
///
///         A user holds an array of positions. A position's `amount` is its
///         current staked principal; on withdrawal the vault zeroes `amount`
///         AND flips `withdrawn`, so an "active" stake is any position with
///         `withdrawn == false`. `weightedAmount` (the lock-multiplier-boosted
///         figure the vault uses for reward accounting) is deliberately IGNORED
///         here — voting power is measured on raw principal, not reward weight.
struct VaultPosition {
    uint256 amount;
    uint256 weightedAmount;
    uint256 rewardDebt;
    uint256 unpaidReward;
    uint64 startTime;
    uint64 lockEndTime;
    uint64 lastHarvestTime;
    uint8 lockType;
    // Per-position emergency-penalty snapshot the vault added in its hardening
    // pass; it sits BEFORE `withdrawn` in the vault's Position layout, so it
    // MUST be present here or the `getUserPositions` ABI-decode shifts by one
    // word and reads `maxPenaltyBps` into `withdrawn` (Panic 0x21). Value is
    // IGNORED for voting — kept only to preserve the field layout.
    uint16 maxPenaltyBps;
    bool withdrawn;
}

interface ITartStakingVault {
    function getUserPositions(address user) external view returns (VaultPosition[] memory);
}

/// @title  VaultStakeAdapter
/// @notice An {IStakeAdapter} that surfaces a user's COMMITTED staked principal
///         in a TartStakingVault as voting stake. The vault exposes no per-user
///         staked-total view (only a global `totalStaked` and the raw position
///         array), so this adapter sums qualifying positions' `amount`.
///
///         ANTI-FLASH-LOAN RULE (H-1): only positions that CANNOT be freely
///         withdrawn before `minCommitUntil` count. Concretely a position must
///         be (a) not withdrawn, (b) a LOCKED tier (`lockType != 0` — the
///         vault's LOCK_FLEXIBLE tier is same-block exitable and therefore
///         worth zero voting power), and (c) locked through the horizon:
///         `lockEndTime >= minCommitUntil`. The vote contract passes the
///         voting epoch's end, so capital rented for one block (stake → vote →
///         withdraw) grants no power.
///
///         Residual: the vault's `emergencyWithdraw` can exit a locked position
///         early, but only at a pro-rata penalty of the tier's `maxPenaltyBps`
///         (5–12%), which makes rented-capital voting strictly unprofitable
///         rather than free; the vault has no penalty-free early exit for
///         locked tiers.
contract VaultStakeAdapter is IStakeAdapter {
    uint8 private constant LOCK_FLEXIBLE = 0;

    /// @notice The staking vault this adapter reads (immutable — one adapter per vault).
    ITartStakingVault public immutable vault;

    error ZeroVault();

    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroVault();
        vault = ITartStakingVault(vault_);
    }

    /// @inheritdoc IStakeAdapter
    /// @dev Sums committed positions' principal. Unbounded in position count,
    ///      but called only in `view` context (no gas-metered writes); a user
    ///      with pathologically many positions only makes THEIR OWN power query
    ///      heavy, never anyone else's vote.
    function votingStakeOf(address user, uint256 minCommitUntil) external view returns (uint256 total) {
        VaultPosition[] memory ps = vault.getUserPositions(user);
        uint256 len = ps.length;
        for (uint256 i = 0; i < len; ++i) {
            VaultPosition memory p = ps[i];
            if (p.withdrawn) continue;
            // Flexible stake is exitable at will (same-block) → zero power.
            if (p.lockType == LOCK_FLEXIBLE) continue;
            // Lock must extend through the required horizon (epoch end).
            if (uint256(p.lockEndTime) < minCommitUntil) continue;
            total += p.amount;
        }
    }
}
