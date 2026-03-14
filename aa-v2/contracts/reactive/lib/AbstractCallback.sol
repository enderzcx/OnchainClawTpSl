// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

abstract contract AbstractCallback {
    address public immutable callbackSender;
    bool public immutable vm;

    constructor(address authorizedCallbackSender, bool vmMode) payable {
        callbackSender = authorizedCallbackSender;
        vm = vmMode;
    }

    modifier authorizedSenderOnly() {
        require(vm || msg.sender == callbackSender, "unauthorized_callback_sender");
        _;
    }
}
