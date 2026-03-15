// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../official-lib/abstract-base/AbstractCallback.sol";
import "./RescuableBase.sol";

contract BaselineStopTakeProfitCallback is AbstractCallback, RescuableBase {
    using SafeERC20 for IERC20;

    event StopOrderCreated(
        address indexed pair,
        uint256 indexed orderId,
        bool sellToken0,
        address tokenSell,
        address tokenBuy,
        uint256 amount,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    );
    event StopOrderExecuted(
        address indexed pair,
        uint256 indexed orderId,
        address tokenSell,
        address tokenBuy,
        uint256 amountIn,
        uint256 amountOut
    );
    event StopOrderCancelled(uint256 indexed orderId);
    event StopOrderPaused(uint256 indexed orderId);
    event StopOrderResumed(uint256 indexed orderId);

    error OrderNotActive(uint256 orderId);
    error PriceConditionNotMet(uint256 orderId);
    error MaxRetriesExceeded(uint256 orderId);
    error InsufficientBalanceOrAllowance(uint256 orderId);

    enum OrderStatus {
        Active,
        Paused,
        Cancelled,
        Executed,
        Failed
    }

    enum OrderType {
        StopLoss,
        TakeProfit
    }

    struct StopOrder {
        uint256 id;
        address pair;
        address tokenSell;
        address tokenBuy;
        uint256 amount;
        bool sellToken0;
        uint256 coefficient;
        uint256 threshold;
        OrderType orderType;
        OrderStatus status;
        uint256 createdAt;
        uint256 executedAt;
        uint8 retryCount;
        uint256 lastExecutionAttempt;
    }

    address public immutable owner;
    IUniswapV2Router02 public immutable router;

    StopOrder[] public stopOrders;

    uint256 private constant DEADLINE_OFFSET = 300;
    uint8 private constant MAX_RETRIES = 3;
    uint256 private constant RETRY_COOLDOWN = 30;
    uint256 private constant MIN_AMOUNT = 1000;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner_only");
        _;
    }

    modifier validOrder(uint256 orderId) {
        require(orderId < stopOrders.length, "order_missing");
        _;
    }

    function nextOrderId() external view returns (uint256) {
        return stopOrders.length;
    }

    constructor(address ownerAddress, address callbackSender, address routerAddress)
        payable
        AbstractCallback(callbackSender)
    {
        require(ownerAddress != address(0), "owner_required");
        require(routerAddress != address(0), "router_required");
        owner = ownerAddress;
        router = IUniswapV2Router02(routerAddress);
    }

    function createStopOrder(
        address pair,
        bool sellToken0,
        uint256 amount,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    ) external onlyOwner returns (uint256 orderId) {
        require(pair != address(0), "pair_required");
        require(amount >= MIN_AMOUNT, "amount_too_small");
        require(coefficient > 0 && threshold > 0, "invalid_price_params");

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        address tokenSell = sellToken0 ? token0 : token1;
        address tokenBuy = sellToken0 ? token1 : token0;

        require(IERC20(tokenSell).balanceOf(owner) >= amount, "insufficient_balance");
        require(IERC20(tokenSell).allowance(owner, address(this)) >= amount, "insufficient_allowance");

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "pair_has_no_liquidity");

        orderId = stopOrders.length;
        stopOrders.push(
            StopOrder({
                id: orderId,
                pair: pair,
                tokenSell: tokenSell,
                tokenBuy: tokenBuy,
                amount: amount,
                sellToken0: sellToken0,
                coefficient: coefficient,
                threshold: threshold,
                orderType: orderType,
                status: OrderStatus.Active,
                createdAt: block.timestamp,
                executedAt: 0,
                retryCount: 0,
                lastExecutionAttempt: 0
            })
        );

        emit StopOrderCreated(pair, orderId, sellToken0, tokenSell, tokenBuy, amount, coefficient, threshold, orderType);
    }

    function executeStopOrder(address, uint256 orderId)
        external
        authorizedSenderOnly
        validOrder(orderId)
    {
        StopOrder storage order = stopOrders[orderId];
        if (order.status != OrderStatus.Active) {
            revert OrderNotActive(orderId);
        }

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(order.pair).getReserves();
        if (!_isPriceConditionMet(order.sellToken0, reserve0, reserve1, order.coefficient, order.threshold, order.orderType)) {
            revert PriceConditionNotMet(orderId);
        }

        if (order.lastExecutionAttempt > 0 && block.timestamp < order.lastExecutionAttempt + RETRY_COOLDOWN) {
            return;
        }
        if (order.retryCount >= MAX_RETRIES) {
            order.status = OrderStatus.Failed;
            revert MaxRetriesExceeded(orderId);
        }

        order.lastExecutionAttempt = block.timestamp;
        order.retryCount += 1;

        uint256 ownerBalance = IERC20(order.tokenSell).balanceOf(owner);
        uint256 ownerAllowance = IERC20(order.tokenSell).allowance(owner, address(this));

        uint256 executeAmount = order.amount;
        if (ownerBalance < executeAmount) {
            executeAmount = ownerBalance;
        }
        if (ownerAllowance < executeAmount) {
            executeAmount = ownerAllowance;
        }
        if (executeAmount < MIN_AMOUNT) {
            order.status = OrderStatus.Failed;
            revert InsufficientBalanceOrAllowance(orderId);
        }

        uint256 amountOut = _executeSwap(order, executeAmount);
        order.status = OrderStatus.Executed;
        order.executedAt = block.timestamp;

        emit StopOrderExecuted(order.pair, orderId, order.tokenSell, order.tokenBuy, executeAmount, amountOut);
    }

    function cancelStopOrder(uint256 orderId) external onlyOwner validOrder(orderId) {
        StopOrder storage order = stopOrders[orderId];
        require(order.status == OrderStatus.Active || order.status == OrderStatus.Paused, "cannot_cancel");
        order.status = OrderStatus.Cancelled;
        emit StopOrderCancelled(orderId);
    }

    function pauseStopOrder(uint256 orderId) external onlyOwner validOrder(orderId) {
        StopOrder storage order = stopOrders[orderId];
        require(order.status == OrderStatus.Active, "order_not_active");
        order.status = OrderStatus.Paused;
        emit StopOrderPaused(orderId);
    }

    function resumeStopOrder(uint256 orderId) external onlyOwner validOrder(orderId) {
        StopOrder storage order = stopOrders[orderId];
        require(order.status == OrderStatus.Paused, "order_not_paused");
        order.status = OrderStatus.Active;
        emit StopOrderResumed(orderId);
    }

    function getAllOrders() external view returns (uint256[] memory allOrderIds) {
        uint256 totalOrders = stopOrders.length;
        allOrderIds = new uint256[](totalOrders);
        for (uint256 i = 0; i < totalOrders; ) {
            allOrderIds[i] = i;
            unchecked {
                ++i;
            }
        }
    }

    function getActiveOrders() external view returns (uint256[] memory activeOrders) {
        uint256 totalOrders = stopOrders.length;
        uint256 activeCount = 0;
        for (uint256 i = 0; i < totalOrders; ) {
            if (stopOrders[i].status == OrderStatus.Active) {
                activeCount += 1;
            }
            unchecked {
                ++i;
            }
        }
        activeOrders = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < totalOrders; ) {
            if (stopOrders[i].status == OrderStatus.Active) {
                activeOrders[index] = i;
                index += 1;
            }
            unchecked {
                ++i;
            }
        }
    }

    function getCurrentPrice(address pair, bool sellToken0) external view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "no_liquidity");
        if (sellToken0) {
            return _quote(1, uint256(reserve0), uint256(reserve1));
        }
        return _quote(1, uint256(reserve1), uint256(reserve0));
    }

    function _executeSwap(StopOrder memory order, uint256 amount) internal returns (uint256 amountOut) {
        IERC20 tokenSell = IERC20(order.tokenSell);
        IERC20 tokenBuy = IERC20(order.tokenBuy);

        tokenSell.safeTransferFrom(owner, address(this), amount);
        tokenSell.forceApprove(address(router), amount);

        address[] memory path = new address[](2);
        path[0] = order.tokenSell;
        path[1] = order.tokenBuy;

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + DEADLINE_OFFSET
        );

        amountOut = amounts[1];
        tokenBuy.safeTransfer(owner, amountOut);
    }

    function _quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "insufficient_amount");
        require(reserveA > 0 && reserveB > 0, "insufficient_liquidity");
        amountB = (amountA * reserveB) / reserveA;
    }

    function _isPriceConditionMet(
        bool sellToken0,
        uint112 reserve0,
        uint112 reserve1,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType
    ) internal pure returns (bool) {
        uint256 currentPrice = sellToken0
            ? Math.mulDiv(uint256(reserve1), coefficient, uint256(reserve0))
            : Math.mulDiv(uint256(reserve0), coefficient, uint256(reserve1));

        if (orderType == OrderType.StopLoss) {
            return currentPrice <= threshold;
        }
        return currentPrice >= threshold;
    }

    function _rescueRecipient() internal view override returns (address) {
        return owner;
    }

    function rescueETH(uint256 amount) external override onlyOwner {
        require(amount > 0, "amount_required");
        _rescueETH(amount);
    }

    function rescueAllETH() external override onlyOwner {
        _rescueETH(0);
    }

    function rescueERC20(address token, uint256 amount) external override onlyOwner {
        require(amount > 0, "amount_required");
        _rescueERC20(token, amount);
    }

    function rescueAllERC20(address token) external override onlyOwner {
        _rescueERC20(token, 0);
    }
}
