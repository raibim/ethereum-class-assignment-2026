// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title OrderBook - on-chain order book for PNPT (tokenA) and FNBT (tokenB)
/// @dev All order sizes are in PNPT (tokenA). Price is always FNBT per 1 PNPT.
contract OrderBook {
    using SafeERC20 for IERC20;

    IERC20 public immutable tokenA; // PNPT — asset being bought/sold
    IERC20 public immutable tokenB; // FNBT — quote / payment token

    /// @dev Buy = maker pays FNBT and receives PNPT; Sell = maker pays PNPT and receives FNBT.
    enum Side {
        Buy,
        Sell
    }

    struct Order {
        address maker;           // account that placed the order (only they can cancel)
        Side side;
        uint256 remainingAmount; // unfilled size in PNPT units
        uint256 price;           // limit price: FNBT per 1 PNPT
        bool isOpen;             // false once fully filled or canceled
    }

    // Order IDs are array indices. Canceled orders stay in the array (isOpen = false) to keep IDs stable.
    Order[] private _orders;

    /// @param side 0 = Buy, 1 = Sell (uint8 for ABI compatibility with tests)
    /// @param amount Initial PNPT size at placement (not updated on partial fills — use `remaining()`)
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        uint8 side,
        address payToken,
        address receiveToken,
        uint256 amount,
        uint256 price
    );

    event OrderMatched(uint256 indexed buyOrderId, uint256 indexed sellOrderId, uint256 fillAmount);

    event OrderCanceled(uint256 indexed orderId, address indexed maker);

    error InvalidAmount();
    error InvalidPrice();
    error PriceMismatch();
    error UnauthorizedCancellation();

    /// @notice Stores the two ERC20 tokens traded on this book.
    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    // -------------------------------------------------------------------------
    // Place orders — escrow tokens in this contract until match or cancel
    // -------------------------------------------------------------------------

    /// @notice Buy PNPT (tokenA) by locking FNBT (tokenB): escrow = amount * price.
    /// @param amount PNPT to buy
    /// @param price Max FNBT willing to pay per 1 PNPT
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Lock the worst-case FNBT cost up front (full size × limit price).
        uint256 escrow = amount * price;
        tokenB.safeTransferFrom(msg.sender, address(this), escrow);

        orderId = _orders.length;
        _orders.push(
            Order({ maker: msg.sender, side: Side.Buy, remainingAmount: amount, price: price, isOpen: true })
        );

        // side 0 = Buy: pay FNBT, receive PNPT
        emit OrderPlaced(orderId, msg.sender, 0, address(tokenB), address(tokenA), amount, price);
    }

    /// @notice Sell PNPT (tokenA) for FNBT (tokenB): lock `amount` of tokenA.
    /// @param amount PNPT to sell
    /// @param price Min FNBT to accept per 1 PNPT
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        tokenA.safeTransferFrom(msg.sender, address(this), amount);

        orderId = _orders.length;
        _orders.push(
            Order({ maker: msg.sender, side: Side.Sell, remainingAmount: amount, price: price, isOpen: true })
        );

        // side 1 = Sell: pay PNPT, receive FNBT
        emit OrderPlaced(orderId, msg.sender, 1, address(tokenA), address(tokenB), amount, price);
    }

    // -------------------------------------------------------------------------
    // Match — atomic swap between one buy and one sell at the sell's price
    // -------------------------------------------------------------------------

    /// @notice Match a buy and sell order; fill min(remaining); pay seller fill * sell price.
    /// @dev Buyer must have offered at least the seller's price (buy.price >= sell.price).
    ///      Settlement uses sellOrder.price so the seller always gets their ask.
    ///      If buy.price > sell.price, the extra FNBT the buyer locked stays in the contract
    ///      until they cancel the buy (refund uses buy.price on the unfilled remainder).
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = _orders[buyOrderId];
        Order storage sellOrder = _orders[sellOrderId];

        // Cross only when the buyer's limit is at least the seller's ask.
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        // Partial fill: trade the smaller of the two open sizes (in PNPT).
        uint256 fillAmount = buyOrder.remainingAmount < sellOrder.remainingAmount
            ? buyOrder.remainingAmount
            : sellOrder.remainingAmount;

        // FNBT paid to seller for this fill (always at the sell order's price).
        uint256 payment = fillAmount * sellOrder.price;

        // Release escrowed tokens: PNPT to buyer, FNBT to seller.
        tokenA.safeTransfer(buyOrder.maker, fillAmount);
        tokenB.safeTransfer(sellOrder.maker, payment);

        buyOrder.remainingAmount -= fillAmount;
        sellOrder.remainingAmount -= fillAmount;

        if (buyOrder.remainingAmount == 0) buyOrder.isOpen = false;
        if (sellOrder.remainingAmount == 0) sellOrder.isOpen = false;

        emit OrderMatched(buyOrderId, sellOrderId, fillAmount);
    }

    // -------------------------------------------------------------------------
    // Cancel — return unused escrow to the maker
    // -------------------------------------------------------------------------

    /// @notice Cancel an open order and refund unused escrow to the maker.
    /// @dev Buy refund = remaining PNPT × buy limit price (FNBT).
    ///      Sell refund = remaining PNPT still held in the contract.
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];
        if (order.maker != msg.sender) revert UnauthorizedCancellation();
        if (!order.isOpen) return; // already filled or canceled — no-op

        if (order.side == Side.Buy) {
            uint256 refund = order.remainingAmount * order.price;
            tokenB.safeTransfer(order.maker, refund);
        } else {
            tokenA.safeTransfer(order.maker, order.remainingAmount);
        }

        order.isOpen = false;
        order.remainingAmount = 0;

        emit OrderCanceled(orderId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice How much of the order is still unfilled (in PNPT units).
    function remaining(uint256 orderId) external view returns (uint256) {
        return _orders[orderId].remainingAmount;
    }

    /// @notice Whether the order is still open (not fully filled or canceled).
    function isOpen(uint256 orderId) external view returns (bool) {
        return _orders[orderId].isOpen;
    }
}
