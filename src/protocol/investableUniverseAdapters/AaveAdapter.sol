// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IPool} from "../../vendor/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AaveAdapter {
    using SafeERC20 for IERC20;

    error AaveAdapter__TransferFailed();

    IPool public immutable i_aavePool;

    constructor(address aavePool) {
        i_aavePool = IPool(aavePool);
    }

    /**
     * @notice 金库使用该函数将底层资产代币作为借贷金额存入Aave v3
     * @param asset 金库的底层资产代币
     * @param amount 要投资的底层资产代币数量
     */
    function _aaveInvest(IERC20 asset, uint256 amount) internal {
        bool succ = asset.approve(address(i_aavePool), amount);
        if (!succ) {
            revert AaveAdapter__TransferFailed();
        }
        i_aavePool.supply({
            asset: address(asset),
            amount: amount,
            onBehalfOf: address(this), // 决定谁获得Aave的aToken。在此情况下，铸造给金库
            referralCode: 0
        });
    }

    /**
     * @notice 金库使用该函数提取其作为借贷金额存入Aave v3的底层资产代币
     * @param token 要提取的金库底层资产代币
     * @param amount 要提取的底层资产代币数量
     */
    function _aaveDivest(
        IERC20 token,
        uint256 amount
    ) internal returns (uint256 amountOfAssetReturned) {
        amountOfAssetReturned = i_aavePool.withdraw({
            asset: address(token),
            amount: amount,
            to: address(this)
        });
    }
}
