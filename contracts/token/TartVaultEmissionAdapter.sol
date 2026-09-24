// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ---------------------------------------------------------------------------
/// TartVaultEmissionAdapter — locker → vault funding bridge (LOCAL/UNRELEASED)
/// ---------------------------------------------------------------------------
/// The emission locker funds its targets through the farm interface —
/// `fundRewards(pid, amount)` with a transferFrom pull — while the staking
/// vault is fed through `notifyRewardAmount(amount)` by a whitelisted
/// notifier. This 30-line bridge speaks both dialects, so the vault can be a
/// first-class locker target:
///
///   locker.release() ──approve──▶ adapter.fundRewards(pid, share)
///        pulls from caller, approves the vault, vault pulls + streams 7d
///
///   * STATELESS and OWNERLESS: no funds ever rest here beyond the single
///     transaction, nothing to configure, nothing to rug.
///   * `pid` is accepted for interface compatibility and ignored — the vault
///     has no pools, its tiers weight one shared stream.
///   * fundRewards is permissionless on purpose (the farm's is too): a third
///     party "funding" the vault through it is simply donating to stakers.
///   * The vault must flag this adapter via `setRewardNotifier(adapter, true)`.
/// ---------------------------------------------------------------------------

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);
}

interface IStakingVault {
    function stakingToken() external view returns (address);

    function notifyRewardAmount(uint256 amount) external;
}

contract TartVaultEmissionAdapter {
    IStakingVault public immutable vault;
    IERC20 public immutable token;

    event Bridged(address indexed from, uint256 amount);

    error TransferFailed();

    constructor(address vault_) {
        vault = IStakingVault(vault_);
        token = IERC20(IStakingVault(vault_).stakingToken());
    }

    /// Locker-compatible funding entrypoint: pull, approve, notify — the whole
    /// amount reaches the vault's reward stream in the same transaction.
    function fundRewards(uint256, uint256 amount) external {
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        if (!token.approve(address(vault), amount)) revert TransferFailed();
        vault.notifyRewardAmount(amount);
        emit Bridged(msg.sender, amount);
    }
}
