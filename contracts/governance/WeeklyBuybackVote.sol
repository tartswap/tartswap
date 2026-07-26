// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakeAdapter} from "./IStakeAdapter.sol";

/// @notice The GameFeeSplitter surface this contract curates: it retargets the
///         buyback token and its swap route each epoch. This contract must be
///         set as the splitter's `buybackTokenCurator` for the finalize call to
///         succeed. `collateral()` is read at candidate-submission time so paths
///         can be validated up-front (a bad path must never be able to brick the
///         permissionless finalize).
interface IGameFeeSplitter {
    function collateral() external view returns (address);
    function setBuybackToken(address token) external;
    function setSwapPath(address[] calldata path) external;
    /// @notice Read at candidate-submission time so a disallowed buyback token
    ///         can never become a candidate — and therefore never win — which
    ///         keeps the permissionless finalize's `setBuybackToken` un-brickable.
    function isAllowedBuybackToken(address token) external view returns (bool);
}

/// @title  WeeklyBuybackVote
/// @notice A weekly, stake-weighted on-chain vote that chooses which token the
///         {GameFeeSplitter} buys-and-burns. Voting power is aggregated across a
///         configurable registry of staking sources (CREPE now, TART later),
///         each fronted by an {IStakeAdapter} with its own weight.
///
///         TIMELINE (per 7-day epoch N):
///           [epochStart(N) ...................... voteWindowStart(N) ... epochEnd(N))
///            └─ candidates may be submitted ──────┘└── vote window (last VOTE_WINDOW) ──┘
///                                                                        └─ finalize N here on ─
///
///         Votes cast during epoch N's window elect epoch N's `winner`, and that
///         winner becomes the splitter's buyback token for the FOLLOWING period
///         (set at finalize, which runs at/after epochEnd(N)). Finalize is
///         PERMISSIONLESS and idempotent.
///
///         TRUST MODEL: the owner (multisig on mainnet) configures the stake
///         registry, the candidate submitter, and timing. The `candidateSubmitter`
///         curates the weekly ballot but cannot pick the winner — voters do.
///         Candidate-path LIQUIDITY is NOT checkable on-chain; the submitter is
///         trusted to post routable paths (validated only for shape here).
contract WeeklyBuybackVote is Ownable2Step, ReentrancyGuard {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Fixed 7-day epoch length.
    uint256 public constant EPOCH_DURATION = 7 days;
    /// @notice Basis-point denominator for stake-source weights.
    uint16 public constant BPS = 10_000;
    /// @notice Hard cap on a single source's weight (4x) so no source can be
    ///         configured into overflow-adjacent or vote-dominating territory.
    uint16 public constant MAX_SOURCE_WEIGHT_BPS = 4 * BPS;
    /// @notice Ballot size bounds (runoff epochs post exactly 3).
    uint256 public constant MIN_CANDIDATES = 3;
    uint256 public constant MAX_CANDIDATES = 10;
    /// @notice Number of prior epochs that seed a monthly runoff ballot.
    uint256 public constant RUNOFF_LOOKBACK = 3;
    /// @notice Upper bound for a configured quorum: a quorum can never exceed the
    ///         theoretical max voting power, so this both documents intent and stops
    ///         the owner from freezing governance with an unmeetable bar. It is
    ///         generous (fits any realistic stake × weight aggregate) yet leaves
    ///         `type(uint256).max` — the "brick everything" value — unreachable.
    uint256 public constant MAX_QUORUM = type(uint256).max / 2;

    // ------------------------------------------------------------------
    // Immutable / config
    // ------------------------------------------------------------------

    /// @notice Epoch-0 start; `currentEpoch() = (block.timestamp - genesis) / EPOCH_DURATION`.
    uint256 public immutable genesis;
    /// @notice The fee splitter this vote curates (must set us as its curator).
    IGameFeeSplitter public immutable splitter;

    /// @notice Length of the vote window at the END of each epoch (default 1 day).
    uint256 public voteWindow = 1 days;
    /// @notice The address (besides the owner) allowed to post each epoch's ballot.
    address public candidateSubmitter;
    /// @notice Minimum total voting power an epoch must draw for its winner to be
    ///         installed (turnout quorum). 0 = disabled. An epoch that ends below
    ///         quorum is treated as {NoWinner}: the splitter is NOT retargeted,
    ///         but the epoch still finalizes and settlement advances in order.
    ///         A `setQuorum` change only takes effect for epochs whose ballot has
    ///         not yet been posted — the value in force is snapshotted per epoch at
    ///         submit time (see {epochQuorum}) so the owner can never inflate the
    ///         bar after votes are in to nullify a live result.
    uint256 public quorumVotes;
    /// @notice Owner-curated allowlist of tokens permitted as INTERMEDIATE hops
    ///         in candidate swap paths (e.g. WBNB, USDT). Endpoints are already
    ///         pinned (collateral → … → candidate); this bounds a malicious
    ///         submitter's ability to route through poisoned pools. (M-3)
    mapping(address => bool) public allowedHop;

    // ------------------------------------------------------------------
    // Stake-source registry
    // ------------------------------------------------------------------

    struct StakeSource {
        IStakeAdapter adapter;
        uint16 weightBps;
        bool active;
    }

    StakeSource[] private _stakeSources;

    // ------------------------------------------------------------------
    // Per-epoch state
    // ------------------------------------------------------------------

    /// @notice The ordered candidate list for an epoch (index = tie-break rank).
    mapping(uint256 => address[]) private _candidates;
    /// @notice Membership test for O(1) candidate validation during voting.
    mapping(uint256 => mapping(address => bool)) public isCandidate;
    /// @notice The stored collateral→…→token swap route for each candidate.
    mapping(uint256 => mapping(address => address[])) private _candidatePath;
    /// @notice Whether an epoch's ballot has been posted (guards single-submission).
    mapping(uint256 => bool) public candidatesSet;
    /// @notice The quorum in force for an epoch, snapshotted when its ballot is
    ///         posted. Finalize reads THIS, not the live {quorumVotes}, so a
    ///         `setQuorum` after votes are cast can never retroactively raise the
    ///         bar to nullify a result (only future ballots feel the new value).
    mapping(uint256 => uint256) public epochQuorum;

    /// @notice Accumulated voting power per (epoch, token).
    mapping(uint256 => mapping(address => uint256)) public votes;
    /// @notice Total voting power cast in an epoch.
    mapping(uint256 => uint256) public totalVotes;
    /// @notice One-vote-per-voter-per-epoch guard.
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice The elected token for an epoch (0 until finalized / NoWinner).
    mapping(uint256 => address) public winner;
    /// @notice The last epoch a token won (for observability; cooldown uses `winner`).
    mapping(address => uint256) public lastWonEpoch;
    /// @notice Whether an epoch has been finalized (idempotency guard).
    mapping(uint256 => bool) public finalized;
    /// @notice The next epoch finalizeEpoch will accept — settlement is STRICTLY
    ///         in order so a stale ended-but-unfinalized epoch can never be
    ///         detonated later to hijack the splitter's live buyback. (H-2)
    uint256 public nextEpochToFinalize;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error ZeroAddress();
    error BadWeight();
    error BadVoteWindow();
    error BadSourceId();
    error NotSubmitter();
    error WindowOpen();
    error AlreadySubmitted();
    error BadCandidateCount();
    error DuplicateCandidate();
    error CooldownActive();
    error BadRunoffSet();
    error BadPath();
    error VoteClosed();
    error NotACandidate();
    error AlreadyVoted();
    error NoVotingPower();
    error EpochNotEnded();
    error AlreadyFinalized();
    error OutOfOrderFinalize();
    error PriorEpochNotFinalized();
    error HopNotAllowed();
    error TokenNotAllowed();
    error BadQuorum();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event VoteWindowSet(uint256 voteWindow);
    event CandidateSubmitterSet(address indexed submitter);
    event StakeSourceAdded(uint256 indexed id, address indexed adapter, uint16 weightBps);
    event StakeSourceSet(uint256 indexed id, address indexed adapter, uint16 weightBps, bool active);
    event CandidatesSubmitted(uint256 indexed epoch, address[] tokens, bool runoff);
    event Voted(uint256 indexed epoch, address indexed voter, address indexed token, uint256 power);
    event EpochFinalized(uint256 indexed epoch, address indexed winner, uint256 totalVotes);
    event NoWinner(uint256 indexed epoch);
    event AllowedHopSet(address indexed hop, bool allowed);
    event QuorumSet(uint256 quorumVotes);
    /// @notice Emitted when a winner is recorded for runoff history but NOT
    ///         pushed to the splitter because a newer epoch has already ended
    ///         (catch-up finalization must never install a stale buyback).
    event StaleWinnerNotApplied(uint256 indexed epoch, address indexed winner);
    /// @notice Emitted when finalize elected a winner but retargeting the splitter
    ///         (setBuybackToken / setSwapPath) reverted — e.g. the owner
    ///         de-allowlisted the token or changed the curator between submit and
    ///         finalize. The winner is still recorded and settlement still advances
    ///         in order: finalize is INFALLIBLE so a single bad retarget can never
    ///         brick the strictly-in-order chain (~7 days per stuck epoch). The
    ///         owner can re-point the splitter manually afterwards. (H-3)
    event RetargetFailed(uint256 indexed epoch, address indexed token);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param initialOwner deployer/admin (multisig on mainnet).
    /// @param splitter_     the GameFeeSplitter to curate (non-zero).
    /// @param genesis_      epoch-0 start timestamp; 0 defaults to deploy time.
    constructor(address initialOwner, address splitter_, uint256 genesis_) Ownable(initialOwner) {
        if (splitter_ == address(0)) revert ZeroAddress();
        splitter = IGameFeeSplitter(splitter_);
        genesis = genesis_ == 0 ? block.timestamp : genesis_;
    }

    // ------------------------------------------------------------------
    // Epoch math (views)
    // ------------------------------------------------------------------

    /// @notice The epoch containing the current block. Reverts implicitly is
    ///         impossible — `block.timestamp >= genesis` always holds post-deploy
    ///         unless a future genesis was configured (then it underflows-guards
    ///         to 0 below).
    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < genesis) return 0;
        return (block.timestamp - genesis) / EPOCH_DURATION;
    }

    function epochStart(uint256 epoch) public view returns (uint256) {
        return genesis + epoch * EPOCH_DURATION;
    }

    function epochEnd(uint256 epoch) public view returns (uint256) {
        return genesis + (epoch + 1) * EPOCH_DURATION;
    }

    /// @notice Timestamp the last-VOTE_WINDOW voting phase opens for `epoch`.
    function voteWindowStart(uint256 epoch) public view returns (uint256) {
        return epochEnd(epoch) - voteWindow;
    }

    /// @notice True while `epoch`'s vote window is live.
    function voteWindowOpen(uint256 epoch) public view returns (bool) {
        return block.timestamp >= voteWindowStart(epoch) && block.timestamp < epochEnd(epoch);
    }

    /// @notice True when `epoch` is a monthly runoff (every 4th: 3, 7, 11, …).
    function isRunoffEpoch(uint256 epoch) public pure returns (bool) {
        return epoch % 4 == 3;
    }

    // ------------------------------------------------------------------
    // Owner config
    // ------------------------------------------------------------------

    /// @notice Set the vote-window length (0 < w < EPOCH_DURATION).
    function setVoteWindow(uint256 w) external onlyOwner {
        if (w == 0 || w >= EPOCH_DURATION) revert BadVoteWindow();
        voteWindow = w;
        emit VoteWindowSet(w);
    }

    /// @notice Set the address that may post the weekly ballot (0 = owner-only).
    function setCandidateSubmitter(address submitter) external onlyOwner {
        candidateSubmitter = submitter; // zero is valid → owner-only submission
        emit CandidateSubmitterSet(submitter);
    }

    /// @notice Register a new staking source. `weightBps` may exceed 10_000 to
    ///         over-weight a source relative to others (capped at
    ///         {MAX_SOURCE_WEIGHT_BPS}); 0 is rejected.
    function addStakeSource(IStakeAdapter adapter, uint16 weightBps) external onlyOwner {
        if (address(adapter) == address(0)) revert ZeroAddress();
        if (weightBps == 0 || weightBps > MAX_SOURCE_WEIGHT_BPS) revert BadWeight();
        uint256 id = _stakeSources.length;
        _stakeSources.push(StakeSource({adapter: adapter, weightBps: weightBps, active: true}));
        emit StakeSourceAdded(id, address(adapter), weightBps);
    }

    /// @notice Update an existing staking source (retarget, reweight, toggle).
    function setStakeSource(uint256 id, IStakeAdapter adapter, uint16 weightBps, bool active) external onlyOwner {
        if (id >= _stakeSources.length) revert BadSourceId();
        if (address(adapter) == address(0)) revert ZeroAddress();
        if (weightBps == 0 || weightBps > MAX_SOURCE_WEIGHT_BPS) revert BadWeight();
        _stakeSources[id] = StakeSource({adapter: adapter, weightBps: weightBps, active: active});
        emit StakeSourceSet(id, address(adapter), weightBps, active);
    }

    /// @notice Allow/disallow a token as an INTERMEDIATE hop in candidate swap
    ///         paths (M-3). Endpoints (collateral, candidate) need no listing.
    function setAllowedHop(address hop, bool allowed) external onlyOwner {
        if (hop == address(0)) revert ZeroAddress();
        allowedHop[hop] = allowed;
        emit AllowedHopSet(hop, allowed);
    }

    /// @notice Set the turnout quorum: the minimum total voting power an epoch
    ///         must draw for its winner to be installed. 0 disables the check;
    ///         values above {MAX_QUORUM} are rejected so governance can never be
    ///         frozen behind an unmeetable bar. The change is NOT retroactive: it
    ///         only binds epochs whose ballot is posted afterwards, because each
    ///         epoch snapshots the quorum in force at submit time (see
    ///         {epochQuorum}). An owner therefore cannot inflate the quorum after
    ///         votes land to cancel a live result.
    function setQuorum(uint256 quorumVotes_) external onlyOwner {
        if (quorumVotes_ > MAX_QUORUM) revert BadQuorum();
        quorumVotes = quorumVotes_;
        emit QuorumSet(quorumVotes_);
    }

    // ------------------------------------------------------------------
    // Voting power (views)
    // ------------------------------------------------------------------

    function stakeSourceCount() external view returns (uint256) {
        return _stakeSources.length;
    }

    function stakeSourceAt(uint256 id) external view returns (IStakeAdapter adapter, uint16 weightBps, bool active) {
        StakeSource storage s = _stakeSources[id];
        return (s.adapter, s.weightBps, s.active);
    }

    /// @notice Aggregate stake-weighted voting power of `user` for the CURRENT
    ///         epoch: Σ adapter.votingStakeOf(user, epochEnd(currentEpoch())) *
    ///         weightBps / 10_000. Only stake committed (locked, non-exitable)
    ///         through the epoch's end counts — flash-rented or flexible stake
    ///         is worth zero (H-1).
    function votingPowerOf(address user) public view returns (uint256) {
        return _votingPower(user, epochEnd(currentEpoch()));
    }

    /// @dev Aggregates across active sources, requiring each source's stake to
    ///      be committed through `minCommitUntil`. A broken source — reverting,
    ///      codeless, or returning malformed data — contributes zero instead of
    ///      bricking every vote (M-4). A raw staticcall is used because Solidity
    ///      try/catch does NOT catch return-data decode failures (they raise in
    ///      the caller), so a codeless adapter would otherwise still brick.
    ///      Adapters are owner-registered, bounding griefing via gas/returndata.
    function _votingPower(address user, uint256 minCommitUntil) private view returns (uint256 power) {
        uint256 len = _stakeSources.length;
        for (uint256 i = 0; i < len; ++i) {
            StakeSource storage s = _stakeSources[i];
            if (!s.active) continue;
            (bool ok, bytes memory ret) = address(s.adapter).staticcall(
                abi.encodeCall(IStakeAdapter.votingStakeOf, (user, minCommitUntil))
            );
            // Broken source ⇒ zero contribution; other sources still count.
            if (!ok || ret.length < 32) continue;
            uint256 stakeAmt = abi.decode(ret, (uint256));
            if (stakeAmt == 0) continue;
            power += (stakeAmt * s.weightBps) / BPS;
        }
    }

    // ------------------------------------------------------------------
    // Candidates
    // ------------------------------------------------------------------

    /// @notice Post `epoch`'s ballot. Callable by the submitter or owner, only
    ///         BEFORE the epoch's vote window opens. Posted once; the owner may
    ///         re-post (still before the window) to correct a mistake.
    ///
    ///         PREREQUISITE (M-1): for epoch >= 1 the PRIOR epoch must already
    ///         be finalized, so the cooldown (and a runoff's lookback) compare
    ///         against the REAL prior winner, never a not-yet-written zero.
    ///         With strictly-in-order finalization this also guarantees every
    ///         earlier epoch is settled. Pre-loading future ballots is thereby
    ///         impossible.
    ///
    ///         NORMAL epochs: 3..10 distinct tokens, none of which is the
    ///         immediately-prior epoch's winner (one-epoch cooldown).
    ///
    ///         RUNOFF epochs (epoch % 4 == 3): the ballot MUST be exactly the
    ///         winners of the prior 3 epochs in lookback order [epoch-1,
    ///         epoch-2, epoch-3], with zero-address (NoWinner) entries DROPPED
    ///         and duplicates DEDUPED (first occurrence kept) (M-2); the
    ///         cooldown is waived. If fewer than 2 distinct real winners
    ///         remain, the epoch deterministically falls back to a NORMAL
    ///         ballot (count bounds + cooldown apply).
    ///
    /// @param paths paths[i] is the collateral→…→tokens[i] swap route stored for
    ///        the splitter's `setSwapPath` if tokens[i] wins. Validated for
    ///        shape (endpoints + no zero hops) and intermediate hops must be
    ///        owner-allowlisted (M-3); pool liquidity is off-chain.
    function submitCandidates(uint256 epoch, address[] calldata tokens, address[][] calldata paths)
        external
    {
        if (msg.sender != owner() && msg.sender != candidateSubmitter) revert NotSubmitter();
        if (block.timestamp >= voteWindowStart(epoch)) revert WindowOpen();
        // Once posted, only the owner may overwrite (submitter gets one shot).
        if (candidatesSet[epoch] && msg.sender != owner()) revert AlreadySubmitted();
        // Cooldown/runoff must see the real prior winner (M-1).
        if (epoch >= 1 && !finalized[epoch - 1]) revert PriorEpochNotFinalized();

        uint256 n = tokens.length;
        if (n != paths.length) revert BadCandidateCount();

        bool runoff = isRunoffEpoch(epoch);
        if (runoff) {
            // Exactly the deduped non-zero prior-3-winner set, in lookback
            // order; cooldown waived. Falls back to a normal ballot when the
            // set is degenerate (M-2).
            address[] memory expected = runoffBallotOf(epoch);
            uint256 m = expected.length;
            if (m >= 2) {
                if (n != m) revert BadRunoffSet();
                for (uint256 i = 0; i < m; ++i) {
                    if (tokens[i] != expected[i]) revert BadRunoffSet();
                }
            } else {
                runoff = false; // degenerate history → normal ballot rules
            }
        }
        if (!runoff) {
            if (n < MIN_CANDIDATES || n > MAX_CANDIDATES) revert BadCandidateCount();
        }

        _clearCandidates(epoch);

        address prevWinner = epoch >= 1 ? winner[epoch - 1] : address(0);
        for (uint256 i = 0; i < n; ++i) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (isCandidate[epoch][token]) revert DuplicateCandidate();
            // One-epoch cooldown (waived for runoff): last epoch's winner sits out.
            if (!runoff && token == prevWinner) revert CooldownActive();
            // Only owner-allowlisted buyback targets may run, so a winner is
            // always installable at finalize — setBuybackToken can never revert
            // on the permissionless finalize path (mirrors the M-3 hop pattern).
            if (!splitter.isAllowedBuybackToken(token)) revert TokenNotAllowed();
            _validatePath(paths[i], token);

            isCandidate[epoch][token] = true;
            _candidates[epoch].push(token);
            _candidatePath[epoch][token] = paths[i];
        }

        candidatesSet[epoch] = true;
        // Snapshot the quorum in force NOW so a later setQuorum can't move this
        // epoch's bar after votes are cast. Owner re-submits (still pre-window,
        // pre-vote) simply re-snapshot the then-current value.
        epochQuorum[epoch] = quorumVotes;
        emit CandidatesSubmitted(epoch, tokens, runoff);
    }

    /// @dev Purge a prior (owner re-submit) ballot so stale membership/paths
    ///      never leak. Safe because submission is only possible pre-window, so
    ///      no votes can exist yet for `epoch`.
    function _clearCandidates(uint256 epoch) private {
        address[] storage prev = _candidates[epoch];
        uint256 len = prev.length;
        for (uint256 i = 0; i < len; ++i) {
            address t = prev[i];
            delete isCandidate[epoch][t];
            delete _candidatePath[epoch][t];
        }
        delete _candidates[epoch];
    }

    /// @notice The deterministic runoff ballot for `epoch`: the prior 3 epochs'
    ///         winners in lookback order [epoch-1, epoch-2, epoch-3], with
    ///         zero-address (NoWinner) entries dropped and duplicates deduped
    ///         (first occurrence kept). A result shorter than 2 means the epoch
    ///         falls back to a normal ballot (M-2).
    function runoffBallotOf(uint256 epoch) public view returns (address[] memory expected) {
        address[] memory buf = new address[](RUNOFF_LOOKBACK);
        uint256 m = 0;
        for (uint256 k = 1; k <= RUNOFF_LOOKBACK && k <= epoch; ++k) {
            address w = winner[epoch - k];
            if (w == address(0)) continue; // NoWinner epoch → dropped
            bool dup = false;
            for (uint256 j = 0; j < m; ++j) {
                if (buf[j] == w) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue; // repeat winner → deduped
            buf[m++] = w;
        }
        expected = new address[](m);
        for (uint256 i = 0; i < m; ++i) {
            expected[i] = buf[i];
        }
    }

    /// @dev Mirror the splitter's `setSwapPath` shape rules so a winning path is
    ///      guaranteed to be accepted at finalize: collateral → … → token, no
    ///      zero hops, length >= 2. Additionally every INTERMEDIATE hop must be
    ///      owner-allowlisted (M-3) to bound submitter path-poisoning.
    function _validatePath(address[] calldata path, address token) private view {
        uint256 len = path.length;
        if (len < 2) revert BadPath();
        if (path[0] != splitter.collateral() || path[len - 1] != token) revert BadPath();
        for (uint256 i = 0; i < len; ++i) {
            if (path[i] == address(0)) revert BadPath();
            // Endpoints are pinned above; interior hops need allowlisting.
            if (i != 0 && i != len - 1 && !allowedHop[path[i]]) revert HopNotAllowed();
        }
    }

    // ------------------------------------------------------------------
    // Voting
    // ------------------------------------------------------------------

    /// @notice Cast your full voting power for `token` in `epoch`. Open only
    ///         during the epoch's vote window; one choice per voter; power is
    ///         snapshotted at call time and counts ONLY stake locked through
    ///         this epoch's end — stake that could be withdrawn before then
    ///         (flexible/flash-rented) is worth zero (H-1).
    function vote(uint256 epoch, address token) external nonReentrant {
        if (!voteWindowOpen(epoch)) revert VoteClosed();
        if (!isCandidate[epoch][token]) revert NotACandidate();
        if (hasVoted[epoch][msg.sender]) revert AlreadyVoted();

        uint256 power = _votingPower(msg.sender, epochEnd(epoch));
        if (power == 0) revert NoVotingPower();

        hasVoted[epoch][msg.sender] = true;
        votes[epoch][token] += power;
        totalVotes[epoch] += power;

        emit Voted(epoch, msg.sender, token, power);
    }

    // ------------------------------------------------------------------
    // Finalize
    // ------------------------------------------------------------------

    /// @notice PERMISSIONLESS tally of `epoch` once its window has closed (i.e.
    ///         at/after epochEnd). Idempotent, and STRICTLY IN ORDER: epochs
    ///         settle sequentially (`epoch == nextEpochToFinalize`), so a stale
    ///         ended-but-unfinalized epoch can never be detonated later to
    ///         override a newer decision (H-2). The candidate with the most
    ///         votes wins; ties break to the LOWEST candidate index. On a
    ///         winner, the splitter is retargeted to buy that token via its
    ///         stored path for the following period — but ONLY when `epoch` is
    ///         the most recently ended epoch; during catch-up finalization of
    ///         older epochs the winner is recorded for runoff history without
    ///         touching the splitter. An empty ballot or a zero-vote epoch
    ///         emits {NoWinner} and leaves the splitter's prior token untouched.
    function finalizeEpoch(uint256 epoch) external nonReentrant {
        if (block.timestamp < epochEnd(epoch)) revert EpochNotEnded();
        if (finalized[epoch]) revert AlreadyFinalized();
        if (epoch != nextEpochToFinalize) revert OutOfOrderFinalize();
        finalized[epoch] = true;
        nextEpochToFinalize = epoch + 1;

        address[] storage cands = _candidates[epoch];
        uint256 len = cands.length;
        uint256 total = totalVotes[epoch];

        // NoWinner when there is no ballot, no turnout, OR turnout fell below the
        // quorum SNAPSHOTTED for this epoch at submit time (not the live value, so
        // a post-vote setQuorum can't nullify a result). All three take the
        // identical NoWinner path: emit, leave `winner[epoch]` at zero, do NOT
        // retarget the splitter — while the epoch stays finalized and settlement
        // has already advanced in order.
        uint256 quorum = epochQuorum[epoch];
        if (len == 0 || total == 0 || (quorum != 0 && total < quorum)) {
            emit NoWinner(epoch);
            return;
        }

        // Highest votes; strict `>` keeps the first (lowest-index) on a tie.
        address win = cands[0];
        uint256 best = votes[epoch][win];
        for (uint256 i = 1; i < len; ++i) {
            address t = cands[i];
            uint256 v = votes[epoch][t];
            if (v > best) {
                best = v;
                win = t;
            }
        }

        winner[epoch] = win;
        lastWonEpoch[win] = epoch;

        // Retarget the splitter for the FOLLOWING period — only when `epoch`
        // is the most recently ENDED epoch (currentEpoch == epoch + 1). During
        // catch-up finalization of older epochs the winner is recorded for
        // runoff history but a stale route must never displace the live one.
        // setBuybackToken clears the old path, then setSwapPath installs the
        // winner's (pre-validated) route.
        //
        // The two splitter calls are wrapped in try/catch so finalize is
        // INFALLIBLE: if the owner de-allowlisted the winner or swapped the
        // curator between submit and finalize, the retarget fails LOUDLY
        // (RetargetFailed) but the winner is still recorded, the epoch stays
        // finalized, and `nextEpochToFinalize` still advances — a single bad
        // retarget can never lock the strictly-in-order chain (~7 days/epoch).
        // The owner can re-point the splitter manually afterwards. (H-3)
        if (currentEpoch() == epoch + 1) {
            try splitter.setBuybackToken(win) {
                try splitter.setSwapPath(_candidatePath[epoch][win]) {}
                catch {
                    emit RetargetFailed(epoch, win);
                }
            } catch {
                emit RetargetFailed(epoch, win);
            }
        } else {
            emit StaleWinnerNotApplied(epoch, win);
        }

        emit EpochFinalized(epoch, win, total);
    }

    // ------------------------------------------------------------------
    // Candidate views
    // ------------------------------------------------------------------

    function candidatesOf(uint256 epoch) external view returns (address[] memory) {
        return _candidates[epoch];
    }

    function candidateCount(uint256 epoch) external view returns (uint256) {
        return _candidates[epoch].length;
    }

    function candidatePathOf(uint256 epoch, address token) external view returns (address[] memory) {
        return _candidatePath[epoch][token];
    }

    /// @notice Whether `epoch`'s turnout meets the quorum SNAPSHOTTED for it at
    ///         submit time (matching what finalize enforces). Always true when the
    ///         snapshot is disabled (0), including before a ballot is posted. Note
    ///         this reflects turnout only — an epoch can still finalize as
    ///         {NoWinner} for want of any votes.
    function quorumReached(uint256 epoch) external view returns (bool) {
        uint256 quorum = epochQuorum[epoch];
        if (quorum == 0) return true;
        return totalVotes[epoch] >= quorum;
    }
}
