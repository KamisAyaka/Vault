// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Pair} from "../../vendor/IUniswapV2Pair.sol";
import {IUniswapV2Router01} from "../../vendor/IUniswapV2Router01.sol";
import {IUniswapV2Factory} from "../../vendor/IUniswapV2Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UniswapAdapter {
    error UniswapAdapter__TransferFailed();

    using SafeERC20 for IERC20;

    IUniswapV2Router01 internal immutable i_uniswapRouter;
    IUniswapV2Factory internal immutable i_uniswapFactory;

    uint256 private s_slippageTolerance = 100; // 默认 1% 滑点容忍
    address[] private s_pathArray;

    event UniswapInvested(
        uint256 tokenAmount,
        uint256 counterPartyTokenAmount,
        uint256 liquidity
    );
    event UniswapDivested(uint256 tokenAmount, uint256 counterPartyTokenAmount);
    event SlippageToleranceUpdated(uint256 tolerance);

    constructor(address uniswapRouter) {
        i_uniswapRouter = IUniswapV2Router01(uniswapRouter);
        i_uniswapFactory = IUniswapV2Factory(
            IUniswapV2Router01(i_uniswapRouter).factory()
        );
    }

    // slither-disable-start reentrancy-eth
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-events
    /**
     * @notice 金库仅持有一种资产代币。但我们需要提供流动性到Uniswap的交易对
     * @notice 所以如果资产是USDC或WETH，我们用一半的资产兑换WETH
     * @notice 如果资产是WETH，则兑换一半为USDC（tokenOne）
     * @notice 然后将获得的代币添加到Uniswap池，铸造LP代币给金库
     * @param token 金库的底层资产代币
     * @param amount 用于投资的资产数量
     */
    function _uniswapInvest(
        IERC20 token,
        IERC20 counterPartyToken,
        uint256 amount
    ) internal {
        uint256 amountOfTokenToSwap = amount / 2;

        // 动态生成路径数组
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(counterPartyToken);

        // 计算最小输出量
        uint256[] memory expectedAmounts = i_uniswapRouter.getAmountsOut(
            amountOfTokenToSwap,
            path
        );
        uint256 minAmountOut = (expectedAmounts[1] *
            (10000 - s_slippageTolerance)) / 10000;

        // 执行兑换
        uint256 actualAmountOut = _swap(
            token,
            counterPartyToken,
            amountOfTokenToSwap,
            minAmountOut
        );

        // 批准流动性添加
        counterPartyToken.approve(address(i_uniswapRouter), actualAmountOut);
        token.approve(
            address(i_uniswapRouter),
            amountOfTokenToSwap
        );

        // 添加流动性
        (
            uint256 tokenAmount,
            uint256 counterPartyTokenAmount,
            uint256 liquidity
        ) = i_uniswapRouter.addLiquidity({
                tokenA: address(token),
                tokenB: address(counterPartyToken),
                amountADesired: amountOfTokenToSwap + expectedAmounts[0],
                amountBDesired: expectedAmounts[1],
                amountAMin: ((amountOfTokenToSwap + expectedAmounts[0]) *
                    (10000 - s_slippageTolerance)) / 10000, // 添加滑点保护
                amountBMin: (expectedAmounts[1] * (10000 - s_slippageTolerance)) /
                    10000, // 添加滑点保护
                to: address(this),
                deadline: block.timestamp + 300
            });

        emit UniswapInvested(tokenAmount, counterPartyTokenAmount, liquidity);
    }

    /**
     * @notice 销毁添加的流动性对应的LP代币
     * @notice 将非金库底层资产的代币兑换回底层资产
     * @param token 金库的底层资产代币
     * @param liquidityAmount 要销毁的LP代币数量
     */
    function _uniswapDivest(
        IERC20 token,
        IERC20 counterPartyToken,
        uint256 liquidityAmount
    ) internal returns (uint256) {
        address pairAddress = i_uniswapFactory.getPair(
            address(token),
            address(counterPartyToken)
        );
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);

        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();

        // 计算滑点保护值
        (uint256 minToken, uint256 minCounter) = _calculateMinAmounts(
            token,
            pair,
            reserve0,
            reserve1,
            totalSupply,
            liquidityAmount
        );

        // 执行流动性移除
        (uint256 tokenAmount, uint256 counterPartyAmount) = i_uniswapRouter
            .removeLiquidity({
                tokenA: address(token),
                tokenB: address(counterPartyToken),
                liquidity: liquidityAmount,
                amountAMin: minToken,
                amountBMin: minCounter,
                to: address(this),
                deadline: block.timestamp + 300
            });

        // 将配对代币兑换回底层资产
        if (address(token) != pair.token0() && counterPartyAmount > 0) {
            // 创建正确的交易路径
            address[] memory path = new address[](2);
            path[0] = address(counterPartyToken);
            path[1] = address(token);

            uint256 expectedOut = i_uniswapRouter.getAmountsOut(counterPartyAmount, path)[1];
            uint256 minOut = (expectedOut * (10000 - s_slippageTolerance)) / 10000;
            
            _swap(
                counterPartyToken,
                token,
                counterPartyAmount,
                minOut
            );
        }

        return tokenAmount;
    }

    /**
     * @notice 执行代币兑换的通用逻辑
     * @param tokenIn 输入代币
     * @param tokenOut 输出代币
     * @param amountIn 输入代币数量
     * @param minOut 最小输出数量（用于滑点保护）
     * @return 实际兑换获得的代币数量
     */
    function _swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (uint256) {
        // 创建交易路径
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);

        // 执行兑换
        tokenIn.approve(address(i_uniswapRouter), amountIn);
        
        uint256[] memory amounts = i_uniswapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: minOut,
            path: path,
            to: address(this),
            deadline: block.timestamp + 300
        });

        return amounts[1];
    }

    // 分离最小金额计算逻辑
    function _calculateMinAmounts(
        IERC20 token,
        IUniswapV2Pair pair,
        uint112 reserve0,
        uint112 reserve1,
        uint256 totalSupply,
        uint256 liquidityAmount
    ) private view returns (uint256, uint256) {
        uint256 slippage = s_slippageTolerance;
        if (address(token) == pair.token0()) {
            return (
                (((uint256(reserve0) * liquidityAmount) / totalSupply) *
                    (10000 - slippage)) / 10000,
                (((uint256(reserve1) * liquidityAmount) / totalSupply) *
                    (10000 - slippage)) / 10000
            );
        }
        return (
            (((uint256(reserve1) * liquidityAmount) / totalSupply) *
                (10000 - slippage)) / 10000,
            (((uint256(reserve0) * liquidityAmount) / totalSupply) *
                (10000 - slippage)) / 10000
        );
    }

    // slither-disable-end reentrancy-benign
    // slither-disable-end reentrancy-events
    // slither-disable-end reentrancy-eth

    function setSlippageTolerance(uint256 tolerance) internal {
        s_slippageTolerance = tolerance;
        emit SlippageToleranceUpdated(tolerance);
    }

    function slippageTolerance() public view returns (uint256) {
        return s_slippageTolerance;
    }
}
