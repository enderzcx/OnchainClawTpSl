// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import "reactive/OnchainClawTpSlCallback.sol";
import "reactive/OnchainClawTpSlReactive.sol";
import "reactive/lib/AbstractCallback.sol";
import "reactive/lib/AbstractReactive.sol";
import "reactive/lib/IReactive.sol";

import "./mocks/MockERC20.sol";
import "./mocks/MockPair.sol";
import "./mocks/MockRouter.sol";
import "./mocks/MockSubscriptionService.sol";

contract AbstractReactiveHarness is AbstractReactive {
    constructor(address subscriptionService, address reactiveNetworkAddress, bool vmMode)
        AbstractReactive(subscriptionService, reactiveNetworkAddress, vmMode)
    {}

    function runVmOnly() external view vmOnly returns (bool) {
        return true;
    }

    function runRnOnly() external view rnOnly returns (bool) {
        return true;
    }
}

contract AbstractCallbackHarness is AbstractCallback {
    constructor(address authorizedCallbackSender, bool vmMode) AbstractCallback(authorizedCallbackSender, vmMode) {}

    function runAuthorizedOnly() external view authorizedSenderOnly returns (bool) {
        return true;
    }
}

contract OnchainClawTpSlCallbackTest is Test {
    MockERC20 internal token0;
    MockERC20 internal token1;
    MockPair internal pair;
    MockRouter internal router;
    OnchainClawTpSlCallback internal callback;

    address internal user = address(0xBEEF);
    uint256 internal constant COEFFICIENT = 1e18;

    receive() external payable {}

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        pair = new MockPair(address(token0), address(token1));
        router = new MockRouter();
        callback = new OnchainClawTpSlCallback(address(0xCA11), address(router), true);

        pair.setReserves(1e18, 2e18);
        token0.mint(user, 100e18);
        token1.mint(address(router), 1_000e18);

        vm.prank(user);
        token0.approve(address(callback), type(uint256).max);
    }

    function _callbackStatus(uint256 orderId) internal view returns (OnchainClawTpSlCallback.OrderStatus status) {
        (,,,,,,,,,,, status) = callback.orders(orderId);
    }

    function testCreateOrderPreservesGetterShape() public {
        vm.prank(user);
        uint256 orderId = callback.createOrder(
            address(pair), true, 5e18, 1e18, COEFFICIENT, 15e17, OnchainClawTpSlCallback.OrderType.TakeProfit
        );

        assertEq(orderId, 0);
        assertEq(callback.nextOrderId(), 1);

        (
            uint256 id,
            address owner,
            address orderPair,
            address tokenSell,
            address tokenBuy,
            bool sellToken0,
            uint256 amount,
            uint256 minAmountOut,
            uint256 coefficient,
            uint256 threshold,
            OnchainClawTpSlCallback.OrderType orderType,
            OnchainClawTpSlCallback.OrderStatus status
        ) = callback.orders(orderId);

        assertEq(id, orderId);
        assertEq(owner, user);
        assertEq(orderPair, address(pair));
        assertEq(tokenSell, address(token0));
        assertEq(tokenBuy, address(token1));
        assertTrue(sellToken0);
        assertEq(amount, 5e18);
        assertEq(minAmountOut, 1e18);
        assertEq(coefficient, COEFFICIENT);
        assertEq(threshold, 15e17);
        assertEq(uint8(orderType), uint8(OnchainClawTpSlCallback.OrderType.TakeProfit));
        assertEq(uint8(status), uint8(OnchainClawTpSlCallback.OrderStatus.Active));
    }

    function testExecuteBracketOrderCancelsSiblingInO1Path() public {
        vm.prank(user);
        (uint256 stopLossOrderId, uint256 takeProfitOrderId) =
            callback.createBracketOrders(address(pair), true, 5e18, COEFFICIENT, 1e18, 1e18, 3e18, 15e17);

        assertEq(callback.siblingOrders(stopLossOrderId), takeProfitOrderId + 1);
        assertEq(callback.siblingOrders(takeProfitOrderId), stopLossOrderId + 1);

        router.setNextAmountOut(4e18);
        callback.executeOrder(address(0), takeProfitOrderId);

        (,,,,,,,,,,, OnchainClawTpSlCallback.OrderStatus stopLossStatus) = callback.orders(stopLossOrderId);
        (,,,,,,,,,,, OnchainClawTpSlCallback.OrderStatus takeProfitStatus) = callback.orders(takeProfitOrderId);

        assertEq(uint8(stopLossStatus), uint8(OnchainClawTpSlCallback.OrderStatus.Cancelled));
        assertEq(uint8(takeProfitStatus), uint8(OnchainClawTpSlCallback.OrderStatus.Executed));
        assertEq(callback.siblingOrders(stopLossOrderId), 0);
        assertEq(callback.siblingOrders(takeProfitOrderId), 0);
        assertEq(token1.balanceOf(user), 4e18);
    }

    function testBracketGroupAccessorsExposeSharedOrderData() public {
        vm.expectEmit(true, true, true, true);
        emit OnchainClawTpSlCallback.BracketGroupCreated(0, 0, 1, user, address(pair));

        vm.prank(user);
        (uint256 stopLossOrderId, uint256 takeProfitOrderId) =
            callback.createBracketOrders(address(pair), true, 5e18, COEFFICIENT, 1e18, 1e18, 3e18, 15e17);

        (bool stopLossHasGroup, uint256 stopLossGroupId) = callback.bracketGroupIdForOrder(stopLossOrderId);
        (bool takeProfitHasGroup, uint256 takeProfitGroupId) = callback.bracketGroupIdForOrder(takeProfitOrderId);

        assertTrue(callback.isBracketOrder(stopLossOrderId));
        assertTrue(callback.isBracketOrder(takeProfitOrderId));
        assertTrue(stopLossHasGroup);
        assertTrue(takeProfitHasGroup);
        assertEq(stopLossGroupId, 0);
        assertEq(takeProfitGroupId, 0);

        (
            address owner,
            address orderPair,
            address tokenSell,
            address tokenBuy,
            bool sellToken0,
            uint256 amount,
            uint256 coefficient
        ) = callback.bracketGroup(0);

        assertEq(owner, user);
        assertEq(orderPair, address(pair));
        assertEq(tokenSell, address(token0));
        assertEq(tokenBuy, address(token1));
        assertTrue(sellToken0);
        assertEq(amount, 5e18);
        assertEq(coefficient, COEFFICIENT);

        vm.prank(user);
        uint256 singleOrderId = callback.createOrder(
            address(pair), true, 1e18, 1, COEFFICIENT, 10e17, OnchainClawTpSlCallback.OrderType.StopLoss
        );

        (bool singleHasGroup, uint256 singleGroupId) = callback.bracketGroupIdForOrder(singleOrderId);
        assertFalse(callback.isBracketOrder(singleOrderId));
        assertFalse(singleHasGroup);
        assertEq(singleGroupId, 0);
    }

    function testBracketGroupGetterRevertsForMissingGroup() public {
        vm.expectRevert("bracket_group_missing");
        callback.bracketGroup(999);
    }

    function testPauseResumeAndFailWhenAllowanceFallsToZero() public {
        vm.prank(user);
        uint256 orderId = callback.createOrder(
            address(pair), true, 5e18, 1e18, COEFFICIENT, 15e17, OnchainClawTpSlCallback.OrderType.TakeProfit
        );

        vm.prank(user);
        callback.pauseOrder(orderId);
        assertEq(uint8(_callbackStatus(orderId)), uint8(OnchainClawTpSlCallback.OrderStatus.Paused));

        vm.prank(user);
        callback.resumeOrder(orderId);
        assertEq(uint8(_callbackStatus(orderId)), uint8(OnchainClawTpSlCallback.OrderStatus.Active));

        vm.prank(user);
        token0.approve(address(callback), 0);

        callback.executeOrder(address(0), orderId);

        assertEq(uint8(_callbackStatus(orderId)), uint8(OnchainClawTpSlCallback.OrderStatus.Failed));
    }

    function testExecuteOrderUsesReducedAllowanceInsteadOfReverting() public {
        vm.prank(user);
        uint256 orderId = callback.createOrder(
            address(pair), true, 5e18, 1e18, COEFFICIENT, 15e17, OnchainClawTpSlCallback.OrderType.TakeProfit
        );

        vm.prank(user);
        token0.approve(address(callback), 2e18);
        router.setNextAmountOut(4e18);

        callback.executeOrder(address(0), orderId);

        assertEq(uint8(_callbackStatus(orderId)), uint8(OnchainClawTpSlCallback.OrderStatus.Executed));
        assertEq(token1.balanceOf(user), 4e18);
    }

    function testPartialExecutionScalesMinAmountOutProportionally() public {
        vm.prank(user);
        uint256 orderId = callback.createOrder(
            address(pair), true, 5e18, 1e18, COEFFICIENT, 15e17, OnchainClawTpSlCallback.OrderType.TakeProfit
        );

        vm.prank(user);
        token0.approve(address(callback), 2e18);
        router.setNextAmountOut(4e17);

        callback.executeOrder(address(0), orderId);

        assertEq(router.lastAmountIn(), 2e18);
        assertEq(router.lastAmountOutMin(), 4e17);
        assertEq(uint8(_callbackStatus(orderId)), uint8(OnchainClawTpSlCallback.OrderStatus.Executed));
    }

    function testBracketLegFailureLeavesSiblingActive() public {
        vm.prank(user);
        (uint256 stopLossOrderId, uint256 takeProfitOrderId) =
            callback.createBracketOrders(address(pair), true, 5e18, COEFFICIENT, 1e18, 1e18, 3e18, 15e17);

        vm.prank(user);
        token0.approve(address(callback), 0);

        callback.executeOrder(address(0), takeProfitOrderId);

        assertEq(uint8(_callbackStatus(takeProfitOrderId)), uint8(OnchainClawTpSlCallback.OrderStatus.Failed));
        assertEq(uint8(_callbackStatus(stopLossOrderId)), uint8(OnchainClawTpSlCallback.OrderStatus.Active));
        assertEq(callback.siblingOrders(stopLossOrderId), 0);
        assertEq(callback.siblingOrders(takeProfitOrderId), 0);
    }

    function testRescueAdminCanRecoverStuckEthAndTokens() public {
        token1.mint(address(callback), 3e18);
        vm.deal(address(callback), 2 ether);

        uint256 rescueAdminEthBefore = address(this).balance;
        uint256 rescueAdminTokenBefore = token1.balanceOf(address(this));

        callback.rescueETH(1 ether);
        callback.rescueAllERC20(address(token1));

        assertEq(address(callback).balance, 1 ether);
        assertEq(address(this).balance, rescueAdminEthBefore + 1 ether);
        assertEq(token1.balanceOf(address(this)), rescueAdminTokenBefore + 3e18);
    }
}

