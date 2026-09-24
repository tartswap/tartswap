// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ---------------------------------------------------------------------------
/// TartVestedAirdrop — claim-based airdrop with a stepped unlock (LOCAL/UNRELEASED)
/// ---------------------------------------------------------------------------
/// The 5% community airdrop, restructured so receivers cannot dump on listing
/// day: 25% of each allocation is claimable the moment vesting starts, then a
/// further 25% at +30, +60 and +90 days. Steps, not a stream — each month a
/// quarter of the allocation unlocks at once.
///
///   * The OWNER (admin panel) builds the roster: `setAllocations` upserts
///     (wallet, total) pairs in batches — the CREPE staker snapshot plus any
///     manually added community wallets. Amounts are absolute totals, so
///     re-sending a batch is idempotent, and a typo is fixed by upserting the
///     corrected number. An allocation can never be lowered below what that
///     wallet has already claimed.
///   * `start()` begins vesting for everyone at once (listing day) and locks
///     the roster's economics: after start, allocations can only be ADDED or
///     RAISED — never lowered — so a published entitlement cannot be clawed
///     back. There is no revoke and no per-wallet pause.
///   * `claim()` is per-wallet and pull-based: transfers unlocked-minus-claimed.
///     `claimFor(wallet)` lets anyone pay gas for a stranded wallet; tokens
///     always go to the allocated wallet, never the caller.
///   * `sweepExcess` can withdraw ONLY tokens above what the roster is still
///     owed (funding mistakes, dust) — never allocated-but-unclaimed tokens.
///
/// The /token page reads `allocationOf/claimedOf/claimableOf/nextUnlockAt` to
/// render each wallet's timeline live.
/// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

contract TartVestedAirdrop {
    uint256 public constant STEP_BPS = 2_500; // 25% per step
    uint256 public constant STEP_SECONDS = 30 days;
    uint256 public constant STEP_COUNT = 4; // TGE + 3 monthly steps
    uint256 private constant BPS = 10_000;

    IERC20 public immutable token;
    address public owner;

    /// 0 until `start()` — nothing is claimable before it.
    uint64 public startAt;

    mapping(address => uint256) public allocationOf;
    mapping(address => uint256) public claimedOf;
    uint256 public totalAllocated;
    uint256 public totalClaimed;

    event AllocationSet(address indexed wallet, uint256 total);
    event Started(uint64 at);
    event Claimed(address indexed wallet, uint256 amount, address indexed caller);
    event ExcessSwept(uint256 amount, address indexed to);
    event OwnerChanged(address indexed newOwner);

    error NotOwner();
    error AlreadyStarted();
    error NotStarted();
    error LengthMismatch();
    error BelowClaimed();
    error LoweredAfterStart();
    error NothingToClaim();
    error ExceedsExcess();
    error TransferFailed();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address token_) {
        token = IERC20(token_);
        owner = msg.sender;
    }

    // ── Roster ───────────────────────────────────────────────────────────────

    /// Upserts absolute allocation totals. Before start anything goes (typo
    /// fixes included, down to a wallet's already-claimed floor — which is 0
    /// then anyway). After start an entry can only grow.
    function setAllocations(address[] calldata wallets, uint256[] calldata totals)
        external
        onlyOwner
    {
        if (wallets.length != totals.length) revert LengthMismatch();
        bool started = startAt != 0;
        for (uint256 i = 0; i < wallets.length; i++) {
            address w = wallets[i];
            if (w == address(0)) revert ZeroAddress();
            uint256 next = totals[i];
            uint256 prev = allocationOf[w];
            if (next < claimedOf[w]) revert BelowClaimed();
            if (started && next < prev) revert LoweredAfterStart();
            totalAllocated = totalAllocated - prev + next;
            allocationOf[w] = next;
            emit AllocationSet(w, next);
        }
    }

    /// Begins vesting for the whole roster. One-way.
    function start() external onlyOwner {
        if (startAt != 0) revert AlreadyStarted();
        startAt = uint64(block.timestamp);
        emit Started(startAt);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// Unlocked share of an allocation in bps: 2500 at start, +2500 per 30 days,
    /// capped at 10000.
    function unlockedBps() public view returns (uint256) {
        if (startAt == 0) return 0;
        uint256 steps = 1 + (block.timestamp - startAt) / STEP_SECONDS;
        if (steps > STEP_COUNT) steps = STEP_COUNT;
        return steps * STEP_BPS;
    }

    function unlockedOf(address wallet) public view returns (uint256) {
        return (allocationOf[wallet] * unlockedBps()) / BPS;
    }

    function claimableOf(address wallet) public view returns (uint256) {
        uint256 unlocked = unlockedOf(wallet);
        uint256 claimed = claimedOf[wallet];
        return unlocked > claimed ? unlocked - claimed : 0;
    }

    /// Timestamp of the next step, or 0 when fully unlocked / not started.
    function nextUnlockAt() external view returns (uint256) {
        if (startAt == 0) return 0;
        uint256 steps = 1 + (block.timestamp - startAt) / STEP_SECONDS;
        if (steps >= STEP_COUNT) return 0;
        return startAt + steps * STEP_SECONDS;
    }

    /// What the roster is still owed — the balance floor sweepExcess protects.
    function outstanding() public view returns (uint256) {
        return totalAllocated - totalClaimed;
    }

    // ── Claims ───────────────────────────────────────────────────────────────

    function claim() external {
        _claim(msg.sender);
    }

    /// Anyone may pay the gas; tokens always go to the allocated wallet.
    function claimFor(address wallet) external {
        _claim(wallet);
    }

    function _claim(address wallet) internal {
        if (startAt == 0) revert NotStarted();
        uint256 amount = claimableOf(wallet);
        if (amount == 0) revert NothingToClaim();
        claimedOf[wallet] += amount;
        totalClaimed += amount;
        if (!token.transfer(wallet, amount)) revert TransferFailed();
        emit Claimed(wallet, amount, msg.sender);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// Only tokens beyond what the roster is still owed can ever leave this way.
    function sweepExcess(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = token.balanceOf(address(this));
        if (balance < outstanding() + amount) revert ExceedsExcess();
        if (!token.transfer(to, amount)) revert TransferFailed();
        emit ExcessSwept(amount, to);
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }
}
