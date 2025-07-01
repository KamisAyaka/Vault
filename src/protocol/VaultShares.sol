// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IVaultShares, IERC4626} from "../interfaces/IVaultShares.sol";
import {AaveAdapter, IPool} from "./investableUniverseAdapters/AaveAdapter.sol";
import {UniswapAdapter} from "./investableUniverseAdapters/UniswapAdapter.sol";
import {DataTypes} from "../vendor/DataTypes.sol";
import {IUniswapV2Pair} from "../vendor/IUniswapV2Pair.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VaultShares
 * @dev 基于 ERC-4626 的投资金库合约，支持多协议资产配置
 * @dev 继承自 ERC4626（基础代币功能）、IVaultShares（自定义接口）、
 *      AaveAdapter（Aave集成）、UniswapAdapter（Uniswap集成）、
 *      ReentrancyGuard（防重入保护）
 */
contract VaultShares is
    ERC4626, // OpenZeppelin标准ERC4626实现
    IVaultShares, // 自定义VaultShares接口
    AaveAdapter, // Aave协议适配器
    UniswapAdapter, // Uniswap协议适配器
    ReentrancyGuard // 防止重入攻击
{
    // 错误定义
    error VaultShares__DepositMoreThanMax(uint256 amount, uint256 max);
    error VaultShares__NotOperatorGuardian(
        address sender,
        address operatorGuardian
    );
    error VaultShares__NotGovernanceGuardianContract();
    error VaultShares__AllocationNot100Percent(uint256 totalAllocation);
    error VaultShares__NotActive();

    /*//////////////////////////////////////////////////////////////
                            状态变量
    //////////////////////////////////////////////////////////////*/
    IERC20 internal immutable i_uniswapLiquidityToken;
    IERC20 internal immutable i_aaveAToken;
    address private immutable i_operatorGuardian; // 操作管理者地址
    address private immutable i_governanceGuardian; // 治理守护者协议地址
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

    /// @notice 操作管理者更新Uniswap滑点容忍度事件
    event SlippageToleranceUpdatedByOperatorGuardian(
        address indexed operatorGuardian, // 更新滑点容忍度的操作管理者地址
        uint256 tolerance // 新的滑点容忍度（以万分之一为单位）
    );

    /*//////////////////////////////////////////////////////////////
                               修饰符
    //////////////////////////////////////////////////////////////*/

    /// @dev 仅守护者可调用
    /// @dev 仅操作管理者可调用
    modifier onlyOperatorGuardian() {
        if (msg.sender != i_operatorGuardian) {
            revert VaultShares__NotOperatorGuardian(
                msg.sender,
                i_operatorGuardian
            );
        }
        _;
    }

    /// @dev 仅治理守护者协议可调用
    modifier onlyGovernanceGuardian() {
        if (msg.sender != i_governanceGuardian) {
            revert VaultShares__NotGovernanceGuardianContract();
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
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-events
    /**
     * @notice 清算所有 Uniswap 流动性头寸和 Aave 贷款头寸后重新投资
     * @notice 仅在金库活跃时执行再投资，用于调整仓位
     */
    modifier divestThenInvest() {
        _liquidatePositions();
        _;
        if (s_isActive) {
            _investFunds(IERC20(asset()).balanceOf(address(this)));
        }
    }

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
        i_operatorGuardian = constructorData.operatorGuardian; // 初始化操作管理者
        i_guardianAndDaoCut = constructorData.guardianAndDaoCut;
        i_governanceGuardian = constructorData.governanceGuardian; // 初始化治理守护者协议
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
    function setNotActive() public onlyGovernanceGuardian isActive {
        s_isActive = false;
        emit NoLongerActive();
    }

    /**
     * @notice 更新投资分配比例（由守护者调用）
     * @param tokenAllocationData 新的分配数据
     */
    function updateHoldingAllocation(
        AllocationData memory tokenAllocationData
    ) public onlyGovernanceGuardian isActive {
        uint256 totalAllocation = tokenAllocationData.holdAllocation +
            tokenAllocationData.uniswapAllocation +
            tokenAllocationData.aaveAllocation;
        if (totalAllocation != ALLOCATION_PRECISION) {
            revert VaultShares__AllocationNot100Percent(totalAllocation);
        }
        s_allocationData = tokenAllocationData;
        emit UpdatedAllocation(tokenAllocationData);
    }

    function totalAssets()
        public
        view
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        // 1. 获取合约中剩余的底层资产余额
        uint256 baseBalance = IERC20(asset()).balanceOf(address(this));

        // 2. 添加 Aave 投资价值（aToken 与底层资产 1:1 对应）
        uint256 aaveBalance = i_aaveAToken.balanceOf(address(this));

        // 3. 添加 Uniswap 投资价值（计算 LP Token 对应的底层资产数量）
        uint256 uniswapBalance = _getUniswapUnderlyingAssetValue();

        return baseBalance + aaveBalance + uniswapBalance;
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

        _mint(i_operatorGuardian, shares / i_guardianAndDaoCut);
        _mint(i_governanceGuardian, shares / i_guardianAndDaoCut);

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
        if (assets == 0) return;

        // 计算分配金额并执行投资
        uint256 uniswapAllocation = (assets *
            s_allocationData.uniswapAllocation) / ALLOCATION_PRECISION;
        if (uniswapAllocation > 0) {
            _uniswapInvest(IERC20(asset()), uniswapAllocation);
        }

        uint256 aaveAllocation = (assets * s_allocationData.aaveAllocation) /
            ALLOCATION_PRECISION;
        if (aaveAllocation > 0) {
            _aaveInvest(IERC20(asset()), aaveAllocation);
        }

        emit FundsInvested();
    }

    // 计算 Uniswap LP Token 对应的底层资产价值
    function _getUniswapUnderlyingAssetValue() private view returns (uint256) {
        uint256 liquidityTokens = i_uniswapLiquidityToken.balanceOf(
            address(this)
        );
        if (liquidityTokens == 0) return 0;

        IUniswapV2Pair pair = IUniswapV2Pair(address(i_uniswapLiquidityToken));
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();

        // 1. 计算LP代币对应的两种资产数量
        uint256 amount0 = (uint256(reserve0) * liquidityTokens) / totalSupply;
        uint256 amount1 = (uint256(reserve1) * liquidityTokens) / totalSupply;

        address token0 = pair.token0();
        address token1 = pair.token1();
        address underlying = asset();

        // 2. 将配对资产转换为底层资产计价
        if (underlying == token0) {
            // amount0已是底层资产，将amount1(WETH)转换为底层资产
            // 价格 = reserve0/reserve1 表示1个WETH可兑换的底层资产数量
            uint256 amount1InUnderlying = (amount1 * reserve0) / reserve1;
            return amount0 + amount1InUnderlying;
        } else if (underlying == token1) {
            // amount1已是底层资产，将amount0(WETH)转换为底层资产
            uint256 amount0InUnderlying = (amount0 * reserve1) / reserve0;
            return amount1 + amount0InUnderlying;
        } else {
            revert("Invalid asset pair");
        }
    }

    function _liquidatePositions() private {
        uint256 liquidityTokens = i_uniswapLiquidityToken.balanceOf(
            address(this)
        );
        if (liquidityTokens > 0) {
            _uniswapDivest(IERC20(asset()), liquidityTokens);
        }

        liquidityTokens = i_aaveAToken.balanceOf(address(this));
        if (liquidityTokens > 0) {
            _aaveDivest(IERC20(asset()), liquidityTokens);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               操作函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice 强制清算并重新平衡投资组合
     * @notice 任何人都可调用但需支付高昂Gas费用
     * @notice 应用场景是守护者调整仓位或者出现问题时紧急熔断
     */
    function rebalanceFunds() public isActive divestThenInvest nonReentrant {}

    /*//////////////////////////////////////////////////////////////
                               视图函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @return 返回金库守护者地址
     */
    function getOperatorGuardian() external view returns (address) {
        return i_operatorGuardian;
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
    function getGovernanceGuardian() external view returns (address) {
        return i_governanceGuardian;
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

    /**
     * @notice 守护者更新Uniswap滑点容忍度
     * @param tolerance 新的滑点容忍值（以万分之一为单位）
     * @dev 示例：200 = 2%
     * @dev 需守护者身份验证
     */
    function updateUniswapSlippage(
        uint256 tolerance
    ) external onlyOperatorGuardian {
        // 验证新的滑点容忍度不超过最大限制（10%）
        require(tolerance <= 1000, "Slippage tolerance cannot exceed 10%");

        // 验证新的滑点容忍度与当前值不同
        require(
            tolerance != slippageTolerance(),
            "New tolerance is the same as current tolerance"
        );

        super.setSlippageTolerance(tolerance); // 调用父类函数设置新滑点容忍度

        // 发出事件，记录旧值和新值
        emit SlippageToleranceUpdatedByOperatorGuardian(msg.sender, tolerance);
    }
}
