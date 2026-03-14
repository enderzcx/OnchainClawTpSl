// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "reactive/interfaces/IUniswapV2Pair.sol";
import "reactive/interfaces/IUniswapV2Router02.sol";
import "reactive/lib/AbstractCallback.sol";

contract LegacyOnchainClawTpSlCallback is AbstractCallback {
    using SafeERC20 for IERC20;

    uint256 private constant NO_SIBLING = 0;

    enum OrderType {
        StopLoss,
        TakeProfit
    }

    enum OrderStatus {
        Active,
        Cancelled,
        Executed
    }

    struct Order {
        address owner;
        address pair;
        address tokenSell;
        address tokenBuy;
        bool sellToken0;
        uint256 amount;
        uint256 minAmountOut;
        uint256 coefficient;
        uint256 threshold;
        OrderType orderType;
        OrderStatus status;
    }

    address public immutable router;
    uint256 public nextOrderId;
    mapping(uint256 => Order) private _orders;
    mapping(uint256 => uint256) public siblingOrders;

    constructor(address authorizedCallbackSender, address routerAddress, bool vmMode)
        payable
        AbstractCallback(authorizedCallbackSender, vmMode)
    {
        require(routerAddress != address(0), "router_required");
        router = routerAddress;
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
        _requireAllowance(tokenSell, msg.sender, amount);

        stopLossOrderId = _storeOrder(
            msg.sender,
            pair,
            tokenSell,
            tokenBuy,
            sellToken0,
            amount,
            stopLossMinAmountOut,
            coefficient,
            stopLossThreshold,
            OrderType.StopLoss
        );
        takeProfitOrderId = _storeOrder(
            msg.sender,
            pair,
            tokenSell,
            tokenBuy,
            sellToken0,
            amount,
            takeProfitMinAmountOut,
            coefficient,
            takeProfitThreshold,
            OrderType.TakeProfit
        );
        siblingOrders[stopLossOrderId] = takeProfitOrderId + 1;
        siblingOrders[takeProfitOrderId] = stopLossOrderId + 1;
    }

    function executeOrder(address, uint256 orderId) external authorizedSenderOnly {
        Order storage order = _orders[orderId];
        require(order.status == OrderStatus.Active, "order_not_active");

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(order.pair).getReserves();
        require(
            _priceConditionMet(
                order.sellToken0, reserve0, reserve1, order.coefficient, order.threshold, order.orderType
            ),
            "price_not_reached"
        );

        order.status = OrderStatus.Executed;
        IERC20(order.tokenSell).safeTransferFrom(order.owner, address(this), order.amount);
        IERC20(order.tokenSell).forceApprove(router, order.amount);

        address[] memory path = new address[](2);
        path[0] = order.tokenSell;
        path[1] = order.tokenBuy;

        uint256[] memory amounts = IUniswapV2Router02(router)
            .swapExactTokensForTokens(order.amount, order.minAmountOut, path, address(this), block.timestamp + 300);

        uint256 amountOut = amounts[amounts.length - 1];
        IERC20(order.tokenBuy).safeTransfer(order.owner, amountOut);
        _cancelSiblingOrder(orderId);
    }

    function _cancelSiblingOrder(uint256 executedOrderId) internal {
        uint256 siblingReference = siblingOrders[executedOrderId];
        if (siblingReference == NO_SIBLING) {
            return;
        }

        uint256 siblingOrderId = siblingReference - 1;
        Order storage sibling = _orders[siblingOrderId];
        if (sibling.status == OrderStatus.Active) {
            sibling.status = OrderStatus.Cancelled;
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
        tokenSell = sellToken0 ? token0 : token1;
        tokenBuy = sellToken0 ? token1 : token0;
    }

    function _requireAllowance(address tokenSell, address owner, uint256 amount) internal view {
        require(IERC20(tokenSell).allowance(owner, address(this)) >= amount, "insufficient_allowance");
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

        _orders[orderId] = Order({
            owner: owner,
            pair: pair,
            tokenSell: tokenSell,
            tokenBuy: tokenBuy,
            sellToken0: sellToken0,
            amount: amount,
            minAmountOut: minAmountOut,
            coefficient: coefficient,
            threshold: threshold,
            orderType: orderType,
            status: OrderStatus.Active
        });
    }

    function _priceConditionMet(
        bool sellToken0,
        uint112 reserve0,
        uint112 reserve1,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    ) internal pure returns (bool) {
        if (reserve0 == 0 || reserve1 == 0) {
            return false;
        }

        uint256 currentPrice = sellToken0
            ? Math.mulDiv(uint256(reserve1), coefficient, uint256(reserve0))
            : Math.mulDiv(uint256(reserve0), coefficient, uint256(reserve1));

        if (orderType == OrderType.StopLoss) {
            return currentPrice <= threshold;
        }
        return currentPrice >= threshold;
    }
}
