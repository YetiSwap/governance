// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract AirdropTreasury is Ownable {
    using SafeERC20 for IERC20;

    // Token to custody
    IERC20 public yts;

    constructor(address yts_) {
        yts = IERC20(yts_);
    }

    /**
     * Transfer YTS to the destination. Can only be called by the contract owner.
     */
    function transfer(address dest, uint amount) external onlyOwner {
        yts.safeTransfer(dest, amount);
    }

    /**
     * Return the YTS balance of this contract.
     */
    function balance() view external returns(uint) {
        return yts.balanceOf(address(this));
    }

}