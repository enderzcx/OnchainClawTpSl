// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./IReactiveSubscriptionService.sol";

abstract contract AbstractReactive {
    uint256 internal constant REACTIVE_IGNORE = type(uint256).max;

    IReactiveSubscriptionService public immutable service;
    address public immutable reactiveNetwork;
    bool public immutable vm;

    event Callback(
        uint256 indexed chainId,
        address indexed target,
        uint64 gasLimit,
        bytes payload
    );

    constructor(
        address subscriptionService,
        address reactiveNetworkAddress,
        bool vmMode
    ) payable {
        service = IReactiveSubscriptionService(subscriptionService);
        reactiveNetwork = reactiveNetworkAddress;
        vm = vmMode;
    }

    modifier vmOnly() {
        require(vm || msg.sender == reactiveNetwork, "vm_only");
        _;
    }

    modifier rnOnly() {
        require(vm || msg.sender == reactiveNetwork, "rn_only");
        _;
    }
}
