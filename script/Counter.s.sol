// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimeswapV2Arbitrage} from "../src/TimeswapV2Arbitrage.sol";

contract CounterScript is Script {
    TimeswapV2Arbitrage public counter;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // counter = new TimeswapV2Arbitrage();

        vm.stopBroadcast();
    }
}
