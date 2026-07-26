// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library TartSwapV2UQ112x112 {
    uint224 internal constant Q112 = 2 ** 112;

    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112;
    }

    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / y;
    }
}
