// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AStaticWethData} from "./AStaticWethData.sol";

abstract contract AStaticUSDCData is AStaticWethData {
    // Intended to be USDC
    IERC20 internal immutable i_tokenOne;

    constructor(address weth, address tokenOne) AStaticWethData(weth) {
        i_tokenOne = IERC20(tokenOne);
    }

    /**
     * @return The USDC token
     */
    function getTokenOne() external view returns (IERC20) {
        return i_tokenOne;
    }
}
