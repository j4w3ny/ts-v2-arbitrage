// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";

contract Counter {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;

    uint256 public number;

    function setNumber(uint256 newNumber) public {
        number = newNumber;
    }

    function increment() public {
        number++;
    }
}
