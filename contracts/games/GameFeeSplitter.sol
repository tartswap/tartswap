// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The single UniswapV2/PancakeSwapV2 router function the splitter uses.
///         The fee-on-transfer variant is chosen deliberately: the buyback target
///         (CREPE and friends) may carry a transfer tax, which would make the
///         plain `swapExactTokensForTokens` revert on its return-amount check.
interface IUniswapV2RouterFoT {
    /// @notice Read-only spot quote used to derive an on-chain slippage floor.
    ///         Read INSIDE the buyback try-block so a reverting quote (missing
    ///         pair) parks the reserve gracefully rather than bricking process().
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @title  GameFeeSplitter
/// @notice Terminal fee sink for a FastRoundArena (StakinGame) deployment. The
///         arena skims a flat 2% off each genuinely two-sided round and
///         PLAIN-ERC20-TRANSFERS it here in the arena's collateral (testnet
///         pUSDT, mainnet USDT) — no hook, no callback; this contract simply
///         accumulates balance between `process()` calls.
///
///         On a permissionless `process()` the accumulated collateral splits:
///           - `treasuryBps` (default 5_000 = 50%) → straight to `treasury`;
///           - the remainder → market-buy `buybackToken` on a UniswapV2-compatible
///             router (PancakeSwap V2 on BSC) and forward the bought tokens to
///             `buybackReceiver` (a burn address 0x…dEaD, or the treasury).
///
/// @dev    DEPLOYMENT STORY (why this contract exists): the arena's `feeSink`
///         is IMMUTABLE, so fee routing can only be changed by pointing a NEW
///         arena at a new sink. The plan:
///           1. deploy this splitter (collateral = the arena's collateral);
///           2. redeploy FastRoundArena with `feeSink = <this splitter>`;
///           3. update the FA_ARENA env/config to the new arena address.
///         All future routing changes (treasury address, buyback token, router,
///         path, split ratio) then happen HERE without touching the arena again.
///
///         GRACEFUL DEGRADE (important for testnet): the buyback leg only
///         executes when it is fully configured — `buybackEnabled`, a router
///         and buyback token that actually have code on this chain, a non-zero
///         receiver, and a valid path. Otherwise, and also when the router call
///         itself reverts (e.g. no CREPE pair exists on testnet), `process()`
///         still pays the treasury leg and parks the buyback share in
///         `buybackReserve` to be swapped by a later call. The reserve is
///         tracked explicitly so the treasury can never double-dip into a
///         previously-allocated-but-unswapped buyback share.
///
///         SLIPPAGE: the router is called with `amountOutMin = 0` and the real
///         guard is enforced by this contract after the swap — the receiver's
///         `buybackToken` balance must have grown by at least the effective
///         floor or the WHOLE transaction reverts (undoing the bad swap AND the
///         treasury transfer; the keeper simply retries). Measuring at the
///         receiver makes the guard net of any transfer tax. The floor is the
///         STRONGER of the caller-supplied `minBuybackOut` and an on-chain
///         `getAmountsOut` quote haircut by `maxSlippageBps`, so a lazy/zero
///         caller min cannot disable protection; `minBuybackOut == 0` on an
///         executing swap is rejected outright. The quote is read INSIDE the
///         swap try-block, so a reverting quote parks the reserve (no brick).
///
///         TRUST MODEL: the owner (deployer/admin; a multisig on mainnet) is
///         trusted. It can retarget every leg and, explicitly and loudly via
///         `sweepCollateral`, drain held collateral — this is a fee wallet, not
///         user escrow (player collateral never reaches this contract; only the
///         arena's fee leg does). `rescueToken` refuses the collateral so the
///         only collateral exits are `process()` and the explicit sweep.
contract GameFeeSplitter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Basis-point denominator (100% = 10_000).
    uint16 public constant BPS = 10_000;

    /// @notice Hard cap for the configurable buyback slippage tolerance (10%).
    uint16 public constant MAX_SLIPPAGE_CAP_BPS = 1_000;

    /// @notice Default buyback target: CREPE on BSC mainnet. On chains where
    ///         this address has no code (testnet) the buyback leg simply
    ///         degrades gracefully until `setBuybackToken` points elsewhere.
    address public constant DEFAULT_BUYBACK_TOKEN = 0xeb2B7d5691878627eff20492cA7c9a71228d931D;

    // ------------------------------------------------------------------
    // Immutable / config
    // ------------------------------------------------------------------

    /// @notice The arena's collateral (testnet pUSDT / mainnet USDT). Decimals
    ///         are irrelevant here — all math is pure bps on raw amounts.
    IERC20 public immutable collateral;

