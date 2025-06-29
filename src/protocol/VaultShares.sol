// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IVaultShares, IERC4626} from "../interfaces/IVaultShares.sol";
import {AaveAdapter, IPool} from "./investableUniverseAdapters/AaveAdapter.sol";
import {UniswapAdapter} from "./investableUniverseAdapters/UniswapAdapter.sol";
import {DataTypes} from "../vendor/DataTypes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VaultShares
 * @dev 基于 ERC-4626 的投资金库合约，支持多协议资产配置
 * @dev 继承自 ERC4626、IVaultShares、AaveAdapter、UniswapAdapter、ReentrancyGuard
 */
contract VaultShares is
    ERC4626,
    IVaultShares,
    AaveAdapter,
    UniswapAdapter,
    ReentrancyGuard
{
    // 错误定义
    error VaultShares__DepositMoreThanMax(uint256 amount, uint256 max);
    error VaultShares__NotGuardian();
    error VaultShares__NotVaultGuardianContract();
    error VaultShares__AllocationNot100Percent(uint256 totalAllocation);
    error VaultShares__NotActive();

    /*//////////////////////////////////////////////////////////////
                            状态变量
    //////////////////////////////////////////////////////////////*/
    IERC20 internal immutable i_uniswapLiquidityToken;
    IERC20 internal immutable i_aaveAToken;
    address private immutable i_guardian;
    address private immutable i_vaultGuardians;
    uint256 private immutable i_guardianAndDaoCut;
    bool private s_isActive;

    AllocationData private s_allocationData;

    uint256 private constant ALLOCATION_PRECISION = 1_000;

    /*//////////////////////////////////////////////////////////////
                                 事件
    //////////////////////////////////////////////////////////////*/
    event UpdatedAllocation(AllocationData allocationData);
    event NoLongerActive();
    event FundsInvested();

    /*//////////////////////////////////////////////////////////////
                               修饰符
    //////////////////////////////////////////////////////////////*/

    /// @dev 仅守护者可调用
    modifier onlyGuardian() {
        if (msg.sender != i_guardian) {
            revert VaultShares__NotGuardian();
        }
        _;
    }

    /// @dev 仅 VaultGuardians 合约可调用
    modifier onlyVaultGuardians() {
        if (msg.sender != i_vaultGuardians) {
            revert VaultShares__NotVaultGuardianContract();
        }
        _;
    }

    /// @dev 仅当金库处于活跃状态时可调用
    modifier isActive() {
        if (!s_isActive) {
            revert VaultShares__NotActive();
        }
        _;
    }

    // slither-disable-start reentrancy-eth
    /**
     * @notice 清算所有 Uniswap 流动性头寸和 Aave 贷款头寸后重新投资
     * @notice 仅在金库活跃时执行再投资
     */
    modifier divestThenInvest() {
        uint256 uniswapLiquidityTokensBalance = i_uniswapLiquidityToken
            .balanceOf(address(this));
        uint256 aaveAtokensBalance = i_aaveAToken.balanceOf(address(this));

        // 清算现有头寸
        if (uniswapLiquidityTokensBalance > 0) {
            _uniswapDivest(IERC20(asset()), uniswapLiquidityTokensBalance);
        }
        if (aaveAtokensBalance > 0) {
            _aaveDivest(IERC20(asset()), aaveAtokensBalance);
        }

        _;

        // 重新投资
        if (s_isActive) {
            _investFunds(IERC20(asset()).balanceOf(address(this)));
        }
    }

    // slither-disable-end reentrancy-eth

    /*//////////////////////////////////////////////////////////////
                               构造函数
    //////////////////////////////////////////////////////////////*/
    constructor(
        ConstructorData memory constructorData
    )
        ERC4626(constructorData.asset)
        ERC20(constructorData.vaultName, constructorData.vaultSymbol)
        AaveAdapter(constructorData.aavePool)
        UniswapAdapter(
            constructorData.uniswapRouter,
            constructorData.weth,
            constructorData.usdc
        )
    {
        i_guardian = constructorData.guardian;
        i_guardianAndDaoCut = constructorData.guardianAndDaoCut;
        i_vaultGuardians = constructorData.vaultGuardians;
        s_isActive = true;
        updateHoldingAllocation(constructorData.allocationData);

        // 获取外部合约地址
        i_aaveAToken = IERC20(
            IPool(constructorData.aavePool)
                .getReserveData(address(constructorData.asset))
                .aTokenAddress
        );
        i_uniswapLiquidityToken = IERC20(
            i_uniswapFactory.getPair(
                address(constructorData.asset),
                address(i_weth)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                               公共函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice 设置金库为非活跃状态（守护者离职）
     * @notice 用户仍可提取资产，但禁止新投资
     */
    function setNotActive() public onlyVaultGuardians isActive {
        s_isActive = false;
        emit NoLongerActive();
    }

    /**
     * @notice 更新投资分配比例（由守护者调用）
     * @param tokenAllocationData 新的分配数据
     */
    function updateHoldingAllocation(
        AllocationData memory tokenAllocationData
    ) public onlyVaultGuardians isActive {
        uint256 totalAllocation = tokenAllocationData.holdAllocation +
            tokenAllocationData.uniswapAllocation +
            tokenAllocationData.aaveAllocation;
        if (totalAllocation != ALLOCATION_PRECISION) {
            revert VaultShares__AllocationNot100Percent(totalAllocation);
        }
        s_allocationData = tokenAllocationData;
        emit UpdatedAllocation(tokenAllocationData);
    }

    /*//////////////////////////////////////////////////////////////
                               存款逻辑
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev 覆盖 Openzeppelin 的 deposit 实现
     * @dev 向 DAO 和 守护者铸造管理费份额
     */
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(
                assets,
                maxDeposit(receiver)
            );
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        _mint(i_guardian, shares / i_guardianAndDaoCut);
        _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

        _investFunds(assets);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                               内部投资逻辑
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice 根据当前分配配置投资用户资金
     * @param assets 需要投资的资产数量
     */
    function _investFunds(uint256 assets) private {
        uint256 uniswapAllocation = (assets *
            s_allocationData.uniswapAllocation) / ALLOCATION_PRECISION;
        uint256 aaveAllocation = (assets * s_allocationData.aaveAllocation) /
            ALLOCATION_PRECISION;

        emit FundsInvested();

        _uniswapInvest(IERC20(asset()), uniswapAllocation);
        _aaveInvest(IERC20(asset()), aaveAllocation);
    }

    /*//////////////////////////////////////////////////////////////
                               操作函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice 强制清算并重新平衡投资组合
     * @notice 任何人都可调用但需支付高昂Gas费用
     * ？？？？？？？？？？
     */
    function rebalanceFunds() public isActive divestThenInvest nonReentrant {}

    /*//////////////////////////////////////////////////////////////
                               视图函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @return 返回金库守护者地址
     */
    function getGuardian() external view returns (address) {
        return i_guardian;
    }

    /**
     * @return 返回 DAO 和 守护者管理费比例
     */
    function getGuardianAndDaoCut() external view returns (uint256) {
        return i_guardianAndDaoCut;
    }

    /**
     * @return 返回 VaultGuardians 协议地址
     */
    function getVaultGuardians() external view returns (address) {
        return i_vaultGuardians;
    }

    /**
     * @return 返回金库是否处于活跃状态
     */
    function getIsActive() external view returns (bool) {
        return s_isActive;
    }

    /**
     * @return 返回 Aave aToken 地址
     */
    function getAaveAToken() external view returns (address) {
        return address(i_aaveAToken);
    }

    /**
     * @return 返回 Uniswap LP 代币地址
     */
    function getUniswapLiquidtyToken() external view returns (address) {
        return address(i_uniswapLiquidityToken);
    }

    /**
     * @return 返回当前投资分配配置
     */
    function getAllocationData() external view returns (AllocationData memory) {
        return s_allocationData;
    }
}
