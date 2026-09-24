// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ---------------------------------------------------------------------------
/// TartEmissionSync — permissionless halving executor (LOCAL / UNRELEASED)
/// ---------------------------------------------------------------------------
/// The one manual chore the emission system used to have was quarterly: the
/// locker halves its own curve automatically, but each reward pool's drip
/// rate (`rewardPerSecond`) had to be re-set by hand to match. This contract
/// deletes that chore — and the trust it required.
///
///   * `sync()` is PERMISSIONLESS and does the entire quarterly ritual in one
///     transaction, any time, called by anyone (a cron guarantees cadence):
///       1. if the locker has accrued emissions, `release()` them to the pools;
///       2. read the locker's CURRENT per-second curve rate;
///       3. for every target the locker itself points at, set that pool's
///          `rewardPerSecond` to `rate × weight` — preserving every other pool
///          parameter — but only when it actually drifted.
///   * This contract has NO owner, NO configuration and NO storage besides the
///     immutable locker address. Its targets and weights are read live from
///     the locker, so even a timelocked retarget needs no redeploy here.
///   * It must be flagged as OPERATOR on the pool contracts
///     (`setOperator(sync, true)` — an owner action). The owner keeps every
///     other power; this contract can only write the curve-derived rate.
///
/// Result: after the token is renounced, halvings keep landing on schedule
/// with no owner in the loop — the curve is law, and anyone can execute it.
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

contract TartEmissionSync {
    uint256 private constant BPS = 10_000;

    IEmissionLocker public immutable locker;

    event Synced(uint256 released, uint256 ratePerSecond, uint256 poolsUpdated);

    constructor(address locker_) {
        locker = IEmissionLocker(locker_);
    }

    /// Reads a V3 pool through a raw staticcall so a locker target WITHOUT
    /// the pools() surface (the staking vault's adapter) is skipped instead
    /// of bricking the loop. Returns ok=false for such targets.
    function _readPool(address pool, uint256 pid)
        internal
        view
        returns (bool ok, uint256 rps, uint64 startTime, uint64 endTime, uint64 lockDuration, bool active)
    {
        (bool success, bytes memory ret) = pool.staticcall(
            abi.encodeWithSelector(IRewardPools.pools.selector, pid)
        );
        if (!success || ret.length < 320) return (false, 0, 0, 0, 0, false);
        (, , rps, startTime, endTime, lockDuration, , , , active) = abi.decode(
            ret,
            (address, address, uint256, uint64, uint64, uint64, uint64, uint256, uint256, bool)
        );
        ok = true;
    }

    /// True when a call to sync() would change anything — the keeper polls
    /// this so quiet periods cost no gas.
    function syncNeeded() external view returns (bool) {
        if (locker.releasable() > 0) return true;
        uint256 rate = locker.currentRatePerSecond();
        IEmissionLocker.Target[] memory targets = locker.targets();
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok, uint256 rps, , , , ) = _readPool(targets[i].pool, targets[i].pid);
            if (ok && rps != (rate * targets[i].weightBps) / BPS) return true;
        }
        return false;
    }

    function sync() external {
        uint256 released;
        if (locker.releasable() > 0) {
            released = locker.release();
        }

        uint256 rate = locker.currentRatePerSecond();
        IEmissionLocker.Target[] memory targets = locker.targets();
        uint256 updated;
        for (uint256 i = 0; i < targets.length; i++) {
            IEmissionLocker.Target memory t = targets[i];
            // A locker target without the V3 pools() surface (the staking
            // vault's adapter) streams on its own — release() above already
            // funded it; there is no rate to mirror.
            (bool ok, uint256 rps, uint64 startTime, uint64 endTime, uint64 lockDuration, bool active) =
                _readPool(t.pool, t.pid);
            if (!ok) continue;
            uint256 want = (rate * t.weightBps) / BPS;
            if (rps != want) {
                IRewardPools(t.pool).setPool(t.pid, want, startTime, endTime, lockDuration, active);
                updated++;
            }
        }
        emit Synced(released, rate, updated);
    }
}