    /// @notice Treasury leg recipient; receives `treasuryBps` of each new batch.
    address public treasury;
    /// @notice Recipient of the bought `buybackToken` (0x…dEaD to burn, or treasury).
    address public buybackReceiver;
    /// @notice The token the buyback leg market-buys. Settable post-deploy.
    address public buybackToken;
    /// @notice UniswapV2-compatible router (PancakeSwap V2 on BSC).
    address public router;
    /// @notice Master toggle for the buyback leg; when false the buyback share
    ///         accumulates in `buybackReserve` instead of swapping.
    bool public buybackEnabled = true;
    /// @notice The only non-owner address allowed to EXECUTE the buyback swap
    ///         (an off-chain keeper that passes a real `minBuybackOut` quote).
    ///         address(0) = owner-only. This gate exists because a permissionless
    ///         swap with an attacker-chosen `minBuybackOut = 0` is a free MEV
    ///         sandwich on the buyback tranche — the treasury leg stays
    ///         permissionless, only the swap execution is gated.
    address public buybackCaller;
    /// @notice Treasury share of each NEW batch, in bps. Default 5_000 (50/50),
    ///         so the arena's 2% fee becomes 1% treasury + 1% buyback.
    uint16 public treasuryBps = 5_000;

    /// @notice Slippage tolerance applied to the router's own quote to derive an
    ///         on-chain floor for the buyback swap (default 3%, capped at
    ///         {MAX_SLIPPAGE_CAP_BPS}). The enforced floor is the STRONGER of
    ///         this quote-haircut and the caller-supplied `minBuybackOut`.
    uint16 public maxSlippageBps = 300;

    /// @notice Owner allowlist of tokens that may be set as the `buybackToken`.
    ///         Enforced in `setBuybackToken`, and mirrored at
    ///         WeeklyBuybackVote.submitCandidates so a disallowed token can never
    ///         win the vote (keeping the permissionless finalize un-brickable).
    mapping(address token => bool allowed) public allowedBuybackToken;

    /// @notice Optional per-`process()` cap on the collateral swapped into the
    ///         buyback leg (0 = uncapped). Any excess stays parked in
    ///         `buybackReserve` for the next call.
    uint256 public maxBuybackInPerProcess;

    /// @notice A single non-owner curator allowed to retarget ONLY the buyback
    ///         token and its swap path (via `setBuybackToken`/`setSwapPath`).
    ///         Intended for the WeeklyBuybackVote, which sets the epoch's elected
    ///         token; address(0) = owner-only. It CANNOT touch treasury, router,
    ///         shares, sweeps or the swap execution — only the buyback target.
    address public buybackTokenCurator;

    /// @dev Swap route collateral → … → buybackToken. Cleared whenever
    ///      `buybackToken` changes (a stale route must be re-set explicitly).
    address[] private _swapPath;

