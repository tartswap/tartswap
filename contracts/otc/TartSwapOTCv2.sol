// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ---------------------------------------------------------------------------
/// TartSwap OTC v2
/// ---------------------------------------------------------------------------
/// Trustless over-the-counter escrow for BNB and BEP-20 tokens, with two ways
/// to price an offer:
///
///  - FIXED: "15,000,000 TART for 12 BNB". The ask is a number that never
///    moves (v1 behaviour).
///  - MARKET-LINKED: "15,000,000 TART at 10% below the DEX price". The
///    payment is computed at FILL time from the PancakeSwap V2 pool reserves
///    of the two tokens, minus the maker's discount. The offer therefore
///    tracks the market on its own: it is always the same percentage cheaper
///    than the pool, whichever way the price moves, and the maker never has
///    to re-post. Two guards protect the maker:
///      * a floor price (`floorPriceX18`) under which the offer never sells —
///        if the market falls below it the offer simply becomes dearer than
///        the pool and stops filling, until the maker cancels or the market
///        recovers;
///      * a same-second pool guard — a fill reverts while the pool's reserves
///        changed in the current block timestamp, so the price cannot be
///        pushed down and the offer filled inside ONE transaction (flash-loan
///        manipulation). Moving the pool in an earlier block still costs the
///        manipulator the pool fee and, for taxed tokens, the transfer tax on
///        both legs, and is capped by the floor.
///
/// Settlement is atomic and direct: the taker's payment (minus the protocol
/// fee) goes straight to the maker's wallet in the same transaction; nothing
/// is ever parked for the maker to claim.
///
/// Trust model / invariants (unchanged from v1, see SECURITY-REVIEW.md):
///  - The protocol is never a counterparty; it only escrows the sell leg.
///  - The owner can NEVER touch escrowed funds. Owner powers are limited to:
///    setting feeBps (<= MAX_FEE_BPS), changing the treasury, and pausing
///    the creation of NEW offers. Cancels, fills and reclaims can never be
///    paused - makers can always exit.
///  - Checks-Effects-Interactions everywhere + a reentrancy guard.
///  - Fee-on-transfer / rebasing tokens are rejected at deposit time by
///    measuring balance deltas (received must equal the stated amount).
///  - Partial-fill payments round UP in the maker's favour, and a dust guard
///    prevents the "last unit for free" rounding exploit.
///  - Market-linked pools are resolved through the DEX factory at creation,
///    never taken from the maker, so a fake pair can never price an offer.
/// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakePair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract TartSwapOTCv2 {
    // ------------------------------------------------------------------ Types
    enum Status { None, Open, Filled, Cancelled }

    struct Offer {
        address maker;
        address taker;         // zero address = public offer
        address sellToken;     // zero address = native BNB
        address buyToken;      // zero address = native BNB
        uint256 sellRemaining;
        uint256 buyRemaining;  // FIXED: shrinks proportionally with fills. MARKET: always 0.
        uint64  expiry;        // 0 = never expires
        bool    allowPartial;
        Status  status;
        // ── market-linked pricing (pair == 0 means FIXED pricing) ──
        address pair;          // PancakeSwap V2 pool of sellToken/buyToken (WBNB stands in for native)
        uint16  discountBps;   // taken off the pool's spot price at fill time
        uint256 floorPriceX18; // minimum payment per sell unit, scaled by 1e18 (buy wei per sell wei x 1e18)
    }

    // -------------------------------------------------------------- Constants
    uint256 public constant MAX_FEE_BPS = 200;       // hard cap: 2%
    uint256 public constant MAX_DISCOUNT_BPS = 5000; // a market-linked offer can be at most 50% under the pool
    address public constant NATIVE = address(0);

    // ---------------------------------------------------------------- Storage
    address public owner;
    address public treasury;
    uint256 public feeBps;         // taken from the payment leg at fill
    bool    public createPaused;   // pauses NEW offers only, never exits
    uint256 public offerCount;
    mapping(uint256 => Offer) public offers;

    IPancakeFactory public immutable factory; // DEX factory used to resolve market-linked pools
    address public immutable wbnb;            // the pool-side stand-in for native BNB

    uint256 private _entered;      // reentrancy guard (1 = free, 2 = locked)

    // ----------------------------------------------------------------- Events
    event OfferCreated(
        uint256 indexed id, address indexed maker, address indexed taker,
        address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount,
        uint64 expiry, bool allowPartial
    );
    /// Emitted right after OfferCreated for market-linked offers (buyAmount is 0 there).
    event MarketTerms(uint256 indexed id, address pair, uint16 discountBps, uint256 floorPriceX18);
    event OfferFilled(
        uint256 indexed id, address indexed takerActual,
        uint256 sellFilled, uint256 buyPaid, uint256 fee, bool complete
    );
    event OfferCancelled(uint256 indexed id, uint256 sellReturned);
    event OfferReclaimed(uint256 indexed id, uint256 sellReturned);
    event FeeChanged(uint256 feeBps);
    event TreasuryChanged(address treasury);
    event OwnerChanged(address owner);
    event CreatePaused(bool paused);

    // ----------------------------------------------------------------- Errors
    error NotOwner();
    error NotMaker();
    error NotDesignatedTaker();
    error Reentrancy();
    error Paused();
    error BadParams();
    error BadValue();
    error OfferNotOpen();
    error OfferExpired();
    error OfferNotExpired();
    error PartialNotAllowed();
    error FillTooLarge();
    error DustFill();
    error FeeTooHigh();
    error TransferFailed();
    error UnsupportedToken();
    error DiscountTooHigh();
    error NoPool();
    error PoolJustTraded();
    error PriceMoved();

    // ------------------------------------------------------------- Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    // ------------------------------------------------------------ Constructor
    constructor(address _treasury, uint256 _feeBps, address _factory, address _wbnb) {
        if (_treasury == address(0) || _factory == address(0) || _wbnb == address(0)) revert BadParams();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        owner = msg.sender;
        treasury = _treasury;
        feeBps = _feeBps;
        factory = IPancakeFactory(_factory);
        wbnb = _wbnb;
        _entered = 1;
    }

    // ------------------------------------------------------------------ Admin
    /// Fee is hard-capped so no owner (or compromised key) can rug via fees.
    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = _feeBps;
        emit FeeChanged(_feeBps);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert BadParams();
        treasury = _treasury;
        emit TreasuryChanged(_treasury);
    }

    function transferOwnership(address _owner) external onlyOwner {
        if (_owner == address(0)) revert BadParams();
        owner = _owner;
        emit OwnerChanged(_owner);
    }

    /// Emergency brake for NEW offers only. Exits (cancel/reclaim) and fills
    /// of existing offers are intentionally unpausable.
    function setCreatePaused(bool paused) external onlyOwner {
        createPaused = paused;
        emit CreatePaused(paused);
    }

    // ----------------------------------------------------------------- Create
    /// FIXED-price offer. Locks the sell leg in escrow and lists the offer.
    /// sellToken == NATIVE: send the BNB as msg.value.
    /// taker != 0: private offer, only that address can fill.
    /// expiry == 0: never expires. allowPartial: enable partial fills.
    function createOffer(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        address taker,
        uint64  expiry,
        bool    allowPartial
    ) external payable nonReentrant returns (uint256 id) {
        if (buyAmount == 0) revert BadParams();
        id = _create(sellToken, sellAmount, buyToken, buyAmount, taker, expiry, allowPartial, Terms(address(0), 0, 0));
    }

    /// MARKET-LINKED offer: the payment is `sellFill x pool spot x (1 - discountBps/10000)`
    /// at fill time, never below `floorPriceX18` per sell unit. The pool is
    /// resolved through the DEX factory (WBNB stands in for native BNB) and
    /// must exist with liquidity on both sides.
    function createMarketOffer(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint16  discountBps,
        uint256 floorPriceX18,
        address taker,
        uint64  expiry,
        bool    allowPartial
    ) external payable nonReentrant returns (uint256 id) {
        if (discountBps > MAX_DISCOUNT_BPS) revert DiscountTooHigh();
        Terms memory terms = Terms(_resolvePool(sellToken, buyToken), discountBps, floorPriceX18);
        id = _create(sellToken, sellAmount, buyToken, 0, taker, expiry, allowPartial, terms);
        emit MarketTerms(id, terms.pair, terms.discountBps, terms.floorPriceX18);
    }

    /// Market terms travel as one value so the create path stays within the
    /// EVM stack limit (a fixed offer carries an empty set: pair == 0).
    struct Terms { address pair; uint16 discountBps; uint256 floorPriceX18; }

    /// The DEX pool for the two legs (native BNB maps to WBNB). Must exist and
    /// hold liquidity on both sides, or the offer could never be priced.
    function _resolvePool(address sellToken, address buyToken) internal view returns (address pair) {
        address sellSide = _poolSide(sellToken);
        address buySide = _poolSide(buyToken);
        if (sellSide == buySide) revert BadParams();
        pair = factory.getPair(sellSide, buySide);
        if (pair == address(0)) revert NoPool();
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        if (r0 == 0 || r1 == 0) revert NoPool();
    }

    function _create(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        address taker,
        uint64  expiry,
        bool    allowPartial,
        Terms memory terms
    ) internal returns (uint256 id) {
        if (createPaused) revert Paused();
        if (sellAmount == 0) revert BadParams();
        if (sellToken == buyToken) revert BadParams();
        if (taker == msg.sender) revert BadParams();
        if (expiry != 0 && expiry <= block.timestamp) revert BadParams();

        // --- Effects first: register the offer before any token interaction.
        id = ++offerCount;
        offers[id] = Offer({
            maker: msg.sender,
            taker: taker,
            sellToken: sellToken,
            buyToken: buyToken,
            sellRemaining: sellAmount,
            buyRemaining: buyAmount,
            expiry: expiry,
            allowPartial: allowPartial,
            status: Status.Open,
            pair: terms.pair,
            discountBps: terms.discountBps,
            floorPriceX18: terms.floorPriceX18
        });

        // --- Interactions: take custody of the sell leg.
        if (sellToken == NATIVE) {
            if (msg.value != sellAmount) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            _pullExact(sellToken, msg.sender, sellAmount);
        }

        emit OfferCreated(id, msg.sender, taker, sellToken, sellAmount, buyToken, buyAmount, expiry, allowPartial);
    }

    // ------------------------------------------------------------------- Fill
    /// Fill `sellFill` units of the sell leg. For full fills pass the entire
    /// remaining amount. `maxPay` is the taker's price protection: the fill
    /// reverts if the payment due exceeds it (a market-linked price that moved
    /// between the quote and the block).
    /// FIXED offers: payment = ceil(sellFill * buyRemaining / sellRemaining) —
    /// rounding always favours the maker.
    /// buyToken == NATIVE: send at least the payment as msg.value; any excess
    /// (a market-linked quote that came in lower) is refunded in the same tx.
    /// buyToken == ERC-20: send no value; exactly the payment is pulled.
    function fillOffer(uint256 id, uint256 sellFill, uint256 maxPay) external payable nonReentrant {
        Offer storage o = offers[id];
        if (o.status != Status.Open) revert OfferNotOpen();
        if (o.expiry != 0 && block.timestamp >= o.expiry) revert OfferExpired();
        if (o.taker != address(0) && msg.sender != o.taker) revert NotDesignatedTaker();
        if (msg.sender == o.maker) revert BadParams();
        if (sellFill == 0) revert BadParams();
        if (sellFill > o.sellRemaining) revert FillTooLarge();
        if (!o.allowPartial && sellFill != o.sellRemaining) revert PartialNotAllowed();

        uint256 pay;
        uint256 newSellRemaining = o.sellRemaining - sellFill;
        uint256 newBuyRemaining;
        if (o.pair == address(0)) {
            pay = _ceilDiv(sellFill * o.buyRemaining, o.sellRemaining);
            newBuyRemaining = o.buyRemaining - pay; // pay <= buyRemaining, proven in review
            // Dust guard: never leave sell units purchasable for zero payment.
            if (newSellRemaining > 0 && newBuyRemaining == 0) revert DustFill();
        } else {
            pay = _marketPay(o, sellFill, true);
            if (pay == 0) revert DustFill();
            newBuyRemaining = 0;
        }
        if (pay > maxPay) revert PriceMoved();

        // --- Effects: update remainders before any external call.
        o.sellRemaining = newSellRemaining;
        o.buyRemaining = newBuyRemaining;
        bool complete = newSellRemaining == 0;
        if (complete) o.status = Status.Filled;

        uint256 fee = (pay * feeBps) / 10_000;

        // --- Interactions.
        // 1) Collect the payment leg from the taker.
        uint256 refund;
        if (o.buyToken == NATIVE) {
            if (msg.value < pay) revert BadValue();
            refund = msg.value - pay;
        } else {
            if (msg.value != 0) revert BadValue();
            _pullExact(o.buyToken, msg.sender, pay);
        }
        // 2) Pay the maker (payment minus fee) and the treasury (fee) — straight
        //    to their wallets, nothing is held for a later claim.
        _push(o.buyToken, o.maker, pay - fee);
        if (fee > 0) _push(o.buyToken, treasury, fee);
        // 3) Deliver the sell leg to the taker, then return any overpayment.
        _push(o.sellToken, msg.sender, sellFill);
        if (refund > 0) _push(NATIVE, msg.sender, refund);

        emit OfferFilled(id, msg.sender, sellFill, pay, fee, complete);
    }

    // ----------------------------------------------------------------- Cancel
    /// Maker exits any time; remaining escrow returns in full. Unpausable.
    function cancelOffer(uint256 id) external nonReentrant {
        Offer storage o = offers[id];
        if (o.status != Status.Open) revert OfferNotOpen();
        if (msg.sender != o.maker) revert NotMaker();

        uint256 refund = o.sellRemaining;
        o.sellRemaining = 0;
        o.buyRemaining = 0;
        o.status = Status.Cancelled;

        _push(o.sellToken, o.maker, refund);
        emit OfferCancelled(id, refund);
    }

    /// After expiry anyone may sweep the escrow back to the maker
    /// (permissionless hygiene; funds only ever move to the maker).
    function reclaimExpired(uint256 id) external nonReentrant {
        Offer storage o = offers[id];
        if (o.status != Status.Open) revert OfferNotOpen();
        if (o.expiry == 0 || block.timestamp < o.expiry) revert OfferNotExpired();

        uint256 refund = o.sellRemaining;
        o.sellRemaining = 0;
        o.buyRemaining = 0;
        o.status = Status.Cancelled;

        _push(o.sellToken, o.maker, refund);
        emit OfferReclaimed(id, refund);
    }

    // ------------------------------------------------------------------ Views
    function getOffer(uint256 id) external view returns (Offer memory) {
        return offers[id];
    }

    /// Paginated open-offer scan for a lobby with no indexer. Frontends
    /// should prefer event indexing at scale.
    function openOffers(uint256 fromId, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] memory buf = new uint256[](limit);
        uint256 n;
        for (uint256 i = fromId; i <= offerCount && n < limit; i++) {
            Offer storage o = offers[i];
            if (o.status == Status.Open && (o.expiry == 0 || block.timestamp < o.expiry)) {
                buf[n++] = i;
            }
        }
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = buf[i];
    }

    /// Quote the payment required to buy `sellFill` units of offer `id`.
    /// Mirrors every fillOffer precondition except the same-second pool guard
    /// (a quote is informational; the guard belongs to the fill itself), so a
    /// nonzero quote is fillable as soon as the pool has been still for a block.
    function quoteFill(uint256 id, uint256 sellFill) external view returns (uint256 pay, uint256 fee) {
        Offer storage o = offers[id];
        if (o.status != Status.Open || sellFill == 0 || sellFill > o.sellRemaining) return (0, 0);
        if (o.expiry != 0 && block.timestamp >= o.expiry) return (0, 0);
        if (!o.allowPartial && sellFill != o.sellRemaining) return (0, 0);
        if (o.pair == address(0)) {
            pay = _ceilDiv(sellFill * o.buyRemaining, o.sellRemaining);
            if (o.sellRemaining - sellFill > 0 && o.buyRemaining - pay == 0) return (0, 0); // dust guard
        } else {
            pay = _marketPay(o, sellFill, false);
            if (pay == 0) return (0, 0);
        }
        fee = (pay * feeBps) / 10_000;
    }

    /// The pool's current spot price for a market-linked offer: buy-token wei
    /// per sell-token wei, scaled by 1e18 (0 for fixed offers or empty pools).
    function marketPriceX18(uint256 id) external view returns (uint256) {
        Offer storage o = offers[id];
        if (o.pair == address(0)) return 0;
        (uint256 rSell, uint256 rBuy,) = _reserves(o);
        if (rSell == 0) return 0;
        return (rBuy * 1e18) / rSell;
    }

    // ------------------------------------------------------------- Internals
    /// Market-linked payment for `sellFill`: pool spot minus the discount,
    /// rounded up, never under the maker's floor. With `guard` set, a pool
    /// whose reserves changed in this block timestamp reverts (see header).
    function _marketPay(Offer storage o, uint256 sellFill, bool guard) internal view returns (uint256 pay) {
        (uint256 rSell, uint256 rBuy, uint32 lastTs) = _reserves(o);
        if (rSell == 0 || rBuy == 0) revert NoPool();
        if (guard && lastTs == uint32(block.timestamp)) revert PoolJustTraded();
        pay = _ceilDiv(sellFill * rBuy * (10_000 - o.discountBps), rSell * 10_000);
        uint256 floorPay = _ceilDiv(sellFill * o.floorPriceX18, 1e18);
        if (floorPay > pay) pay = floorPay;
    }

    /// Reserves of the offer's pool ordered as (sell side, buy side).
    function _reserves(Offer storage o) internal view returns (uint256 rSell, uint256 rBuy, uint32 lastTs) {
        (uint112 r0, uint112 r1, uint32 ts) = IPancakePair(o.pair).getReserves();
        bool sellIs0 = IPancakePair(o.pair).token0() == _poolSide(o.sellToken);
        (rSell, rBuy) = sellIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        lastTs = ts;
    }

    function _poolSide(address token) internal view returns (address) {
        return token == NATIVE ? wbnb : token;
    }

    /// Pull exactly `amount` of `token` from `from`, measuring the balance
    /// delta. Rejects fee-on-transfer / rebasing tokens (delta != amount)
    /// and tokens that lie in their return value.
    function _pullExact(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        _safeCall(token, abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert UnsupportedToken();
    }

    /// Send `amount` of `token` (or native BNB) to `to`.
    function _push(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            _safeCall(token, abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        }
    }

    /// Tolerates non-standard ERC20s that return nothing (e.g. USDT-style),
    /// reverts on `false` returns and failed calls.
    function _safeCall(address token, bytes memory data) internal {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
        if (token.code.length == 0) revert UnsupportedToken();
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
