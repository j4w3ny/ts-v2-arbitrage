// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
pragma abicoder v2;

import "./interface/ITimeswapV2Pool.sol";
import "./interface/ITimeswapV2Option.sol";
import "./structs/PoolParam.sol";
import "./structs/ArbitrageParam.sol";
import "./interface/callback/ITimeswapV2PoolRebalanceCallback.sol";
import {TimeswapV2OptionBurnParam, TimeswapV2OptionMintParam} from "./structs/OptionParam.sol";
import {TimeswapV2OptionBurn, TimeswapV2OptionMint} from "./structs/enums/OptionTransaction.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract TimeswapV2Arbitrage is ITimeswapV2PoolRebalanceCallback, Ownable {
    ITimeswapV2Pool private immutable timeswapV2Pool;
    ISwapRouter public immutable swapRouter;

    constructor(ITimeswapV2Pool _poolAddress,ISwapRouter _swapRouter) Ownable(msg.sender) {
        timeswapV2Pool = _poolAddress;
		swapRouter = _swapRouter;
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
        option.burn(
            TimeswapV2OptionBurnParam({
                strike: param.strike,
                maturity: param.maturity,
                token0To: address(this),
                token1To: address(this),
                transaction: TimeswapV2OptionBurn.GivenTokensAndLongs,
                amount0: param.long0Amount,
                amount1: param.long1Amount,
				data: bytes("")
            })
        );
        uint24 poolFee = 500;
        uint256 deadline = block.timestamp + 200;
        if (param.isLong0ToLong1) {
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
            uint256 token0Out = swapRouter.exactInputSingle(swapParam);

            // mint position and payback
            option.mint(
                TimeswapV2OptionMintParam({
                    strike: param.strike,
                    maturity: param.maturity,
                    long0To: address(option),
                    long1To: address(option),
                    shortTo: address(option),
                    transaction: TimeswapV2OptionMint.GivenTokensAndLongs,
                    amount0: token0Out,
                    amount1: 0,
					data: bytes('')
                })
            );
        } else {
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

			uint256 token1Out = swapRouter.exactInputSingle(swapParam);

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
                    amount1: token1Out,
					data: bytes('')
                })
            );
        }
    }
    // @todo make multiple dex source for the arbitrage

    function arbitrage(TimeswapV2ArbitrageParam calldata param) external onlyOwner {
        // TODO
        timeswapV2Pool.rebalance(TimeswapV2PoolRebalanceParam({
            strike: param.strike,
            maturity: param.maturity,
            to: address(this),
            isLong0ToLong1: param.isLong0ToLong1,
            transaction: param.transaction,
            delta: param.delta,
			data: bytes('')
        }));
    }

    function withdraw() external onlyOwner {
        ITimeswapV2Option option = ITimeswapV2Option(timeswapV2Pool.optionPair());
        IERC20 token0 = IERC20(option.token0());
        IERC20 token1 = IERC20(option.token1());
        // dont check, just send cuz owner should check.
        token0.transfer(msg.sender, token0.balanceOf(address(this)));
        token1.transfer(msg.sender, token1.balanceOf(address(this)));
    }
}
