// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {VaultGuardiansBase, IERC20, SafeERC20} from "./VaultGuardiansBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VaultGuardians
 * @notice 本合约是 Vault Guardian 系统的入口合约
 * @notice 包含 DAO 拥有的所有控制功能，所有者是DAO
 * @notice VaultGuardiansBase 包含用户和操作管理者的所有功能
 */
contract VaultGuardians is Ownable, VaultGuardiansBase {
    using SafeERC20 for IERC20;

    /// @notice 转账失败错误
    error VaultGuardians__TransferFailed();

    /// @notice 批准代币事件
    event ApprovedTokenAdded(address indexed token);

    /*//////////////////////////////////////////////////////////////
                                 事件
    //////////////////////////////////////////////////////////////*/
    /// @notice 质押价格更新事件
    /// @param oldStakePrice 旧质押价格
    /// @param newStakePrice 新质押价格
    event VaultGuardians__UpdatedStakePrice(
        uint256 oldStakePrice,
        uint256 newStakePrice
    );
    /// @notice 操作管理者手续费更新事件
    /// @param oldFee 旧手续费
    /// @param newFee 新手续费
    event VaultGuardians__UpdatedFee(uint256 oldFee, uint256 newFee);
    /// @notice 提取代币事件
    /// @param asset 被提取的代币地址
    event VaultGuardians__SweptTokens(address asset);

    /*//////////////////////////////////////////////////////////////
                               构造函数
    //////////////////////////////////////////////////////////////*/
    constructor(
        address aavePool,
        address uniswapV2Router,
        address weth,
        address tokenOne,
        address tokenTwo,
        address vaultGuardiansToken
    )
        Ownable(msg.sender)
        VaultGuardiansBase(
            aavePool,
            uniswapV2Router,
            weth,
            tokenOne,
            tokenTwo,
            vaultGuardiansToken
        )
    {}

    /*//////////////////////////////////////////////////////////////
                               外部函数
    //////////////////////////////////////////////////////////////*/
    /// @notice 更新守护者的质押价格（现为操作管理者）
    /// @param newStakePrice 新的质押价格（以 wei 为单位）
    function updateGuardianStakePrice(
        uint256 newStakePrice
    ) external onlyOwner {
        s_guardianStakePrice = newStakePrice;
        emit VaultGuardians__UpdatedStakePrice(
            s_guardianStakePrice,
            newStakePrice
        );
    }

    /// @notice 更新新金库中操作管理者和 DAO 获取的份额比例
    /// @param newCut 新的比例值
    /// @dev 该值将在用户存入金库时除以份额总数
    /// @dev 历史金库不会更新比例，仅影响后续新创建的金库
    function updateGuardianAndDaoCut(uint256 newCut) external onlyOwner {
        s_guardianAndDaoCut = newCut;
        emit VaultGuardians__UpdatedStakePrice(s_guardianAndDaoCut, newCut);
    }

    /// @notice DAO添加新的批准代币
    /// @param token 要新增的代币地址
    function addApprovedToken(IERC20 token) external onlyOwner {
        _addApprovedToken(token);
        emit ApprovedTokenAdded(address(token));
    }

    /// @notice DAO 可以提取金库中的多余 ERC20 代币
    /// @notice 这些代币通常是兑换或舍入误差产生的零散资产
    /// @dev 由于金库归属 DAO 所有，这些资金将始终归 DAO 所有
    /// @param asset 需要提取的 ERC20 代币
    function sweepErc20s(IERC20 asset) external {
        uint256 amount = asset.balanceOf(address(this));
        emit VaultGuardians__SweptTokens(address(asset));
        asset.safeTransfer(owner(), amount);
    }
}