contract OnchainClawTpSlReactiveTest is Test {
    MockSubscriptionService internal service;
    OnchainClawTpSlReactive internal reactiveContract;

    address internal callbackContract = address(0xCA11);
    address internal reactiveNetwork = address(0xB0B);
    address internal pair = address(0xA11CE);
    uint256 internal constant ORIGIN_CHAIN_ID = 56;
    uint256 internal constant REACTIVE_CHAIN_ID = 1597;
    uint256 internal constant COEFFICIENT = 1e18;

    function setUp() public {
        service = new MockSubscriptionService();
        reactiveContract = new OnchainClawTpSlReactive(
            address(service), reactiveNetwork, callbackContract, ORIGIN_CHAIN_ID, REACTIVE_CHAIN_ID, false
        );
    }

    function _buildLifecycleLog(uint256 topic0, uint256 topic1, uint256 topic2)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN_ID,
            _contract: callbackContract,
            topic_0: topic0,
            topic_1: topic1,
            topic_2: topic2,
            topic_3: 0,
            data: bytes(""),
            blockNumber: 1,
            txHash: bytes32(uint256(7)),
            logIndex: 0
        });
    }

    function _buildCreatedLog(uint256 orderId, address pairAddress, uint8 orderType)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN_ID,
            _contract: callbackContract,
            topic_0: reactiveContract.ORDER_CREATED_TOPIC_0(),
            topic_1: uint256(uint160(pairAddress)),
            topic_2: orderId,
            topic_3: 0,
            data: abi.encode(true, address(0x1), address(0x2), 5e18, 1e18, COEFFICIENT, 15e17, orderType),
            blockNumber: 1,
            txHash: bytes32(uint256(7)),
            logIndex: 0
        });
    }

    function _trackedStatus(uint256 orderId) internal view returns (OnchainClawTpSlReactive.OrderStatus status) {
        (,,,,,, status) = reactiveContract.trackedOrders(orderId);
    }

    function _trackedStatusFor(OnchainClawTpSlReactive target, uint256 orderId)
        internal
        view
        returns (OnchainClawTpSlReactive.OrderStatus status)
    {
        (,,,,,, status) = target.trackedOrders(orderId);
    }

    function testConstructorAndOrderTrackingPreserveGetterShape() public {
        assertEq(service.subscribeCallsCount(), 6);

        IReactive.LogRecord memory createdLog =
            _buildCreatedLog(42, pair, uint8(OnchainClawTpSlReactive.OrderType.TakeProfit));

        vm.prank(reactiveNetwork);
        reactiveContract.react(createdLog);

        (
            uint256 id,
            address trackedPair,
            bool sellToken0,
            uint256 coefficient,
            uint256 threshold,
            OnchainClawTpSlReactive.OrderType orderType,
            OnchainClawTpSlReactive.OrderStatus status
        ) = reactiveContract.trackedOrders(42);

        assertEq(id, 42);
        assertEq(trackedPair, pair);
        assertTrue(sellToken0);
        assertEq(coefficient, COEFFICIENT);
        assertEq(threshold, 15e17);
        assertEq(uint8(orderType), uint8(OnchainClawTpSlReactive.OrderType.TakeProfit));
        assertEq(uint8(status), uint8(OnchainClawTpSlReactive.OrderStatus.Active));
        assertEq(reactiveContract.pairOrderCount(pair), 1);
        assertFalse(reactiveContract.subscribedPairs(pair));

        vm.prank(reactiveNetwork);
        reactiveContract.subscribeToPair(address(0), pair, ORIGIN_CHAIN_ID);

        assertTrue(reactiveContract.subscribedPairs(pair));
        assertEq(service.subscribeCallsCount(), 7);
    }

    function testPauseResumeCancelAndUnsubscribeFlow() public {
        OnchainClawTpSlReactive vmReactive = new OnchainClawTpSlReactive(
            address(service), reactiveNetwork, callbackContract, ORIGIN_CHAIN_ID, REACTIVE_CHAIN_ID, true
        );

        vmReactive.react(
            IReactive.LogRecord({
                chainId: ORIGIN_CHAIN_ID,
                _contract: callbackContract,
                topic_0: vmReactive.ORDER_CREATED_TOPIC_0(),
                topic_1: uint256(uint160(pair)),
                topic_2: 1,
                topic_3: 0,
                data: abi.encode(
                    true,
                    address(0x1),
                    address(0x2),
                    5e18,
                    1e18,
                    COEFFICIENT,
                    15e17,
                    uint8(OnchainClawTpSlReactive.OrderType.TakeProfit)
                ),
                blockNumber: 1,
                txHash: bytes32(uint256(8)),
                logIndex: 0
            })
        );

        assertTrue(vmReactive.subscribedPairs(pair));
        assertEq(vmReactive.pairOrderCount(pair), 1);

        vmReactive.react(_buildLifecycleLog(vmReactive.ORDER_PAUSED_TOPIC_0(), 1, 0));
        assertEq(uint8(_trackedStatusFor(vmReactive, 1)), uint8(OnchainClawTpSlReactive.OrderStatus.Paused));
        assertEq(vmReactive.pairOrderCount(pair), 0);
        assertFalse(vmReactive.subscribedPairs(pair));

        vmReactive.react(_buildLifecycleLog(vmReactive.ORDER_RESUMED_TOPIC_0(), 1, 0));
        assertEq(uint8(_trackedStatusFor(vmReactive, 1)), uint8(OnchainClawTpSlReactive.OrderStatus.Active));
        assertEq(vmReactive.pairOrderCount(pair), 1);
        assertTrue(vmReactive.subscribedPairs(pair));

        vmReactive.react(_buildLifecycleLog(vmReactive.ORDER_CANCELLED_TOPIC_0(), 1, 0));
        assertEq(uint8(_trackedStatusFor(vmReactive, 1)), uint8(OnchainClawTpSlReactive.OrderStatus.Cancelled));
        assertEq(vmReactive.pairOrderCount(pair), 0);
        assertFalse(vmReactive.subscribedPairs(pair));
    }

    function testUnknownLifecycleEventsAreIgnored() public {
        IReactive.LogRecord memory cancelledLog = _buildLifecycleLog(reactiveContract.ORDER_CANCELLED_TOPIC_0(), 999, 0);

        vm.prank(reactiveNetwork);
        reactiveContract.react(cancelledLog);

        (uint256 id, address trackedPair,,,,,) = reactiveContract.trackedOrders(999);
        assertEq(id, 0);
        assertEq(trackedPair, address(0));
        assertEq(reactiveContract.pairOrderCount(pair), 0);
        assertFalse(reactiveContract.subscribedPairs(pair));
    }

    function testTriggerCooldownSkipsImmediateRetrigger() public {
        OnchainClawTpSlReactive vmReactive = new OnchainClawTpSlReactive(
            address(service), reactiveNetwork, callbackContract, ORIGIN_CHAIN_ID, REACTIVE_CHAIN_ID, true
        );

        vmReactive.react(
            IReactive.LogRecord({
                chainId: ORIGIN_CHAIN_ID,
                _contract: callbackContract,
                topic_0: vmReactive.ORDER_CREATED_TOPIC_0(),
                topic_1: uint256(uint160(pair)),
                topic_2: 9,
                topic_3: 0,
                data: abi.encode(
                    true,
                    address(0x1),
                    address(0x2),
                    5e18,
                    1e18,
                    COEFFICIENT,
                    15e17,
                    uint8(OnchainClawTpSlReactive.OrderType.TakeProfit)
                ),
                blockNumber: 1,
                txHash: bytes32(uint256(11)),
                logIndex: 0
            })
        );

        IReactive.LogRecord memory syncLog = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN_ID,
            _contract: pair,
            topic_0: vmReactive.SYNC_TOPIC_0(),
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint112(1e18), uint112(2e18)),
            blockNumber: 2,
            txHash: bytes32(uint256(12)),
            logIndex: 0
        });

        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");

        vm.recordLogs();
        vmReactive.react(syncLog);
        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        assertEq(_countLogsWithTopic(firstLogs, callbackTopic), 1);

        vm.recordLogs();
        vmReactive.react(syncLog);
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();
        assertEq(_countLogsWithTopic(secondLogs, callbackTopic), 0);
    }

    function testRepeatedTriggeringEventuallyFailsAndUntracks() public {
        OnchainClawTpSlReactive vmReactive = new OnchainClawTpSlReactive(
            address(service), reactiveNetwork, callbackContract, ORIGIN_CHAIN_ID, REACTIVE_CHAIN_ID, true
        );

        vmReactive.react(
            IReactive.LogRecord({
                chainId: ORIGIN_CHAIN_ID,
                _contract: callbackContract,
                topic_0: vmReactive.ORDER_CREATED_TOPIC_0(),
                topic_1: uint256(uint160(pair)),
                topic_2: 7,
                topic_3: 0,
                data: abi.encode(
                    true,
                    address(0x1),
                    address(0x2),
                    5e18,
                    1e18,
                    COEFFICIENT,
                    15e17,
                    uint8(OnchainClawTpSlReactive.OrderType.TakeProfit)
                ),
                blockNumber: 1,
                txHash: bytes32(uint256(9)),
                logIndex: 0
            })
        );

        IReactive.LogRecord memory syncLog = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN_ID,
            _contract: pair,
            topic_0: vmReactive.SYNC_TOPIC_0(),
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint112(1e18), uint112(2e18)),
            blockNumber: 2,
            txHash: bytes32(uint256(10)),
            logIndex: 0
        });

        for (uint256 i = 0; i < 5;) {
            vmReactive.react(syncLog);
            vm.warp(block.timestamp + vmReactive.TRIGGER_COOLDOWN() + 1);
            unchecked {
                ++i;
            }
        }

        vmReactive.react(syncLog);

        (,,,,,, OnchainClawTpSlReactive.OrderStatus status) = vmReactive.trackedOrders(7);

        assertEq(uint8(status), uint8(OnchainClawTpSlReactive.OrderStatus.Failed));
        assertEq(vmReactive.pairOrderCount(pair), 0);
        assertFalse(vmReactive.subscribedPairs(pair));
    }

    function _countLogsWithTopic(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 count) {
        uint256 totalLogs = logs.length;
        for (uint256 index = 0; index < totalLogs;) {
            if (logs[index].topics.length > 0 && logs[index].topics[0] == topic) {
                count += 1;
            }
            unchecked {
                ++index;
            }
        }
    }
}

