// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

// https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/types/DataTypes.sol
library DataTypes {
    struct ReserveData {
        // 存储储备池配置信息
        ReserveConfigurationMap configuration;
        // 流动性指数，以ray为单位
        uint128 liquidityIndex;
        // 当前供应利率，以ray为单位
        uint128 currentLiquidityRate;
        // 可变借贷指数，以ray为单位
        uint128 variableBorrowIndex;
        // 当前可变借贷利率，以ray为单位
        uint128 currentVariableBorrowRate;
        // 当前稳定借贷利率，以ray为单位
        uint128 currentStableBorrowRate;
        // 最后更新时间戳
        uint40 lastUpdateTimestamp;
        // 储备池ID，表示在活跃储备池列表中的位置
        uint16 id;
        // aToken地址
        address aTokenAddress;
        // 稳定债务代币地址
        address stableDebtTokenAddress;
        // 可变债务代币地址
        address variableDebtTokenAddress;
        // 利率策略地址
        address interestRateStrategyAddress;
        // 当前金库收益余额，已缩放
        uint128 accruedToTreasury;
        // 通过桥接功能铸造的未担保aToken余额
        uint128 unbacked;
        // 在隔离模式下借出的该资产债务总额
        uint128 isolationModeTotalDebt;
    }

    struct ReserveConfigurationMap {
        // bit 0-15: 贷款价值比(LTV)
        // bit 16-31: 清算阈值
        // bit 32-47: 清算奖励
        // bit 48-55: 小数位数
        // bit 56: 储备池是否激活
        // bit 57: 储备池是否冻结
        // bit 58: 借贷是否启用
        // bit 59: 稳定利率借贷是否启用
        // bit 60: 资产是否暂停
        // bit 61: 隔离模式借贷是否启用
        // bit 62: 单一借贷模式启用
        // bit 63: 闪电贷启用
        // bit 64-79: 储备因子
        // bit 80-115 整数借贷上限，0表示无上限
        // bit 116-151 整数供应上限，0表示无上限
        // bit 152-167 清算协议费用
        // bit 168-175 eMode类别
        // bit 176-211 未担保铸造上限，0表示禁用铸造
        // bit 212-251 隔离模式债务上限（带DEBT_CEILING_DECIMALS小数位）
        // bit 252-255 保留位
        uint256 data;
    }

    struct UserConfigurationMap {
        /**
         * @dev 用户抵押品和借贷的位图。按位对划分，每对位代表一个资产。
         * 第一位表示该资产是否作为用户抵押品，第二位表示是否被用户借贷
         */
        uint256 data;
    }

    struct EModeCategory {
        // 每个eMode类别有自定义LTV和清算阈值
        uint16 ltv;
        uint16 liquidationThreshold;
        uint16 liquidationBonus;
        // 每个eMode类别可能有自定义预言机覆盖资产价格
        address priceSource;
        string label;
    }

    enum InterestRateMode {
        NONE,
        STABLE,
        VARIABLE
    }

    struct ReserveCache {
        uint256 currScaledVariableDebt;
        uint256 nextScaledVariableDebt;
        uint256 currPrincipalStableDebt;
        uint256 currAvgStableBorrowRate;
        uint256 currTotalStableDebt;
        uint256 nextAvgStableBorrowRate;
        uint256 nextTotalStableDebt;
        uint256 currLiquidityIndex;
        uint256 nextLiquidityIndex;
        uint256 currVariableBorrowIndex;
        uint256 nextVariableBorrowIndex;
        uint256 currLiquidityRate;
        uint256 currVariableBorrowRate;
        uint256 reserveFactor;
        ReserveConfigurationMap reserveConfiguration;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        uint40 reserveLastUpdateTimestamp;
        uint40 stableDebtLastUpdateTimestamp;
    }

    struct ExecuteLiquidationCallParams {
        uint256 reservesCount;
        uint256 debtToCover;
        address collateralAsset;
        address debtAsset;
        address user;
        bool receiveAToken;
        address priceOracle;
        uint8 userEModeCategory;
        address priceOracleSentinel;
    }

    struct ExecuteSupplyParams {
        address asset;
        uint256 amount;
        address onBehalfOf;
        uint16 referralCode;
    }

    struct ExecuteBorrowParams {
        address asset;
        address user;
        address onBehalfOf;
        uint256 amount;
        InterestRateMode interestRateMode;
        uint16 referralCode;
        bool releaseUnderlying;
        uint256 maxStableRateBorrowSizePercent;
        uint256 reservesCount;
        address oracle;
        uint8 userEModeCategory;
        address priceOracleSentinel;
    }

    struct ExecuteRepayParams {
        address asset;
        uint256 amount;
        InterestRateMode interestRateMode;
        address onBehalfOf;
        bool useATokens;
    }

    struct ExecuteWithdrawParams {
        address asset;
        uint256 amount;
        address to;
        uint256 reservesCount;
        address oracle;
        uint8 userEModeCategory;
    }

    struct ExecuteSetUserEModeParams {
        uint256 reservesCount;
        address oracle;
        uint8 categoryId;
    }

    struct FinalizeTransferParams {
        address asset;
        address from;
        address to;
        uint256 amount;
        uint256 balanceFromBefore;
        uint256 balanceToBefore;
        uint256 reservesCount;
        address oracle;
        uint8 fromEModeCategory;
    }

    struct FlashloanParams {
        address receiverAddress;
        address[] assets;
        uint256[] amounts;
        uint256[] interestRateModes;
        address onBehalfOf;
        bytes params;
        uint16 referralCode;
        uint256 flashLoanPremiumToProtocol;
        uint256 flashLoanPremiumTotal;
        uint256 maxStableRateBorrowSizePercent;
        uint256 reservesCount;
        address addressesProvider;
        uint8 userEModeCategory;
        bool isAuthorizedFlashBorrower;
    }

    struct FlashloanSimpleParams {
        address receiverAddress;
        address asset;
        uint256 amount;
        bytes params;
        uint16 referralCode;
        uint256 flashLoanPremiumToProtocol;
        uint256 flashLoanPremiumTotal;
    }

    struct FlashLoanRepaymentParams {
        uint256 amount;
        uint256 totalPremium;
        uint256 flashLoanPremiumToProtocol;
        address asset;
        address receiverAddress;
        uint16 referralCode;
    }

    struct CalculateUserAccountDataParams {
        UserConfigurationMap userConfig;
        uint256 reservesCount;
        address user;
        address oracle;
        uint8 userEModeCategory;
    }

    struct ValidateBorrowParams {
        ReserveCache reserveCache;
        UserConfigurationMap userConfig;
        address asset;
        address userAddress;
        uint256 amount;
        InterestRateMode interestRateMode;
        uint256 maxStableLoanPercent;
        uint256 reservesCount;
        address oracle;
        uint8 userEModeCategory;
        address priceOracleSentinel;
        bool isolationModeActive;
        address isolationModeCollateralAddress;
        uint256 isolationModeDebtCeiling;
    }

    struct ValidateLiquidationCallParams {
        ReserveCache debtReserveCache;
        uint256 totalDebt;
        uint256 healthFactor;
        address priceOracleSentinel;
    }

    struct CalculateInterestRatesParams {
        uint256 unbacked;
        uint256 liquidityAdded;
        uint256 liquidityTaken;
        uint256 totalStableDebt;
        uint256 totalVariableDebt;
        uint256 averageStableBorrowRate;
        uint256 reserveFactor;
        address reserve;
        address aToken;
    }

    struct InitReserveParams {
        address asset;
        address aTokenAddress;
        address stableDebtAddress;
        address variableDebtAddress;
        address interestRateStrategyAddress;
        uint16 reservesCount;
        uint16 maxNumberReserves;
    }
}
