// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {VaultShares} from "./VaultShares.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultShares, IVaultData} from "../interfaces/IVaultShares.sol";
import {AStaticTokenData, IERC20} from "../abstract/AStaticTokenData.sol";
import {VaultGuardianToken} from "../dao/VaultGuardianToken.sol";

/**
 * @title VaultGuardiansBase
 * @author Vault Guardian
 * @notice 基础合约，包含用户或守护者与协议交互的所有核心功能
 */
contract VaultGuardiansBase is AStaticTokenData, IVaultData {
    using SafeERC20 for IERC20;

    // 错误定义
    error VaultGuardiansBase__NotEnoughWeth(
        uint256 amount,
        uint256 amountNeeded
    );
    error VaultGuardiansBase__NotAGuardian(
        address guardianAddress,
        IERC20 token
    );
    error VaultGuardiansBase__CantQuitGuardianWithNonWethVaults(
        address guardianAddress
    );
    error VaultGuardiansBase__CantQuitWethWithThisFunction();
    error VaultGuardiansBase__TransferFailed();
    error VaultGuardiansBase__FeeTooSmall(uint256 fee, uint256 requiredFee);
    error VaultGuardiansBase__NotApprovedToken(address token);

    /*//////////////////////////////////////////////////////////////
                            状态变量
    //////////////////////////////////////////////////////////////*/
    address private immutable i_aavePool;
    address private immutable i_uniswapV2Router;
    VaultGuardianToken private immutable i_vgToken;

    uint256 private constant GUARDIAN_FEE = 0.1 ether;

    // DAO 可更新的值
    uint256 internal s_guardianStakePrice = 10 ether;
    uint256 internal s_guardianAndDaoCut = 1000;

    // 守护者地址 → 资产 → 金库份额合约映射
    mapping(address guardianAddress => mapping(IERC20 asset => IVaultShares vaultShares))
        private s_guardians;
    mapping(address token => bool approved) private s_isApprovedToken;

    /*//////////////////////////////////////////////////////////////
                                 事件
    //////////////////////////////////////////////////////////////*/
    event GuardianAdded(address guardianAddress, IERC20 token);
    event GaurdianRemoved(address guardianAddress, IERC20 token);
    event InvestedInGuardian(
        address guardianAddress,
        IERC20 token,
        uint256 amount
    );
    event DinvestedFromGuardian(
        address guardianAddress,
        IERC20 token,
        uint256 amount
    );
    event GuardianUpdatedHoldingAllocation(
        address guardianAddress,
        IERC20 token
    );

    /*//////////////////////////////////////////////////////////////
                               修饰符
    //////////////////////////////////////////////////////////////*/
    /// @dev 仅当调用者是特定代币的守护者时通过
    modifier onlyGuardian(IERC20 token) {
        if (address(s_guardians[msg.sender][token]) == address(0)) {
            revert VaultGuardiansBase__NotAGuardian(msg.sender, token);
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
    ) AStaticTokenData(weth, tokenOne, tokenTwo) {
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
    //能不能合并？？
    /**
     * @notice 成为守护者的入口函数
     * @notice 需支付等值ETH手续费和WETH质押金
     * @param wethAllocationData WETH金库的分配配置
     */
    function becomeGuardian(
        AllocationData memory wethAllocationData
    ) external returns (address) {
        VaultShares wethVault = new VaultShares(
            IVaultShares.ConstructorData({
                asset: i_weth,
                vaultName: WETH_VAULT_NAME,
                vaultSymbol: WETH_VAULT_SYMBOL,
                guardian: msg.sender,
                allocationData: wethAllocationData,
                aavePool: i_aavePool,
                uniswapRouter: i_uniswapV2Router,
                guardianAndDaoCut: s_guardianAndDaoCut,
                vaultGuardians: address(this),
                weth: address(i_weth),
                usdc: address(i_tokenOne)
            })
        );
        return _becomeTokenGuardian(i_weth, wethVault);
    }

    /**
     * @notice 成为非WETH代币的守护者
     * @notice 只有WETH守护者才能成为其他代币的守护者
     * @param allocationData 金库资产分配策略
     * @param token 需要守护的目标代币
     */
    function becomeTokenGuardian(
        AllocationData memory allocationData,
        IERC20 token
    ) external onlyGuardian(i_weth) returns (address) {
        // slither-disable-next-line uninitialized-local
        VaultShares tokenVault;
        if (address(token) == address(i_tokenOne)) {
            tokenVault = new VaultShares(
                IVaultShares.ConstructorData({
                    asset: token,
                    vaultName: TOKEN_ONE_VAULT_NAME,
                    vaultSymbol: TOKEN_ONE_VAULT_SYMBOL,
                    guardian: msg.sender,
                    allocationData: allocationData,
                    aavePool: i_aavePool,
                    uniswapRouter: i_uniswapV2Router,
                    guardianAndDaoCut: s_guardianAndDaoCut,
                    vaultGuardians: address(this),
                    weth: address(i_weth),
                    usdc: address(i_tokenOne)
                })
            );
        } else if (address(token) == address(i_tokenTwo)) {
            tokenVault = new VaultShares(
                IVaultShares.ConstructorData({
                    asset: token,
                    vaultName: TOKEN_TWO_VAULT_NAME, // 修复：使用正确的tokenTwo名称参数
                    vaultSymbol: TOKEN_TWO_VAULT_SYMBOL, // 修复：使用正确的tokenTwo符号参数
                    guardian: msg.sender,
                    allocationData: allocationData,
                    aavePool: i_aavePool,
                    uniswapRouter: i_uniswapV2Router,
                    guardianAndDaoCut: s_guardianAndDaoCut,
                    vaultGuardians: address(this),
                    weth: address(i_weth),
                    usdc: address(i_tokenOne)
                })
            );
        } else {
            revert VaultGuardiansBase__NotApprovedToken(address(token));
        }
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
            revert VaultGuardiansBase__CantQuitWethWithThisFunction();
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
            revert VaultGuardiansBase__CantQuitWethWithThisFunction();
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
        emit GuardianUpdatedHoldingAllocation(msg.sender, token);
        s_guardians[msg.sender][token].updateHoldingAllocation(
            tokenAllocationData
        );
    }

    /*//////////////////////////////////////////////////////////////
                   私有函数
    //////////////////////////////////////////////////////////////*/
    function _quitGuardian(IERC20 token) private returns (uint256) {
        IVaultShares tokenVault = IVaultShares(s_guardians[msg.sender][token]);
        s_guardians[msg.sender][token] = IVaultShares(address(0)); //？？？为什么是这个地址？
        emit GaurdianRemoved(msg.sender, token);
        tokenVault.setNotActive();
        uint256 maxRedeemable = tokenVault.maxRedeem(msg.sender);
        uint256 numberOfAssetsReturned = tokenVault.redeem(
            maxRedeemable,
            msg.sender,
            msg.sender
        );
        // 添加代币销毁逻辑
        i_vgToken.burn(msg.sender, s_guardianStakePrice);
        return numberOfAssetsReturned;
    }

    /**
     * @notice 检查守护者是否持有非WETH金库
     * @param guardian 需要验证的守护者地址
     */
    function _guardianHasNonWethVaults(
        address guardian
    ) private view returns (bool) {
        if (address(s_guardians[guardian][i_tokenOne]) != address(0)) {
            return true;
        } else {
            return address(s_guardians[guardian][i_tokenTwo]) != address(0);
        }
    }

    // slither-disable-start reentrancy-eth
    /**
     * @notice 成为代币守护者的内部实现
     * @notice 铸造治理代币作为质押奖励
     * @param token 被守护的代币
     * @param tokenVault 对应的金库合约
     */
    function _becomeTokenGuardian(
        IERC20 token,
        VaultShares tokenVault
    ) private returns (address) {
        s_guardians[msg.sender][token] = IVaultShares(address(tokenVault));
        emit GuardianAdded(msg.sender, token);
        i_vgToken.mint(msg.sender, s_guardianStakePrice);
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

    // slither-disable-end reentrancy-eth

    /*//////////////////////////////////////////////////////////////
                   视图和纯函数
    //////////////////////////////////////////////////////////////*/
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
}
