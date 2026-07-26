// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IStakeAdapter
/// @notice Uniform read-only view over a single staking source, exposing the
///         amount of a user's stake that counts toward on-chain voting power.
///         Each source (CREPE staking vault now, the team's future TART vault
///         later) is fronted by its own adapter so the WeeklyBuybackVote can
///         aggregate heterogeneous stakes behind one interface with per-source
///         weights.
interface IStakeAdapter {
    /// @notice The user's votable staked balance in this source's own units,
    ///         counting ONLY stake that is committed (non-exitable) until at
    ///         least `minCommitUntil`.
    /// @dev    Anti-flash-loan invariant: stake that the user could withdraw
    ///         before `minCommitUntil` MUST NOT be counted. The vote contract
    ///         passes the voting epoch's end timestamp, so same-block or
    ///         freely-exitable ("flexible") stake is worth zero voting power.
    ///         MUST be a pure view; the vote contract multiplies this by the
    ///         source's configured weight. Returning 0 for an unknown user is
    ///         expected.
    /// @param user           the voter being weighed.
    /// @param minCommitUntil timestamp the stake must remain locked through.
    function votingStakeOf(address user, uint256 minCommitUntil) external view returns (uint256);
}
