// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {DataTypes} from "./DataTypes.sol";

// AaveV3 Pool接口的一个子集
// https://github.com/aave/aave-v3-core/blob/master/contracts/interfaces/IPool.sol
interface IPool {
    /* @notice 向储备池存入指定数量的底层资产，获得对应的aToken
     * - 示例：用户存入100 USDC，获得100 aUSDC
     * @param asset 要存入的底层资产地址
     * @param amount 要存入的数量
     * @param onBehalfOf 接收aToken的地址，若用户希望接收至自己钱包则与msg.sender相同
     *   若希望其他地址接收，则可以指定不同地址
     * @param referralCode 用于记录操作来源的推荐码，0表示无中间人直接操作
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /**
     * @notice 从储备池提取指定数量的底层资产，同时销毁相应的aToken
     * 示例：用户持有100 aUSDC，调用该函数后获得100 USDC并销毁aToken
     * @param asset 要提取的底层资产地址
     * @param amount 要提取的底层资产数量
     *   - 传入type(uint256).max可提取全部aToken余额
     * @param to 接收底层资产的地址，与msg.sender相同表示接收至用户自己的钱包
     * @return 实际提取的资产数量
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    /**
     * @notice 返回储备池的状态和配置信息
     * @param asset 储备资产的地址
     * @return 储备池的状态和配置数据
     */
    function getReserveData(
        address asset
    ) external view returns (DataTypes.ReserveData memory);
}
