// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "../interfaces/IReactive.sol";
import "../interfaces/ISystemContract.sol";
import "./AbstractPayer.sol";

abstract contract AbstractReactive is IReactive, AbstractPayer {
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    ISystemContract internal constant SERVICE_ADDR =
        ISystemContract(payable(0x0000000000000000000000000000000000fffFfF));

    bool internal vm;
    ISystemContract internal service;

    constructor() {
        vendor = service = SERVICE_ADDR;
        addAuthorizedSender(address(SERVICE_ADDR));
        detectVm();
    }

    modifier rnOnly() {
        require(!vm, "Reactive Network only");
        _;
    }

    modifier vmOnly() {
        require(vm, "VM only");
        _;
    }

    function detectVm() internal {
        uint256 size;
        assembly {
            size := extcodesize(0x0000000000000000000000000000000000fffFfF)
        }
        vm = size == 0;
    }
}
