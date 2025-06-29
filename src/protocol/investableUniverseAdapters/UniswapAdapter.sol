// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IUniswapV2Router01} from "../../vendor/IUniswapV2Router01.sol";
import {IUniswapV2Factory} from "../../vendor/IUniswapV2Factory.sol";
import {AStaticUSDCData, IERC20} from "../../abstract/AStaticUSDCData.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UniswapAdapter is AStaticUSDCData {
    error UniswapAdapter__TransferFailed();

    using SafeERC20 for IERC20;

    IUniswapV2Router01 internal immutable i_uniswapRouter;
    IUniswapV2Factory internal immutable i_uniswapFactory;

    address[] private s_pathArray;

    event UniswapInvested(
        uint256 tokenAmount,
        uint256 wethAmount,
        uint256 liquidity
    );
    event UniswapDivested(uint256 tokenAmount, uint256 wethAmount);

    constructor(
        address uniswapRouter,
        address weth,
        address tokenOne
    ) AStaticUSDCData(weth, tokenOne) {
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
    function _uniswapInvest(IERC20 token, uint256 amount) internal {
        IERC20 counterPartyToken = token == i_weth ? i_tokenOne : i_weth;
        // 我们将一半用于WETH，一半用于该代币
        uint256 amountOfTokenToSwap = amount / 2;
        // 路径数组传递给Uniswap路由器，允许创建交换路径
        // 当输入代币和输出代币的池不存在时也适用
        // 但在本例中，我们确定WETH、USDC和LINK的所有组合都存在交易对
        // 索引0是输入代币地址
        // 索引1是输出代币地址
        s_pathArray = [address(token), address(counterPartyToken)];

        bool succ = token.approve(
            address(i_uniswapRouter),
            amountOfTokenToSwap
        );
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }
        uint256[] memory amounts = i_uniswapRouter.swapExactTokensForTokens({
            amountIn: amountOfTokenToSwap,
            amountOutMin: 0,
            path: s_pathArray,
            to: address(this),
            deadline: block.timestamp
        });

        succ = counterPartyToken.approve(address(i_uniswapRouter), amounts[1]);
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }
        succ = token.approve(
            address(i_uniswapRouter),
            amountOfTokenToSwap + amounts[0]
        );
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }

        // amounts[1]应为获得的WETH数量
        (
            uint256 tokenAmount,
            uint256 counterPartyTokenAmount,
            uint256 liquidity
        ) = i_uniswapRouter.addLiquidity({
                tokenA: address(token),
                tokenB: address(counterPartyToken),
                amountADesired: amountOfTokenToSwap + amounts[0],
                amountBDesired: amounts[1],
                amountAMin: 0,
                amountBMin: 0,
                to: address(this),
                deadline: block.timestamp
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
        uint256 liquidityAmount
    ) internal returns (uint256 amountOfAssetReturned) {
        IERC20 counterPartyToken = token == i_weth ? i_tokenOne : i_weth;

        (uint256 tokenAmount, uint256 counterPartyTokenAmount) = i_uniswapRouter
            .removeLiquidity({
                tokenA: address(token),
                tokenB: address(counterPartyToken),
                liquidity: liquidityAmount,
                amountAMin: 0,
                amountBMin: 0,
                to: address(this),
                deadline: block.timestamp
            });
        s_pathArray = [address(counterPartyToken), address(token)];
        uint256[] memory amounts = i_uniswapRouter.swapExactTokensForTokens({
            amountIn: counterPartyTokenAmount,
            amountOutMin: 0,
            path: s_pathArray,
            to: address(this),
            deadline: block.timestamp
        });
        emit UniswapDivested(tokenAmount, amounts[1]);
        amountOfAssetReturned = amounts[1];
    }
    // slither-disable-end reentrancy-benign
    // slither-disable-end reentrancy-events
    // slither-disable-end reentrancy-eth
}
