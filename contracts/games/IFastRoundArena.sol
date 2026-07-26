// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFastRoundArena — integration surface for the parimutuel "Fast Games" engine
///
/// @notice ONE contract type powers EVERY Tart Predict fast game. A game instance is a
///         "round" with 2..16 mutually-exclusive outcomes. Players stake collateral on
///         an outcome before {lockTime}; after {resolveTime} an off-chain keeper (the
///         RESOLVER) submits the single winning outcome; winners split the losers' stake
///         pro-rata to their own stake, minus a flat house fee. The house adds NO
///         liquidity and bears ZERO directional risk — it only ever skims the fee off a
///         two-sided pool. This is PURE PARIMUTUEL, distinct from the CPMM fixed-odds
///         markets and the beta PredictionPool (those are untouched).
///
///         The CONTRACT never fetches data: price / kline / creator outcomes are read
///         off-chain and submitted by the RESOLVER, exactly like the beta resolver model.
interface IFastRoundArena {
    /// @notice Lifecycle of a round.
    ///         None     — never opened (zero slot).
    ///         Open     — accepting stakes until lockTime; awaiting resolution.
    ///         Resolved — a two-sided round settled with a winning outcome + fee; winners
    ///                    claim their pro-rata share of (totalPool - fee).
    ///         Voided   — refund-all: every staker reclaims their OWN stake, NO fee. Covers
    ///                    governance void, no-stakes, one-sided (no losers) and
    ///                    zero-stake-winner (nobody predicted the winner) resolutions.
    enum RoundState {
        None,
        Open,
        Resolved,
        Voided
    }

    /// @notice Why a round became {RoundState.Voided} (transparency; refund rules are
    ///         identical for every reason — own-stake refund, no fee).
    enum VoidReason {
        None,
        NoStakes, // resolve found an empty pool (totalPool == 0)
        OneSided, // resolve found all stake on the winning outcome (no counterparty to skim)
        ZeroStakeWinner, // resolve found the winning outcome had zero stake (nobody predicted it)
        Governance, // GOVERNANCE_ROLE emergency void of an Open round
        Stale // never resolved by resolveTime (+ grace for non-resolvers) → funds-rescue void
    }

    // --- lifecycle ---

    /// @notice SCHEDULER opens a round with `outcomeCount` (2..16) outcomes. Stakes are
    ///         accepted until `lockTime`; resolution is allowed from `resolveTime`.
    /// @return roundId monotonically-increasing id (starts at 1).
    function openRound(
        bytes32 gameType,
        uint8 outcomeCount,
        uint64 lockTime,
        uint64 resolveTime,
        bytes32 meta
    ) external returns (uint256 roundId);

    /// @notice Stake `amount` collateral on `outcome` of `roundId` before lockTime.
    function stake(uint256 roundId, uint8 outcome, uint256 amount) external;

    /// @notice RESOLVER submits the winning outcome after resolveTime. Two-sided pools
    ///         settle (fee skimmed, winners' pot fixed); degenerate pools auto-void.
    function resolve(uint256 roundId, uint8 winningOutcome) external;

    /// @notice GOVERNANCE emergency-voids an Open round → every staker refunds own stake.
    function voidRound(uint256 roundId, bytes32 reasonHash) external;

    /// @notice Void an Open round that was never resolved (funds never lock). RESOLVER may
    ///         call once `block.timestamp >= resolveTime` (prompt void of a detected
    ///         unresolvable round — a tie, dead feed, etc.); ANYONE may call once
    ///         `block.timestamp >= resolveTime + STALE_VOID_GRACE`, a trustless backstop so
    ///         stakers can always rescue their own funds even if every bot is down.
    function voidStale(uint256 roundId) external;

    /// @notice Claim winnings (Resolved) or refund (Voided). Idempotent; single-shot.
    function claim(uint256 roundId) external;

    // --- views ---

    function collateralToken() external view returns (address);
    function feeSink() external view returns (address);
    function feeBps() external view returns (uint16);

    /// @notice Full round snapshot for the frontend.
    function getRound(uint256 roundId)
        external
        view
        returns (
            RoundState state,
            bytes32 gameType,
            bytes32 meta,
            uint8 outcomeCount,
            uint64 lockTime,
            uint64 resolveTime,
            uint8 winningOutcome,
            uint256 totalPool,
            uint256 fee,
            uint256[] memory pools
        );

    /// @notice Stake `user` placed on `outcome` of `roundId`.
    function userStakeOf(uint256 roundId, address user, uint8 outcome) external view returns (uint256);

    /// @notice Collateral `user` could claim/refund from `roundId` right now (0 if the
    ///         round is unsettled, already claimed, or the user is a loser).
    function claimableOf(uint256 roundId, address user) external view returns (uint256);

    /// @notice Implied probabilities per outcome, 1e18-scaled (perOutcome/total). Empty
    ///         pool → all zeros.
    function impliedOdds(uint256 roundId) external view returns (uint256[] memory);
}
