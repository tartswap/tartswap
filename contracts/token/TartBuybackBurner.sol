// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ---------------------------------------------------------------------------
/// TartBuybackBurner — revenue-funded buyback & burn (LOCAL / UNRELEASED)
/// ---------------------------------------------------------------------------
/// A one-way machine: BNB in, burned TART out. It touches no other contract's
/// state — it is an ordinary router customer that market-buys TART and parks
/// every token it buys at the dead address, forever.
///
///   * Fund it by plain BNB transfer, from anywhere (the keeper forwards a
///     share of the treasury lane; anyone else may add to the fire).
///   * `buybackBurn(minTartOut)` is PERMISSIONLESS — anyone may trigger it.
///     The caller provides the slippage floor, so a trigger can never be
///     tricked into buying into a manipulated price beyond that bound.
///   * There is NO withdraw, NO sweep, NO owner. BNB that enters can leave in
///     exactly one form: TART transferred to 0x…dEaD in the same transaction.
///   * `totalBnbSpent` / `totalTartBurned` + the Burn event log are the
///     public, verifiable history the /token page renders live.
///
/// The TART buy itself is taxed like any market buy (the burner is not
/// fee-exempt on purpose — its buys feed the auto-LP lane like everyone
/// else's), and every TART it receives, post-tax, is burned.
/// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

interface IDexRouter {
    function WETH() external view returns (address);

    // The plain variant works on every UniswapV2 fork and is safe when the
    // TAX sits on the OUTPUT token: the router computes amounts against the
    // pool and never verifies what the recipient nets, so the taxed delivery
    // does not revert. `amountOutMin` bounds the pool-side output — exactly
    // the price-manipulation guard the trigger needs.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

contract TartBuybackBurner {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable token;
    IDexRouter public immutable router;
    address public immutable wrappedNative;

    uint256 public totalBnbSpent;
    uint256 public totalTartBurned;
    uint64 public lastBurnAt;
    uint64 public burnCount;

    event BuybackBurned(uint256 bnbSpent, uint256 tartBurned, address indexed caller);

    error NothingToBuy();
    error NothingBought();
    error TransferFailed();

    constructor(address token_, address router_) {
        token = IERC20(token_);
        router = IDexRouter(router_);
        wrappedNative = IDexRouter(router_).WETH();
    }

    /// Anyone may fund the fire.
    receive() external payable {}

    /// Spends the ENTIRE BNB balance on TART and burns every token received.
    /// `minTartOut` is the caller's slippage floor for the swap.
    function buybackBurn(uint256 minTartOut) external {
        uint256 bnb = address(this).balance;
        if (bnb == 0) revert NothingToBuy();

        address[] memory path = new address[](2);
        path[0] = wrappedNative;
        path[1] = address(token);

        uint256 before = token.balanceOf(address(this));
        router.swapExactETHForTokens{value: bnb}(
            minTartOut, path, address(this), block.timestamp
        );
        uint256 bought = token.balanceOf(address(this)) - before;
        if (bought == 0) revert NothingBought();

        totalBnbSpent += bnb;
        totalTartBurned += bought;
        lastBurnAt = uint64(block.timestamp);
        burnCount += 1;

        if (!token.transfer(DEAD, bought)) revert TransferFailed();
        emit BuybackBurned(bnb, bought, msg.sender);
    }
}
