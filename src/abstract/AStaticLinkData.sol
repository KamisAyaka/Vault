// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AStaticUSDCData} from "./AStaticUSDCData.sol";

abstract contract AStaticLinkData is AStaticUSDCData {
    // Intended to be LINK
    IERC20 internal immutable i_tokenTwo;

    constructor(
        address weth,
        address tokenOne,
        address tokenTwo
    ) AStaticUSDCData(weth, tokenOne) {
        i_tokenTwo = IERC20(tokenTwo);
    }

    /**
     * @return The LINK token
     */
    function getTokenTwo() external view returns (IERC20) {
        return i_tokenTwo;
    }
}
