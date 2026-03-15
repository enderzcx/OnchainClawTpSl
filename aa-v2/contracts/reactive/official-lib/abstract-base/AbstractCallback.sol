// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "../interfaces/IPayable.sol";
import "./AbstractPayer.sol";

abstract contract AbstractCallback is AbstractPayer {
    address internal rvm_id;

    constructor(address callbackSender) {
        rvm_id = msg.sender;
        vendor = IPayable(payable(callbackSender));
        addAuthorizedSender(callbackSender);
    }

    modifier rvmIdOnly(address suppliedRvmId) {
        require(rvm_id == suppliedRvmId, "Authorized RVM ID only");
        _;
    }
}
