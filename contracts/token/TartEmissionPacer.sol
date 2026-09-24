// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ---------------------------------------------------------------------------
/// TartEmissionPacer — TVL-paced emission executor (LOCAL / UNRELEASED)
/// ---------------------------------------------------------------------------
/// Drop-in successor of TartEmissionSync for ONE reward pool (the TART/WBNB LP
/// farm). Same permissionless `sync()` / `syncNeeded()` surface, same job of
/// releasing the locker's accrued emission into the pool — but instead of
/// mirroring the locker curve 1:1 into `rewardPerSecond`, it paces the payout
/// to the liquidity actually staked:
///
///   paced   = 2 × stakedLP/lpSupply × TART reserve of the pair × APR / year
///   target  = clamp(paced, minRate, min(maxRate, curveRate))
///
/// The BNB price cancels out of "staked USD × APR / TART price", so the whole
/// rule is computable from on-chain reserves — no oracle, no keeper judgement.
/// Everything the locker releases still lands in the pool; the part not paid
/// out yet simply waits there for LP stakers, and as TVL grows the rate climbs
/// back toward the curve by itself. Halvings still land: the curve is a hard
/// ceiling, so a halved curve pulls the pool rate down on the next sync.
///
/// Safety rails against reserve games (anyone can call sync):
///   * rate never exceeds the locker curve (× the pool's locker weight);
///   * a change must exceed `hysteresisBps` of the current rate;
///   * upward moves are capped at `maxStepUpBps` per sync and spaced by
///     `minInterval`; downward moves are immediate and unbounded.
/// Pushing the rate UP requires raising the pair's TART reserve, i.e. selling
/// TART into the pool (tax + slippage) — which costs far more than any reward
/// it could unlock. The owner (team key) can only tune the parameters inside
/// hard bounds; it can never pay more than the curve or touch anything else.
///
/// Wiring: `farm.setOperator(pacer, true)` and `farm.setOperator(oldSync, false)`
/// (owner actions on the pool contract), then point the emission keeper at
/// this address instead of the sync helper.
/// ---------------------------------------------------------------------------

interface IEmissionLocker {
    struct Target {
        address pool;
        uint256 pid;
        uint256 weightBps;
    }

    function releasable() external view returns (uint256);

    function release() external returns (uint256);

    function currentRatePerSecond() external view returns (uint256);

    function targets() external view returns (Target[] memory);
}

interface IRewardPools {
    function pools(uint256 pid)
        external
        view
        returns (
            address stakeToken,
            address rewardToken,
            uint256 rewardPerSecond,
            uint64 startTime,
            uint64 endTime,
            uint64 lockDuration,
            uint64 lastRewardTime,
            uint256 accRewardPerShare,
            uint256 totalStaked,
            bool active
        );

    function setPool(
        uint256 pid,
        uint256 rewardPerSecond,
        uint64 startTime,
        uint64 endTime,
        uint64 lockDuration,
        bool active
    ) external;
}

interface IPair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112, uint112, uint32);

    function totalSupply() external view returns (uint256);
}

