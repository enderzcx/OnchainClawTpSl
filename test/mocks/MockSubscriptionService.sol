// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockSubscriptionService {
    struct SubscriptionCall {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    SubscriptionCall[] public subscribeCalls;
    SubscriptionCall[] public unsubscribeCalls;

    function subscribe(
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        subscribeCalls.push(SubscriptionCall(chainId, contractAddress, topic0, topic1, topic2, topic3));
    }

    function unsubscribe(
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        unsubscribeCalls.push(SubscriptionCall(chainId, contractAddress, topic0, topic1, topic2, topic3));
    }

    function subscribeCallsCount() external view returns (uint256) {
        return subscribeCalls.length;
    }

    function unsubscribeCallsCount() external view returns (uint256) {
        return unsubscribeCalls.length;
    }
}
