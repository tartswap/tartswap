// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITartSwapV2Callee} from "./interfaces/ITartSwapV2Callee.sol";
import {ITartSwapV2Factory} from "./interfaces/ITartSwapV2Factory.sol";
import {TartSwapV2ERC20} from "./TartSwapV2ERC20.sol";
import {TartSwapV2Math} from "./libraries/TartSwapV2Math.sol";
import {TartSwapV2UQ112x112} from "./libraries/TartSwapV2UQ112x112.sol";
import {TartSwapV2Library} from "./libraries/TartSwapV2Library.sol";

contract TartSwapV2Pair is TartSwapV2ERC20 {
    using TartSwapV2UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 private constant FEE_DENOMINATOR = 10_000;
    // Single-sourced from the library so the pair K-invariant and the router quote math
    // (getAmountOut/getAmountIn) can never drift apart. Changing the fee in one place only.
    uint256 private constant SWAP_FEE_BPS = TartSwapV2Library.SWAP_FEE_BPS; // 0.25%.
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast;

    uint256 private unlocked = 1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    modifier lock() {
        require(unlocked == 1, "TartSwapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor() {
        factory = msg.sender;
    }

    function initialize(address token0_, address token1_) external {
        require(msg.sender == factory, "TartSwapV2: FORBIDDEN");
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() public view returns (uint112 reserve0_, uint112 reserve1_, uint32 blockTimestampLast_) {
        reserve0_ = reserve0;
        reserve1_ = reserve1;
        blockTimestampLast_ = blockTimestampLast;
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0_;
        uint256 amount1 = balance1 - reserve1_;

        bool feeOn = _mintFee(reserve0_, reserve1_);
        uint256 totalSupply_ = totalSupply;
        if (totalSupply_ == 0) {
            liquidity = TartSwapV2Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = TartSwapV2Math.min((amount0 * totalSupply_) / reserve0_, (amount1 * totalSupply_) / reserve1_);
        }
        require(liquidity > 0, "TartSwapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, reserve0_, reserve1_);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        address token0_ = token0;
        address token1_ = token1;
        uint256 balance0 = IERC20(token0_).balanceOf(address(this));
        uint256 balance1 = IERC20(token1_).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(reserve0_, reserve1_);
        uint256 totalSupply_ = totalSupply;
        amount0 = (liquidity * balance0) / totalSupply_;
        amount1 = (liquidity * balance1) / totalSupply_;
        require(amount0 > 0 && amount1 > 0, "TartSwapV2: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        _safeTransfer(token0_, to, amount0);
        _safeTransfer(token1_, to, amount1);
        balance0 = IERC20(token0_).balanceOf(address(this));
        balance1 = IERC20(token1_).balanceOf(address(this));

        _update(balance0, balance1, reserve0_, reserve1_);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "TartSwapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        require(amount0Out < reserve0_ && amount1Out < reserve1_, "TartSwapV2: INSUFFICIENT_LIQUIDITY");

        address token0_ = token0;
        address token1_ = token1;
        require(to != token0_ && to != token1_, "TartSwapV2: INVALID_TO");
        if (amount0Out > 0) _safeTransfer(token0_, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1_, to, amount1Out);
        if (data.length > 0) ITartSwapV2Callee(to).tartswapV2Call(msg.sender, amount0Out, amount1Out, data);
        uint256 balance0 = IERC20(token0_).balanceOf(address(this));
        uint256 balance1 = IERC20(token1_).balanceOf(address(this));

        uint256 amount0In = balance0 > reserve0_ - amount0Out ? balance0 - (reserve0_ - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1_ - amount1Out ? balance1 - (reserve1_ - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "TartSwapV2: INSUFFICIENT_INPUT_AMOUNT");

        _validateK(balance0, balance1, amount0In, amount1In, reserve0_, reserve1_);

        _update(balance0, balance1, reserve0_, reserve1_);
        _emitSwap(amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function skim(address to) external lock {
        address token0_ = token0;
        address token1_ = token1;
        _safeTransfer(token0_, to, IERC20(token0_).balanceOf(address(this)) - reserve0);
        _safeTransfer(token1_, to, IERC20(token1_).balanceOf(address(this)) - reserve1);
    }

    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    function _mintFee(uint112 reserve0_, uint112 reserve1_) private returns (bool feeOn) {
        address feeTo = ITartSwapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 kLast_ = kLast;
        if (feeOn) {
            if (kLast_ != 0) {
                uint256 rootK = TartSwapV2Math.sqrt(uint256(reserve0_) * reserve1_);
                uint256 rootKLast = TartSwapV2Math.sqrt(kLast_);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast);
                    uint256 denominator = (rootK * 5) + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (kLast_ != 0) {
            kLast = 0;
        }
    }

    function _update(uint256 balance0, uint256 balance1, uint112 reserve0_, uint112 reserve1_) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "TartSwapV2: OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        // Matches Uniswap V2: the uint32 timestamp is expected to wrap roughly every 136
        // years, and the TWAP accumulators are designed to overflow. Both operations MUST
        // be unchecked so a wrap can never revert (and brick) a swap/mint/burn/sync.
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && reserve0_ != 0 && reserve1_ != 0) {
                price0CumulativeLast += uint256(TartSwapV2UQ112x112.encode(reserve1_).uqdiv(reserve0_)) * timeElapsed;
                price1CumulativeLast += uint256(TartSwapV2UQ112x112.encode(reserve0_).uqdiv(reserve1_)) * timeElapsed;
            }
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function _emitSwap(uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address to) private {
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function _validateK(
        uint256 balance0,
        uint256 balance1,
        uint256 amount0In,
        uint256 amount1In,
        uint112 reserve0_,
        uint112 reserve1_
    ) private pure {
        uint256 balance0Adjusted = (balance0 * FEE_DENOMINATOR) - (amount0In * SWAP_FEE_BPS);
        uint256 balance1Adjusted = (balance1 * FEE_DENOMINATOR) - (amount1In * SWAP_FEE_BPS);
        require(
            balance0Adjusted * balance1Adjusted >= uint256(reserve0_) * reserve1_ * (FEE_DENOMINATOR ** 2),
            "TartSwapV2: K"
        );
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TartSwapV2: TRANSFER_FAILED");
    }
}
