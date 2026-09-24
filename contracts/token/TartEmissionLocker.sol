// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// ---------------------------------------------------------------------------
/// TartEmissionLocker — the farm/staking reward budget (UNRELEASED)
/// ---------------------------------------------------------------------------
/// Holds the share of TART supply earmarked for staking and LP-farm emissions,
/// and drips it into the reward pools on a schedule nobody can accelerate.
///
/// The point of this contract is what it CANNOT do. There is no `withdraw`, no
/// `sweep`, no `rescue`, no owner escape hatch of any kind. The only ways TART
/// leaves are:
///
///   * `release()` — permissionless. Sends the amount that has accrued since
///     the last call into the registered reward pools via `fundRewards`. The
///     team cannot withhold emissions, and cannot pull them forward either.
///   * `burn()`    — destroys locker-held supply outright. Strictly good for
///     holders, so it needs no delay.
///
/// Emissions follow a halving curve: `initialRatePerSecond` for the first
/// period, half that for the next, and so on until they floor at zero. Nothing
/// can raise the rate — not the owner, not a migration, not a redeploy, because
/// the schedule is immutable and derived from the deploy timestamp. This is the
/// structural answer to the farm death spiral, where emissions stay flat while
/// the price they are denominated in falls.
///
/// Retargeting emissions to different pools is possible but slow: new targets
/// are queued, and can only be executed after `TIMELOCK`. That window is the
/// holders' warning that the reward destination is about to change.
///
/// ⚠️ This contract must be fee-exempt on the TART token, or every `fundRewards`
///    call would be taxed on the way out.
/// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);
}

// The token is CREPE-verbatim and has no burn(); worse, its payable fallback
// would swallow the selector silently. Burns therefore go to the dead address,
// the same way the token's own auto-liquidity LP is burned.
address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

/// The reward-pool surface of TartLPFarmV3 / TartStakingV3.
interface ITartRewardPool {
    function fundRewards(uint256 pid, uint256 amount) external;
}

