// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {VaultShares} from "./VaultShares.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVaultShares, IVaultData} from "../interfaces/IVaultShares.sol";
import {AStaticLinkData, IERC20} from "../abstract/AStaticLinkData.sol";
import {VaultGuardianToken} from "../dao/VaultGuardianToken.sol";

/**
 * @title VaultGuardiansBase
 * @author Vault Guardian
 * @notice 基础合约，包含用户或操作管理者与协议交互的所有核心功能
 */
contract VaultGuardiansBase is AStaticLinkData, IVaultData {
    using SafeERC20 for IERC20;

    // 错误定义
    error VaultGuardiansBase__NotEnoughWeth(
        uint256 amount,
        uint256 amountNeeded
    );
    error VaultGuardiansBase__NotAnOperatorGuardian(
        address guardianAddress,
        IERC20 token
    );
    error VaultGuardiansBase__CantQuitOperatorGuardianWithNonWethVaults(
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
            revert VaultGuardiansBase__NotAnOperatorGuardian(msg.sender, token);
        }
        _;
    }

    /**
     * @dev 仅允许有效金库调用
     */
    modifier onlyETHVaultShares() {
        require(s_validVaults[msg.sender], "Caller not a valid vault");
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
     * @notice 需支付等值ETH手续费和WETH质押金
     * @param wethAllocationData WETH金库的分配配置
     */
    function becomeGuardian(
        AllocationData memory wethAllocationData,
        IERC20 counterPartyToken
    ) external returns (address) {
        VaultShares wethVault = new VaultShares(
            IVaultShares.ConstructorData({
                asset: i_weth,
                counterPartyToken: counterPartyToken,
                weth: i_weth,
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
        s_validVaults[address(wethVault)] = true;
        return _becomeTokenGuardian(i_weth, wethVault);
    }

    /**
     * @notice 成为非WETH代币的操作管理者
     * @notice 只有WETH操作管理者才能成为其他代币的操作管理者
     * @param allocationData 金库资产分配策略
     * @param token 需要管理的目标代币
     */
    function becomeTokenGuardian(
        AllocationData memory allocationData,
        IERC20 token,
        IERC20 counterPartyToken
    ) external onlyGuardian(i_weth) returns (address) {
        // slither-disable-next-line uninitialized-local
        if (
            !s_isApprovedToken[address(token)] &&
            !s_isApprovedToken[address(counterPartyToken)] &&
            token != i_weth
        ) {
            revert VaultGuardiansBase__NotApprovedToken(address(token));
        }

        VaultShares tokenVault;

        tokenVault = new VaultShares(
            IVaultShares.ConstructorData({
                asset: token,
                counterPartyToken: counterPartyToken,
                weth: i_weth,
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

    function updateUniswapSlippage(
        IERC20 token,
        uint256 tolerance
    ) external onlyGuardian(token) {
        emit GuardianUpdatedUniswapSlippage(msg.sender, token, tolerance);
        s_guardians[msg.sender][token].updateUniswapSlippage(tolerance);
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
    function _quitGuardian(IERC20 token) private returns (uint256) {
        IVaultShares tokenVault = IVaultShares(s_guardians[msg.sender][token]);
        s_guardians[msg.sender][token] = IVaultShares(address(0)); //将管理员的权限置为0,管理员无法再管理该金库
        address vaultAddress = address(tokenVault);
        // 移除金库有效性标记
        if (s_validVaults[vaultAddress]) {
            delete s_validVaults[vaultAddress];
        }
        if (s_guardianVaultCount[msg.sender] > 0) {
            s_guardianVaultCount[msg.sender]--;
        }
        emit GaurdianRemoved(msg.sender, token);
        tokenVault.setNotActive();
        uint256 maxRedeemable = tokenVault.maxRedeem(msg.sender);
        uint256 numberOfAssetsReturned = tokenVault.redeem(
            maxRedeemable,
            msg.sender,
            msg.sender
        );

        // 仅销毁WETH相关的治理代币
        if (address(token) == address(i_weth)) {
            // 销毁数量等于质押金额
            i_vgToken.burn(msg.sender, s_guardianStakePrice);
        }

        return numberOfAssetsReturned;
    }

    /**
     * @notice 检查守护者是否持有非WETH金库
     * @param guardian 需要验证的守护者地址
     */
    function _guardianHasNonWethVaults(
        address guardian
    ) private view returns (bool) {
        return s_guardianVaultCount[guardian] > 1;
    }

    // slither-disable-start reentrancy-eth
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-events
    /**
     * @notice 成为代币操作管理者的内部实现
     * @notice 铸造治理代币作为质押奖励
     * @param token 被管理的代币
     * @param tokenVault 对应的金库合约
     * @dev 铸造逻辑说明:
     * - 仅当token为WETH时铸造VGT
     * - 铸造数量等于质押的token数量
     * - 确保DAO可通过s_guardianStakePrice参数调整最低质押要求
     */
    function _becomeTokenGuardian(
        IERC20 token,
        VaultShares tokenVault
    ) private returns (address) {
        s_guardians[msg.sender][token] = IVaultShares(address(tokenVault));
        s_guardianVaultCount[msg.sender]++;
        emit GuardianAdded(msg.sender, token);

        // 仅对WETH质押铸造VGT
        if (address(token) == address(i_weth)) {
            // 铸造数量等于质押金额
            i_vgToken.mint(msg.sender, s_guardianStakePrice);
        }

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

    function getVgTokenAddress() external view returns (address) {
        return address(i_vgToken);
    }
}