    /// @notice Collateral already allocated to the buyback leg but not yet
    ///         swapped (leg unconfigured / disabled / swap failed). Anything a
    ///         `process()` call sees ABOVE this reserve is a new fee batch.
    uint256 public buybackReserve;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error ZeroAddress();
    error BadShares();
    error BadPath();
    error Expired();
    error NothingToProcess();
    error InsufficientTreasuryOut();
    error SlippageExceeded();
    error UseSweepForCollateral();
    error ZeroMinOut();
    error TokenNotAllowed();
    error InvalidSlippage();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event TreasurySet(address indexed treasury);
    event BuybackReceiverSet(address indexed receiver);
    event BuybackTokenSet(address indexed token);
    event RouterSet(address indexed router);
    event SwapPathSet(address[] path);
    event SharesSet(uint16 treasuryBps);
    event BuybackEnabledSet(bool enabled);
    event BuybackCallerSet(address indexed caller);
    event BuybackTokenCuratorSet(address indexed curator);
    event MaxSlippageSet(uint16 maxSlippageBps);
    event AllowedBuybackTokenSet(address indexed token, bool allowed);
    event MaxBuybackInPerProcessSet(uint256 maxBuybackIn);
    /// @notice One per `process()`: `treasuryAmount` collateral paid out,
    ///         `buybackIn` collateral swapped (0 when the leg degraded) and
    ///         `buybackOut` buyback tokens received at the receiver.
    event Processed(uint256 treasuryAmount, uint256 buybackIn, uint256 buybackOut);
    /// @notice The buyback leg degraded this call; `amountHeld` stays parked
    ///         in `buybackReserve` for a later attempt.
    event BuybackSkipped(uint256 amountHeld);
    event CollateralSwept(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param collateral_      the arena's collateral token (pUSDT / USDT).
    /// @param treasury_        initial treasury leg (non-zero; settable later).
    /// @param buybackReceiver_ initial buyback-token recipient. MAY be zero —
    ///                         the buyback leg then degrades gracefully until
    ///                         `setBuybackReceiver` is called.
    /// @param initialOwner_    deployer/admin (multisig on mainnet).
    constructor(address collateral_, address treasury_, address buybackReceiver_, address initialOwner_)
        Ownable(initialOwner_)
    {
        if (collateral_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        collateral = IERC20(collateral_);
        treasury = treasury_;
        buybackReceiver = buybackReceiver_;
        buybackToken = DEFAULT_BUYBACK_TOKEN;
        emit TreasurySet(treasury_);
        emit BuybackReceiverSet(buybackReceiver_);
        emit BuybackTokenSet(DEFAULT_BUYBACK_TOKEN);
    }

    // ------------------------------------------------------------------
    // Access
    // ------------------------------------------------------------------

    /// @dev Owner OR the designated buyback-token curator (the WeeklyBuybackVote).
    ///      Reverts with the same `OwnableUnauthorizedAccount` error as `onlyOwner`
    ///      for anyone else, so existing owner-gating expectations are unchanged.
    modifier onlyOwnerOrCurator() {
        if (msg.sender != owner() && msg.sender != buybackTokenCurator) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        _;
    }

    // ------------------------------------------------------------------
    // Owner config
    // ------------------------------------------------------------------

    /// @notice Set the buyback-token curator (0 = owner-only). Owner-only.
    function setBuybackTokenCurator(address curator) external onlyOwner {
        buybackTokenCurator = curator; // zero is valid → owner-only retargeting
        emit BuybackTokenCuratorSet(curator);
    }

    /// @notice Set the treasury leg recipient.
    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice Set the recipient of bought buyback tokens (0x…dEaD to burn).
    function setBuybackReceiver(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        buybackReceiver = r;
        emit BuybackReceiverSet(r);
    }

    /// @notice Retarget the buyback token. Clears the swap path — a route for
    ///         the old token is meaningless for the new one and must be re-set
    ///         via `setSwapPath` (the leg degrades gracefully meanwhile). The
    ///         token must be owner-allowlisted (`allowedBuybackToken`); the
    ///         vote's finalize never trips this because submitCandidates already
    ///         rejects any non-allowlisted candidate, so a disallowed token can
    ///         never win and reach this call.
    function setBuybackToken(address token) external onlyOwnerOrCurator {
        if (token == address(0)) revert ZeroAddress();
        if (!allowedBuybackToken[token]) revert TokenNotAllowed();
        buybackToken = token;
        delete _swapPath;
        emit BuybackTokenSet(token);
        emit SwapPathSet(_swapPath);
    }

    /// @notice Set the UniswapV2-compatible router (PancakeSwap V2 on BSC).
    function setRouter(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        router = r;
        emit RouterSet(r);
    }

    /// @notice Set the swap route. Must start at the collateral, end at the
    ///         CURRENT `buybackToken`, and contain no zero hops. Intermediate
    ///         hops (e.g. USDT → WBNB → CREPE) are supported by listing them.
    function setSwapPath(address[] calldata path) external onlyOwnerOrCurator {
        uint256 len = path.length;
        if (len < 2) revert BadPath();
        if (path[0] != address(collateral) || path[len - 1] != buybackToken) revert BadPath();
        for (uint256 i = 0; i < len; ++i) {
            if (path[i] == address(0)) revert BadPath();
        }
        _swapPath = path;
        emit SwapPathSet(path);
    }

    /// @notice Set the treasury share of each new batch (0..10_000 bps).
    ///         The buyback leg always gets the exact remainder.
    function setShares(uint16 treasuryBps_) external onlyOwner {
        if (treasuryBps_ > BPS) revert BadShares();
        treasuryBps = treasuryBps_;
        emit SharesSet(treasuryBps_);
    }

    /// @notice Toggle the buyback leg. While disabled the buyback share parks
    ///         in `buybackReserve`; nothing is ever silently re-routed.
    function setBuybackEnabled(bool enabled) external onlyOwner {
        buybackEnabled = enabled;
        emit BuybackEnabledSet(enabled);
    }

    /// @notice Set the slippage tolerance (bps) applied to the router quote to
    ///         derive the on-chain buyback floor. Must be 0 < bps <=
    ///         {MAX_SLIPPAGE_CAP_BPS}.
    function setMaxSlippageBps(uint16 maxSlippageBps_) external onlyOwner {
        if (maxSlippageBps_ == 0 || maxSlippageBps_ > MAX_SLIPPAGE_CAP_BPS) revert InvalidSlippage();
        maxSlippageBps = maxSlippageBps_;
        emit MaxSlippageSet(maxSlippageBps_);
    }

    /// @notice Allow/disallow a token as the buyback target. Gates
    ///         `setBuybackToken` (and, via the vote's submitCandidates mirror,
    ///         which tokens can ever win the weekly vote).
    function setAllowedBuybackToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedBuybackToken[token] = allowed;
        emit AllowedBuybackTokenSet(token, allowed);
    }

    /// @notice Set the per-`process()` cap on collateral swapped into the buyback
    ///         leg (0 = uncapped). Excess parks in `buybackReserve` for the next
    ///         call.
    function setMaxBuybackInPerProcess(uint256 maxBuybackIn) external onlyOwner {
        maxBuybackInPerProcess = maxBuybackIn;
        emit MaxBuybackInPerProcessSet(maxBuybackIn);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The configured swap route (empty until set / after a token change).
    function swapPath() external view returns (address[] memory) {
        return _swapPath;
    }

    /// @notice Whether `token` is allowlisted as a buyback target. Read by
    ///         WeeklyBuybackVote.submitCandidates to reject disallowed candidates
    ///         up-front, mirroring the intermediate-hop allowlist (M-3) pattern.
    function isAllowedBuybackToken(address token) external view returns (bool) {
        return allowedBuybackToken[token];
    }

    /// @notice Preview of the next `process()`: the new (un-allocated) batch and
    ///         how it would split at the current ratio.
    function previewSplit() external view returns (uint256 newFunds, uint256 toTreasury, uint256 toBuyback) {
        uint256 bal = collateral.balanceOf(address(this));
        uint256 reserve = buybackReserve;
        newFunds = bal > reserve ? bal - reserve : 0;
        toTreasury = (newFunds * treasuryBps) / BPS;
        toBuyback = newFunds - toTreasury;
    }

    /// @notice Set the keeper allowed to execute the buyback swap (0 = owner-only).
    function setBuybackCaller(address caller) external onlyOwner {
        buybackCaller = caller; // zero is valid: swap becomes owner-only
        emit BuybackCallerSet(caller);
    }

    /// @notice True when the buyback leg would actually attempt a swap.
    function buybackReady() public view returns (bool) {
        if (!buybackEnabled) return false;
        if (buybackReceiver == address(0)) return false;
        // Code checks make an unset/foreign-chain token or router (e.g. the
        // mainnet CREPE default while on testnet) a graceful skip, not a revert.
        if (router.code.length == 0) return false;
        if (buybackToken.code.length == 0) return false;
        uint256 len = _swapPath.length;
        if (len < 2) return false;
        if (_swapPath[0] != address(collateral) || _swapPath[len - 1] != buybackToken) return false;
        return true;
    }

    // ------------------------------------------------------------------
    // Keeper entry
    // ------------------------------------------------------------------

    /// @notice Permissionless: split the newly-accumulated collateral and flow
    ///         both legs. Callable by any keeper/cron.
    /// @param  minTreasuryOut revert unless the treasury leg pays at least this
    ///         (dust guard for keepers; pass 0 when only retrying the buyback).
    /// @param  minBuybackOut  revert unless the receiver's `buybackToken`
    ///         balance grows by at least this much — the slippage guard. Only
    ///         enforced when a swap actually executes; a gracefully-skipped
    ///         buyback (unconfigured leg, failing router) does NOT revert.
    /// @param  deadline unix timestamp after which the call reverts (also
    ///         forwarded to the router).
    function process(uint256 minTreasuryOut, uint256 minBuybackOut, uint256 deadline) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();

        uint256 bal = collateral.balanceOf(address(this));
        uint256 reserve = buybackReserve;
        if (reserve > bal) reserve = bal; // defensive; sweep already re-clamps
        uint256 newFunds = bal - reserve;

        bool ready = buybackReady();
        // MEV gate: only the owner or the designated keeper may EXECUTE the
        // swap — an arbitrary caller passing minBuybackOut=0 would hand the
        // buyback tranche's slippage to a sandwich bot. Everyone else still
        // processes the treasury leg; the buyback share just stays parked.
        bool mayExecuteSwap = msg.sender == owner()
            || (buybackCaller != address(0) && msg.sender == buybackCaller);
        // No new fees AND no executable reserve retry → a true no-op; make it loud.
        if (newFunds == 0 && (reserve == 0 || !ready || !mayExecuteSwap)) revert NothingToProcess();

        uint256 toTreasury = (newFunds * treasuryBps) / BPS;
        if (toTreasury < minTreasuryOut) revert InsufficientTreasuryOut();
        reserve += newFunds - toTreasury; // exact remainder — dust-free

        if (toTreasury > 0) collateral.safeTransfer(treasury, toTreasury);

        uint256 buybackIn;
        uint256 buybackOut;
        if (reserve > 0 && ready && mayExecuteSwap) {
            // A caller authorized to EXECUTE the swap must always supply a real
            // slippage floor: a zero floor would hand the tranche to a sandwich
            // bot even with the on-chain quote guard as a backstop.
            if (minBuybackOut == 0) revert ZeroMinOut();
            // Clamp the per-call swap input; any excess stays parked in `reserve`
            // for the next call (dust-free, integrates with reserve accounting).
            uint256 swapIn = reserve;
            uint256 cap = maxBuybackInPerProcess;
            if (cap != 0 && swapIn > cap) swapIn = cap;
            (buybackIn, buybackOut) = _tryBuyback(swapIn, minBuybackOut, deadline);
        } else if (reserve > 0) {
            emit BuybackSkipped(reserve);
        }

        buybackReserve = reserve - buybackIn;
        emit Processed(toTreasury, buybackIn, buybackOut);
    }

    /// @dev Attempts to swap `amountIn` of the buyback reserve. Router failures
    ///      (no pair, paused router, a reverting quote — anything) are swallowed
    ///      → the reserve stays parked. A swap that EXECUTES but under-delivers
    ///      the effective floor reverts the whole transaction — the only way to
    ///      undo a bad fill.
    ///
    ///      FLOOR: the on-chain `getAmountsOut` quote is read INSIDE the try so a
    ///      reverting quote parks gracefully (no brick). The enforced floor is
    ///      the STRONGER of {caller `minBuybackOut`, quote * (1 - maxSlippageBps)},
    ///      measured at the receiver so it is net of any transfer tax.
    function _tryBuyback(uint256 amountIn, uint256 minBuybackOut, uint256 deadline)
        private
        returns (uint256 spent, uint256 received)
    {
        address rtr = router;
        address receiver = buybackReceiver;
        IERC20 target = IERC20(buybackToken);

        uint256 balBefore = target.balanceOf(receiver);
        collateral.forceApprove(rtr, amountIn);
        try IUniswapV2RouterFoT(rtr).getAmountsOut(amountIn, _swapPath) returns (uint256[] memory amounts) {
            uint256 quoted = amounts.length == 0 ? 0 : amounts[amounts.length - 1];
            uint256 floor = (quoted * (BPS - maxSlippageBps)) / BPS;
            if (floor < minBuybackOut) floor = minBuybackOut; // enforce the stronger guard
            try IUniswapV2RouterFoT(rtr).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn,
                0, // real guard enforced below, net of any transfer tax
                _swapPath,
                receiver,
                deadline
            ) {
                received = target.balanceOf(receiver) - balBefore;
                if (received < floor) revert SlippageExceeded();
                spent = amountIn;
            } catch {
                emit BuybackSkipped(amountIn);
            }
        } catch {
            // Quote reverted (e.g. missing pair): park the reserve, do not brick.
            emit BuybackSkipped(amountIn);
        }
        collateral.forceApprove(rtr, 0);
    }

    // ------------------------------------------------------------------
    // Rescue / sweep (owner-trusted; see contract NatSpec)
    // ------------------------------------------------------------------

    /// @notice Rescue a NON-collateral token sent here by mistake. The
    ///         collateral is refused so pending fee accounting cannot be
    ///         drained under the guise of a rescue — draining collateral is
    ///         only possible via the explicit, loudly-evented `sweepCollateral`.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(collateral)) revert UseSweepForCollateral();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @notice EXPLICIT owner escape hatch: sweep the ENTIRE collateral balance
    ///         (including any parked buyback reserve) to `to` and reset the
    ///         reserve. This is a trusted-owner fee wallet — player escrow
    ///         never reaches this contract — but the action is deliberately
    ///         all-or-nothing and separately evented so it can never be
    ///         mistaken for routine processing.
    function sweepCollateral(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = collateral.balanceOf(address(this));
        buybackReserve = 0;
        if (bal > 0) collateral.safeTransfer(to, bal);
        emit CollateralSwept(to, bal);
    }
}
