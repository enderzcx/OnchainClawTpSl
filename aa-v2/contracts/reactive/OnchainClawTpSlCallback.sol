// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./lib/AbstractCallback.sol";

contract OnchainClawTpSlCallback is AbstractCallback {
    using SafeERC20 for IERC20;
    uint256 private constant NO_SIBLING = 0;
    uint256 private constant EXECUTION_COOLDOWN = 30;
    uint8 private constant MAX_EXECUTION_ATTEMPTS = 3;

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

    struct Order {
        uint256 bracketGroupRef;
        address owner;
        address pair;
        address tokenSell;
        address tokenBuy;
        uint256 amount;
        uint256 minAmountOut;
        uint256 coefficient;
        uint256 threshold;
        uint40 lastExecutionAttempt;
        uint8 executionAttempts;
        bool sellToken0;
        OrderType orderType;
        OrderStatus status;
    }

    struct BracketGroupData {
        address owner;
        address pair;
        address tokenSell;
        address tokenBuy;
        uint256 amount;
        uint256 coefficient;
        bool sellToken0;
    }

    event OrderCreated(
        address indexed pair,
        uint256 indexed orderId,
        bool sellToken0,
        address tokenSell,
        address tokenBuy,
        uint256 amount,
        uint256 minAmountOut,
        uint256 coefficient,
        uint256 threshold,
        uint8 orderType
    );

    event OrderExecuted(address indexed pair, uint256 indexed orderId, uint256 amountIn, uint256 amountOut);

    event OrderCancelled(uint256 indexed orderId);
    event OrderPaused(uint256 indexed orderId);
    event OrderResumed(uint256 indexed orderId);
    event OrderFailed(uint256 indexed orderId);
    event BracketGroupCreated(
        uint256 indexed bracketGroupId,
        uint256 indexed stopLossOrderId,
        uint256 indexed takeProfitOrderId,
        address owner,
        address pair
    );

    address public immutable rescueAdmin;
    address public immutable router;
    uint256 public nextOrderId;
    uint256 public nextBracketGroupId;
    mapping(uint256 => Order) private _orders;
    mapping(uint256 => BracketGroupData) private _bracketGroups;
    mapping(uint256 => uint256) public siblingOrders;

    constructor(address authorizedCallbackSender, address routerAddress, bool vmMode)
        payable
        AbstractCallback(authorizedCallbackSender, vmMode)
    {
        require(routerAddress != address(0), "router_required");
        rescueAdmin = msg.sender;
        router = routerAddress;
    }

    modifier onlyOrderOwner(uint256 orderId) {
        require(msg.sender == _orderOwner(orderId), "not_order_owner");
        _;
    }

    function orders(uint256 orderId)
        external
        view
        returns (
            uint256 id,
            address owner,
            address pair,
            address tokenSell,
            address tokenBuy,
            bool sellToken0,
            uint256 amount,
            uint256 minAmountOut,
            uint256 coefficient,
            uint256 threshold,
            OrderType orderType,
            OrderStatus status
        )
    {
        Order storage order = _orders[orderId];
        if (!_orderExists(orderId)) {
            return (
                0,
                address(0),
                address(0),
                address(0),
                address(0),
                false,
                0,
                0,
                0,
                0,
                OrderType.StopLoss,
                OrderStatus.Active
            );
        }

        (
            address resolvedOwner,
            address resolvedPair,
            address resolvedTokenSell,
            address resolvedTokenBuy,
            bool resolvedSellToken0,
            uint256 resolvedAmount,
            uint256 resolvedCoefficient
        ) = _resolveBracketGroupData(order);

        return (
            orderId,
            resolvedOwner,
            resolvedPair,
            resolvedTokenSell,
            resolvedTokenBuy,
            resolvedSellToken0,
            resolvedAmount,
            order.minAmountOut,
            resolvedCoefficient,
            order.threshold,
            order.orderType,
            order.status
        );
    }

    function bracketGroupIdForOrder(uint256 orderId) external view returns (bool exists, uint256 bracketGroupId) {
        uint256 bracketGroupRef = _orders[orderId].bracketGroupRef;
        if (bracketGroupRef == 0) {
            return (false, 0);
        }

        return (true, bracketGroupRef - 1);
    }

    function isBracketOrder(uint256 orderId) external view returns (bool) {
        return _orders[orderId].bracketGroupRef != 0;
    }

    function bracketGroup(uint256 bracketGroupId)
        external
        view
        returns (
            address owner,
            address pair,
            address tokenSell,
            address tokenBuy,
            bool sellToken0,
            uint256 amount,
            uint256 coefficient
        )
    {
        BracketGroupData storage bracketGroupData = _bracketGroups[bracketGroupId];
        require(bracketGroupData.owner != address(0), "bracket_group_missing");

        return (
            bracketGroupData.owner,
            bracketGroupData.pair,
            bracketGroupData.tokenSell,
            bracketGroupData.tokenBuy,
            bracketGroupData.sellToken0,
            bracketGroupData.amount,
            bracketGroupData.coefficient
        );
    }

    modifier orderExists(uint256 orderId) {
        require(_orderExists(orderId), "order_missing");
        _;
    }

    modifier rescueAdminOnly() {
        require(msg.sender == rescueAdmin, "rescue_admin_only");
        _;
    }

    function createOrder(
        address pair,
        bool sellToken0,
        uint256 amount,
        uint256 minAmountOut,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    ) external returns (uint256 orderId) {
        require(pair != address(0), "pair_required");
        require(amount > 0, "amount_required");
        require(coefficient > 0, "coefficient_required");
        require(threshold > 0, "threshold_required");

        (address tokenSell, address tokenBuy) = _resolveOrderTokens(pair, sellToken0);
        _requirePairLiquidity(pair);
        _requireAllowance(tokenSell, msg.sender, amount);

        orderId = _storeOrder(
            msg.sender, pair, tokenSell, tokenBuy, sellToken0, amount, minAmountOut, coefficient, threshold, orderType
        );
    }

    function createBracketOrders(
        address pair,
        bool sellToken0,
        uint256 amount,
        uint256 coefficient,
        uint256 stopLossMinAmountOut,
        uint256 stopLossThreshold,
        uint256 takeProfitMinAmountOut,
        uint256 takeProfitThreshold
    ) external returns (uint256 stopLossOrderId, uint256 takeProfitOrderId) {
        require(pair != address(0), "pair_required");
        require(amount > 0, "amount_required");
        require(coefficient > 0, "coefficient_required");
        require(stopLossThreshold > 0, "stop_loss_threshold_required");
        require(takeProfitThreshold > 0, "take_profit_threshold_required");

        (address tokenSell, address tokenBuy) = _resolveOrderTokens(pair, sellToken0);
        _requirePairLiquidity(pair);
        _requireAllowance(tokenSell, msg.sender, amount);

        uint256 bracketGroupId = nextBracketGroupId;
        nextBracketGroupId = bracketGroupId + 1;

        _bracketGroups[bracketGroupId] = BracketGroupData({
            owner: msg.sender,
            pair: pair,
            tokenSell: tokenSell,
            tokenBuy: tokenBuy,
            amount: amount,
            coefficient: coefficient,
            sellToken0: sellToken0
        });

        stopLossOrderId = nextOrderId;
        takeProfitOrderId = stopLossOrderId + 1;
        nextOrderId = stopLossOrderId + 2;

        _storeBracketLeg(stopLossOrderId, bracketGroupId, stopLossMinAmountOut, stopLossThreshold, OrderType.StopLoss);
        _storeBracketLeg(
            takeProfitOrderId, bracketGroupId, takeProfitMinAmountOut, takeProfitThreshold, OrderType.TakeProfit
        );
        siblingOrders[stopLossOrderId] = takeProfitOrderId + 1;
        siblingOrders[takeProfitOrderId] = stopLossOrderId + 1;

        emit BracketGroupCreated(bracketGroupId, stopLossOrderId, takeProfitOrderId, msg.sender, pair);
    }

    function cancelOrder(uint256 orderId) external orderExists(orderId) onlyOrderOwner(orderId) {
        Order storage order = _orders[orderId];
        require(order.status == OrderStatus.Active || order.status == OrderStatus.Paused, "order_not_cancellable");
        order.status = OrderStatus.Cancelled;
        emit OrderCancelled(orderId);
    }

    function pauseOrder(uint256 orderId) external orderExists(orderId) onlyOrderOwner(orderId) {
        Order storage order = _orders[orderId];
        require(order.status == OrderStatus.Active, "order_not_active");
        order.status = OrderStatus.Paused;
        emit OrderPaused(orderId);
    }

    function resumeOrder(uint256 orderId) external orderExists(orderId) onlyOrderOwner(orderId) {
        Order storage order = _orders[orderId];
        require(order.status == OrderStatus.Paused, "order_not_paused");
        order.status = OrderStatus.Active;
        emit OrderResumed(orderId);
    }

    function executeOrder(address, uint256 orderId) external authorizedSenderOnly orderExists(orderId) {
        Order storage order = _orders[orderId];
        require(order.status == OrderStatus.Active, "order_not_active");

        (
            address resolvedOwner,
            address resolvedPair,
            address resolvedTokenSell,
            address resolvedTokenBuy,
            bool resolvedSellToken0,
            uint256 resolvedAmount,
            uint256 resolvedCoefficient
        ) = _resolveBracketGroupData(order);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(resolvedPair).getReserves();
        require(
            _priceConditionMet(
                resolvedSellToken0, reserve0, reserve1, resolvedCoefficient, order.threshold, order.orderType
            ),
            "price_not_reached"
        );

        if (
            order.lastExecutionAttempt > 0 && block.timestamp < uint256(order.lastExecutionAttempt) + EXECUTION_COOLDOWN
        ) {
            return;
        }
        if (order.executionAttempts >= MAX_EXECUTION_ATTEMPTS) {
            _failOrder(orderId, order);
            return;
        }

        order.lastExecutionAttempt = uint40(block.timestamp);
        order.executionAttempts += 1;

        uint256 executeAmount = resolvedAmount;
        uint256 ownerBalance = IERC20(resolvedTokenSell).balanceOf(resolvedOwner);
        if (ownerBalance < executeAmount) {
            executeAmount = ownerBalance;
        }
        uint256 ownerAllowance = IERC20(resolvedTokenSell).allowance(resolvedOwner, address(this));
        if (ownerAllowance < executeAmount) {
            executeAmount = ownerAllowance;
        }
        if (executeAmount == 0) {
            _failOrder(orderId, order);
            return;
        }

        IERC20(resolvedTokenSell).safeTransferFrom(resolvedOwner, address(this), executeAmount);
        IERC20(resolvedTokenSell).forceApprove(router, executeAmount);

        address[] memory path = new address[](2);
        path[0] = resolvedTokenSell;
        path[1] = resolvedTokenBuy;

        uint256 effectiveMinAmountOut = Math.mulDiv(order.minAmountOut, executeAmount, resolvedAmount);
        uint256[] memory amounts = IUniswapV2Router02(router)
            .swapExactTokensForTokens(executeAmount, effectiveMinAmountOut, path, address(this), block.timestamp + 300);

        uint256 amountOut = amounts[amounts.length - 1];
        IERC20(resolvedTokenBuy).safeTransfer(resolvedOwner, amountOut);
        order.status = OrderStatus.Executed;
        _cancelSiblingOrder(orderId);

        emit OrderExecuted(resolvedPair, orderId, executeAmount, amountOut);
    }

    function _cancelSiblingOrder(uint256 executedOrderId) internal {
        uint256 siblingReference = siblingOrders[executedOrderId];
        if (siblingReference == NO_SIBLING) {
            return;
        }

        uint256 siblingOrderId = siblingReference - 1;
        Order storage sibling = _orders[siblingOrderId];
        if (sibling.status == OrderStatus.Active || sibling.status == OrderStatus.Paused) {
            sibling.status = OrderStatus.Cancelled;
            emit OrderCancelled(siblingOrderId);
        }

        delete siblingOrders[executedOrderId];
        delete siblingOrders[siblingOrderId];
    }

    function _resolveOrderTokens(address pair, bool sellToken0)
        internal
        view
        returns (address tokenSell, address tokenBuy)
    {
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        require(token0 != address(0) && token1 != address(0), "invalid_pair");
        tokenSell = sellToken0 ? token0 : token1;
        tokenBuy = sellToken0 ? token1 : token0;
    }

    function _requireAllowance(address tokenSell, address owner, uint256 amount) internal view {
        require(IERC20(tokenSell).allowance(owner, address(this)) >= amount, "insufficient_allowance");
    }

    function _requirePairLiquidity(address pair) internal view {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "pair_has_no_liquidity");
    }

    function _orderExists(uint256 orderId) internal view returns (bool) {
        Order storage order = _orders[orderId];
        return order.owner != address(0) || order.bracketGroupRef != 0;
    }

    function _orderOwner(uint256 orderId) internal view returns (address) {
        Order storage order = _orders[orderId];
        uint256 bracketGroupRef = order.bracketGroupRef;
        if (bracketGroupRef == 0) {
            return order.owner;
        }

        return _bracketGroups[bracketGroupRef - 1].owner;
    }

    function _failOrder(uint256 orderId, Order storage order) internal {
        order.status = OrderStatus.Failed;
        emit OrderFailed(orderId);

        uint256 siblingReference = siblingOrders[orderId];
        if (siblingReference == NO_SIBLING) {
            return;
        }

        uint256 siblingOrderId = siblingReference - 1;
        delete siblingOrders[orderId];
        delete siblingOrders[siblingOrderId];
    }

    function _storeOrder(
        address owner,
        address pair,
        address tokenSell,
        address tokenBuy,
        bool sellToken0,
        uint256 amount,
        uint256 minAmountOut,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    ) internal returns (uint256 orderId) {
        orderId = nextOrderId;
        nextOrderId += 1;

        Order storage order = _orders[orderId];
        order.owner = owner;
        order.pair = pair;
        order.tokenSell = tokenSell;
        order.tokenBuy = tokenBuy;
        order.amount = amount;
        order.minAmountOut = minAmountOut;
        order.coefficient = coefficient;
        order.threshold = threshold;
        order.sellToken0 = sellToken0;
        order.orderType = orderType;
        order.status = OrderStatus.Active;

        emit OrderCreated(
            pair,
            orderId,
            sellToken0,
            tokenSell,
            tokenBuy,
            amount,
            minAmountOut,
            coefficient,
            threshold,
            uint8(orderType)
        );
    }

    function _storeBracketLeg(
        uint256 orderId,
        uint256 bracketGroupId,
        uint256 minAmountOut,
        uint256 threshold,
        OrderType orderType
    ) internal {
        Order storage order = _orders[orderId];
        order.bracketGroupRef = bracketGroupId + 1;
        order.minAmountOut = minAmountOut;
        order.threshold = threshold;
        order.orderType = orderType;
        order.status = OrderStatus.Active;

        BracketGroupData storage bracketGroupData = _bracketGroups[bracketGroupId];
        emit OrderCreated(
            bracketGroupData.pair,
            orderId,
            bracketGroupData.sellToken0,
            bracketGroupData.tokenSell,
            bracketGroupData.tokenBuy,
            bracketGroupData.amount,
            minAmountOut,
            bracketGroupData.coefficient,
            threshold,
            uint8(orderType)
        );
    }

    function _resolveBracketGroupData(Order storage order)
        internal
        view
        returns (
            address owner,
            address pair,
            address tokenSell,
            address tokenBuy,
            bool sellToken0,
            uint256 amount,
            uint256 coefficient
        )
    {
        uint256 bracketGroupRef = order.bracketGroupRef;
        if (bracketGroupRef == 0) {
            return (
                order.owner,
                order.pair,
                order.tokenSell,
                order.tokenBuy,
                order.sellToken0,
                order.amount,
                order.coefficient
            );
        }

        BracketGroupData storage bracketGroupData = _bracketGroups[bracketGroupRef - 1];
        return (
            bracketGroupData.owner,
            bracketGroupData.pair,
            bracketGroupData.tokenSell,
            bracketGroupData.tokenBuy,
            bracketGroupData.sellToken0,
            bracketGroupData.amount,
            bracketGroupData.coefficient
        );
    }

    function rescueETH(uint256 amount) external rescueAdminOnly {
        require(amount > 0, "amount_required");
        require(amount <= address(this).balance, "insufficient_eth_balance");

        (bool success,) = payable(rescueAdmin).call{value: amount}("");
        require(success, "eth_transfer_failed");
    }

    function rescueAllETH() external rescueAdminOnly {
        uint256 balance = address(this).balance;
        require(balance > 0, "no_eth_to_rescue");

        (bool success,) = payable(rescueAdmin).call{value: balance}("");
        require(success, "eth_transfer_failed");
    }

    function rescueERC20(address token, uint256 amount) external rescueAdminOnly {
        require(amount > 0, "amount_required");
        IERC20(token).safeTransfer(rescueAdmin, amount);
    }

    function rescueAllERC20(address token) external rescueAdminOnly {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "no_tokens_to_rescue");
        IERC20(token).safeTransfer(rescueAdmin, balance);
    }

    function _priceConditionMet(
        bool sellToken0,
        uint112 reserve0,
        uint112 reserve1,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    ) internal pure returns (bool) {
        uint256 currentPrice = _currentPrice(sellToken0, reserve0, reserve1, coefficient);
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
