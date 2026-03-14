// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./lib/AbstractReactive.sol";
import "./lib/IReactive.sol";

contract OnchainClawTpSlReactive is IReactive, AbstractReactive {
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

    event Triggered(uint256 indexed orderId, address indexed pair);
    event ThresholdCheck(
        uint256 indexed orderId, uint256 calculated, uint256 threshold, bool conditionMet, bool sellToken0
    );
    event ProcessingError(string reason, uint256 orderId);
    event PairSubscribed(address indexed pair);
    event PairUnsubscribed(address indexed pair);

    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;
    uint256 public constant TRIGGER_COOLDOWN = 300;
    uint8 public constant MAX_TRIGGER_ATTEMPTS = 5;
    uint256 public constant SYNC_TOPIC_0 = uint256(keccak256("Sync(uint112,uint112)"));
    uint256 public constant ORDER_CREATED_TOPIC_0 =
        uint256(keccak256("OrderCreated(address,uint256,bool,address,address,uint256,uint256,uint256,uint256,uint8)"));
    uint256 public constant ORDER_CANCELLED_TOPIC_0 = uint256(keccak256("OrderCancelled(uint256)"));
    uint256 public constant ORDER_EXECUTED_TOPIC_0 =
        uint256(keccak256("OrderExecuted(address,uint256,uint256,uint256)"));
    uint256 public constant ORDER_PAUSED_TOPIC_0 = uint256(keccak256("OrderPaused(uint256)"));
    uint256 public constant ORDER_RESUMED_TOPIC_0 = uint256(keccak256("OrderResumed(uint256)"));
    uint256 public constant ORDER_FAILED_TOPIC_0 = uint256(keccak256("OrderFailed(uint256)"));

    struct TrackedOrder {
        address pair;
        uint40 lastTriggeredAt;
        uint8 triggerCount;
        bool sellToken0;
        uint256 coefficient;
        uint256 threshold;
        OrderType orderType;
        OrderStatus status;
    }

    address public immutable callbackContract;
    uint256 public immutable originChainId;
    uint256 public immutable rnkChainId;

    mapping(uint256 => TrackedOrder) private _trackedOrders;
    mapping(address => uint256[]) public pairOrders;
    mapping(uint256 => uint256) private _pairOrderIndex;
    mapping(address => bool) public subscribedPairs;

    constructor(
        address subscriptionService,
        address reactiveNetworkAddress,
        address callbackContractAddress,
        uint256 originChainIdValue,
        uint256 rnkChainIdValue,
        bool vmMode
    ) payable AbstractReactive(subscriptionService, reactiveNetworkAddress, vmMode) {
        require(callbackContractAddress != address(0), "callback_required");
        callbackContract = callbackContractAddress;
        originChainId = originChainIdValue;
        rnkChainId = rnkChainIdValue;

        if (!vm && address(service) != address(0)) {
            service.subscribe(
                originChainId,
                callbackContractAddress,
                ORDER_CREATED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId,
                callbackContractAddress,
                ORDER_CANCELLED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId,
                callbackContractAddress,
                ORDER_EXECUTED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId,
                callbackContractAddress,
                ORDER_PAUSED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId,
                callbackContractAddress,
                ORDER_RESUMED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId,
                callbackContractAddress,
                ORDER_FAILED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log._contract == callbackContract) {
            _handleOrderLifecycle(log);
        } else if (log.topic_0 == SYNC_TOPIC_0 && subscribedPairs[log._contract]) {
            _handleSync(log);
        }
    }

    function subscribeToPair(address, address pair, uint256 chainId) external rnOnly {
        require(pair != address(0), "pair_required");
        if (address(service) != address(0)) {
            service.subscribe(chainId, pair, SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        subscribedPairs[pair] = true;
        emit PairSubscribed(pair);
    }

    function unsubscribeFromPair(address, address pair, uint256 chainId) external rnOnly {
        require(pair != address(0), "pair_required");
        if (address(service) != address(0)) {
            service.unsubscribe(chainId, pair, SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        subscribedPairs[pair] = false;
        emit PairUnsubscribed(pair);
    }

    function pairOrderCount(address pair) external view returns (uint256) {
        return pairOrders[pair].length;
    }

    function trackedOrders(uint256 orderId)
        external
        view
        returns (
            uint256 id,
            address pair,
            bool sellToken0,
            uint256 coefficient,
            uint256 threshold,
            OrderType orderType,
            OrderStatus status
        )
    {
        TrackedOrder storage order = _trackedOrders[orderId];
        if (order.pair == address(0)) {
            return (0, address(0), false, 0, 0, OrderType.StopLoss, OrderStatus.Active);
        }

        return
            (orderId, order.pair, order.sellToken0, order.coefficient, order.threshold, order.orderType, order.status);
    }

    function _handleOrderLifecycle(LogRecord calldata log) internal {
        if (log.topic_0 == ORDER_CREATED_TOPIC_0) {
            address pair = address(uint160(log.topic_1));
            uint256 orderId = uint256(log.topic_2);

            (bool sellToken0,,,,, uint256 coefficient, uint256 threshold, uint8 orderTypeValue) =
                abi.decode(log.data, (bool, address, address, uint256, uint256, uint256, uint256, uint8));

            _trackedOrders[orderId] = TrackedOrder({
                pair: pair,
                lastTriggeredAt: 0,
                triggerCount: 0,
                sellToken0: sellToken0,
                coefficient: coefficient,
                threshold: threshold,
                orderType: OrderType(orderTypeValue),
                status: OrderStatus.Active
            });
            if (pairOrders[pair].length == 0) {
                _requestPairSubscription(pair);
            }
            _addActiveOrder(pair, orderId);

            return;
        }

        if (log.topic_0 == ORDER_CANCELLED_TOPIC_0) {
            _markOrderInactive(uint256(log.topic_1), OrderStatus.Cancelled);
            return;
        }

        if (log.topic_0 == ORDER_EXECUTED_TOPIC_0) {
            _markOrderInactive(uint256(log.topic_2), OrderStatus.Executed);
            return;
        }

        if (log.topic_0 == ORDER_PAUSED_TOPIC_0) {
            _pauseOrder(uint256(log.topic_1));
            return;
        }

        if (log.topic_0 == ORDER_RESUMED_TOPIC_0) {
            _resumeOrder(uint256(log.topic_1));
            return;
        }

        if (log.topic_0 == ORDER_FAILED_TOPIC_0) {
            _markOrderInactive(uint256(log.topic_1), OrderStatus.Failed);
        }
    }

    function _handleSync(LogRecord calldata log) internal {
        (uint112 reserve0, uint112 reserve1) = abi.decode(log.data, (uint112, uint112));

        uint256[] storage ids = pairOrders[log._contract];
        uint256 totalIds = ids.length;
        for (uint256 index = 0; index < totalIds;) {
            uint256 orderId = ids[index];
            TrackedOrder storage order = _trackedOrders[orderId];
            if (order.status != OrderStatus.Active) {
                unchecked {
                    ++index;
                }
                continue;
            }
            if (order.lastTriggeredAt > 0 && block.timestamp < uint256(order.lastTriggeredAt) + TRIGGER_COOLDOWN) {
                unchecked {
                    ++index;
                }
                continue;
            }
            if (order.triggerCount >= MAX_TRIGGER_ATTEMPTS) {
                _markOrderInactive(orderId, OrderStatus.Failed);
                emit ProcessingError("max_trigger_attempts_exceeded", orderId);
                unchecked {
                    ++index;
                }
                continue;
            }

            uint256 currentPrice = _currentPrice(order.sellToken0, reserve0, reserve1, order.coefficient);
            bool hit = _priceConditionMet(currentPrice, order.threshold, order.orderType);
            emit ThresholdCheck(orderId, currentPrice, order.threshold, hit, order.sellToken0);
            if (!hit) {
                unchecked {
                    ++index;
                }
                continue;
            }

            order.lastTriggeredAt = uint40(block.timestamp);
            order.triggerCount += 1;

            emit Callback(
                originChainId,
                callbackContract,
                CALLBACK_GAS_LIMIT,
                abi.encodeWithSignature("executeOrder(address,uint256)", address(0), orderId)
            );
            emit Triggered(orderId, log._contract);
            unchecked {
                ++index;
            }
        }
    }

    function _requestPairSubscription(address pair) internal {
        if (subscribedPairs[pair]) {
            return;
        }

        if (vm) {
            subscribedPairs[pair] = true;
            emit PairSubscribed(pair);
            return;
        }

        emit Callback(
            rnkChainId,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature("subscribeToPair(address,address,uint256)", address(0), pair, originChainId)
        );
    }

    function _requestPairUnsubscription(address pair) internal {
        if (!subscribedPairs[pair]) {
            return;
        }

        if (vm) {
            subscribedPairs[pair] = false;
            emit PairUnsubscribed(pair);
            return;
        }

        emit Callback(
            rnkChainId,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature("unsubscribeFromPair(address,address,uint256)", address(0), pair, originChainId)
        );
    }

    function _markOrderInactive(uint256 orderId, OrderStatus nextStatus) internal {
        TrackedOrder storage order = _trackedOrders[orderId];
        if (order.pair == address(0)) {
            return;
        }
        if (order.status == OrderStatus.Active) {
            bool wasLastActiveOrder = pairOrders[order.pair].length == 1;
            _removeActiveOrder(order.pair, orderId);
            if (wasLastActiveOrder) {
                _requestPairUnsubscription(order.pair);
            }
        }
        order.status = nextStatus;
    }

    function _pauseOrder(uint256 orderId) internal {
        TrackedOrder storage order = _trackedOrders[orderId];
        if (order.pair == address(0) || order.status != OrderStatus.Active) {
            return;
        }
        bool wasLastActiveOrder = pairOrders[order.pair].length == 1;
        _removeActiveOrder(order.pair, orderId);
        if (wasLastActiveOrder) {
            _requestPairUnsubscription(order.pair);
        }
        order.status = OrderStatus.Paused;
    }

    function _resumeOrder(uint256 orderId) internal {
        TrackedOrder storage order = _trackedOrders[orderId];
        if (order.pair == address(0) || order.status != OrderStatus.Paused) {
            return;
        }
        if (pairOrders[order.pair].length == 0) {
            _requestPairSubscription(order.pair);
        }
        _addActiveOrder(order.pair, orderId);
        order.status = OrderStatus.Active;
    }

    function _addActiveOrder(address pair, uint256 orderId) internal {
        pairOrders[pair].push(orderId);
        _pairOrderIndex[orderId] = pairOrders[pair].length;
    }

    function _removeActiveOrder(address pair, uint256 orderId) internal {
        uint256 indexPlusOne = _pairOrderIndex[orderId];
        if (indexPlusOne == 0) {
            return;
        }

        uint256[] storage activeOrders = pairOrders[pair];
        uint256 lastIndex = activeOrders.length - 1;
        uint256 index = indexPlusOne - 1;
        if (index != lastIndex) {
            uint256 movedOrderId = activeOrders[lastIndex];
            activeOrders[index] = movedOrderId;
            _pairOrderIndex[movedOrderId] = index + 1;
        }

        activeOrders.pop();
        delete _pairOrderIndex[orderId];
    }

    function _priceConditionMet(uint256 currentPrice, uint256 threshold, OrderType orderType)
        internal
        pure
        returns (bool)
    {
        if (currentPrice == 0) {
            return false;
        }

        if (orderType == OrderType.StopLoss) {
            return currentPrice <= threshold;
        }
        return currentPrice >= threshold;
    }

    function _currentPrice(bool sellToken0, uint112 reserve0, uint112 reserve1, uint256 coefficient)
        internal
        pure
        returns (uint256)
    {
        if (reserve0 == 0 || reserve1 == 0) {
            return 0;
        }

        return sellToken0
            ? Math.mulDiv(uint256(reserve1), coefficient, uint256(reserve0))
            : Math.mulDiv(uint256(reserve0), coefficient, uint256(reserve1));
    }
}
