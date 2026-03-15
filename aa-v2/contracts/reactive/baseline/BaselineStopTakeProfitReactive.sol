// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../official-lib/abstract-base/AbstractReactive.sol";
import "../official-lib/interfaces/IReactive.sol";

contract BaselineStopTakeProfitReactive is IReactive, AbstractReactive {
    event OrderTracked(address indexed pair, uint256 indexed orderId);
    event OrderUntracked(address indexed pair, uint256 indexed orderId);
    event PairSubscribed(address indexed pair);
    event PairUnsubscribed(address indexed pair);
    event ExecutionTriggered(uint256 indexed orderId, address indexed pair, bool priceConditionMet);
    event ProcessingError(string reason, uint256 orderId);
    event ThresholdCheck(uint256 indexed orderId, uint256 calculated, uint256 threshold, bool conditionMet, bool sellToken0);

    uint256 private constant ORIGIN_CHAIN_ID = 56;
    uint256 private constant REACTIVE_CHAIN_ID = 1597;
    uint256 private constant UNISWAP_V2_SYNC_TOPIC_0 =
        0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 private constant STOP_ORDER_CREATED_TOPIC_0 =
        0xc617c0f87fe14fdefff1476f1b4c2c15c9492ea39a9c2e19d4401bf09fbb06a8;
    uint256 private constant STOP_ORDER_CANCELLED_TOPIC_0 =
        0xad9e9b6169c70ec1a50cf90107a9621b005376a3aa8662130d414a541693149d;
    uint256 private constant STOP_ORDER_EXECUTED_TOPIC_0 =
        0x90979f4e8ed6baf430ca253822dfbd281b8d2c27d7a5121b484b4bfcaca4297f;
    uint256 private constant STOP_ORDER_PAUSED_TOPIC_0 =
        0x7c070b2e9334d802a093c6b4a80f124bf4ffc8a9af89d0dae72ab22309f96889;
    uint256 private constant STOP_ORDER_RESUMED_TOPIC_0 =
        0x310f8f7e10ddae556ab6ef7c362667de2c95fad69956c224c16aa058755669a7;
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    enum OrderType {
        StopLoss,
        TakeProfit
    }

    enum OrderStatus {
        Active,
        Paused,
        Cancelled,
        Executed,
        Failed
    }

    struct Reserves {
        uint112 reserve0;
        uint112 reserve1;
    }

    struct TrackedOrder {
        uint256 id;
        address pair;
        bool sellToken0;
        uint256 coefficient;
        uint256 threshold;
        OrderType orderType;
        OrderStatus status;
        uint256 lastTriggeredAt;
        uint8 triggerCount;
    }

    address public immutable owner;
    address public immutable stopOrderCallback;

    mapping(uint256 => TrackedOrder) public trackedOrders;
    mapping(address => uint256[]) public pairOrders;
    mapping(address => uint256) public pairOrderCount;
    mapping(address => bool) public subscribedPairs;

    uint256 private constant TRIGGER_COOLDOWN = 300;
    uint8 private constant MAX_TRIGGER_ATTEMPTS = 5;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner_only");
        _;
    }

    constructor(address ownerAddress, address callbackAddress)
        payable
    {
        require(ownerAddress != address(0), "owner_required");
        require(callbackAddress != address(0), "callback_required");
        owner = ownerAddress;
        stopOrderCallback = callbackAddress;

        if (!vm) {
            service.subscribe(ORIGIN_CHAIN_ID, stopOrderCallback, STOP_ORDER_CREATED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(ORIGIN_CHAIN_ID, stopOrderCallback, STOP_ORDER_CANCELLED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(ORIGIN_CHAIN_ID, stopOrderCallback, STOP_ORDER_EXECUTED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(ORIGIN_CHAIN_ID, stopOrderCallback, STOP_ORDER_PAUSED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(ORIGIN_CHAIN_ID, stopOrderCallback, STOP_ORDER_RESUMED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log._contract == stopOrderCallback) {
            _processStopOrderEvent(log);
        } else if (log.topic_0 == UNISWAP_V2_SYNC_TOPIC_0 && subscribedPairs[log._contract]) {
            _processSyncEvent(log);
        }
    }

    function _processStopOrderEvent(LogRecord calldata log) internal {
        if (log.topic_0 == STOP_ORDER_CREATED_TOPIC_0) {
            _processOrderCreated(log);
        } else if (log.topic_0 == STOP_ORDER_CANCELLED_TOPIC_0) {
            _processOrderCancelled(log);
        } else if (log.topic_0 == STOP_ORDER_EXECUTED_TOPIC_0) {
            _processOrderExecuted(log);
        } else if (log.topic_0 == STOP_ORDER_PAUSED_TOPIC_0) {
            _processOrderPaused(log);
        } else if (log.topic_0 == STOP_ORDER_RESUMED_TOPIC_0) {
            _processOrderResumed(log);
        }
    }

    function _processOrderCreated(LogRecord calldata log) internal {
        address pair = address(uint160(log.topic_1));
        uint256 orderId = uint256(log.topic_2);

        (bool sellToken0, , , , uint256 coefficient, uint256 threshold, OrderType orderType) =
            abi.decode(log.data, (bool, address, address, uint256, uint256, uint256, OrderType));

        trackedOrders[orderId] = TrackedOrder({
            id: orderId,
            pair: pair,
            sellToken0: sellToken0,
            coefficient: coefficient,
            threshold: threshold,
            orderType: orderType,
            status: OrderStatus.Active,
            lastTriggeredAt: 0,
            triggerCount: 0
        });

        pairOrders[pair].push(orderId);
        if (pairOrderCount[pair] == 0) {
            _requestPairSubscription(pair);
        }
        pairOrderCount[pair] += 1;

        emit OrderTracked(pair, orderId);
    }

    function _processOrderCancelled(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_1);
        if (trackedOrders[orderId].id == orderId) {
            address pair = trackedOrders[orderId].pair;
            trackedOrders[orderId].status = OrderStatus.Cancelled;
            _decrementPairCount(pair);
            emit OrderUntracked(pair, orderId);
        }
    }

    function _processOrderExecuted(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_2);
        if (trackedOrders[orderId].id == orderId) {
            address pair = trackedOrders[orderId].pair;
            trackedOrders[orderId].status = OrderStatus.Executed;
            _decrementPairCount(pair);
            emit OrderUntracked(pair, orderId);
        }
    }

    function _processOrderPaused(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_1);
        if (trackedOrders[orderId].id == orderId) {
            trackedOrders[orderId].status = OrderStatus.Paused;
        }
    }

    function _processOrderResumed(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_1);
        if (trackedOrders[orderId].id == orderId) {
            trackedOrders[orderId].status = OrderStatus.Active;
        }
    }

    function _processSyncEvent(LogRecord calldata log) internal {
        address pair = log._contract;
        Reserves memory reserves = abi.decode(log.data, (Reserves));
        uint256[] storage orderIds = pairOrders[pair];
        uint256 totalOrders = orderIds.length;

        for (uint256 i = 0; i < totalOrders; ) {
            uint256 orderId = orderIds[i];
            TrackedOrder storage order = trackedOrders[orderId];
            if (order.status != OrderStatus.Active) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (order.lastTriggeredAt > 0 && block.timestamp < order.lastTriggeredAt + TRIGGER_COOLDOWN) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (order.triggerCount >= MAX_TRIGGER_ATTEMPTS) {
                order.status = OrderStatus.Failed;
                emit ProcessingError("Max retries exceeded", orderId);
                unchecked {
                    ++i;
                }
                continue;
            }

            bool shouldTrigger = _isPriceConditionMet(order.sellToken0, reserves, order.coefficient, order.threshold, order.orderType);
            uint256 calculated = order.sellToken0
                ? Math.mulDiv(uint256(reserves.reserve1), order.coefficient, uint256(reserves.reserve0))
                : Math.mulDiv(uint256(reserves.reserve0), order.coefficient, uint256(reserves.reserve1));
            emit ThresholdCheck(orderId, calculated, order.threshold, shouldTrigger, order.sellToken0);

            if (shouldTrigger) {
                _triggerExecution(orderId, pair);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _isPriceConditionMet(
        bool sellToken0,
        Reserves memory reserves,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    ) internal pure returns (bool) {
        uint256 currentPrice = sellToken0
            ? Math.mulDiv(uint256(reserves.reserve1), coefficient, uint256(reserves.reserve0))
            : Math.mulDiv(uint256(reserves.reserve0), coefficient, uint256(reserves.reserve1));

        if (orderType == OrderType.StopLoss) {
            return currentPrice <= threshold;
        }
        return currentPrice >= threshold;
    }

    function _triggerExecution(uint256 orderId, address pair) internal {
        TrackedOrder storage order = trackedOrders[orderId];
        order.lastTriggeredAt = block.timestamp;
        order.triggerCount += 1;

        bytes memory payload = abi.encodeWithSignature("executeStopOrder(address,uint256)", address(0), orderId);
        emit Callback(ORIGIN_CHAIN_ID, stopOrderCallback, CALLBACK_GAS_LIMIT, payload);
        emit ExecutionTriggered(orderId, pair, true);
    }

    function _requestPairSubscription(address pair) internal {
        if (!subscribedPairs[pair]) {
            bytes memory payload =
                abi.encodeWithSignature("subscribeToPair(address,address,uint256)", address(0), pair, ORIGIN_CHAIN_ID);
            emit Callback(REACTIVE_CHAIN_ID, address(this), CALLBACK_GAS_LIMIT, payload);
            subscribedPairs[pair] = true;
            emit PairSubscribed(pair);
        }
    }

    function _requestPairUnsubscription(address pair) internal {
        if (subscribedPairs[pair]) {
            bytes memory payload =
                abi.encodeWithSignature("unsubscribeFromPair(address,address,uint256)", address(0), pair, ORIGIN_CHAIN_ID);
            emit Callback(REACTIVE_CHAIN_ID, address(this), CALLBACK_GAS_LIMIT, payload);
            subscribedPairs[pair] = false;
            emit PairUnsubscribed(pair);
        }
    }

    function subscribeToPair(address, address pair, uint256 chainId) external rnOnly {
        service.subscribe(chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function unsubscribeFromPair(address, address pair, uint256 chainId) external rnOnly {
        service.unsubscribe(chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _decrementPairCount(address pair) internal {
        if (pairOrderCount[pair] > 0) {
            pairOrderCount[pair] -= 1;
            if (pairOrderCount[pair] == 0) {
                _requestPairUnsubscription(pair);
            }
        }
    }

    function emergencySubscribeToPair(address pair, uint256 chainId) external onlyOwner {
        service.subscribe(chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        subscribedPairs[pair] = true;
        emit PairSubscribed(pair);
    }

    function emergencyUnsubscribeFromPair(address pair, uint256 chainId) external onlyOwner {
        service.unsubscribe(chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        subscribedPairs[pair] = false;
        emit PairUnsubscribed(pair);
    }

    function getActiveOrdersForPair(address pair) external view returns (uint256[] memory activeOrders) {
        uint256[] storage allOrders = pairOrders[pair];
        uint256 totalOrders = allOrders.length;
        uint256 activeCount = 0;
        for (uint256 i = 0; i < totalOrders; ) {
            if (trackedOrders[allOrders[i]].status == OrderStatus.Active) {
                activeCount += 1;
            }
            unchecked {
                ++i;
            }
        }
        activeOrders = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < totalOrders; ) {
            if (trackedOrders[allOrders[i]].status == OrderStatus.Active) {
                activeOrders[index] = allOrders[i];
                index += 1;
            }
            unchecked {
                ++i;
            }
        }
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "recipient_required");
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function rescueAllERC20(address token, address to) external onlyOwner {
        require(to != address(0), "recipient_required");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "no_tokens_to_rescue");
        SafeERC20.safeTransfer(IERC20(token), to, balance);
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "insufficient_eth_balance");
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "eth_transfer_failed");
    }

    function withdrawAllETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "no_eth_to_withdraw");
        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "eth_transfer_failed");
    }
}
