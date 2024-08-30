// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/interface/ITimeswapV2Pool.sol";
import "../src/structs/ArbitrageParam.sol";
import {TimeswapV2PoolRebalance} from "../src/structs/enums/PoolTransaction.sol";
import {TimeswapV2Arbitrage} from "../src/TimeswapV2Arbitrage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract TimeswapV2ArbitrageTest is Test {
    TimeswapV2Arbitrage public arbitrage;
    address constant ARB_ON_ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address constant USDC_ON_ARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant TIMESWAP_V2_OPTION_ARB_USDC = 0x018fCaBD71E01064807Fe74425fc6A0AFFDf1029;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private randomUser;

    uint256 private strike = 204169420152563078078024764;
    uint256 private maturity = 1725883200;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC"));
        vm.rollFork(247_275_500);
        deal(USDC_ON_ARB, msg.sender, 100_000 * 10 ** 6);
        vm.startPrank(msg.sender);
        arbitrage = new TimeswapV2Arbitrage(ITimeswapV2Pool(TIMESWAP_V2_OPTION_ARB_USDC), ISwapRouter(SWAP_ROUTER));

        console.log("ARB Current balance: %s", IERC20(ARB_ON_ARB).balanceOf(msg.sender));
        console.log("USDC Current balance: %s", IERC20(USDC_ON_ARB).balanceOf(msg.sender));
        uint256 deadline = block.timestamp + 200;
        IERC20(USDC_ON_ARB).approve(SWAP_ROUTER, IERC20(USDC_ON_ARB).balanceOf(msg.sender));
        console.log("USDC approved:  %s", IERC20(USDC_ON_ARB).allowance(msg.sender, SWAP_ROUTER));
        ISwapRouter.ExactInputSingleParams memory swapParam = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC_ON_ARB,
            tokenOut: ARB_ON_ARB,
            fee: 500,
            recipient: msg.sender,
            deadline: deadline,
            amountIn: IERC20(USDC_ON_ARB).balanceOf(msg.sender),
            amountOutMinimum: 1000 * 10 ** 6,
            sqrtPriceLimitX96: 0
        });
        uint256 amountOut = ISwapRouter(SWAP_ROUTER).exactInputSingle(swapParam);
        vm.stopPrank();
        console.log("USDC Current balance: %s", IERC20(USDC_ON_ARB).balanceOf(msg.sender));
        console.log("ARB Current balance: %s", IERC20(ARB_ON_ARB).balanceOf(msg.sender));
    }

    function test_Arbitrage() public {
        vm.startPrank(msg.sender);
        (uint256 long0, uint256 long1) =
            ITimeswapV2Pool(TIMESWAP_V2_OPTION_ARB_USDC).totalLongBalanceAdjustFees(strike, maturity);
        console.log("Current Long(0,1): %s %s", long0, long1);
        TimeswapV2ArbitrageParam memory param = TimeswapV2ArbitrageParam({
            strike: strike,
            maturity: maturity,
            isLong0ToLong1: false,
            transaction: TimeswapV2PoolRebalance.GivenLong0,
            delta: long0,
            data: bytes("")
        });
        arbitrage.arbitrage(param);
    }
    // function test_Increment() public {
    //     counter.increment();
    //     assertEq(counter.number(), 1);
    // }

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    // }
}
