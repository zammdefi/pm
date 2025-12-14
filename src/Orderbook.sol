// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimal PAMM interface for orderbook operations.
interface IPAMM {
    function markets(uint256 marketId)
        external
        view
        returns (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        );

    function getNoId(uint256 marketId) external pure returns (uint256);

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);

    function setOperator(address operator, bool approved) external returns (bool);

    function isOperator(address owner, address operator) external view returns (bool);

    function buyYes(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minYesOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 yesOut);

    function buyNo(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minNoOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 noOut);

    function sellYes(
        uint256 marketId,
        uint256 yesAmount,
        uint256 swapAmount,
        uint256 minCollateralOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external returns (uint256 collateralOut);

    function sellNo(
        uint256 marketId,
        uint256 noAmount,
        uint256 swapAmount,
        uint256 minCollateralOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external returns (uint256 collateralOut);

    function tradingOpen(uint256 marketId) external view returns (bool);
}

/// @notice ZAMM orderbook interface.
interface IZAMMOrderbook {
    function makeOrder(
        address tokenIn,
        uint256 idIn,
        uint96 amtIn,
        address tokenOut,
        uint256 idOut,
        uint96 amtOut,
        uint56 deadline,
        bool partialFill
    ) external payable returns (bytes32 orderHash);

    function cancelOrder(
        address tokenIn,
        uint256 idIn,
        uint96 amtIn,
        address tokenOut,
        uint256 idOut,
        uint96 amtOut,
        uint56 deadline,
        bool partialFill
    ) external;

    function fillOrder(
        address maker,
        address tokenIn,
        uint256 idIn,
        uint96 amtIn,
        address tokenOut,
        uint256 idOut,
        uint96 amtOut,
        uint56 deadline,
        bool partialFill,
        uint96 amountToFill
    ) external payable returns (uint96 filled);

    function orders(bytes32 orderHash)
        external
        view
        returns (bool partialFill, uint56 deadline, uint96 inDone, uint96 outDone);
}

/// @title Orderbook
/// @notice Complete orderbook for PAMM prediction markets using ZAMM backend.
/// @dev Features: limit orders, market orders, batch operations, discoverability, fills.
///      Compatible with all PAMM markets including those created via Resolver and GasPM.
contract Orderbook {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    IPAMM public immutable pamm;
    IZAMMOrderbook public constant ZAMM =
        IZAMMOrderbook(0x000000000000040470635EB91b7CE4D132D616eD);
    address internal constant ETH = address(0);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AmountZero();
    error ArrayMismatch();
    error OrderNotFound();
    error OrderInactive();
    error NotOrderOwner();
    error MustFillAll();
    error NothingToFill();
    error MarketNotFound();
    error MarketClosed();
    error MarketResolved();
    error DeadlineExpired();
    error InvalidETHAmount();
    error WrongCollateralType();
    error TradingNotOpen();
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event LimitOrderPlaced(
        uint256 indexed marketId,
        bytes32 indexed orderHash,
        address indexed owner,
        bool isYes,
        bool isBuy,
        uint96 shares,
        uint96 collateral,
        uint56 deadline,
        bool partialFill
    );

    event LimitOrderFilled(
        uint256 indexed marketId,
        bytes32 indexed orderHash,
        address indexed taker,
        uint96 sharesFilled,
        uint96 collateralTransferred
    );

    event LimitOrderCancelled(uint256 indexed marketId, bytes32 indexed orderHash);

    event MarketOrderExecuted(
        uint256 indexed marketId,
        address indexed trader,
        bool isYes,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut
    );

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Limit order metadata for discoverability (actual order state in ZAMM).
    /// @dev Packed into 3 storage slots (was 4). Order: owner+deadline+flags | shares+collateral | marketId
    struct LimitOrder {
        address owner; // 20 bytes - real beneficiary (this contract is maker on ZAMM)
        uint56 deadline; // 7 bytes - order expiration
        bool isYes; // 1 byte - true = YES token, false = NO token
        bool isBuy; // 1 byte - true = buying shares with collateral, false = selling
        bool partialFill; // 1 byte - allow partial fills
        // slot 0: 30 bytes
        uint96 shares; // 12 bytes - total share amount
        uint96 collateral; // 12 bytes - total collateral amount
        // slot 1: 24 bytes (8 free)
        uint256 marketId; // 32 bytes - which prediction market
        // slot 2: 32 bytes
    }

    /// @notice Parameters for placing a batch of orders.
    struct PlaceOrderParams {
        uint256 marketId;
        bool isYes;
        bool isBuy;
        uint96 shares;
        uint96 collateral;
        uint56 deadline;
        bool partialFill;
    }

    /// @notice Orderbook level with aggregated size.
    struct PriceLevel {
        uint256 price; // 1e18-scaled price
        uint256 size; // total shares at this price
        bytes32[] orderHashes; // orders at this level
    }

    /// @notice Full orderbook state for a market.
    struct OrderbookState {
        PriceLevel[] bids; // sorted highest to lowest price
        PriceLevel[] asks; // sorted lowest to highest price
        uint256 bestBid; // highest bid price (0 if no bids)
        uint256 bestAsk; // lowest ask price (type(uint256).max if no asks)
        uint256 spread; // bestAsk - bestBid (0 if no spread or crossed)
        uint256 midPrice; // (bestBid + bestAsk) / 2
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Order hashes per market for discoverability.
    mapping(uint256 marketId => bytes32[]) internal _marketOrders;

    /// @notice Order metadata by hash (owner, market, params).
    mapping(bytes32 orderHash => LimitOrder) public limitOrders;

    /// @notice Orders by user for discoverability.
    mapping(address user => bytes32[]) internal _userOrders;

    /// @notice Active order count per market (for efficient filtering).
    mapping(uint256 marketId => uint256) public activeOrderCount;

    /// @notice Reentrancy lock.
    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _pamm) {
        pamm = IPAMM(_pamm);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               MULTICALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Batch multiple calls in a single transaction.
    /// @dev Non-payable to prevent msg.value reuse. Use specific ETH functions.
    function multicall(bytes[] calldata data) public returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                PERMIT
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-2612 permit for gasless ERC20 approvals.
    function permit(
        address token,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), value)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), v)
            mstore(add(m, 0xa4), r)
            mstore(add(m, 0xc4), s)
            if iszero(call(gas(), token, 0, m, 0xe4, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /// @notice DAI-style permit for gasless approvals.
    function permitDAI(
        address token,
        address owner,
        uint256 nonce,
        uint256 deadline,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x8fcbaf0c00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), nonce)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), allowed)
            mstore(add(m, 0xa4), v)
            mstore(add(m, 0xc4), r)
            mstore(add(m, 0xe4), s)
            if iszero(call(gas(), token, 0, m, 0x104, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         LIMIT ORDER PLACEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a limit order to buy or sell YES/NO shares.
    /// @dev Uses this contract as maker on ZAMM; escrows tokens and tracks ownership.
    ///      For BUY orders: user provides collateral (ETH via msg.value or ERC20).
    ///      For SELL orders: user provides shares (must have approved this contract).
    function placeLimitOrder(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint96 shares,
        uint96 collateral,
        uint56 deadline,
        bool partialFill
    ) public payable nonReentrant returns (bytes32 orderHash) {
        orderHash = _placeLimitOrder(
            msg.sender, marketId, isYes, isBuy, shares, collateral, deadline, partialFill
        );
    }

    /// @notice Place multiple limit orders in a single transaction.
    /// @dev All orders must be for ERC20 collateral markets (no ETH).
    function batchPlaceLimitOrders(PlaceOrderParams[] calldata orders)
        public
        nonReentrant
        returns (bytes32[] memory orderHashes)
    {
        orderHashes = new bytes32[](orders.length);
        for (uint256 i; i < orders.length; ++i) {
            PlaceOrderParams calldata o = orders[i];
            orderHashes[i] = _placeLimitOrder(
                msg.sender,
                o.marketId,
                o.isYes,
                o.isBuy,
                o.shares,
                o.collateral,
                o.deadline,
                o.partialFill
            );
        }
    }

    function _placeLimitOrder(
        address owner,
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint96 shares,
        uint96 collateral,
        uint56 deadline,
        bool partialFill
    ) internal returns (bytes32 orderHash) {
        if (shares == 0 || collateral == 0) revert AmountZero();
        if (deadline <= block.timestamp) revert DeadlineExpired();

        // Get market info from PAMM
        (address resolver, bool resolved,,, uint64 close, address collateralToken,) =
            pamm.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        if (resolved) revert MarketResolved();
        if (block.timestamp >= close) revert MarketClosed();
        if (deadline > close) deadline = uint56(close);

        uint256 tokenId = isYes ? marketId : pamm.getNoId(marketId);

        if (isBuy) {
            // BUY order: escrow collateral, will receive shares on fill
            if (collateralToken == ETH) {
                if (msg.value != collateral) revert InvalidETHAmount();
                orderHash = ZAMM.makeOrder{value: collateral}(
                    address(0), 0, collateral, address(pamm), tokenId, shares, deadline, partialFill
                );
            } else {
                if (msg.value != 0) revert WrongCollateralType();
                safeTransferFrom(collateralToken, owner, address(this), collateral);
                _ensureApproval(collateralToken, address(ZAMM));
                orderHash = ZAMM.makeOrder(
                    collateralToken,
                    0,
                    collateral,
                    address(pamm),
                    tokenId,
                    shares,
                    deadline,
                    partialFill
                );
            }
        } else {
            // SELL order: escrow shares, will receive collateral on fill
            if (msg.value != 0) revert WrongCollateralType();
            // Pull shares from user (user must have approved this contract on PAMM)
            pamm.transferFrom(owner, address(this), tokenId, shares);
            _ensureApprovalPAMM();
            // Make order with shares as tokenIn
            orderHash = ZAMM.makeOrder(
                address(pamm),
                tokenId,
                shares,
                collateralToken == ETH ? address(0) : collateralToken,
                0,
                collateral,
                deadline,
                partialFill
            );
        }

        // Track order for discoverability
        _marketOrders[marketId].push(orderHash);
        _userOrders[owner].push(orderHash);
        activeOrderCount[marketId]++;

        limitOrders[orderHash] = LimitOrder({
            owner: owner,
            marketId: marketId,
            isYes: isYes,
            isBuy: isBuy,
            shares: shares,
            collateral: collateral,
            deadline: deadline,
            partialFill: partialFill
        });

        emit LimitOrderPlaced(
            marketId, orderHash, owner, isYes, isBuy, shares, collateral, deadline, partialFill
        );
    }

    /*//////////////////////////////////////////////////////////////
                        LIMIT ORDER CANCELLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Cancel own limit order and reclaim escrowed assets.
    function cancelLimitOrder(bytes32 orderHash) public nonReentrant {
        _cancelLimitOrder(orderHash);
    }

    /// @notice Cancel multiple limit orders.
    function batchCancelLimitOrders(bytes32[] calldata orderHashes) public nonReentrant {
        for (uint256 i; i < orderHashes.length; ++i) {
            _cancelLimitOrder(orderHashes[i]);
        }
    }

    function _cancelLimitOrder(bytes32 orderHash) internal {
        LimitOrder storage order = limitOrders[orderHash];
        address orderOwner = order.owner;
        if (orderOwner == address(0)) revert OrderNotFound();
        if (orderOwner != msg.sender) revert NotOrderOwner();

        // Cache order fields to avoid repeated storage reads
        uint256 marketId = order.marketId;
        bool isYes = order.isYes;
        bool isBuy = order.isBuy;
        uint96 shares = order.shares;
        uint96 collateral = order.collateral;
        uint56 orderDeadline = order.deadline;
        bool partialFill = order.partialFill;

        (,,,,, address collateralToken,) = pamm.markets(marketId);
        uint256 tokenId = isYes ? marketId : pamm.getNoId(marketId);

        // Get fill state from ZAMM
        (, uint56 zammDeadline, uint96 inDone,) = ZAMM.orders(orderHash);

        // Cancel on ZAMM
        if (isBuy) {
            ZAMM.cancelOrder(
                collateralToken == ETH ? address(0) : collateralToken,
                0,
                collateral,
                address(pamm),
                tokenId,
                shares,
                orderDeadline,
                partialFill
            );
            // Return unfilled collateral to owner
            if (zammDeadline != 0) {
                uint96 collateralRemaining = collateral - inDone;
                if (collateralRemaining > 0) {
                    if (collateralToken == ETH) {
                        safeTransferETH(msg.sender, collateralRemaining);
                    } else {
                        safeTransfer(collateralToken, msg.sender, collateralRemaining);
                    }
                }
            }
        } else {
            ZAMM.cancelOrder(
                address(pamm),
                tokenId,
                shares,
                collateralToken == ETH ? address(0) : collateralToken,
                0,
                collateral,
                orderDeadline,
                partialFill
            );
            // Return unfilled shares to owner
            if (zammDeadline != 0) {
                uint96 sharesRemaining = shares - inDone;
                if (sharesRemaining > 0) {
                    pamm.transfer(msg.sender, tokenId, sharesRemaining);
                }
            }
        }

        // Update tracking
        unchecked {
            if (activeOrderCount[marketId] > 0) {
                activeOrderCount[marketId]--;
            }
        }

        delete limitOrders[orderHash];
        emit LimitOrderCancelled(marketId, orderHash);
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER FILLING
    //////////////////////////////////////////////////////////////*/

    /// @notice Fill a limit order (as taker).
    /// @param orderHash The order to fill
    /// @param sharesToFill Amount of shares to fill (0 = fill all available)
    /// @param to Recipient of output tokens (address(0) = msg.sender)
    function fillOrder(bytes32 orderHash, uint96 sharesToFill, address to)
        public
        payable
        nonReentrant
        returns (uint96 sharesFilled, uint96 collateralTransferred)
    {
        if (to == address(0)) to = msg.sender;

        LimitOrder storage order = limitOrders[orderHash];
        if (order.owner == address(0)) revert OrderNotFound();

        uint256 marketId = order.marketId;
        (,,,,, address collateralToken,) = pamm.markets(marketId);
        uint256 tokenId = order.isYes ? marketId : pamm.getNoId(marketId);

        // Get current fill state
        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);
        if (deadline == 0 || block.timestamp > deadline) revert OrderInactive();

        uint96 sharesAvailable;
        if (order.isBuy) {
            sharesAvailable = order.shares - outDone;
        } else {
            sharesAvailable = order.shares - inDone;
        }

        if (sharesAvailable == 0) revert NothingToFill();

        if (sharesToFill == 0 || sharesToFill > sharesAvailable) {
            sharesToFill = sharesAvailable;
        }

        if (!order.partialFill && sharesToFill != sharesAvailable) {
            revert MustFillAll();
        }

        // Calculate collateral for this fill
        collateralTransferred = uint96(uint256(order.collateral) * sharesToFill / order.shares);

        if (order.isBuy) {
            // Maker is buying shares, taker is selling shares
            // Taker provides shares, receives collateral
            pamm.transferFrom(msg.sender, address(this), tokenId, sharesToFill);
            _ensureApprovalPAMM();

            sharesFilled = ZAMM.fillOrder(
                address(this),
                collateralToken == ETH ? address(0) : collateralToken,
                0,
                order.collateral,
                address(pamm),
                tokenId,
                order.shares,
                order.deadline,
                order.partialFill,
                sharesToFill
            );

            // Transfer collateral to taker
            if (collateralToken == ETH) {
                safeTransferETH(to, collateralTransferred);
            } else {
                safeTransfer(collateralToken, to, collateralTransferred);
            }

            // Transfer shares to order owner
            pamm.transfer(order.owner, tokenId, sharesFilled);
        } else {
            // Maker is selling shares, taker is buying shares
            // Taker provides collateral, receives shares
            if (collateralToken == ETH) {
                if (msg.value < collateralTransferred) revert InvalidETHAmount();
                sharesFilled = ZAMM.fillOrder{value: collateralTransferred}(
                    address(this),
                    address(pamm),
                    tokenId,
                    order.shares,
                    address(0),
                    0,
                    order.collateral,
                    order.deadline,
                    order.partialFill,
                    sharesToFill
                );
                // Refund excess ETH
                if (msg.value > collateralTransferred) {
                    safeTransferETH(msg.sender, msg.value - collateralTransferred);
                }
            } else {
                if (msg.value != 0) revert WrongCollateralType();
                safeTransferFrom(collateralToken, msg.sender, address(this), collateralTransferred);
                _ensureApproval(collateralToken, address(ZAMM));

                sharesFilled = ZAMM.fillOrder(
                    address(this),
                    address(pamm),
                    tokenId,
                    order.shares,
                    collateralToken,
                    0,
                    order.collateral,
                    order.deadline,
                    order.partialFill,
                    sharesToFill
                );
            }

            // Transfer shares to taker
            pamm.transfer(to, tokenId, sharesFilled);

            // Transfer collateral to order owner
            if (collateralToken == ETH) {
                safeTransferETH(order.owner, collateralTransferred);
            } else {
                safeTransfer(collateralToken, order.owner, collateralTransferred);
            }
        }

        // Check if order is now fully filled (avoid extra ZAMM call)
        if (sharesFilled == sharesAvailable) {
            unchecked {
                if (activeOrderCount[marketId] > 0) {
                    activeOrderCount[marketId]--;
                }
            }
        }

        emit LimitOrderFilled(marketId, orderHash, msg.sender, sharesFilled, collateralTransferred);
    }

    /// @notice Fill multiple orders in sequence.
    /// @param orderHashes Orders to fill
    /// @param amounts Amounts to fill per order (0 = fill all)
    /// @param to Recipient of output tokens
    function batchFillOrders(bytes32[] calldata orderHashes, uint96[] calldata amounts, address to)
        public
        payable
        nonReentrant
        returns (uint96 totalSharesFilled, uint96 totalCollateral)
    {
        if (orderHashes.length != amounts.length) revert ArrayMismatch();
        if (to == address(0)) to = msg.sender;

        // Note: For ETH orders, caller must send enough ETH for all fills
        uint256 ethUsed;

        for (uint256 i; i < orderHashes.length; ++i) {
            LimitOrder storage order = limitOrders[orderHashes[i]];
            if (order.owner == address(0)) continue;

            (,,,,, address collateralToken,) = pamm.markets(order.marketId);

            // Calculate ETH needed for this fill if applicable
            uint256 ethForThisFill;
            if (!order.isBuy && collateralToken == ETH) {
                uint96 sharesToFill = amounts[i];
                (, uint56 deadline, uint96 inDone,) = ZAMM.orders(orderHashes[i]);
                if (deadline == 0 || block.timestamp > deadline) continue;

                uint96 sharesAvailable = order.shares - inDone;
                if (sharesToFill == 0 || sharesToFill > sharesAvailable) {
                    sharesToFill = sharesAvailable;
                }
                ethForThisFill = uint256(order.collateral) * sharesToFill / order.shares;
            }

            _locked = 1; // Allow reentrant call to fillOrder
            try this.fillOrder{value: ethForThisFill}(orderHashes[i], amounts[i], to) returns (
                uint96 filled, uint96 coll
            ) {
                totalSharesFilled += filled;
                totalCollateral += coll;
                ethUsed += ethForThisFill;
            } catch {}
            _locked = 2;
        }

        // Refund unused ETH
        if (msg.value > ethUsed) {
            safeTransferETH(msg.sender, msg.value - ethUsed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           MARKET ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a market buy order for YES shares via PAMM's AMM.
    /// @param marketId The market to trade
    /// @param collateralIn Amount of collateral to spend
    /// @param minSharesOut Minimum shares to receive (slippage protection)
    /// @param feeOrHook Pool fee tier
    /// @param to Recipient of shares
    function marketBuyYes(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to
    ) public payable nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;

        (address resolver,,,,, address collateralToken,) = pamm.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        if (!pamm.tradingOpen(marketId)) revert TradingNotOpen();

        if (collateralToken == ETH) {
            if (msg.value != collateralIn) revert InvalidETHAmount();
            sharesOut = pamm.buyYes{value: collateralIn}(
                marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp
            );
        } else {
            if (msg.value != 0) revert WrongCollateralType();
            safeTransferFrom(collateralToken, msg.sender, address(this), collateralIn);
            _ensureApproval(collateralToken, address(pamm));
            sharesOut = pamm.buyYes(
                marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp
            );
        }

        emit MarketOrderExecuted(marketId, msg.sender, true, true, collateralIn, sharesOut);
    }

    /// @notice Execute a market buy order for NO shares via PAMM's AMM.
    function marketBuyNo(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to
    ) public payable nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;

        (address resolver,,,,, address collateralToken,) = pamm.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        if (!pamm.tradingOpen(marketId)) revert TradingNotOpen();

        if (collateralToken == ETH) {
            if (msg.value != collateralIn) revert InvalidETHAmount();
            sharesOut = pamm.buyNo{value: collateralIn}(
                marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp
            );
        } else {
            if (msg.value != 0) revert WrongCollateralType();
            safeTransferFrom(collateralToken, msg.sender, address(this), collateralIn);
            _ensureApproval(collateralToken, address(pamm));
            sharesOut =
                pamm.buyNo(marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp);
        }

        emit MarketOrderExecuted(marketId, msg.sender, false, true, collateralIn, sharesOut);
    }

    /// @notice Execute a market sell order for YES shares via PAMM's AMM.
    function marketSellYes(
        uint256 marketId,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to
    ) public nonReentrant returns (uint256 collateralOut) {
        if (to == address(0)) to = msg.sender;

        (address resolver,,,,,,) = pamm.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        if (!pamm.tradingOpen(marketId)) revert TradingNotOpen();

        // Pull shares from user
        pamm.transferFrom(msg.sender, address(this), marketId, sharesIn);
        _ensureApprovalPAMM();

        collateralOut = pamm.sellYes(
            marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, block.timestamp
        );

        emit MarketOrderExecuted(marketId, msg.sender, true, false, sharesIn, collateralOut);
    }

    /// @notice Execute a market sell order for NO shares via PAMM's AMM.
    function marketSellNo(
        uint256 marketId,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to
    ) public nonReentrant returns (uint256 collateralOut) {
        if (to == address(0)) to = msg.sender;

        (address resolver,,,,,,) = pamm.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        if (!pamm.tradingOpen(marketId)) revert TradingNotOpen();

        uint256 noId = pamm.getNoId(marketId);
        // Pull shares from user
        pamm.transferFrom(msg.sender, address(this), noId, sharesIn);
        _ensureApprovalPAMM();

        collateralOut =
            pamm.sellNo(marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, block.timestamp);

        emit MarketOrderExecuted(marketId, msg.sender, false, false, sharesIn, collateralOut);
    }

    /*//////////////////////////////////////////////////////////////
                           ORDERBOOK VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all order hashes for a market.
    function getMarketOrders(uint256 marketId) public view returns (bytes32[] memory) {
        return _marketOrders[marketId];
    }

    /// @notice Get all order hashes for a user.
    function getUserOrders(address user) public view returns (bytes32[] memory) {
        return _userOrders[user];
    }

    /// @notice Get only active orders for a market.
    function getActiveMarketOrders(uint256 marketId)
        public
        view
        returns (bytes32[] memory activeHashes)
    {
        bytes32[] memory allHashes = _marketOrders[marketId];
        uint256 activeCount;

        // First pass: count active orders
        for (uint256 i; i < allHashes.length; ++i) {
            if (_isOrderActive(allHashes[i])) {
                activeCount++;
            }
        }

        // Second pass: populate array
        activeHashes = new bytes32[](activeCount);
        uint256 idx;
        for (uint256 i; i < allHashes.length && idx < activeCount; ++i) {
            if (_isOrderActive(allHashes[i])) {
                activeHashes[idx++] = allHashes[i];
            }
        }
    }

    /// @notice Get only active orders for a user.
    function getActiveUserOrders(address user) public view returns (bytes32[] memory activeHashes) {
        bytes32[] memory allHashes = _userOrders[user];
        uint256 activeCount;

        for (uint256 i; i < allHashes.length; ++i) {
            if (_isOrderActive(allHashes[i])) {
                activeCount++;
            }
        }

        activeHashes = new bytes32[](activeCount);
        uint256 idx;
        for (uint256 i; i < allHashes.length && idx < activeCount; ++i) {
            if (_isOrderActive(allHashes[i])) {
                activeHashes[idx++] = allHashes[i];
            }
        }
    }

    /// @notice Get order details with current fill state from ZAMM.
    function getOrderDetails(bytes32 orderHash)
        public
        view
        returns (
            LimitOrder memory order,
            uint96 sharesFilled,
            uint96 sharesRemaining,
            uint96 collateralFilled,
            uint96 collateralRemaining,
            bool isActive
        )
    {
        order = limitOrders[orderHash];
        if (order.owner == address(0)) return (order, 0, 0, 0, 0, false);

        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);
        isActive = deadline != 0 && block.timestamp <= deadline;

        if (order.isBuy) {
            sharesFilled = outDone;
            collateralFilled = inDone;
        } else {
            sharesFilled = inDone;
            collateralFilled = outDone;
        }

        sharesRemaining = order.shares - sharesFilled;
        collateralRemaining = order.collateral - collateralFilled;
    }

    /// @notice Get sorted orderbook for a market (bids high→low, asks low→high).
    function getOrderbookSorted(uint256 marketId, uint256 maxLevels)
        public
        view
        returns (OrderbookState memory state)
    {
        bytes32[] memory allHashes = _marketOrders[marketId];
        (uint256 bidCount, uint256 askCount) = _countBidsAsks(allHashes);

        // Build sorted bids
        (bytes32[] memory bidHashes, uint256[] memory bidPrices, uint256[] memory bidSizes) =
            _buildSortedSide(allHashes, bidCount, true);

        // Build sorted asks
        (bytes32[] memory askHashes, uint256[] memory askPrices, uint256[] memory askSizes) =
            _buildSortedSide(allHashes, askCount, false);

        // Limit to maxLevels
        uint256 numBidLevels = bidCount > maxLevels ? maxLevels : bidCount;
        uint256 numAskLevels = askCount > maxLevels ? maxLevels : askCount;

        state.bids = new PriceLevel[](numBidLevels);
        state.asks = new PriceLevel[](numAskLevels);

        _buildPriceLevels(state.bids, bidHashes, bidPrices, bidSizes, numBidLevels);
        _buildPriceLevels(state.asks, askHashes, askPrices, askSizes, numAskLevels);

        // Compute summary stats
        if (numBidLevels > 0) state.bestBid = state.bids[0].price;
        if (numAskLevels > 0) state.bestAsk = state.asks[0].price;
        else state.bestAsk = type(uint256).max;

        if (state.bestBid > 0 && state.bestAsk < type(uint256).max && state.bestAsk > state.bestBid)
        {
            state.spread = state.bestAsk - state.bestBid;
            state.midPrice = (state.bestBid + state.bestAsk) / 2;
        }
    }

    function _buildSortedSide(bytes32[] memory allHashes, uint256 count, bool isBidSide)
        internal
        view
        returns (bytes32[] memory hashes, uint256[] memory prices, uint256[] memory sizes)
    {
        hashes = new bytes32[](count);
        prices = new uint256[](count);
        sizes = new uint256[](count);
        uint256 idx;

        for (uint256 i; i < allHashes.length && idx < count; ++i) {
            (uint256 price, uint96 remaining, bool isBid) = _getOrderPriceInfo(allHashes[i]);
            if (remaining == 0) continue;
            if (isBid != isBidSide) continue;

            hashes[idx] = allHashes[i];
            prices[idx] = price;
            sizes[idx] = remaining;
            idx++;
        }

        // Sort: bids descending, asks ascending
        for (uint256 i; i < count; ++i) {
            for (uint256 j = i + 1; j < count; ++j) {
                bool shouldSwap = isBidSide ? prices[j] > prices[i] : prices[j] < prices[i];
                if (shouldSwap) {
                    (prices[i], prices[j]) = (prices[j], prices[i]);
                    (sizes[i], sizes[j]) = (sizes[j], sizes[i]);
                    (hashes[i], hashes[j]) = (hashes[j], hashes[i]);
                }
            }
        }
    }

    function _buildPriceLevels(
        PriceLevel[] memory levels,
        bytes32[] memory hashes,
        uint256[] memory prices,
        uint256[] memory sizes,
        uint256 count
    ) internal pure {
        for (uint256 i; i < count; ++i) {
            levels[i].price = prices[i];
            levels[i].size = sizes[i];
            levels[i].orderHashes = new bytes32[](1);
            levels[i].orderHashes[0] = hashes[i];
        }
    }

    /// @notice Get orderbook summary for a market (bids and asks for YES).
    function getOrderbook(uint256 marketId, uint256 maxOrders)
        public
        view
        returns (
            bytes32[] memory bidHashes,
            uint256[] memory bidPrices,
            uint256[] memory bidSizes,
            bytes32[] memory askHashes,
            uint256[] memory askPrices,
            uint256[] memory askSizes
        )
    {
        bytes32[] memory allHashes = _marketOrders[marketId];
        (uint256 bidCount, uint256 askCount) = _countBidsAsks(allHashes);

        if (bidCount > maxOrders) bidCount = maxOrders;
        if (askCount > maxOrders) askCount = maxOrders;

        bidHashes = new bytes32[](bidCount);
        bidPrices = new uint256[](bidCount);
        bidSizes = new uint256[](bidCount);
        askHashes = new bytes32[](askCount);
        askPrices = new uint256[](askCount);
        askSizes = new uint256[](askCount);

        _fillOrderbookArrays(
            allHashes, bidHashes, bidPrices, bidSizes, askHashes, askPrices, askSizes
        );
    }

    function _countBidsAsks(bytes32[] memory allHashes)
        internal
        view
        returns (uint256 bidCount, uint256 askCount)
    {
        for (uint256 i; i < allHashes.length; ++i) {
            (, uint96 remaining, bool isBid) = _getOrderPriceInfo(allHashes[i]);
            if (remaining == 0) continue;
            if (isBid) bidCount++;
            else askCount++;
        }
    }

    function _fillOrderbookArrays(
        bytes32[] memory allHashes,
        bytes32[] memory bidHashes,
        uint256[] memory bidPrices,
        uint256[] memory bidSizes,
        bytes32[] memory askHashes,
        uint256[] memory askPrices,
        uint256[] memory askSizes
    ) internal view {
        uint256 bIdx;
        uint256 aIdx;

        for (uint256 i; i < allHashes.length; ++i) {
            if (bIdx >= bidHashes.length && aIdx >= askHashes.length) break;

            bytes32 h = allHashes[i];
            (uint256 price, uint96 remaining, bool isBid) = _getOrderPriceInfo(h);
            if (remaining == 0) continue;

            if (isBid && bIdx < bidHashes.length) {
                bidHashes[bIdx] = h;
                bidPrices[bIdx] = price;
                bidSizes[bIdx] = remaining;
                bIdx++;
            } else if (!isBid && aIdx < askHashes.length) {
                askHashes[aIdx] = h;
                askPrices[aIdx] = price;
                askSizes[aIdx] = remaining;
                aIdx++;
            }
        }
    }

    function _getOrderPriceInfo(bytes32 h)
        internal
        view
        returns (uint256 price, uint96 remaining, bool isBid)
    {
        LimitOrder storage o = limitOrders[h];
        if (o.owner == address(0)) return (0, 0, false);

        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(h);
        if (deadline == 0 || block.timestamp > deadline) return (0, 0, false);

        uint96 sharesDone = o.isBuy ? outDone : inDone;
        remaining = o.shares - sharesDone;
        if (remaining == 0) return (0, 0, false);

        price = (uint256(o.collateral) * 1e18) / o.shares;
        isBid = o.isYes ? o.isBuy : !o.isBuy;
        if (!o.isYes) price = 1e18 - price;
    }

    /// @notice Get best bid and ask prices for a market.
    function getBestBidAsk(uint256 marketId)
        public
        view
        returns (uint256 bestBid, uint256 bestAsk, bytes32 bestBidHash, bytes32 bestAskHash)
    {
        bytes32[] memory allHashes = _marketOrders[marketId];
        bestAsk = type(uint256).max;

        for (uint256 i; i < allHashes.length; ++i) {
            bytes32 h = allHashes[i];
            (uint256 price, uint96 remaining, bool isBid) = _getOrderPriceInfo(h);
            if (remaining == 0) continue;

            if (isBid && price > bestBid) {
                bestBid = price;
                bestBidHash = h;
            } else if (!isBid && price < bestAsk) {
                bestAsk = price;
                bestAskHash = h;
            }
        }

        if (bestAsk == type(uint256).max) bestAsk = 0;
    }

    /// @notice Quote the effective price for filling an order.
    function quoteOrder(bytes32 orderHash, uint96 sharesToFill)
        public
        view
        returns (uint256 pricePerShare, uint256 totalCollateral, uint96 sharesAvailable)
    {
        LimitOrder storage order = limitOrders[orderHash];
        if (order.owner == address(0)) return (0, 0, 0);

        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);
        if (deadline == 0 || block.timestamp > deadline) return (0, 0, 0);

        uint96 sharesDone = order.isBuy ? outDone : inDone;
        sharesAvailable = order.shares - sharesDone;

        if (sharesToFill == 0 || sharesToFill > sharesAvailable) {
            sharesToFill = sharesAvailable;
        }
        if (sharesToFill == 0) return (0, 0, 0);

        totalCollateral = uint256(order.collateral) * sharesToFill / order.shares;
        pricePerShare = (uint256(order.collateral) * 1e18) / order.shares;
    }

    /// @notice Get ZAMM fill params for an order (for direct ZAMM.fillOrder calls).
    function getFillParams(bytes32 orderHash)
        public
        view
        returns (
            address maker,
            address tokenIn,
            uint256 idIn,
            uint96 amtIn,
            address tokenOut,
            uint256 idOut,
            uint96 amtOut,
            uint56 deadline,
            bool partialFill
        )
    {
        LimitOrder storage order = limitOrders[orderHash];
        if (order.owner == address(0)) {
            return (address(0), address(0), 0, 0, address(0), 0, 0, 0, false);
        }

        (,,,,, address collateralToken,) = pamm.markets(order.marketId);
        uint256 tokenId = order.isYes ? order.marketId : pamm.getNoId(order.marketId);

        maker = address(this); // This contract is maker on ZAMM
        deadline = order.deadline;
        partialFill = order.partialFill;

        if (order.isBuy) {
            tokenIn = collateralToken == ETH ? address(0) : collateralToken;
            idIn = 0;
            amtIn = order.collateral;
            tokenOut = address(pamm);
            idOut = tokenId;
            amtOut = order.shares;
        } else {
            tokenIn = address(pamm);
            idIn = tokenId;
            amtIn = order.shares;
            tokenOut = collateralToken == ETH ? address(0) : collateralToken;
            idOut = 0;
            amtOut = order.collateral;
        }
    }

    /// @notice Check if an order is currently active.
    function isOrderActive(bytes32 orderHash) public view returns (bool) {
        return _isOrderActive(orderHash);
    }

    function _isOrderActive(bytes32 orderHash) internal view returns (bool) {
        LimitOrder storage order = limitOrders[orderHash];
        if (order.owner == address(0)) return false;

        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);
        if (deadline == 0 || block.timestamp > deadline) return false;

        uint96 sharesDone = order.isBuy ? outDone : inDone;
        return sharesDone < order.shares;
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER CLEANUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Prune inactive orders from market's order list.
    /// @dev Anyone can call to clean up storage. Does not affect ZAMM state.
    function pruneMarketOrders(uint256 marketId, uint256 maxToPrune)
        public
        returns (uint256 pruned)
    {
        bytes32[] storage orders = _marketOrders[marketId];
        uint256 len = orders.length;
        uint256 i;

        while (i < len && pruned < maxToPrune) {
            if (!_isOrderActive(orders[i])) {
                // Move last element to this position and pop
                orders[i] = orders[len - 1];
                orders.pop();
                len--;
                pruned++;
            } else {
                i++;
            }
        }
    }

    /// @notice Prune inactive orders from user's order list.
    function pruneUserOrders(address user, uint256 maxToPrune) public returns (uint256 pruned) {
        bytes32[] storage orders = _userOrders[user];
        uint256 len = orders.length;
        uint256 i;

        while (i < len && pruned < maxToPrune) {
            if (!_isOrderActive(orders[i])) {
                orders[i] = orders[len - 1];
                orders.pop();
                len--;
                pruned++;
            } else {
                i++;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          TRANSFER HELPERS
    //////////////////////////////////////////////////////////////*/

    function safeTransferETH(address to, uint256 amount) internal {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                revert(0, 0)
            }
        }
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0xa9059cbb000000000000000000000000)
            let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    revert(0, 0)
                }
            }
            mstore(0x34, 0)
        }
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x60, amount)
            mstore(0x40, to)
            mstore(0x2c, shl(96, from))
            mstore(0x0c, 0x23b872dd000000000000000000000000)
            let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    revert(0, 0)
                }
            }
            mstore(0x60, 0)
            mstore(0x40, m)
        }
    }

    /// @dev Ensure max approval to spender if needed.
    function _ensureApproval(address token, address spender) internal {
        assembly ("memory-safe") {
            mstore(0x00, 0xdd62ed3e000000000000000000000000)
            mstore(0x14, address())
            mstore(0x34, spender)
            let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(success, gt(mload(0x00), 0xffffffffffffffffffffffffffffffff))) {
                mstore(0x14, spender)
                mstore(0x34, not(0))
                mstore(0x00, 0x095ea7b3000000000000000000000000)
                success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                        revert(0, 0)
                    }
                }
            }
            mstore(0x34, 0)
        }
    }

    /// @dev Ensure this contract is operator on PAMM for ZAMM pulls.
    function _ensureApprovalPAMM() internal {
        if (!pamm.isOperator(address(this), address(ZAMM))) {
            pamm.setOperator(address(ZAMM), true);
        }
    }
}
