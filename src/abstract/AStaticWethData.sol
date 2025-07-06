// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract AStaticWethData {
    // The following four tokens are the approved tokens the protocol accepts
    // The default values are for Mainnet
    IERC20 internal immutable i_weth;

    constructor(address weth) {
        i_weth = IERC20(weth);
    }

    /**
     * @return The WETH token
     */
    function getWeth() external view returns (IERC20) {
        return i_weth;
    }
}