contract TartEmissionLocker {
    // ------------------------------------------------------------- Constants
    uint256 public constant BPS = 10_000;
    /// Delay before a queued target change can be executed.
    uint256 public constant TIMELOCK = 7 days;
    /// The rate is right-shifted once per elapsed period; past this it is zero.
    uint256 public constant MAX_HALVINGS = 32;

    // ------------------------------------------------------------ Immutables
    IERC20 public immutable token;
    uint256 public immutable startTime;
    uint256 public immutable halvingPeriod;
    uint256 public immutable initialRatePerSecond;

    // ----------------------------------------------------------------- State
    address public owner;

    struct Target {
        address pool; // TartLPFarmV3 / TartStakingV3 instance
        uint256 pid; // pool id inside that instance
        uint256 weightBps; // share of each release; all targets must total 10000
    }

    Target[] private _targets;

    uint256 public totalReleased;
    uint256 public totalBurned;
    uint256 public lastReleaseTime;

    bytes32 public pendingTargetsHash;
    uint256 public pendingTargetsReadyAt;

    // ---------------------------------------------------------------- Events
    event Released(uint256 amount, uint256 totalReleased);
    event PoolFunded(address indexed pool, uint256 indexed pid, uint256 amount);
    event Burned(uint256 amount, uint256 totalBurned);
    event TargetsQueued(bytes32 indexed targetsHash, uint256 readyAt);
    event TargetsExecuted(bytes32 indexed targetsHash);
    event TargetsQueueCancelled(bytes32 indexed targetsHash);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Locker: caller is not the owner");
        _;
    }

    /// @param token_                 TART.
    /// @param owner_                 May queue target changes and burn. Nothing else.
    /// @param halvingPeriod_         Seconds between emission halvings.
    /// @param initialRatePerSecond_  Emission rate during the first period.
    /// @param initialTargets         Reward pools funded from day one.
    constructor(
        address token_,
        address owner_,
        uint256 halvingPeriod_,
        uint256 initialRatePerSecond_,
        Target[] memory initialTargets
    ) {
        require(token_ != address(0), "Locker: token is the zero address");
        require(owner_ != address(0), "Locker: owner is the zero address");
        require(halvingPeriod_ >= 1 days, "Locker: halving period too short");
        require(initialRatePerSecond_ > 0, "Locker: rate must be positive");

        token = IERC20(token_);
        owner = owner_;
        halvingPeriod = halvingPeriod_;
        initialRatePerSecond = initialRatePerSecond_;
        startTime = block.timestamp;
        lastReleaseTime = block.timestamp;

        _setTargets(initialTargets);

        emit OwnershipTransferred(address(0), owner_);
    }

    // ----------------------------------------------------------------- Views
    function targets() external view returns (Target[] memory) {
        return _targets;
    }

    function targetCount() external view returns (uint256) {
        return _targets.length;
    }

    /// Emission rate right now, in token units per second.
    function currentRatePerSecond() public view returns (uint256) {
        uint256 elapsedPeriods = (block.timestamp - startTime) / halvingPeriod;
        if (elapsedPeriods >= MAX_HALVINGS) return 0;
        return initialRatePerSecond >> elapsedPeriods;
    }

    /// Everything this schedule will ever emit, summed across all halvings.
    /// A halving curve is a geometric series, so the total converges to roughly
    /// `initialRatePerSecond * halvingPeriod * 2` no matter how long you wait —
    /// fund the locker with about this much. Fund it with far more and the
    /// surplus is stranded until it is burned; fund it with far less and
    /// emissions stop early, at the balance rather than at the schedule.
    function totalScheduledEmission() external view returns (uint256 total) {
        for (uint256 i = 0; i < MAX_HALVINGS; i++) {
            total += (initialRatePerSecond >> i) * halvingPeriod;
        }
    }

    /// Amount that has accrued since the last release, capped by the balance
    /// actually held. The cap is what makes the schedule self-terminating: once
    /// the budget is spent, `release()` stops paying out.
    function releasable() public view returns (uint256) {
        uint256 accrued = _accrued(lastReleaseTime, block.timestamp);
        uint256 balance = token.balanceOf(address(this));
        return accrued > balance ? balance : accrued;
    }

    /// Integrates the step-function emission rate across period boundaries. A
    /// flat `rate * elapsed` would over-pay whenever a release spans a halving.
    function _accrued(uint256 from, uint256 to) internal view returns (uint256 total) {
        if (to <= from) return 0;

        uint256 period = (from - startTime) / halvingPeriod;
        uint256 cursor = from;

        while (cursor < to && period < MAX_HALVINGS) {
            uint256 periodEnd = startTime + ((period + 1) * halvingPeriod);
            uint256 segmentEnd = periodEnd < to ? periodEnd : to;
            total += (segmentEnd - cursor) * (initialRatePerSecond >> period);
            cursor = segmentEnd;
            period++;
        }
    }

    // --------------------------------------------------------------- Release
    /// Permissionless on purpose: emissions are a commitment to stakers, not a
    /// lever the team gets to hold.
    function release() external returns (uint256 amount) {
        amount = releasable();
        require(amount > 0, "Locker: nothing to release");

        lastReleaseTime = block.timestamp;
        totalReleased += amount;

        uint256 distributed;
        uint256 length = _targets.length;

        for (uint256 i = 0; i < length; i++) {
            Target memory target = _targets[i];
            // The final target absorbs the rounding dust so the full amount
            // always leaves the contract.
            uint256 share = i == length - 1 ? amount - distributed : (amount * target.weightBps) / BPS;
            if (share == 0) continue;
            distributed += share;

            require(token.approve(target.pool, share), "Locker: approve failed");
            ITartRewardPool(target.pool).fundRewards(target.pid, share);
            require(token.approve(target.pool, 0), "Locker: approve reset failed");

            emit PoolFunded(target.pool, target.pid, share);
        }

        emit Released(amount, totalReleased);
    }

    // ------------------------------------------------------------------ Burn
    /// Removes locker-held supply from circulation forever by parking it at the
    /// dead address. Reduces what can ever be emitted, so it can only help
    /// holders and needs no timelock. totalSupply() does not shrink — the dead
    /// balance is the on-chain proof, exactly like the token's burned LP.
    function burn(uint256 amount) external onlyOwner {
        require(amount > 0, "Locker: nothing to burn");
        require(amount <= token.balanceOf(address(this)), "Locker: amount exceeds balance");

        totalBurned += amount;
        require(token.transfer(DEAD_ADDRESS, amount), "Locker: burn transfer failed");

        emit Burned(amount, totalBurned);
    }

    // --------------------------------------------------------------- Targets
    function queueTargets(Target[] calldata newTargets) external onlyOwner {
        _validateTargets(newTargets);

        bytes32 targetsHash = keccak256(abi.encode(newTargets));
        pendingTargetsHash = targetsHash;
        pendingTargetsReadyAt = block.timestamp + TIMELOCK;

        emit TargetsQueued(targetsHash, pendingTargetsReadyAt);
    }

    function cancelQueuedTargets() external onlyOwner {
        require(pendingTargetsHash != bytes32(0), "Locker: nothing queued");

        bytes32 targetsHash = pendingTargetsHash;
        pendingTargetsHash = bytes32(0);
        pendingTargetsReadyAt = 0;

        emit TargetsQueueCancelled(targetsHash);
    }

    function executeTargets(Target[] calldata newTargets) external onlyOwner {
        require(pendingTargetsHash != bytes32(0), "Locker: nothing queued");
        require(block.timestamp >= pendingTargetsReadyAt, "Locker: timelock not elapsed");
        require(keccak256(abi.encode(newTargets)) == pendingTargetsHash, "Locker: targets mismatch");

        pendingTargetsHash = bytes32(0);
        pendingTargetsReadyAt = 0;

        _setTargets(newTargets);

        emit TargetsExecuted(keccak256(abi.encode(newTargets)));
    }

    function _validateTargets(Target[] memory newTargets) private pure {
        require(newTargets.length > 0, "Locker: no targets");
        require(newTargets.length <= 16, "Locker: too many targets");

        uint256 totalWeight;
        for (uint256 i = 0; i < newTargets.length; i++) {
            require(newTargets[i].pool != address(0), "Locker: target is the zero address");
            require(newTargets[i].weightBps > 0, "Locker: target weight is zero");
            totalWeight += newTargets[i].weightBps;
        }
        require(totalWeight == BPS, "Locker: weights must total 10000");
    }

    function _setTargets(Target[] memory newTargets) private {
        _validateTargets(newTargets);

        delete _targets;
        for (uint256 i = 0; i < newTargets.length; i++) {
            _targets.push(newTargets[i]);
        }
    }

    // ------------------------------------------------------------- Ownership
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Locker: new owner is the zero address");

        address previous = owner;
        owner = newOwner;

        emit OwnershipTransferred(previous, newOwner);
    }
}
