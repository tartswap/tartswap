// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBuybackDistributor} from "../interfaces/IBuybackDistributor.sol";
import {IUniswapV2Router} from "../interfaces/IUniswapV2Router.sol";

interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/// @title BuybackDistributor
/// @notice Accrues collateral-denominated protocol fees and periodically buys back the
///         (future) TartSwap target token on a whitelisted UniswapV2-compatible router,
///         then burns the proceeds.
///
/// @dev Design invariants:
///      - Accrued collateral can NEVER be withdrawn by the owner. There is deliberately
///        no `withdraw` function; `rescueToken` refuses the target token and any token
///        that has ever been accrued as collateral. The only exit for accrued collateral
///        is `executeDailyBuyback`, which swaps it and burns the output.
///      - `executeDailyBuyback` is permissionless (anyone may call), rate-limited by a
///        24h per-collateral cooldown, a per-collateral minimum balance threshold, and
///        an optional per-collateral per-call swap-input cap (maxBuybackInPerCall).
///      - `targetToken` starts unset (address(0)). It can be set ONCE directly by the
///        owner; every subsequent change must pass a two-step propose/accept timelock of
///        `TIMELOCK_DELAY` (24h). The router follows the same pattern (this is the
///        router "whitelist": only a timelocked owner action can point the contract at
///        a different router).
///      - Slippage: minAmountOut is derived from `router.getAmountsOut` with a
///        `maxSlippageBps` haircut. NOTE (documented in docs/AUDIT_CHECKLIST.md):
///        an on-chain spot quote can be manipulated in the same block; for mainnet a
///        keeper supplying an off-chain reference price, TWAP checks, or small per-swap
///        caps are recommended, and an independent audit is required before mainnet.
///
///      Owner SHOULD be a multisig behind a timelock in production.
contract BuybackDistributor is IBuybackDistributor, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------
    error ZeroAddress();
    error ZeroAmount();
    error AlreadySet();
    error TargetTokenNotSet();
    error RouterNotSet();
    error NoPendingChange();
    error TimelockNotElapsed();
    error CooldownActive();
    error BelowMinimumBalance();
    error InvalidPath();
    error InvalidSlippage();
    error NotACollateral();
    error RescueRestricted();
    error SlippageExceeded();
    error FeeOnTransferNotSupported();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event BuybackAccrued(address indexed token, uint256 amount, address indexed source);
    event BuybackExecuted(
        address indexed token,
        uint256 amountIn,
        uint256 amountOut,
        uint256 burned,
        address indexed caller,
        uint256 timestamp
    );
    event TargetTokenProposed(address indexed token, uint64 eta);
    event TargetTokenSet(address indexed token);
    event RouterProposed(address indexed router, uint64 eta);
    event RouterSet(address indexed router);
    event SwapPathSet(address indexed collateral, address[] path);
    event MinBuybackAmountSet(address indexed collateral, uint256 minAmount);
    event MaxBuybackInPerCallSet(address indexed collateral, uint256 cap);
    event MaxSlippageSet(uint16 maxSlippageBps);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------
    // Constants / config
    // ------------------------------------------------------------------
    uint256 public constant BUYBACK_COOLDOWN = 24 hours;
    uint256 public constant TIMELOCK_DELAY = 24 hours;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @dev Hard cap for the slippage config (10%).
    uint16 public constant MAX_SLIPPAGE_CAP_BPS = 1_000;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public targetToken;
    address public pendingTargetToken;
    uint64 public targetTokenEta;

    address public router;
    address public pendingRouter;
    uint64 public routerEta;

    /// @notice Slippage tolerance applied to the router quote (default 3%).
    uint16 public maxSlippageBps = 300;

    /// @notice Swap path per collateral. path[0] == collateral, path[last] == targetToken.
    ///         A WBNB (or any) hop is supported by simply including it in the path.
    mapping(address collateral => address[] path) private _swapPath;

    /// @notice Minimum collateral balance required before a buyback may execute.
    mapping(address collateral => uint256 minAmount) public minBuybackAmount;

    /// @notice Optional per-call swap-input cap per collateral. 0 = uncapped (the
    ///         whole balance is swapped in one shot, as before). When set, a single
    ///         `executeDailyBuyback` swaps at most this much collateral and leaves
    ///         the remainder for the next (cooldown-gated) call — bounding a single
    ///         permissionless swap's price impact / sandwich surface on mainnet.
    mapping(address collateral => uint256 cap) public maxBuybackInPerCall;

    /// @notice Cumulative amount ever accrued per token (informational).
    mapping(address token => uint256 amount) public accruedTotal;

    /// @notice Permanent marker: once a token has been accrued it can never be rescued.
    mapping(address token => bool marked) public isCollateral;

    /// @notice Last successful buyback timestamp per collateral.
    mapping(address collateral => uint256 timestamp) public lastBuybackAt;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ------------------------------------------------------------------
    // Accrual
    // ------------------------------------------------------------------

    /// @inheritdoc IBuybackDistributor
    /// @dev Pull-based so the accrual amount is provable: the caller (FeeVault or anyone
    ///      donating to the burn) approves first. Fee-on-transfer tokens are rejected.
    function accrue(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert FeeOnTransferNotSupported();

        accruedTotal[token] += amount;
        isCollateral[token] = true;
        emit BuybackAccrued(token, amount, msg.sender);
    }

    // ------------------------------------------------------------------
    // Buyback + burn
    // ------------------------------------------------------------------

    /// @inheritdoc IBuybackDistributor
    /// @dev Callable by ANYONE, rate-limited by the 24h per-collateral cooldown.
    ///      Swaps up to `maxBuybackInPerCall[collateral]` of the collateral balance
    ///      (the WHOLE balance when the cap is 0) into `targetToken` using the
    ///      configured path, then burns the output: tries `targetToken.burn(amount)`
    ///      and falls back to a transfer to 0x..dEaD for tokens without a burn
    ///      function. Special case: when the collateral IS the target token, the
    ///      capped amount is burned directly without a swap.
    ///
    ///      MAINNET NOTE: this call is permissionless and (uncapped) drains the
    ///      whole balance through a single on-chain swap, whose spot quote is
    ///      manipulable in-block. For mainnet, gate it behind a keeper AND/OR set a
    ///      `maxBuybackInPerCall` per collateral so no single call can move price
    ///      by more than a bounded amount (see docs/AUDIT_CHECKLIST.md).
    function executeDailyBuyback(address collateral) external nonReentrant {
        address target = targetToken;
        if (target == address(0)) revert TargetTokenNotSet();
        if (!isCollateral[collateral]) revert NotACollateral();
        if (block.timestamp < lastBuybackAt[collateral] + BUYBACK_COOLDOWN) revert CooldownActive();

        uint256 balance = IERC20(collateral).balanceOf(address(this));
        if (balance == 0 || balance < minBuybackAmount[collateral]) revert BelowMinimumBalance();

        // Bound a single permissionless swap's size when a cap is configured; the
        // remainder waits for the next cooldown-gated call.
        uint256 cap = maxBuybackInPerCall[collateral];
        uint256 amountIn = (cap != 0 && cap < balance) ? cap : balance;

        lastBuybackAt[collateral] = block.timestamp;

        if (collateral == target) {
            // Fees are already denominated in the target token: burn directly.
            uint256 burnedDirect = _burn(target, amountIn);
            emit BuybackExecuted(collateral, amountIn, amountIn, burnedDirect, msg.sender, block.timestamp);
            return;
        }

        address routerAddress = router;
        if (routerAddress == address(0)) revert RouterNotSet();

        address[] memory path = _swapPath[collateral];
        if (path.length < 2 || path[0] != collateral || path[path.length - 1] != target) revert InvalidPath();

        uint256[] memory quoted = IUniswapV2Router(routerAddress).getAmountsOut(amountIn, path);
        uint256 quotedOut = quoted[quoted.length - 1];
        if (quotedOut == 0) revert ZeroAmount();
        uint256 minAmountOut = (quotedOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        if (minAmountOut == 0) revert ZeroAmount();

        uint256 targetBefore = IERC20(target).balanceOf(address(this));

        IERC20(collateral).forceApprove(routerAddress, amountIn);
        IUniswapV2Router(routerAddress).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        );
        IERC20(collateral).forceApprove(routerAddress, 0);

        uint256 amountOut = IERC20(target).balanceOf(address(this)) - targetBefore;
        if (amountOut < minAmountOut) revert SlippageExceeded();

        uint256 burned = _burn(target, amountOut);
        emit BuybackExecuted(collateral, amountIn, amountOut, burned, msg.sender, block.timestamp);
    }

    function _burn(address token, uint256 amount) private returns (uint256 burned) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        // Try a native burn first; tokens without burn() (or with a reverting burn)
        // fall back to a transfer to the dead address.
        try IERC20Burnable(token).burn(amount) {
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            if (balanceBefore - balanceAfter >= amount) {
                return amount;
            }
            // Burn call "succeeded" but did not reduce our balance (non-standard token):
            // send whatever is still owed to the dead address.
            uint256 remaining = amount - (balanceBefore - balanceAfter);
            IERC20(token).safeTransfer(DEAD_ADDRESS, remaining);
            return amount;
        } catch {
            IERC20(token).safeTransfer(DEAD_ADDRESS, amount);
            return amount;
        }
    }

    // ------------------------------------------------------------------
    // Target token / router governance (set once, then 24h two-step timelock)
    // ------------------------------------------------------------------

    /// @notice One-time initial assignment of the target token (only while unset).
    function setInitialTargetToken(address token) external onlyOwner {
        if (targetToken != address(0)) revert AlreadySet();
        if (token == address(0)) revert ZeroAddress();
        targetToken = token;
        emit TargetTokenSet(token);
    }

    function proposeTargetToken(address token) external onlyOwner {
        if (targetToken == address(0)) revert TargetTokenNotSet(); // use setInitialTargetToken first
        if (token == address(0)) revert ZeroAddress();
        pendingTargetToken = token;
        targetTokenEta = uint64(block.timestamp + TIMELOCK_DELAY);
        emit TargetTokenProposed(token, targetTokenEta);
    }

    function acceptTargetToken() external onlyOwner {
        if (pendingTargetToken == address(0)) revert NoPendingChange();
        if (block.timestamp < targetTokenEta) revert TimelockNotElapsed();
        targetToken = pendingTargetToken;
        pendingTargetToken = address(0);
        targetTokenEta = 0;
        emit TargetTokenSet(targetToken);
    }

    /// @notice One-time initial assignment of the whitelisted router (only while unset).
    function setInitialRouter(address router_) external onlyOwner {
        if (router != address(0)) revert AlreadySet();
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
        emit RouterSet(router_);
    }

    function proposeRouter(address router_) external onlyOwner {
        if (router == address(0)) revert RouterNotSet(); // use setInitialRouter first
        if (router_ == address(0)) revert ZeroAddress();
        pendingRouter = router_;
        routerEta = uint64(block.timestamp + TIMELOCK_DELAY);
        emit RouterProposed(router_, routerEta);
    }

    function acceptRouter() external onlyOwner {
        if (pendingRouter == address(0)) revert NoPendingChange();
        if (block.timestamp < routerEta) revert TimelockNotElapsed();
        router = pendingRouter;
        pendingRouter = address(0);
        routerEta = 0;
        emit RouterSet(router);
    }

    // ------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------

    /// @notice Sets the swap path for a collateral. Supports intermediate hops
    ///         (e.g. collateral -> WBNB -> targetToken).
    function setSwapPath(address collateral, address[] calldata path) external onlyOwner {
        if (targetToken == address(0)) revert TargetTokenNotSet();
        if (path.length < 2 || path[0] != collateral || path[path.length - 1] != targetToken) revert InvalidPath();
        if (collateral == targetToken) revert InvalidPath(); // direct-burn case needs no path
        _swapPath[collateral] = path;
        emit SwapPathSet(collateral, path);
    }

    function getSwapPath(address collateral) external view returns (address[] memory) {
        return _swapPath[collateral];
    }

    function setMinBuybackAmount(address collateral, uint256 minAmount) external onlyOwner {
        minBuybackAmount[collateral] = minAmount;
        emit MinBuybackAmountSet(collateral, minAmount);
    }

    /// @notice Sets the per-call swap-input cap for a collateral (0 = uncapped).
    ///         Bounds how much collateral a single permissionless `executeDailyBuyback`
    ///         may push through the router, limiting per-swap price impact.
    function setMaxBuybackInPerCall(address collateral, uint256 cap) external onlyOwner {
        maxBuybackInPerCall[collateral] = cap;
        emit MaxBuybackInPerCallSet(collateral, cap);
    }

    function setMaxSlippageBps(uint16 maxSlippageBps_) external onlyOwner {
        if (maxSlippageBps_ == 0 || maxSlippageBps_ > MAX_SLIPPAGE_CAP_BPS) revert InvalidSlippage();
        maxSlippageBps = maxSlippageBps_;
        emit MaxSlippageSet(maxSlippageBps_);
    }

    // ------------------------------------------------------------------
    // Rescue (strictly limited)
    // ------------------------------------------------------------------

    /// @notice Rescues tokens sent here by mistake. NEVER usable for the target token
    ///         or for any token that has ever been accrued as buyback collateral —
    ///         accrued collateral can only leave via executeDailyBuyback.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == targetToken || token == pendingTargetToken || isCollateral[token]) revert RescueRestricted();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