contract AbstractAccessSemanticsTest is Test {
    address internal reactiveNetwork = address(0xB0B);
    address internal callbackSender = address(0xCA11);

    function testAbstractReactiveHelpersReflectAuthorizationModel() public {
        AbstractReactiveHarness liveHarness = new AbstractReactiveHarness(address(0), reactiveNetwork, false);
        AbstractReactiveHarness vmHarness = new AbstractReactiveHarness(address(0), reactiveNetwork, true);

        assertTrue(liveHarness.isReactiveCallerAuthorized(reactiveNetwork));
        assertFalse(liveHarness.isReactiveCallerAuthorized(address(this)));
        assertTrue(liveHarness.isReactiveNetworkCaller(reactiveNetwork));
        assertFalse(liveHarness.isReactiveNetworkCaller(address(this)));
        assertTrue(vmHarness.isReactiveCallerAuthorized(address(this)));

        vm.prank(reactiveNetwork);
        assertTrue(liveHarness.runVmOnly());
        vm.prank(reactiveNetwork);
        assertTrue(liveHarness.runRnOnly());

        vm.expectRevert(abi.encodeWithSelector(AbstractReactive.UnauthorizedReactiveCaller.selector, address(this)));
        liveHarness.runVmOnly();

        assertTrue(vmHarness.runVmOnly());
        assertTrue(vmHarness.runRnOnly());
    }

    function testAbstractCallbackHelpersReflectAuthorizationModel() public {
        AbstractCallbackHarness liveHarness = new AbstractCallbackHarness(callbackSender, false);
        AbstractCallbackHarness vmHarness = new AbstractCallbackHarness(callbackSender, true);

        assertTrue(liveHarness.isCallbackCallerAuthorized(callbackSender));
        assertFalse(liveHarness.isCallbackCallerAuthorized(address(this)));
        assertTrue(liveHarness.isDirectCallbackSender(callbackSender));
        assertFalse(liveHarness.isDirectCallbackSender(address(this)));
        assertTrue(vmHarness.isCallbackCallerAuthorized(address(this)));

        vm.prank(callbackSender);
        assertTrue(liveHarness.runAuthorizedOnly());

        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.UnauthorizedCallbackCaller.selector, address(this)));
        liveHarness.runAuthorizedOnly();

        assertTrue(vmHarness.runAuthorizedOnly());
    }
}
