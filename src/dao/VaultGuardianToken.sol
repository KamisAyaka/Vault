// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit, Nonces} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VaultGuardianToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    constructor()
        ERC20("VaultGuardianToken", "VGT")
        ERC20Permit("VaultGuardianToken")
        Ownable(msg.sender)
    {}

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(
        address ownerOfNonce
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(ownerOfNonce);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice 销毁指定账户的代币
     * @param account 要销毁代币的账户地址
     * @param amount 要销毁的代币数量
     */
    function burn(address account, uint256 amount) public virtual {
        require(
            msg.sender == owner() || msg.sender == address(this),
            "Only owner or contract can burn"
        );
        _burn(account, amount);
    }
}
