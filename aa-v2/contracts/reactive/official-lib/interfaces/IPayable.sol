// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface IPayable {
    function debt(address) external view returns (uint256);
}
