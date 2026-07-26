// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TartSwapV2Pair} from "./TartSwapV2Pair.sol";

contract TartSwapV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    constructor(address feeToSetter_) {
        require(feeToSetter_ != address(0), "TartSwapV2: ZERO_SETTER");
        feeToSetter = feeToSetter_;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(TartSwapV2Pair).creationCode);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "TartSwapV2: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "TartSwapV2: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "TartSwapV2: PAIR_EXISTS");
        bytes memory bytecode = type(TartSwapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        TartSwapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address feeTo_) external {
        require(msg.sender == feeToSetter, "TartSwapV2: FORBIDDEN");
        feeTo = feeTo_;
    }

    function setFeeToSetter(address feeToSetter_) external {
        require(msg.sender == feeToSetter, "TartSwapV2: FORBIDDEN");
        require(feeToSetter_ != address(0), "TartSwapV2: ZERO_SETTER");
        feeToSetter = feeToSetter_;
    }
}
