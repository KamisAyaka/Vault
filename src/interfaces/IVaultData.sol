// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IVaultData {
    /**
     * @notice 该结构体存储由金库守护者设置的底层资产代币投资比例
     * @notice holdAllocation 表示保留在金库中的代币比例（不用于Uniswap v2或Aave v3投资）
     * @notice uniswapAllocation 表示添加到Uniswap v2的流动性比例
     * @notice aaveAllocation 表示在Aave v3中作为借贷金额的比例
     */
    struct AllocationData {
        uint256 holdAllocation;
        uint256 uniswapAllocation;
        uint256 aaveAllocation;
    }
}
