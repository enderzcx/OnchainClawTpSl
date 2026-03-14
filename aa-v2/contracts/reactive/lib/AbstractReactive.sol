// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./IReactiveSubscriptionService.sol";

abstract contract AbstractReactive {
    uint256 internal constant REACTIVE_IGNORE = type(uint256).max;

    error UnauthorizedReactiveCaller(address caller);

    IReactiveSubscriptionService public immutable service;
    address public immutable reactiveNetwork;
    bool public immutable vm;

    event Callback(uint256 indexed chainId, address indexed target, uint64 gasLimit, bytes payload);

    constructor(address subscriptionService, address reactiveNetworkAddress, bool vmMode) payable {
        service = IReactiveSubscriptionService(subscriptionService);
        reactiveNetwork = reactiveNetworkAddress;
        vm = vmMode;
    }

    function isReactiveCallerAuthorized(address caller) public view returns (bool) {
        return vm || caller == reactiveNetwork;
    }

    function isReactiveNetworkCaller(address caller) public view returns (bool) {
        return caller == reactiveNetwork;
    }

    modifier vmOnly() {
        if (!isReactiveCallerAuthorized(msg.sender)) {
            revert UnauthorizedReactiveCaller(msg.sender);
        }
        _;
    }

    modifier rnOnly() {
        if (!isReactiveCallerAuthorized(msg.sender)) {
            revert UnauthorizedReactiveCaller(msg.sender);
        }
        _;
    }
}
