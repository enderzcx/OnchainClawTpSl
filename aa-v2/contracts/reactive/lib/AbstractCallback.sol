// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

abstract contract AbstractCallback {
    error UnauthorizedCallbackCaller(address caller);

    address public immutable callbackSender;
    bool public immutable vm;

    constructor(address authorizedCallbackSender, bool vmMode) payable {
        callbackSender = authorizedCallbackSender;
        vm = vmMode;
    }

    function isCallbackCallerAuthorized(address caller) public view returns (bool) {
        return vm || caller == callbackSender;
    }

    function isDirectCallbackSender(address caller) public view returns (bool) {
        return caller == callbackSender;
    }

    modifier authorizedSenderOnly() {
        if (!isCallbackCallerAuthorized(msg.sender)) {
            revert UnauthorizedCallbackCaller(msg.sender);
        }
        _;
    }
}
