// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {VaultShares} from "./VaultShares.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVaultShares, IVaultData} from "../interfaces/IVaultShares.sol";
import {AStaticLinkData, IERC20} from "../abstract/AStaticLinkData.sol";
import {VaultGuardianToken} from "../dao/VaultGuardianToken.sol";

/**
 * @title VaultGuardiansBase
 * @notice 基础合约，包含用户或操作管理者与协议交互的所有核心功能
 */
contract VaultGuardiansBase is AStaticLinkData, IVaultData {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            错误定义
    //////////////////////////////////////////////////////////////*/
    error VaultGuardiansBase__InvalidOperatorGuardian(
        address guardianAddress,
        IERC20 token
    );
    error VaultGuardiansBase__InvalidVault(address vaultAddress);
    error VaultGuardiansBase__NonWethVaultsExist(address guardianAddress);
    error VaultGuardiansBase__WethVaultOnlyFunction();
    error VaultGuardiansBase__TransferFailed();
    error VaultGuardiansBase__UnsupportedToken(address token);
    error VaultGuardiansBase__SlippageToleranceTooHigh(
        uint256 tolerance,
        uint256 maxTolerance
    );

    /*//////////////////////////////////////////////////////////////
                            状态变量
    //////////////////////////////////////////////////////////////*/
    address private immutable i_aavePool;
    address private immutable i_uniswapV2Router;
    VaultGuardianToken private immutable i_vgToken;

    // DAO 可更新的值
    uint256 internal s_guardianStakePrice = 10 ether;
    uint256 internal s_guardianAndDaoCut = 1000;

    // 守护者地址 → 资产 → 金库合约映射
    mapping(address guardianAddress => mapping(IERC20 asset => IVaultShares vaultShares))
        private s_guardians;
    mapping(address token => bool approved) private s_isApprovedToken;
    mapping(address vault => bool) private s_validVaults;
    mapping(address guardian => uint256) public s_guardianVaultCount;

    /*//////////////////////////////////////////////////////////////
                                 事件
    //////////////////////////////////////////////////////////////*/
    event GuardianAdded(address guardianAddress, IERC20 token);
    event GaurdianRemoved(address guardianAddress, IERC20 token);
    event GuardianUpdatedHoldingAllocation(
        address guardianAddress,
        IERC20 token
    );
    event GuardianUpdatedUniswapSlippage(
        address guardianAddress,
        IERC20 token,
        uint256 tolerance
    );

    /*//////////////////////////////////////////////////////////////
                               修饰符
    //////////////////////////////////////////////////////////////*/
    /// @dev 仅当调用者是特定代币的操作管理者时通过
    modifier onlyGuardian(IERC20 token) {
        if (address(s_guardians[msg.sender][token]) == address(0)) {
            revert VaultGuardiansBase__InvalidOperatorGuardian(
                msg.sender,
                token
            );
        }
        _;
    }

    /**
     * @dev 仅允许有效金库调用
     */
    modifier onlyETHVaultShares() {
        if (!s_validVaults[msg.sender]) {
            revert VaultGuardiansBase__InvalidVault(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               构造函数
    //////////////////////////////////////////////////////////////*/
    constructor(
        address aavePool,
        address uniswapV2Router,
        address weth,
        address tokenOne, // USDC
        address tokenTwo, // LINK
        address vgToken
    ) AStaticLinkData(weth, tokenOne, tokenTwo) {
        s_isApprovedToken[weth] = true;
        s_isApprovedToken[tokenOne] = true;
        s_isApprovedToken[tokenTwo] = true;

        i_aavePool = aavePool;
        i_uniswapV2Router = uniswapV2Router;
        i_vgToken = VaultGuardianToken(vgToken);
    }

    /*//////////////////////////////////////////////////////////////
                               外部函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice 成为守护者的入口函数
     * @notice 需支付一定金额的WETH质押金，这笔质押金会被投入到创建的金库中作为投资资金
     * @param wethAllocationData WETH金库的分配配置
     * @param counterPartyToken Uniswap 交易对代币，默认weth与该代币进行添加流动性质押
     */
    function becomeGuardian(
        AllocationData memory wethAllocationData,
        IERC20 counterPartyToken
    ) external returns (address) {
        // 防止重复创建WETH金库
        if (address(s_guardians[msg.sender][i_weth]) != address(0)) {
            revert VaultGuardiansBase__InvalidOperatorGuardian(
                msg.sender,
                i_weth
            );
        }
        VaultShares wethVault = new VaultShares(
            IVaultShares.ConstructorData({
                asset: i_weth,
                counterPartyToken: counterPartyToken,
                vaultName: string.concat(
                    "Vault Guardian ",
                    IERC20Metadata(address(i_weth)).name()
                ),
                vaultSymbol: string.concat(
                    "vg",
                    IERC20Metadata(address(i_weth)).symbol()
                ),
                operatorGuardian: msg.sender,
                allocationData: wethAllocationData,
                aavePool: i_aavePool,
                uniswapRouter: i_uniswapV2Router,
                guardianAndDaoCut: s_guardianAndDaoCut,
                governanceGuardian: address(this)
            })
        );
        // 只有WETH金库有效
        s_validVaults[address(wethVault)] = true;
        return _becomeTokenGuardian(i_weth, wethVault);
    }

    /**
     * @notice 成为非WETH代币的操作管理者
     * @notice 只有WETH操作管理者才能成为其他代币的操作管理者
     * @param allocationData 金库资产分配策略
     * @param token 需要管理的目标代币
     * @param counterPartyToken Uniswap 交易对代币，token与该代币进行添加流动性质押
     */
    function becomeTokenGuardian(
        AllocationData memory allocationData,
        IERC20 token,
        IERC20 counterPartyToken
    ) external onlyGuardian(i_weth) returns (address) {
        // 防止重复创建相同资产的金库
        if (address(s_guardians[msg.sender][token]) != address(0)) {
            revert VaultGuardiansBase__InvalidOperatorGuardian(
                msg.sender,
                token
            );
        }
        if (
            !s_isApprovedToken[address(token)] ||
            !s_isApprovedToken[address(counterPartyToken)] ||
            token == i_weth
        ) {
            revert VaultGuardiansBase__UnsupportedToken(address(token));
        }

        VaultShares tokenVault;

        tokenVault = new VaultShares(
            IVaultShares.ConstructorData({
                asset: token,
                counterPartyToken: counterPartyToken,
                vaultName: string.concat(
                    "Vault Guardian ",
                    IERC20Metadata(address(token)).name()
                ),
                vaultSymbol: string.concat(
                    "vg",
                    IERC20Metadata(address(token)).symbol()
                ),
                operatorGuardian: msg.sender,
                allocationData: allocationData,
                aavePool: i_aavePool,
                uniswapRouter: i_uniswapV2Router,
                guardianAndDaoCut: s_guardianAndDaoCut,
                governanceGuardian: address(this)
            })
        );

        return _becomeTokenGuardian(token, tokenVault);
    }

    /**
     * @notice 主动退出WETH守护者角色
     * @notice 只有仅持有WETH金库的守护者才能调用
     * @notice 需要授权本合约操作您的份额代币
     * @notice 退出后金库进入非活跃状态，禁止新投资
     */
    function quitGuardian() external onlyGuardian(i_weth) returns (uint256) {
        if (_guardianHasNonWethVaults(msg.sender)) {
            revert VaultGuardiansBase__NonWethVaultsExist(msg.sender);
        }
        return _quitGuardian(i_weth);
    }

    /**
     * @notice 退出非WETH代币守护者角色
     * @param token 需要退出的代币
     */
    function quitGuardian(
        IERC20 token
    ) external onlyGuardian(token) returns (uint256) {
        if (token == i_weth) {
            revert VaultGuardiansBase__WethVaultOnlyFunction();
        }
        return _quitGuardian(token);
    }

    /**
     * @notice 更新金库资产分配策略
     * @param token 需要更新的代币
     * @param tokenAllocationData 新的分配配置
     */
    function updateHoldingAllocation(
        IERC20 token,
        AllocationData memory tokenAllocationData
    ) external onlyGuardian(token) {
        if (_guardianHasNonWethVaults(msg.sender)) {
            revert VaultGuardiansBase__NonWethVaultsExist(msg.sender);
        }
        emit GuardianUpdatedHoldingAllocation(msg.sender, token);
        s_guardians[msg.sender][token].updateHoldingAllocation(
            tokenAllocationData
        );
    }

    /**
     * @notice 更新指定代币的Uniswap滑点容忍度
     * @param token 需要更新滑点设置的金库资产
     * @param tolerance 新的滑点容忍值（以万分之一为单位）
     * @dev 示例：200 = 2%滑点容忍度
     * @dev 仅当前token的守护者可调用
     * @dev 触发GuardianUpdatedUniswapSlippage事件记录变更
     */
    function updateUniswapSlippage(
        IERC20 token,
        uint256 tolerance
    ) external onlyGuardian(token) {
        emit GuardianUpdatedUniswapSlippage(msg.sender, token, tolerance);
        s_guardians[msg.sender][token].updateUniswapSlippage(tolerance);
    }

    /**
     * @notice 更新金库的交易对
     * @notice 新交易对必须是VaultGuardiansBase批准的代币
     * @param token 要更新的管理代币
     * @param newCounterPartyToken 新的交易对代币
     */
    function updateVaultCounterPartyToken(
        IERC20 token,
        IERC20 newCounterPartyToken
    ) external onlyGuardian(token) {
        // 验证新交易对代币是否已批准
        if (
            !s_isApprovedToken[address(newCounterPartyToken)] ||
            newCounterPartyToken == token
        ) {
            revert VaultGuardiansBase__UnsupportedToken(
                address(newCounterPartyToken)
            );
        }

        // 调用VaultShares的updateCounterPartyToken
        s_guardians[msg.sender][token].updateCounterPartyToken(
            newCounterPartyToken
        );
    }

    function mintVGT(address to, uint256 amount) external onlyETHVaultShares {
        i_vgToken.mint(to, amount);
    }

    function burnVGT(address to, uint256 amount) external onlyETHVaultShares {
        i_vgToken.burn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                   私有函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice 成为代币操作管理者的内部实现
     * @notice 在调用deposit方法的时候金库会判断管理的资产是否为weth代币
     * @notice 如果是的话就会给存入WETH的账户铸造治理代币作为质押奖励
     * @param token 被管理的代币
     * @param tokenVault 对应的金库合约
     * @dev 铸造逻辑说明:
     * - 仅当token为WETH时铸造VGT
     * - 铸造数量等于质押的token数量，但有少部分会分给金库管理者和DAO作为奖励
     * - 确保DAO可通过s_guardianStakePrice参数调整最低质押要求
     */
    function _becomeTokenGuardian(
        IERC20 token,
        VaultShares tokenVault
    ) private returns (address) {
        s_guardians[msg.sender][token] = IVaultShares(address(tokenVault));
        s_guardianVaultCount[msg.sender]++;
        emit GuardianAdded(msg.sender, token);

        // 执行质押转账
        token.safeTransferFrom(msg.sender, address(this), s_guardianStakePrice);
        bool succ = token.approve(address(tokenVault), s_guardianStakePrice);
        if (!succ) {
            revert VaultGuardiansBase__TransferFailed();
        }

        uint256 shares = tokenVault.deposit(s_guardianStakePrice, msg.sender);
        if (shares == 0) {
            revert VaultGuardiansBase__TransferFailed();
        }
        return address(tokenVault);
    }

    /**
     * @notice 守护者退出金库管理的内部实现
     * @param token 需要退出管理的金库资产类型
     * @return numberOfAssetsReturned 返回赎回的资产数量
     * @dev 执行流程：
     * 1. 获取守护者的金库实例
     * 2. 清除守护者对该金库的管理权限
     * 3. 触发GaurdianRemoved事件
     * 4. 将金库设为非活跃状态
     * 5. 赎回守护者持有的全部份额
     * 6. 清理金库有效性标记和减少守护者金库计数
     * @dev 金库停用后用户仍可提取资产，但禁止新投资
     */
    function _quitGuardian(IERC20 token) private returns (uint256) {
        IVaultShares tokenVault = IVaultShares(s_guardians[msg.sender][token]);
        s_guardians[msg.sender][token] = IVaultShares(address(0)); //将管理员的权限置为0,管理员无法再管理该金库
        address vaultAddress = address(tokenVault);
        emit GaurdianRemoved(msg.sender, token);
        tokenVault.setNotActive();
        uint256 maxRedeemable = tokenVault.maxRedeem(msg.sender);
        uint256 numberOfAssetsReturned = tokenVault.redeem(
            maxRedeemable,
            msg.sender,
            msg.sender
        );

        // 移除金库有效性标记
        if (s_validVaults[vaultAddress]) {
            delete s_validVaults[vaultAddress];
        }
        if (s_guardianVaultCount[msg.sender] > 0) {
            s_guardianVaultCount[msg.sender]--;
        }

        return numberOfAssetsReturned;
    }

    /// @notice 添加批准代币的内部实现
    /// @param token 要新增的代币地址
    function _addApprovedToken(IERC20 token) internal {
        if (address(token) == address(0)) {
            revert VaultGuardiansBase__UnsupportedToken(address(0));
        }
        if (s_isApprovedToken[address(token)]) {
            revert VaultGuardiansBase__UnsupportedToken(address(token));
        }
        s_isApprovedToken[address(token)] = true;
    }

    /*//////////////////////////////////////////////////////////////
                   视图和纯函数
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice 检查守护者是否持有非WETH金库
     * @param guardian 需要验证的守护者地址
     */
    function _guardianHasNonWethVaults(
        address guardian
    ) public view returns (bool) {
        return s_guardianVaultCount[guardian] > 1;
    }

    /**
     * @notice 获取守护者对应的金库合约
     * @param guardian 守护者地址
     * @param token 金库底层资产
     */
    function getVaultFromGuardianAndToken(
        address guardian,
        IERC20 token
    ) external view returns (IVaultShares) {
        return s_guardians[guardian][token];
    }

    /**
     * @notice 检查代币是否被协议支持
     * @param token 需要验证的代币地址
     */
    function isApprovedToken(address token) external view returns (bool) {
        return s_isApprovedToken[token];
    }

    /**
     * @return Aave池地址
     */
    function getAavePool() external view returns (address) {
        return i_aavePool;
    }

    /**
     * @return UniswapV2路由器地址
     */
    function getUniswapV2Router() external view returns (address) {
        return i_uniswapV2Router;
    }

    /**
     * @return 获取守护者质押价格
     */
    function getGuardianStakePrice() external view returns (uint256) {
        return s_guardianStakePrice;
    }

    /**
     * @return 获取DAO和守护者管理费比例
     */
    function getGuardianAndDaoCut() external view returns (uint256) {
        return s_guardianAndDaoCut;
    }

    function getVgTokenAddress() external view returns (address) {
        return address(i_vgToken);
    }

    function getWethAddress() external view returns (IERC20) {
        return i_weth;
    }
}
