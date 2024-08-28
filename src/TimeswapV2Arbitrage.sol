// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
pragma abicoder v2;

import "./interface/ITimeswapV2Pool.sol";
import "./interface/ITimeswapV2Option.sol";
import "./structs/PoolParam.sol";
import "./structs/ArbitrageParam.sol";
import {TimeswapV2OptionPosition} from "./structs/enums/Position.sol";
import {ITimeswapV2PoolRebalanceCallback} from "./interface/callback/ITimeswapV2PoolRebalanceCallback.sol";
import {ITimeswapV2OptionBurnCallback} from "./interface/callback/ITimeswapV2OptionBurnCallback.sol";
import {TimeswapV2OptionBurnParam, TimeswapV2OptionMintParam} from "./structs/OptionParam.sol";
import {TimeswapV2OptionBurn, TimeswapV2OptionMint} from "./structs/enums/OptionTransaction.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import '@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol';

import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

contract TimeswapV2Arbitrage is
    IUniswapV3FlashCallback,
    ITimeswapV2PoolRebalanceCallback,
    Ownable,
    ITimeswapV2OptionBurnCallback
{
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;

    ISwapRouter public immutable swapRouter;
    ITimeswapV2Pool private immutable timeswapV2Pool;

    constructor(ITimeswapV2Pool _poolAddress, ISwapRouter _swapRouter) Ownable(msg.sender) {
        timeswapV2Pool = _poolAddress;
        swapRouter = _swapRouter;
    }

   function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override { 
		FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
		CallbackValidation.verifyCallback(factory, decoded.poolKey);

	}

    // @dev mint short by flash swap to ensure it pass.

    function timeswapV2OptionBurnCallback(TimeswapV2OptionBurnCallbackParam calldata param)
        external
        override
        returns (bytes memory data)
    {
        require(msg.sender == timeswapV2Pool.optionPair(), "Not allowed external");
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee1});
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));
        if (param.token0AndLong0Amount != 0) {
            pool.flash(address(this), param.token0AndLong0Amount, 0, bytes(""));
            // abi.encode(
            //     FlashCallbackData({
            //         amount0: param.token0AndLong0Amount,
            //         amount1: 0,
            //         payer: msg.sender,
            //         poolKey: poolKey,
            //         poolFee2: params.fee2,
            //         poolFee3: params.fee3
            //     })
            // )
        } else if (param.token1AndLong1Amount != 0) {
            pool.flash(address(this), 0, param.token1AndLong1Amount, bytes(""));
            // abi.encode(
            //     FlashCallbackData({
            //         amount0: param.token0AndLong0Amount,
            //         amount1: 0,
            //         payer: msg.sender,
            //         poolKey: poolKey,
            //         poolFee2: params.fee2,
            //         poolFee3: params.fee3
            //     })
            // )
        }
    }
    // @dev repay the debt of the pool and store profit

    function timeswapV2PoolRebalanceCallback(TimeswapV2PoolRebalanceCallbackParam calldata param)
        external
        override
        returns (bytes memory data)
    {
        require(msg.sender == address(timeswapV2Pool), "Not allowed external");
        ITimeswapV2Option option = ITimeswapV2Option(timeswapV2Pool.optionPair());
        IERC20 token0 = IERC20(option.token0());
        IERC20 token1 = IERC20(option.token1());

        // burn to get token

        uint24 poolFee = 500;
        uint256 deadline = block.timestamp + 200;
        if (param.isLong0ToLong1) {
            option.burn(
                TimeswapV2OptionBurnParam({
                    strike: param.strike,
                    maturity: param.maturity,
                    token0To: address(this),
                    token1To: address(this),
                    transaction: TimeswapV2OptionBurn.GivenTokensAndLongs,
                    amount0: 0,
                    amount1: param.long1Amount,
                    data: bytes("")
                })
            );
            uint256 token1Amount = token1.balanceOf(address(this));
            TransferHelper.safeApprove(address(token1), address(swapRouter), token1Amount);
            ISwapRouter.ExactInputSingleParams memory swapParam = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token1),
                tokenOut: address(token0),
                fee: poolFee,
                recipient: msg.sender,
                deadline: deadline,
                amountIn: token1Amount,
                amountOutMinimum: param.long0Amount,
                sqrtPriceLimitX96: 0
            });
            swapRouter.exactInputSingle(swapParam);

            TransferHelper.safeApprove(address(token0), address(option), param.long0Amount);
            // mint position and payback
            option.mint(
                TimeswapV2OptionMintParam({
                    strike: param.strike,
                    maturity: param.maturity,
                    long0To: address(option),
                    long1To: address(option),
                    shortTo: address(option),
                    transaction: TimeswapV2OptionMint.GivenTokensAndLongs,
                    amount0: param.long0Amount,
                    amount1: 0,
                    data: bytes("")
                })
            );

            TransferHelper.safeTransfer(address(token0), owner(), token0.balanceOf(address(this)));
        } else {
            option.burn(
                TimeswapV2OptionBurnParam({
                    strike: param.strike,
                    maturity: param.maturity,
                    token0To: address(this),
                    token1To: address(this),
                    transaction: TimeswapV2OptionBurn.GivenTokensAndLongs,
                    amount0: param.long0Amount,
                    amount1: 0,
                    data: bytes("MINTSHORT")
                })
            );
            uint256 token0Amount = token0.balanceOf(address(this));
            TransferHelper.safeApprove(address(token0), address(swapRouter), param.long0Amount);
            ISwapRouter.ExactInputSingleParams memory swapParam = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: poolFee,
                recipient: msg.sender,
                deadline: deadline,
                amountIn: token0Amount,
                // @todo add a profit margin here?
                amountOutMinimum: param.long1Amount,
                sqrtPriceLimitX96: 0
            });

            swapRouter.exactInputSingle(swapParam);

            TransferHelper.safeApprove(address(token1), address(option), param.long1Amount);

            // mint position and payback
            option.mint(
                TimeswapV2OptionMintParam({
                    strike: param.strike,
                    maturity: param.maturity,
                    long0To: address(option),
                    long1To: address(option),
                    shortTo: address(option),
                    transaction: TimeswapV2OptionMint.GivenTokensAndLongs,
                    amount0: 0,
                    amount1: param.long1Amount,
                    data: bytes("")
                })
            );

            TransferHelper.safeTransfer(address(token1), owner(), token1.balanceOf(address(this)));
        }
    }
    // @todo make multiple dex source for the arbitrage

    function arbitrage(TimeswapV2ArbitrageParam calldata param) public onlyOwner {
        // TODO
        timeswapV2Pool.rebalance(
            TimeswapV2PoolRebalanceParam({
                strike: param.strike,
                maturity: param.maturity,
                to: address(this),
                isLong0ToLong1: param.isLong0ToLong1,
                transaction: param.transaction,
                delta: param.delta,
                data: bytes("")
            })
        );
    }
}
