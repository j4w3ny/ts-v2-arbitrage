// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

import {TimeswapV2PoolRebalance} from "./enums/PoolTransaction.sol";

/// @dev The parameter for arbitrage function.
/// @param strike The strike price of the pool.
/// @param maturity The maturity of the pool.
/// @param transaction The type of rebalance transaction, more information in Transaction module.
/// @param delta If transaction is GivenLong0 and Long0ToLong1, the amount of long0 positions to be deposited.
/// If transaction is GivenLong0 and Long1ToLong0, the amount of long1 positions to be withdrawn.
/// If transaction is GivenLong1 and Long0ToLong1, the amount of long1 positions to be withdrawn.
/// If transaction is GivenLong1 and Long1ToLong0, the amount of long1 positions to be deposited.
/// @param data The data to be sent to the function, which will go to the rebalance callback.

struct TimeswapV2ArbitrageParam {
    uint256 strike;
    uint256 maturity;
    bool isLong0ToLong1;
    TimeswapV2PoolRebalance transaction;
    uint256 delta;
    bytes data;
}
