// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
pragma abicoder v2;

import "./interface/ITimeswapV2Pool.sol";
import "./interface/ITimeswapV2Option.sol";
import {TimeswapV2OptionBurnCallbackParam, TimeswapV2OptionMintCallbackParam} from "./structs/OptionCallbackParam.sol";
import "./structs/PoolParam.sol";
import {TimeswapV2PoolRebalanceCallbackParam} from "./structs/CallbackParam.sol";
import "./structs/ArbitrageParam.sol";
import {TimeswapV2OptionPosition} from "./structs/enums/Position.sol";
import {ITimeswapV2PoolRebalanceCallback} from "./interface/callback/ITimeswapV2PoolRebalanceCallback.sol";
import {ITimeswapV2OptionBurnCallback} from "./interface/callback/ITimeswapV2OptionBurnCallback.sol";
import {ITimeswapV2OptionMintCallback} from "./interface/callback/ITimeswapV2OptionMintCallback.sol";

import {TimeswapV2OptionBurnParam, TimeswapV2OptionMintParam} from "./structs/OptionParam.sol";
import {TimeswapV2OptionBurn, TimeswapV2OptionMint} from "./structs/enums/OptionTransaction.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import "@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol";

import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

contract TimeswapV2Arbitrage is
    IUniswapV3FlashCallback,
    ITimeswapV2PoolRebalanceCallback,
    Ownable,
    ITimeswapV2OptionMintCallback,
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

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {}

    function timeswapV2OptionMintCallback(TimeswapV2OptionMintCallbackParam calldata param)
        external
        override
        returns (bytes memory data)
    {
        address option = timeswapV2Pool.optionPair();
        require(msg.sender == option, "Not allowed external");
        address token0 = ITimeswapV2Option(option).token0();
        address token1 = ITimeswapV2Option(option).token1();
        if (param.token0AndLong0Amount != 0) {
            TransferHelper.safeTransfer(token0, option, param.token0AndLong0Amount);
        } else if (param.token1AndLong1Amount != 0) {
            TransferHelper.safeTransfer(token1, option, param.token1AndLong1Amount);
        }
    }

    // @dev mint short by flash swap to ensure it pass.

    function timeswapV2OptionBurnCallback(TimeswapV2OptionBurnCallbackParam calldata param)
        external
        override
        returns (bytes memory data)
    {
        address option = timeswapV2Pool.optionPair();
        TimeswapV2PoolRebalanceCallbackParam memory decoded =
            abi.decode(param.data, (TimeswapV2PoolRebalanceCallbackParam));
        require(msg.sender == option, "Not allowed external");
        address token0 = ITimeswapV2Option(option).token0();
        address token1 = ITimeswapV2Option(option).token1();
        uint24 poolFee = 500;
        uint256 deadline = block.timestamp + 200;

        if (param.token0AndLong0Amount != 0) {
            uint256 token0Amount = IERC20(token0).balanceOf(address(this));
            TransferHelper.safeApprove(token0, address(swapRouter), token0Amount);
            ISwapRouter.ExactInputSingleParams memory swapParam = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: poolFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: token0Amount,
                // @todo add a profit margin here?
                amountOutMinimum: decoded.long1Amount,
                sqrtPriceLimitX96: 0
            });

            swapRouter.exactInputSingle(swapParam);
            ITimeswapV2Option(option).mint(
                TimeswapV2OptionMintParam({
                    strike: param.strike,
                    maturity: param.maturity,
                    long0To: address(this),
                    long1To: address(this),
                    shortTo: address(this),
                    transaction: TimeswapV2OptionMint.GivenTokensAndLongs,
                    amount0: 0,
                    amount1: decoded.long1Amount,
                    data: bytes("")
                })
            );
        } else if (param.token1AndLong1Amount != 0) {
            uint256 token1Amount = IERC20(token1).balanceOf(address(this));
            TransferHelper.safeApprove(address(token1), address(swapRouter), token1Amount);
            ISwapRouter.ExactInputSingleParams memory swapParam = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token1),
                tokenOut: address(token0),
                fee: poolFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: token1Amount,
                amountOutMinimum: decoded.long0Amount,
                sqrtPriceLimitX96: 0
            });
            swapRouter.exactInputSingle(swapParam);
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
                    data: abi.encode(
                        TimeswapV2PoolRebalanceCallbackParam({
                            strike: param.strike,
                            maturity: param.maturity,
                            isLong0ToLong1: param.isLong0ToLong1,
                            long0Amount: param.long0Amount,
                            long1Amount: param.long1Amount,
                            data: bytes("")
                        })
                    )
                })
            );

            option.positionOf(param.strike, param.maturity, address(this), TimeswapV2OptionPosition.Long0);

            option.positionOf(param.strike, param.maturity, address(this), TimeswapV2OptionPosition.Long1);

            option.positionOf(param.strike, param.maturity, address(this), TimeswapV2OptionPosition.Short);
            IERC20(token0).balanceOf(address(this));
            IERC20(token1).balanceOf(address(this));
            option.transferPosition(
                param.strike, param.maturity, address(timeswapV2Pool), TimeswapV2OptionPosition.Long0, param.long0Amount
            );
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
                    data: abi.encode(
                        TimeswapV2PoolRebalanceCallbackParam({
                            strike: param.strike,
                            maturity: param.maturity,
                            isLong0ToLong1: param.isLong0ToLong1,
                            long0Amount: param.long0Amount,
                            long1Amount: param.long1Amount,
                            data: bytes("")
                        })
                    )
                })
            );
            option.positionOf(param.strike, param.maturity, address(this), TimeswapV2OptionPosition.Long0);

            option.positionOf(param.strike, param.maturity, address(this), TimeswapV2OptionPosition.Long1);

            option.positionOf(param.strike, param.maturity, address(this), TimeswapV2OptionPosition.Short);
            IERC20(token0).balanceOf(address(this));
            IERC20(token1).balanceOf(address(this));
            option.transferPosition(
                param.strike, param.maturity, address(timeswapV2Pool), TimeswapV2OptionPosition.Long1, param.long1Amount
            );
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

        address option = timeswapV2Pool.optionPair();
        address token0 = ITimeswapV2Option(option).token0();
        address token1 = ITimeswapV2Option(option).token1();
        uint256 token0Balance = IERC20(token0).balanceOf(address(this));
        uint256 token1Balance = IERC20(token1).balanceOf(address(this));
        if (token0Balance != 0) {
            TransferHelper.safeTransfer(address(token0), owner(), token0Balance);
        }
        if (token1Balance != 0) {
            TransferHelper.safeTransfer(address(token1), owner(), token1Balance);
        }
    }
}
