// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFastRoundArena} from "./IFastRoundArena.sol";

/// @title FastRoundArena — the general PARIMUTUEL multi-outcome round engine for Tart
///        Predict "Fast Games".
///
/// @notice ONE contract type, MANY games. A round has 2..16 outcomes; every fast game is
///         just a round with the right outcome count + a `gameType` tag the frontend
///         reads: 15-min Up/Down (2), BTC-vs-ETH / Gold-vs-Silver / Touch / Big-move /
///         New-high / Tug-of-War (2), the Race (4), Survival "last coin standing" (N).
///
///         PURE PARIMUTUEL — the house adds NO liquidity and bears ZERO directional risk:
///         winners split the LOSERS' stake pro-rata to their own stake, and the house
///         only skims a flat {feeBps} (2%) off the TOTAL pool of a genuinely two-sided
///         round. There is nothing to skim when there is no counterparty, so one-sided
///         and degenerate rounds refund everyone their own stake with NO fee.
///
///         MONEY-SAFETY INVARIANTS (property-tested to the wei):
///           1. CONSERVATION. For a settled two-sided round, once every staker has
///              claimed: Σ winner-claims + fee == totalPool EXACTLY (dust-safe: the LAST
///              winner to claim absorbs the flooring remainder, so the round drains to 0
///              and no base unit is ever created or stranded). For a voided round:
///              Σ refunds == totalPool exactly.
///           2. POOL-FAVOURABLE. No claim path can pay more than the pot: winner payouts
///              are floored against a running remainder that can never exceed what is
///              left, and the fee is `floor(totalPool * feeBps / BPS)` so distributable ==
///              totalPool - fee is fully covered by collateral physically held.
///           3. NO ADMIN SWEEP. There is NO sweep / rescue / seize / withdraw-any / skim
///              surface anywhere (structurally, ABI-tested). Collateral leaves ONLY as a
///              winner's claim, a voided-round refund, or the fee leg routed to the
///              immutable {feeSink} at resolution.
///           4. EXIT ALWAYS OPEN. Pause halts new {openRound}/{stake} only; {claim} and
///              refunds are NEVER blocked.
contract FastRoundArena is IFastRoundArena, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Opens rounds (an off-chain scheduler / keeper).
    bytes32 public constant SCHEDULER_ROLE = keccak256("SCHEDULER_ROLE");
    /// @notice Submits the winning outcome (an off-chain price/kline/creator keeper). The
    ///         CONTRACT never reads data — the resolver does, and submits the result.
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    /// @notice Emergency void + pause/unpause (the GovernanceTimelock in production).
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice After `resolveTime + STALE_VOID_GRACE` ANYONE may void an unresolved round,
    ///         so stakers can always rescue their funds even if every keeper is down.
    uint256 public constant STALE_VOID_GRACE = 12 hours;

    uint256 internal constant BPS = 10_000;
    uint8 internal constant MIN_OUTCOMES = 2;
    uint8 internal constant MAX_OUTCOMES = 16;

    // ------------------------------------------------------------------
    // Immutable configuration
    // ------------------------------------------------------------------

    IERC20 private immutable _collateral;
    /// @notice Collateral decimals, read DYNAMICALLY from the token (never assumed).
    uint8 public immutable collateralDecimals;
    /// @notice Flat house fee in bps, skimmed off the total pool of a two-sided round.
    uint16 public immutable override feeBps;
    /// @notice The FeeVaultV3-shaped sink the fee leg is transferred to at resolution.
    address public immutable override feeSink;

    // ------------------------------------------------------------------
    // Round state
    // ------------------------------------------------------------------

    struct Round {
        bytes32 gameType;
        bytes32 meta;
        uint64 lockTime;
        uint64 resolveTime;
        uint8 outcomeCount;
        uint8 winningOutcome; // meaningful only when state == Resolved
        RoundState state;
        uint256 totalPool;
        uint256 fee; // 0 unless Resolved two-sided
        // --- settlement bookkeeping for the exact-drain claim path (Resolved only) ---
        uint256 distributableRemaining; // (totalPool - fee) not yet claimed
        uint256 winnerPoolRemaining; // winning-outcome stake not yet claimed
    }

    uint256 public roundCount;
    mapping(uint256 => Round) private _rounds;
    /// @notice Per-round, per-outcome staked total. `_pools[roundId].length == outcomeCount`.
    mapping(uint256 => uint256[]) private _pools;
    /// @notice Per-round, per-user, per-outcome stake.
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) private _userStake;
    /// @notice Per-round, per-user single-shot claim guard.
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ------------------------------------------------------------------
    // Errors / events
    // ------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error BadFeeConfig();
    error BadOutcomeCount();
    error BadTiming();
    error UnknownRound();
    error RoundNotOpen();
    error StakingClosed();
    error InvalidOutcome();
    error NotResolvable();
    error NotVoidable();
    error NotSettled();
    error AlreadyClaimed();
    error NothingToClaim();
    error FeeOnTransferToken();

    event RoundOpened(
        uint256 indexed roundId,
        bytes32 indexed gameType,
        uint8 outcomeCount,
        uint64 lockTime,
        uint64 resolveTime,
        bytes32 meta
    );
    event Staked(uint256 indexed roundId, address indexed user, uint8 indexed outcome, uint256 amount, uint256 outcomeTotal);
    event Resolved(uint256 indexed roundId, uint8 indexed winningOutcome, uint256 totalPool, uint256 fee, uint256 distributable);
    event FeeRouted(uint256 indexed roundId, address indexed feeSink, uint256 amount);
    event RoundVoided(uint256 indexed roundId, VoidReason indexed reason, bytes32 reasonHash);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 payout);

    /// @param collateral_ ERC20 collateral (decimals read DYNAMICALLY).
    /// @param feeSink_     FeeVaultV3-shaped fee sink (non-zero).
    /// @param feeBps_      flat house fee (<= 1000 = 10%); 200 = 2% for production.
    /// @param admin_       DEFAULT_ADMIN_ROLE + GOVERNANCE_ROLE (GovernanceTimelock in prod).
    constructor(address collateral_, address feeSink_, uint16 feeBps_, address admin_) {
        if (collateral_ == address(0) || feeSink_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (feeBps_ > 1000) revert BadFeeConfig();
        _collateral = IERC20(collateral_);
        collateralDecimals = IERC20Metadata(collateral_).decimals();
        feeSink = feeSink_;
        feeBps = feeBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(GOVERNANCE_ROLE, admin_);
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// @inheritdoc IFastRoundArena
    /// @dev Blocked while paused (no new rounds). `lockTime` must be in the future so a
    ///      staking window exists; `resolveTime` must be at or after `lockTime`.
    function openRound(
        bytes32 gameType,
        uint8 outcomeCount,
        uint64 lockTime,
        uint64 resolveTime,
        bytes32 meta
    ) external override whenNotPaused onlyRole(SCHEDULER_ROLE) returns (uint256 roundId) {
        if (outcomeCount < MIN_OUTCOMES || outcomeCount > MAX_OUTCOMES) revert BadOutcomeCount();
        if (lockTime <= block.timestamp || resolveTime < lockTime) revert BadTiming();

        roundId = ++roundCount;
        Round storage r = _rounds[roundId];
        r.gameType = gameType;
        r.meta = meta;
        r.lockTime = lockTime;
        r.resolveTime = resolveTime;
        r.outcomeCount = outcomeCount;
        r.state = RoundState.Open;
        // Fixed-length per-outcome ledger, zero-initialised.
        _pools[roundId] = new uint256[](outcomeCount);

        emit RoundOpened(roundId, gameType, outcomeCount, lockTime, resolveTime, meta);
    }

    /// @inheritdoc IFastRoundArena
    /// @dev Pulls collateral (rejects fee-on-transfer) and books it to (outcome, user).
    function stake(uint256 roundId, uint8 outcome, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        if (block.timestamp >= r.lockTime) revert StakingClosed();
        if (outcome >= r.outcomeCount) revert InvalidOutcome();
        if (amount == 0) revert ZeroAmount();

        _pull(msg.sender, amount);

        _pools[roundId][outcome] += amount;
        _userStake[roundId][msg.sender][outcome] += amount;
        r.totalPool += amount;

        emit Staked(roundId, msg.sender, outcome, amount, _pools[roundId][outcome]);
    }

    /// @inheritdoc IFastRoundArena
    /// @dev Settlement decision tree (all money-conserving):
    ///        totalPool == 0            → auto-void (NoStakes)
    ///        winnerPool == 0           → auto-void (ZeroStakeWinner: nobody predicted it)
    ///        winnerPool == totalPool   → auto-void (OneSided: no losers, nothing to skim)
    ///        otherwise (two-sided)     → skim fee, fix winners' distributable pot
    function resolve(uint256 roundId, uint8 winningOutcome)
        external
        override
        nonReentrant
        onlyRole(RESOLVER_ROLE)
    {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        if (block.timestamp < r.resolveTime) revert NotResolvable();
        if (winningOutcome >= r.outcomeCount) revert InvalidOutcome();

        uint256 totalPool = r.totalPool;
        if (totalPool == 0) {
            _void(roundId, r, VoidReason.NoStakes, bytes32(0));
            return;
        }
        uint256 winnerPool = _pools[roundId][winningOutcome];
        if (winnerPool == 0) {
            // Nobody staked the winning outcome — refund everyone (safe rule, documented).
            _void(roundId, r, VoidReason.ZeroStakeWinner, bytes32(0));
            return;
        }
        if (winnerPool == totalPool) {
            // Everyone is on the winner: no losers to skim, so no fee — refund own stake.
            _void(roundId, r, VoidReason.OneSided, bytes32(0));
            return;
        }

        // Two-sided: skim the flat fee off the TOTAL pool, but NEVER more than the
        // losers' pool. The fee is economically funded by the losers' stake (the
        // winnings); taxing the total would dip into the winners' own principal
        // whenever loserPool < fee (a lopsided round, e.g. a heavy favourite, or a
        // 1-wei counter-stake weaponising the skim against the one-sided refund
        // rule). Capping at loserPool guarantees distributable >= winnerPool, so a
        // winning bet can never be repaid below its own stake. Conservation is
        // preserved either way (Σ winner claims + fee == totalPool exactly).
        uint256 loserPool = totalPool - winnerPool;
        uint256 fee = (totalPool * feeBps) / BPS;
        if (fee > loserPool) fee = loserPool;
        uint256 distributable = totalPool - fee; // always >= winnerPool now

        r.state = RoundState.Resolved;
        r.winningOutcome = winningOutcome;
        r.fee = fee;
        r.distributableRemaining = distributable;
        r.winnerPoolRemaining = winnerPool;

        if (fee > 0) {
            _collateral.safeTransfer(feeSink, fee);
            emit FeeRouted(roundId, feeSink, fee);
        }
        emit Resolved(roundId, winningOutcome, totalPool, fee, distributable);
    }

    /// @inheritdoc IFastRoundArena
    /// @dev Emergency void of an Open round (before resolution). Resolved rounds cannot be
    ///      voided — their fee is already routed and payouts fixed.
    function voidRound(uint256 roundId, bytes32 reasonHash) external override onlyRole(GOVERNANCE_ROLE) {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        _void(roundId, r, VoidReason.Governance, reasonHash);
    }

    /// @inheritdoc IFastRoundArena
    /// @dev Trustless funds-rescue for an Open round the resolver never settled. The
    ///      RESOLVER may void promptly once `resolveTime` passes (a detected tie / dead
    ///      feed) so funds are not held for the grace period; ANYONE may void after
    ///      `resolveTime + STALE_VOID_GRACE`, so no round can ever lock funds even if the
    ///      resolver bot is permanently down or lacks GOVERNANCE_ROLE. Never voids before
    ///      `resolveTime` (the measurement window must complete first). Refund rules are
    ///      identical to any other void — every staker reclaims their own stake, no fee.
    function voidStale(uint256 roundId) external {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        if (block.timestamp < r.resolveTime) revert NotVoidable();
        if (!hasRole(RESOLVER_ROLE, msg.sender) && block.timestamp < uint256(r.resolveTime) + STALE_VOID_GRACE) {
            revert NotVoidable();
        }
        _void(roundId, r, VoidReason.Stale, bytes32(0));
    }

    function _void(uint256 roundId, Round storage r, VoidReason reason, bytes32 reasonHash) internal {
        r.state = RoundState.Voided;
        emit RoundVoided(roundId, reason, reasonHash);
    }

    /// @inheritdoc IFastRoundArena
    /// @dev NEVER blocked by pause (exit path). Single-shot per (round, user).
    ///      RESOLVED: pro-rata winner share against a RUNNING remainder so the final
    ///      claimant absorbs the flooring dust → the round drains to exactly 0.
    ///      VOIDED:   refund the user's OWN total stake across every outcome.
    function claim(uint256 roundId) external override nonReentrant {
        Round storage r = _rounds[roundId];
        RoundState s = r.state;
        if (s != RoundState.Resolved && s != RoundState.Voided) revert NotSettled();
        if (claimed[roundId][msg.sender]) revert AlreadyClaimed();

        uint256 payout;
        if (s == RoundState.Resolved) {
            uint256 stakeOnWinner = _userStake[roundId][msg.sender][r.winningOutcome];
            if (stakeOnWinner == 0) revert NothingToClaim(); // loser (or non-participant)
            // Running-remainder pro-rata: share = stake * distRemaining / winnerRemaining.
            // The LAST winner has winnerRemaining == their own stake, so they receive the
            // entire distRemaining — the flooring remainder from earlier claims included.
            // Pool-favourable throughout: distRemaining never goes negative, total out ==
            // distributable exactly.
            uint256 distRem = r.distributableRemaining;
            uint256 winRem = r.winnerPoolRemaining;
            payout = (stakeOnWinner * distRem) / winRem;
            r.distributableRemaining = distRem - payout;
            r.winnerPoolRemaining = winRem - stakeOnWinner;
        } else {
            // Voided → own-stake refund across all outcomes.
            payout = _totalUserStake(roundId, msg.sender, r.outcomeCount);
            if (payout == 0) revert NothingToClaim();
        }

        claimed[roundId][msg.sender] = true;
        _collateral.safeTransfer(msg.sender, payout);
        emit Claimed(roundId, msg.sender, payout);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function collateralToken() external view override returns (address) {
        return address(_collateral);
    }

    /// @inheritdoc IFastRoundArena
    function getRound(uint256 roundId)
        external
        view
        override
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
        )
    {
        Round storage r = _rounds[roundId];
        state = r.state;
        gameType = r.gameType;
        meta = r.meta;
        outcomeCount = r.outcomeCount;
        lockTime = r.lockTime;
        resolveTime = r.resolveTime;
        winningOutcome = r.winningOutcome;
        totalPool = r.totalPool;
        fee = r.fee;
        pools = _pools[roundId];
    }

    /// @inheritdoc IFastRoundArena
    function userStakeOf(uint256 roundId, address user, uint8 outcome) external view override returns (uint256) {
        return _userStake[roundId][user][outcome];
    }

    /// @inheritdoc IFastRoundArena
    /// @dev For a Resolved winner this is the amount they would receive IF THEY CLAIMED
    ///      NOW (the running remainder can only grow the last claimant's share, never
    ///      shrink it below a floored pro-rata). 0 for unsettled/claimed/loser.
    function claimableOf(uint256 roundId, address user) external view override returns (uint256) {
        Round storage r = _rounds[roundId];
        if (claimed[roundId][user]) return 0;
        if (r.state == RoundState.Resolved) {
            uint256 stakeOnWinner = _userStake[roundId][user][r.winningOutcome];
            if (stakeOnWinner == 0) return 0;
            return (stakeOnWinner * r.distributableRemaining) / r.winnerPoolRemaining;
        }
        if (r.state == RoundState.Voided) {
            return _totalUserStake(roundId, user, r.outcomeCount);
        }
        return 0;
    }

    /// @inheritdoc IFastRoundArena
    function impliedOdds(uint256 roundId) external view override returns (uint256[] memory odds) {
        Round storage r = _rounds[roundId];
        uint8 n = r.outcomeCount;
        odds = new uint256[](n);
        uint256 total = r.totalPool;
        if (total == 0) return odds; // all zeros
        uint256[] storage pools = _pools[roundId];
        for (uint8 i = 0; i < n; i++) {
            odds[i] = (pools[i] * 1e18) / total;
        }
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    /// @notice Pause new rounds + staking. NEVER blocks claim / refund.
    function pause() external onlyRole(GOVERNANCE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _totalUserStake(uint256 roundId, address user, uint8 outcomeCount) internal view returns (uint256 sum) {
        mapping(uint8 => uint256) storage us = _userStake[roundId][user];
        for (uint8 i = 0; i < outcomeCount; i++) {
            sum += us[i];
        }
    }

    /// @dev Pull exactly `amount`, rejecting fee-on-transfer collateral (parity with the
    ///      fixed-odds market): the balance delta must equal the requested amount.
    function _pull(address from, uint256 amount) internal {
        uint256 before = _collateral.balanceOf(address(this));
        _collateral.safeTransferFrom(from, address(this), amount);
        if (_collateral.balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();
    }
}
