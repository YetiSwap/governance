// SPDX-License-Identifier: MIT

pragma solidity ^0.5.16;

import "@yetiswap/exchange-contracts/contracts/yetiswap-core/YetiSwapFactory.sol";
import "@yetiswap/exchange-contracts/contracts/yetiswap-core/YetiSwapPair.sol";


contract YetFactory is YetiSwapFactory {
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }
}