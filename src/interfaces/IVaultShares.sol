// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultData} from "./IVaultData.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultShares is IERC4626, IVaultData {
    struct ConstructorData {
        IERC20 asset;
        IERC20 counterPartyToken;
        string vaultName;
        string vaultSymbol;
        address operatorGuardian;
        AllocationData allocationData;
        address aavePool;
        address uniswapRouter;
        uint256 guardianAndDaoCut;
        address governanceGuardian;
    }

    function updateHoldingAllocation(
        AllocationData memory tokenAllocationData
    ) external;

    function updateUniswapSlippage(uint256 tolerance) external;

    function updateCounterPartyToken(IERC20 newCounterPartyToken) external;

    function setNotActive() external;
}