contract TartEmissionPacer {
    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;

    IEmissionLocker public immutable locker;
    IRewardPools public immutable farm;
    uint256 public immutable pid;
    IPair public immutable pair;
    address public immutable rewardToken;
    bool private immutable rewardIsToken0;

    address public owner;

    // Tunables (owner, bounded). Rates are reward-token units per second.
    uint256 public aprBps; // target APR on staked LP value, e.g. 40_000 = 400 %
    uint256 public minRatePerSecond; // floor so a near-empty farm still pays something
    uint256 public maxRatePerSecond; // ceiling below the curve (optional; >= curve = no-op)
    uint256 public hysteresisBps; // ignore drifts smaller than this share of the current rate
    uint256 public maxStepUpBps; // largest upward move per sync, as a share of the current rate
    uint256 public minInterval; // minimum spacing between upward moves
    uint256 public lastRateChange;

    event Synced(uint256 released, uint256 curveRate, uint256 targetRate, uint256 appliedRate);
    event RateWriteFailed(uint256 currentRate, uint256 attemptedRate);
    event ParamsSet(
        uint256 aprBps,
        uint256 minRatePerSecond,
        uint256 maxRatePerSecond,
        uint256 hysteresisBps,
        uint256 maxStepUpBps,
        uint256 minInterval
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Pacer: not owner");
        _;
    }

    constructor(
        address locker_,
        address farm_,
        uint256 pid_,
        address pair_,
        address rewardToken_,
        address owner_,
        uint256 aprBps_,
        uint256 minRatePerSecond_,
        uint256 maxRatePerSecond_
    ) {
        require(locker_ != address(0) && farm_ != address(0) && pair_ != address(0), "Pacer: zero address");
        require(owner_ != address(0), "Pacer: zero owner");
        address t0 = IPair(pair_).token0();
        address t1 = IPair(pair_).token1();
        require(t0 == rewardToken_ || t1 == rewardToken_, "Pacer: token not in pair");
        (address stakeToken, address poolReward, , , , , , , , ) = IRewardPools(farm_).pools(pid_);
        require(stakeToken == pair_, "Pacer: pool stakes another token");
        require(poolReward == rewardToken_, "Pacer: pool pays another token");

        locker = IEmissionLocker(locker_);
        farm = IRewardPools(farm_);
        pid = pid_;
        pair = IPair(pair_);
        rewardToken = rewardToken_;
        rewardIsToken0 = t0 == rewardToken_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        _setParams(aprBps_, minRatePerSecond_, maxRatePerSecond_, 1_000, 5_000, 1 hours);
    }

    // ----------------------------------------------------------------- Views
    /// The locker curve's share for this pool: rate × the pool's weight in the
    /// locker's target list. Zero when the locker no longer points here — a
    /// pool that gets no emission must not promise any.
    function curveRate() public view returns (uint256) {
        uint256 rate = locker.currentRatePerSecond();
        IEmissionLocker.Target[] memory targets = locker.targets();
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].pool == address(farm) && targets[i].pid == pid) {
                return (rate * targets[i].weightBps) / BPS;
            }
        }
        return 0;
    }

    /// The APR rule before clamping, in reward-token units per second.
    function pacedRate() public view returns (uint256) {
        uint256 lpSupply = pair.totalSupply();
        if (lpSupply == 0) return 0;
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        uint256 reserve = rewardIsToken0 ? uint256(r0) : uint256(r1);
        (, , , , , , , , uint256 totalStaked, ) = farm.pools(pid);
        // staked LP value in TART terms = 2 × share × TART reserve; per year × APR.
        return (2 * totalStaked * reserve * aprBps) / (lpSupply * BPS * YEAR);
    }

    /// What the pool rate should be right now, and the curve it is capped by.
    function targetRate() public view returns (uint256 want, uint256 curve) {
        curve = curveRate();
        uint256 cap = maxRatePerSecond < curve ? maxRatePerSecond : curve;
        want = pacedRate();
        if (want < minRatePerSecond) want = minRatePerSecond;
        if (want > cap) want = cap;
    }

    function currentRate() public view returns (uint256 rps) {
        (, , rps, , , , , , , ) = farm.pools(pid);
    }

    /// True when a call to sync() would change anything — the keeper polls
    /// this so quiet periods cost no gas.
    function syncNeeded() external view returns (bool) {
        if (locker.releasable() > 0) return true;
        uint256 rps = currentRate();
        (uint256 want, ) = targetRate();
        return _nextRate(rps, want) != rps;
    }

    // ---------------------------------------------------------------- Actions
    /// Permissionless: release accrued emission into the pool, then re-pace.
    function sync() external {
        uint256 released;
        if (locker.releasable() > 0) {
            released = locker.release();
        }

        (, , uint256 rps, uint64 startTime, uint64 endTime, uint64 lockDuration, , , , bool active) = farm.pools(pid);
        (uint256 want, uint256 curve) = targetRate();
        uint256 next = _nextRate(rps, want);
        if (next != rps) {
            // The rate write must never hold the emission hostage: if the farm
            // refuses it (operator revoked, pool rules), the release above still
            // stands and the rate simply stays where it is until the next sync.
            try farm.setPool(pid, next, startTime, endTime, lockDuration, active) {
                lastRateChange = block.timestamp;
            } catch {
                emit RateWriteFailed(rps, next);
                next = rps;
            }
        }
        emit Synced(released, curve, want, next);
    }

    /// The rate a sync would apply now: `want` filtered through hysteresis,
    /// the upward step cap and the upward spacing. Downward moves pass as is.
    function _nextRate(uint256 rps, uint256 want) internal view returns (uint256) {
        if (want == rps) return rps;
        if (want < rps) {
            uint256 down = rps - want;
            // A small dip is noise; a zero target (pool dropped by the locker) always lands.
            if (want != 0 && (down * BPS) / rps <= hysteresisBps) return rps;
            return want;
        }
        // Upward.
        if (block.timestamp < lastRateChange + minInterval) return rps;
        if (rps == 0) return want;
        uint256 up = want - rps;
        if ((up * BPS) / rps <= hysteresisBps) return rps;
        uint256 stepCap = rps + (rps * maxStepUpBps) / BPS;
        return want > stepCap ? stepCap : want;
    }

    // ------------------------------------------------------------------ Owner
    function setParams(
        uint256 aprBps_,
        uint256 minRatePerSecond_,
        uint256 maxRatePerSecond_,
        uint256 hysteresisBps_,
        uint256 maxStepUpBps_,
        uint256 minInterval_
    ) external onlyOwner {
        _setParams(aprBps_, minRatePerSecond_, maxRatePerSecond_, hysteresisBps_, maxStepUpBps_, minInterval_);
    }

    function _setParams(
        uint256 aprBps_,
        uint256 minRatePerSecond_,
        uint256 maxRatePerSecond_,
        uint256 hysteresisBps_,
        uint256 maxStepUpBps_,
        uint256 minInterval_
    ) internal {
        require(aprBps_ >= 100 && aprBps_ <= 100_000, "Pacer: apr out of range"); // 1 % .. 1000 %
        require(minRatePerSecond_ <= maxRatePerSecond_, "Pacer: min above max");
        require(hysteresisBps_ <= 5_000, "Pacer: hysteresis too wide");
        require(maxStepUpBps_ >= 1_000, "Pacer: step cap too tight");
        require(minInterval_ <= 1 days, "Pacer: interval too long");
        aprBps = aprBps_;
        minRatePerSecond = minRatePerSecond_;
        maxRatePerSecond = maxRatePerSecond_;
        hysteresisBps = hysteresisBps_;
        maxStepUpBps = maxStepUpBps_;
        minInterval = minInterval_;
        emit ParamsSet(aprBps_, minRatePerSecond_, maxRatePerSecond_, hysteresisBps_, maxStepUpBps_, minInterval_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Pacer: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
