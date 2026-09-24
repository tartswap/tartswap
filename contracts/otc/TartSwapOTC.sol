// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ---------------------------------------------------------------------------
/// TartSwap OTC
/// ---------------------------------------------------------------------------
/// Trustless over-the-counter escrow for BNB and BEP-20 tokens.
///
///  - A maker locks the asset they are selling and states what they want in
///    return ("500,000 TART for 2,400 USDT"). Optional: a designated taker
///    (private deal), an expiry, and whether partial fills are allowed.
///  - A taker fills the offer (fully or partially). The contract swaps both
///    legs atomically in the same transaction - no "you send first" risk.
///  - Fee: `feeBps` (default 0.5%, hard-capped at 2%) is taken from the
///    payment leg at fill time and sent to the treasury.
///
/// Trust model / invariants (see SECURITY-REVIEW.md for the full analysis):
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
/// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract TartSwapOTC {
    // ------------------------------------------------------------------ Types
    enum Status { None, Open, Filled, Cancelled }

    struct Offer {
        address maker;
        address taker;        // zero address = public offer
        address sellToken;    // zero address = native BNB
        address buyToken;     // zero address = native BNB
        uint256 sellRemaining;
        uint256 buyRemaining; // shrinks proportionally with fills
        uint64  expiry;       // 0 = never expires
        bool    allowPartial;
        Status  status;
    }

    // -------------------------------------------------------------- Constants
    uint256 public constant MAX_FEE_BPS = 200; // hard cap: 2%
    address public constant NATIVE = address(0);

    // ---------------------------------------------------------------- Storage
    address public owner;
    address public treasury;
    uint256 public feeBps;         // taken from the payment leg at fill
    bool    public createPaused;   // pauses NEW offers only, never exits
    uint256 public offerCount;
    mapping(uint256 => Offer) public offers;

    uint256 private _entered;      // reentrancy guard (1 = free, 2 = locked)

    // ----------------------------------------------------------------- Events
    event OfferCreated(
        uint256 indexed id, address indexed maker, address indexed taker,
        address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount,
        uint64 expiry, bool allowPartial
    );
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
    constructor(address _treasury, uint256 _feeBps) {
        if (_treasury == address(0)) revert BadParams();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        owner = msg.sender;
        treasury = _treasury;
        feeBps = _feeBps;
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
    /// Locks the sell leg in escrow and lists the offer.
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
        if (createPaused) revert Paused();
        if (sellAmount == 0 || buyAmount == 0) revert BadParams();
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
            status: Status.Open
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
    /// remaining amount. Payment = ceil(sellFill * buyRemaining / sellRemaining)
    /// - rounding always favours the maker.
    /// buyToken == NATIVE: send the exact payment as msg.value.
    function fillOffer(uint256 id, uint256 sellFill) external payable nonReentrant {
        Offer storage o = offers[id];
        if (o.status != Status.Open) revert OfferNotOpen();
        if (o.expiry != 0 && block.timestamp >= o.expiry) revert OfferExpired();
        if (o.taker != address(0) && msg.sender != o.taker) revert NotDesignatedTaker();
        if (msg.sender == o.maker) revert BadParams();
        if (sellFill == 0) revert BadParams();
        if (sellFill > o.sellRemaining) revert FillTooLarge();
        if (!o.allowPartial && sellFill != o.sellRemaining) revert PartialNotAllowed();

        // Payment, rounded up (maker-favouring).
        uint256 pay = _ceilDiv(sellFill * o.buyRemaining, o.sellRemaining);

        // --- Effects: update remainders before any external call.
        uint256 newSellRemaining = o.sellRemaining - sellFill;
        uint256 newBuyRemaining = o.buyRemaining - pay; // pay <= buyRemaining, proven in review
        // Dust guard: never leave sell units purchasable for zero payment.
        if (newSellRemaining > 0 && newBuyRemaining == 0) revert DustFill();
        o.sellRemaining = newSellRemaining;
        o.buyRemaining = newBuyRemaining;
        bool complete = newSellRemaining == 0;
        if (complete) o.status = Status.Filled;

        uint256 fee = (pay * feeBps) / 10_000;

        // --- Interactions.
        // 1) Collect the payment leg from the taker.
        if (o.buyToken == NATIVE) {
            if (msg.value != pay) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            _pullExact(o.buyToken, msg.sender, pay);
        }
        // 2) Pay the maker (payment minus fee) and the treasury (fee).
        _push(o.buyToken, o.maker, pay - fee);
        if (fee > 0) _push(o.buyToken, treasury, fee);
        // 3) Deliver the sell leg to the taker.
        _push(o.sellToken, msg.sender, sellFill);

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
    /// Mirrors EVERY fillOffer precondition (expiry, partial policy, dust
    /// guard) so a nonzero quote is always actually fillable — the original
    /// version happily quoted expired offers and dust-guarded partials.
    /// NOTE: source-level fix; live deployments predating it keep the loose
    /// quote (their UIs compute quotes locally and do not rely on this view).
    function quoteFill(uint256 id, uint256 sellFill) external view returns (uint256 pay, uint256 fee) {
        Offer storage o = offers[id];
        if (o.status != Status.Open || sellFill == 0 || sellFill > o.sellRemaining) return (0, 0);
        if (o.expiry != 0 && block.timestamp >= o.expiry) return (0, 0);
        if (!o.allowPartial && sellFill != o.sellRemaining) return (0, 0);
        pay = _ceilDiv(sellFill * o.buyRemaining, o.sellRemaining);
        if (o.sellRemaining - sellFill > 0 && o.buyRemaining - pay == 0) return (0, 0); // dust guard
        fee = (pay * feeBps) / 10_000;
    }

    // ------------------------------------------------------------- Internals
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
