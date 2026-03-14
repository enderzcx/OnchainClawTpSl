// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IReactive {
    struct LogRecord {
        uint256 chainId;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
        bytes data;
        uint256 blockNumber;
        bytes32 txHash;
        uint256 logIndex;
    }

    function react(LogRecord calldata log) external;
}
