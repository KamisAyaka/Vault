// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Base_Test} from "../../Base.t.sol";
import {VaultShares} from "../../../src/protocol/VaultShares.sol";
import {IERC20} from "../../../src/protocol/VaultGuardians.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {VaultGuardiansBase} from "../../../src/protocol/VaultGuardiansBase.sol";

import {VaultGuardians} from "../../../src/protocol/VaultGuardians.sol";
import {VaultGuardianGovernor} from "../../../src/dao/VaultGuardianGovernor.sol";
import {VaultGuardianToken} from "../../../src/dao/VaultGuardianToken.sol";
import {console} from "forge-std/console.sol";

contract VaultGuardiansBaseTest is Base_Test {
    address public guardian = makeAddr("guardian");
    address public user = makeAddr("user");

    VaultShares public wethVaultShares;
    VaultShares public usdcVaultShares;
    VaultShares public linkVaultShares;

    uint256 guardianAndDaoCut;
    uint256 stakePrice;
    uint256 mintAmount = 100 ether;

    // 500 hold, 250 uniswap, 250 aave
    AllocationData allocationData = AllocationData(500, 250, 250);
    AllocationData newAllocationData = AllocationData(0, 500, 500);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
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

    function setUp() public override {
        Base_Test.setUp();
        guardianAndDaoCut = vaultGuardians.getGuardianAndDaoCut();
        stakePrice = vaultGuardians.getGuardianStakePrice();
    }

    function testDefaultsToNonFork() public view {
        assert(block.chainid != 1);
    }

    function testSetupAddsTokensAndPools() public view {
        assertEq(vaultGuardians.isApprovedToken(usdcAddress), true);
        assertEq(vaultGuardians.isApprovedToken(linkAddress), true);
        assertEq(vaultGuardians.isApprovedToken(wethAddress), true);

        assertEq(address(vaultGuardians.getWeth()), wethAddress);
        assertEq(address(vaultGuardians.getTokenOne()), usdcAddress);
        assertEq(address(vaultGuardians.getTokenTwo()), linkAddress);

        assertEq(vaultGuardians.getAavePool(), aavePool);
        assertEq(vaultGuardians.getUniswapV2Router(), uniswapRouter);
    }

    function testBecomeGuardian() public {
        weth.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), mintAmount);
        address wethVault = vaultGuardians.becomeGuardian(allocationData, usdc);
        vm.stopPrank();

        assertEq(
            address(
                vaultGuardians.getVaultFromGuardianAndToken(guardian, weth)
            ),
            wethVault
        );
    }

    function testBecomeGuardianMovesStakePrice() public {
        weth.mint(mintAmount, guardian);

        vm.startPrank(guardian);
        uint256 wethBalanceBefore = weth.balanceOf(address(guardian));
        weth.approve(address(vaultGuardians), mintAmount);
        vaultGuardians.becomeGuardian(allocationData, usdc);
        vm.stopPrank();

        uint256 wethBalanceAfter = weth.balanceOf(address(guardian));
        assertEq(
            wethBalanceBefore - wethBalanceAfter,
            vaultGuardians.getGuardianStakePrice()
        );
    }

    function testBecomeGuardianEmitsEvent() public {
        weth.mint(mintAmount, guardian);

        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), mintAmount);
        vm.expectEmit(false, false, false, true, address(vaultGuardians));
        emit GuardianAdded(guardian, weth);
        vaultGuardians.becomeGuardian(allocationData, usdc);
        vm.stopPrank();
    }

    function testCantBecomeTokenGuardianWithoutBeingAWethGuardian() public {
        usdc.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        usdc.approve(address(vaultGuardians), mintAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultGuardiansBase
                    .VaultGuardiansBase__InvalidOperatorGuardian
                    .selector,
                guardian,
                address(weth)
            )
        );
        vaultGuardians.becomeTokenGuardian(allocationData, usdc, weth);
        vm.stopPrank();
    }

    modifier hasGuardian() {
        weth.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), mintAmount);
        address wethVault = vaultGuardians.becomeGuardian(allocationData, usdc);
        wethVaultShares = VaultShares(wethVault);
        vm.stopPrank();
        _;
    }

    function testUpdatedHoldingAllocationEmitsEvent() public hasGuardian {
        vm.startPrank(guardian);
        vm.expectEmit(false, false, false, true, address(vaultGuardians));
        emit GuardianUpdatedHoldingAllocation(guardian, weth);
        vaultGuardians.updateHoldingAllocation(weth, newAllocationData);
        vm.stopPrank();
    }

    function testOnlyGuardianCanUpdateHoldingAllocation() public hasGuardian {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultGuardiansBase
                    .VaultGuardiansBase__InvalidOperatorGuardian
                    .selector,
                user,
                weth
            )
        );
        vaultGuardians.updateHoldingAllocation(weth, newAllocationData);
        vm.stopPrank();
    }

    function testQuitGuardian() public hasGuardian {
        vm.startPrank(guardian);
        wethVaultShares.approve(address(vaultGuardians), mintAmount);
        vaultGuardians.quitGuardian();
        vm.stopPrank();

        assertEq(
            address(
                vaultGuardians.getVaultFromGuardianAndToken(guardian, weth)
            ),
            address(0)
        );
    }

    function testQuitGuardianEmitsEvent() public hasGuardian {
        vm.startPrank(guardian);
        wethVaultShares.approve(address(vaultGuardians), mintAmount);
        vm.expectEmit(false, false, false, true, address(vaultGuardians));
        emit GaurdianRemoved(guardian, weth);
        vaultGuardians.quitGuardian();
        vm.stopPrank();
    }

    function testBecomeTokenGuardian() public hasGuardian {
        usdc.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        usdc.approve(address(vaultGuardians), mintAmount);
        address tokenVault = vaultGuardians.becomeTokenGuardian(
            allocationData,
            usdc,
            weth
        );
        usdcVaultShares = VaultShares(tokenVault);
        vm.stopPrank();

        assertEq(
            address(
                vaultGuardians.getVaultFromGuardianAndToken(guardian, usdc)
            ),
            tokenVault
        );
    }

    function testBecomeTokenGuardianOnlyApprovedTokens() public hasGuardian {
        ERC20Mock mockToken = new ERC20Mock();
        mockToken.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        mockToken.approve(address(vaultGuardians), mintAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                VaultGuardiansBase
                    .VaultGuardiansBase__UnsupportedToken
                    .selector,
                address(mockToken)
            )
        );
        vaultGuardians.becomeTokenGuardian(allocationData, mockToken, weth);
        vm.stopPrank();
    }

    function testBecomeTokenGuardianTokenOneName() public hasGuardian {
        usdc.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        usdc.approve(address(vaultGuardians), mintAmount);
        address tokenVault = vaultGuardians.becomeTokenGuardian(
            allocationData,
            usdc,
            weth
        );
        usdcVaultShares = VaultShares(tokenVault);
        vm.stopPrank();

        assertEq(
            usdcVaultShares.name(),
            string.concat("Vault Guardian ", usdc.name())
        );
        assertEq(usdcVaultShares.symbol(), string.concat("vg", usdc.symbol()));
    }

    function testBecomeTokenGuardianTokenTwoNameEmitsEvent()
        public
        hasGuardian
    {
        link.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        link.approve(address(vaultGuardians), mintAmount);

        vm.expectEmit(false, false, false, true, address(vaultGuardians));
        emit GuardianAdded(guardian, link);
        vaultGuardians.becomeTokenGuardian(allocationData, link, weth);
        vm.stopPrank();
    }

    modifier hasTokenGuardian() {
        usdc.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        usdc.approve(address(vaultGuardians), mintAmount);
        address tokenVault = vaultGuardians.becomeTokenGuardian(
            allocationData,
            usdc,
            weth
        );
        usdcVaultShares = VaultShares(tokenVault);
        vm.stopPrank();
        _;
    }

    function testCantQuitWethGuardianWithTokens()
        public
        hasGuardian
        hasTokenGuardian
    {
        vm.startPrank(guardian);
        wethVaultShares.approve(address(vaultGuardians), mintAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultGuardiansBase
                    .VaultGuardiansBase__NonWethVaultsExist
                    .selector,
                guardian
            )
        );
        vaultGuardians.quitGuardian(); // 修改为无参数调用
        vm.stopPrank();
    }

    function testQuitNonWethGuardian() public hasGuardian hasTokenGuardian {
        vm.startPrank(guardian);
        usdcVaultShares.approve(address(vaultGuardians), mintAmount);
        address tokenVaultBefore = address(
            vaultGuardians.getVaultFromGuardianAndToken(guardian, usdc)
        );
        assertNotEq(tokenVaultBefore, address(0));

        vaultGuardians.quitGuardian(usdc);

        assertEq(
            address(
                vaultGuardians.getVaultFromGuardianAndToken(guardian, usdc)
            ),
            address(0)
        );
        vm.stopPrank();
    }

    function testCannotRecreateGuardian() public {
        weth.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), mintAmount);
        vaultGuardians.becomeGuardian(allocationData, usdc);

        vm.expectRevert(
            abi.encodeWithSelector(
                VaultGuardiansBase
                    .VaultGuardiansBase__InvalidOperatorGuardian
                    .selector,
                guardian,
                address(weth)
            )
        );
        vaultGuardians.becomeGuardian(allocationData, usdc);
        vm.stopPrank();
    }

    function testNonWethVaultNoVGT() public hasGuardian hasTokenGuardian {
        // 用户存款USDC
        uint256 usdcAmount = 1000 * 10 ** 6; // USDC has 6 decimals
        usdc.mint(usdcAmount, user);
        vm.startPrank(user);
        usdc.approve(address(usdcVaultShares), usdcAmount);
        usdcVaultShares.deposit(usdcAmount, user);

        // 验证VGT余额应为0
        assertEq(IERC20(vaultGuardians.getVgTokenAddress()).balanceOf(user), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetVault() public hasGuardian hasTokenGuardian {
        assertEq(
            address(
                vaultGuardians.getVaultFromGuardianAndToken(guardian, weth)
            ),
            address(wethVaultShares)
        );
        assertEq(
            address(
                vaultGuardians.getVaultFromGuardianAndToken(guardian, usdc)
            ),
            address(usdcVaultShares)
        );
    }

    function testIsApprovedToken() public view {
        assertEq(vaultGuardians.isApprovedToken(usdcAddress), true);
        assertEq(vaultGuardians.isApprovedToken(linkAddress), true);
        assertEq(vaultGuardians.isApprovedToken(wethAddress), true);
    }

    function testIsNotApprovedToken() public {
        ERC20Mock mock = new ERC20Mock();
        assertEq(vaultGuardians.isApprovedToken(address(mock)), false);
    }

    function testGetAavePool() public view {
        assertEq(vaultGuardians.getAavePool(), aavePool);
    }

    function testGetUniswapV2Router() public view {
        assertEq(vaultGuardians.getUniswapV2Router(), uniswapRouter);
    }

    function testGetGuardianStakePrice() public view {
        assertEq(vaultGuardians.getGuardianStakePrice(), stakePrice);
    }

    function testGetGuardianDaoAndCut() public view {
        assertEq(vaultGuardians.getGuardianAndDaoCut(), guardianAndDaoCut);
    }

    function testSetSlippageToleranceWithTooHighValue() public hasGuardian {
        uint256 tolerance = 1001; // 假设最大允许的滑点容忍度是1000
        vm.startPrank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultShares.VaultShares__SlippageToleranceTooHigh.selector,
                tolerance,
                1000 // 最大允许值
            )
        );
        vaultGuardians.updateUniswapSlippage(weth, tolerance);
        vm.stopPrank();
    }
}
