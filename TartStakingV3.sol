// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TartLPFarmV3} from "./TartLPFarmV3.sol";

/**
 * @title TartStakingV3
 * @notice Operator-enabled multi-pool single-token staking contract.
 * @dev Reuses the V3 reward-pool engine for non-LP staking pools.
 */
contract TartStakingV3 is TartLPFarmV3 {
    constructor(address initialOwner, address initialOperator) TartLPFarmV3(initialOwner, initialOperator) {}
}
