// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice ZAMM orderbook + AMM interface.
interface IZAMM {
    // Orderbook
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

    // AMM
    function swap(
        address tokenIn,
        uint256 idIn,
        address tokenOut,
        uint256 idOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}

/// @notice PAMM interface.
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
    function tradingOpen(uint256 marketId) external view returns (bool);

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);
    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address owner, address operator) external view returns (bool);
    function balanceOf(address owner, uint256 id) external view returns (uint256);

    // Market orders
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

    // Collateral operations
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function merge(uint256 marketId, uint256 amount, address to) external;
    function claim(uint256 marketId, address to) external returns (uint256 payout);
}

/// @title PMRouter
/// @notice Limit order and trading router for PAMM prediction markets.
/// @dev Handles YES/NO share limit orders via ZAMM, market orders via PAMM, and collateral ops.
contract PMRouter {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address internal constant ETH = address(0);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Reentrancy();
    error AmountZero();
    error MustFillAll();
    error MarketClosed();
    error OrderInactive();
    error NotOrderOwner();
    error OrderNotFound();
    error MarketNotFound();
    error TradingNotOpen();
    error DeadlineExpired();
    error SlippageExceeded();
    error InvalidETHAmount();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OrderCancelled(bytes32 indexed orderHash);

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed taker,
        uint96 sharesFilled,
        uint96 collateralFilled
    );

    event OrderPlaced(
        bytes32 indexed orderHash,
        uint256 indexed marketId,
        address indexed owner,
        bool isYes,
        bool isBuy,
        uint96 shares,
        uint96 collateral,
        uint56 deadline,
        bool partialFill
    );

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Limit order for PM shares.
    struct Order {
        address owner; // 20 bytes
        uint56 deadline; // 7 bytes
        bool isYes; // 1 byte - YES or NO shares
        bool isBuy; // 1 byte - buying or selling shares
        bool partialFill; // 1 byte
        // slot 0: 30 bytes
        uint96 shares; // 12 bytes
        uint96 collateral; // 12 bytes
        // slot 1: 24 bytes
        uint256 marketId; // 32 bytes - slot 2
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => Order) public orders;
    mapping(uint256 => bytes32[]) internal _marketOrders; // marketId => orderHashes
    mapping(address => bytes32[]) internal _userOrders; // user => orderHashes
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

    constructor() payable {}

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               MULTICALL
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                            LIMIT ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Place limit order to buy/sell YES or NO shares.
    /// @param marketId Prediction market ID
    /// @param isYes True for YES shares, false for NO
    /// @param isBuy True to buy shares with collateral, false to sell shares for collateral
    /// @param shares Amount of shares
    /// @param collateral Amount of collateral
    /// @param deadline Order expiration
    /// @param partialFill Allow partial fills
    function placeOrder(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint96 shares,
        uint96 collateral,
        uint56 deadline,
        bool partialFill
    ) public payable nonReentrant returns (bytes32 orderHash) {
        if (shares == 0 || collateral == 0) revert AmountZero();
        if (deadline <= block.timestamp) revert DeadlineExpired();

        (address resolver,,,, uint64 close, address collateralToken,) = PAMM.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        if (block.timestamp >= close) revert MarketClosed();
        if (deadline > close) deadline = uint56(close);

        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);

        if (isBuy) {
            // BUY: escrow collateral, receive shares on fill
            if (collateralToken == ETH) {
                if (msg.value != collateral) revert InvalidETHAmount();
                orderHash = ZAMM.makeOrder{value: collateral}(
                    ETH, 0, collateral, address(PAMM), tokenId, shares, deadline, partialFill
                );
            } else {
                if (msg.value != 0) revert InvalidETHAmount();
                _safeTransferFrom(collateralToken, msg.sender, address(this), collateral);
                _ensureApproval(collateralToken, address(ZAMM));
                orderHash = ZAMM.makeOrder(
                    collateralToken,
                    0,
                    collateral,
                    address(PAMM),
                    tokenId,
                    shares,
                    deadline,
                    partialFill
                );
            }
        } else {
            // SELL: escrow shares, receive collateral on fill
            if (msg.value != 0) revert InvalidETHAmount();
            PAMM.transferFrom(msg.sender, address(this), tokenId, shares);
            _ensureOperatorPAMM();
            orderHash = ZAMM.makeOrder(
                address(PAMM),
                tokenId,
                shares,
                collateralToken,
                0,
                collateral,
                deadline,
                partialFill
            );
        }

        orders[orderHash] = Order({
            owner: msg.sender,
            deadline: deadline,
            isYes: isYes,
            isBuy: isBuy,
            partialFill: partialFill,
            shares: shares,
            collateral: collateral,
            marketId: marketId
        });

        // Track order for discoverability
        _marketOrders[marketId].push(orderHash);
        _userOrders[msg.sender].push(orderHash);

        emit OrderPlaced(
            orderHash, marketId, msg.sender, isYes, isBuy, shares, collateral, deadline, partialFill
        );
    }

    /// @notice Cancel order and reclaim tokens.
    function cancelOrder(bytes32 orderHash) public nonReentrant {
        Order storage order = orders[orderHash];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert NotOrderOwner();

        (,,,,, address collateralToken,) = PAMM.markets(order.marketId);
        uint256 tokenId = order.isYes ? order.marketId : PAMM.getNoId(order.marketId);

        (, uint56 zammDeadline, uint96 inDone,) = ZAMM.orders(orderHash);

        if (order.isBuy) {
            ZAMM.cancelOrder(
                collateralToken,
                0,
                order.collateral,
                address(PAMM),
                tokenId,
                order.shares,
                order.deadline,
                order.partialFill
            );
            if (zammDeadline != 0) {
                uint96 remaining = order.collateral - inDone;
                if (remaining > 0) {
                    if (collateralToken == ETH) {
                        _safeTransferETH(msg.sender, remaining);
                    } else {
                        _safeTransfer(collateralToken, msg.sender, remaining);
                    }
                }
            }
        } else {
            ZAMM.cancelOrder(
                address(PAMM),
                tokenId,
                order.shares,
                collateralToken,
                0,
                order.collateral,
                order.deadline,
                order.partialFill
            );
            if (zammDeadline != 0) {
                uint96 remaining = order.shares - inDone;
                if (remaining > 0) {
                    PAMM.transfer(msg.sender, tokenId, remaining);
                }
            }
        }

        delete orders[orderHash];
        emit OrderCancelled(orderHash);
    }

    /// @notice Fill a limit order.
    /// @param orderHash Order to fill
    /// @param sharesToFill Amount to fill (0 = fill all)
    /// @param to Recipient
    function fillOrder(bytes32 orderHash, uint96 sharesToFill, address to)
        public
        payable
        nonReentrant
        returns (uint96 sharesFilled, uint96 collateralFilled)
    {
        if (to == address(0)) to = msg.sender;

        Order storage order = orders[orderHash];
        if (order.owner == address(0)) revert OrderNotFound();

        (,,,,, address collateralToken,) = PAMM.markets(order.marketId);
        uint256 tokenId = order.isYes ? order.marketId : PAMM.getNoId(order.marketId);

        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);
        if (deadline == 0 || block.timestamp > deadline) revert OrderInactive();

        uint96 sharesAvailable = order.isBuy ? order.shares - outDone : order.shares - inDone;
        if (sharesAvailable == 0) revert OrderInactive();

        if (sharesToFill == 0 || sharesToFill > sharesAvailable) {
            sharesToFill = sharesAvailable;
        }
        if (!order.partialFill && sharesToFill != sharesAvailable) {
            revert MustFillAll();
        }

        // Calculate expected collateral for ETH validation (actual amount calculated after fill)
        uint96 expectedCollateral = uint96(uint256(order.collateral) * sharesToFill / order.shares);

        if (order.isBuy) {
            // Maker buying shares: taker sells shares, receives collateral
            PAMM.transferFrom(msg.sender, address(this), tokenId, sharesToFill);
            _ensureOperatorPAMM();

            sharesFilled = ZAMM.fillOrder(
                address(this),
                collateralToken,
                0,
                order.collateral,
                address(PAMM),
                tokenId,
                order.shares,
                order.deadline,
                order.partialFill,
                sharesToFill
            );
            collateralFilled = uint96(uint256(order.collateral) * sharesFilled / order.shares);

            // Collateral to taker
            if (collateralToken == ETH) {
                _safeTransferETH(to, collateralFilled);
            } else {
                _safeTransfer(collateralToken, to, collateralFilled);
            }
            // Shares to order owner
            PAMM.transfer(order.owner, tokenId, sharesFilled);
        } else {
            // Maker selling shares: taker buys shares, provides collateral
            if (collateralToken == ETH) {
                if (msg.value < expectedCollateral) revert InvalidETHAmount();
                sharesFilled = ZAMM.fillOrder{value: expectedCollateral}(
                    address(this),
                    address(PAMM),
                    tokenId,
                    order.shares,
                    ETH,
                    0,
                    order.collateral,
                    order.deadline,
                    order.partialFill,
                    sharesToFill
                );
                collateralFilled = uint96(uint256(order.collateral) * sharesFilled / order.shares);
                if (msg.value > collateralFilled) {
                    _safeTransferETH(msg.sender, msg.value - collateralFilled);
                }
            } else {
                if (msg.value != 0) revert InvalidETHAmount();
                _safeTransferFrom(collateralToken, msg.sender, address(this), expectedCollateral);
                _ensureApproval(collateralToken, address(ZAMM));
                sharesFilled = ZAMM.fillOrder(
                    address(this),
                    address(PAMM),
                    tokenId,
                    order.shares,
                    collateralToken,
                    0,
                    order.collateral,
                    order.deadline,
                    order.partialFill,
                    sharesToFill
                );
                collateralFilled = uint96(uint256(order.collateral) * sharesFilled / order.shares);
                // Refund excess if any
                if (expectedCollateral > collateralFilled) {
                    _safeTransfer(
                        collateralToken, msg.sender, expectedCollateral - collateralFilled
                    );
                }
            }

            // Shares to taker
            PAMM.transfer(to, tokenId, sharesFilled);
            // Collateral to order owner
            if (collateralToken == ETH) {
                _safeTransferETH(order.owner, collateralFilled);
            } else {
                _safeTransfer(collateralToken, order.owner, collateralFilled);
            }
        }

        emit OrderFilled(orderHash, msg.sender, sharesFilled, collateralFilled);
    }

    /*//////////////////////////////////////////////////////////////
                           MARKET ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy YES or NO shares via PAMM AMM.
    function buy(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to
    ) public payable nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) revert TradingNotOpen();

        (,,,,, address collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralIn) revert InvalidETHAmount();
            sharesOut = isYes
                ? PAMM.buyYes{value: collateralIn}(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp
                )
                : PAMM.buyNo{value: collateralIn}(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp
                );
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(PAMM));
            sharesOut = isYes
                ? PAMM.buyYes(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp
                )
                : PAMM.buyNo(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, block.timestamp
                );
        }
    }

    /// @notice Sell YES or NO shares via PAMM AMM.
    function sell(
        uint256 marketId,
        bool isYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to
    ) public nonReentrant returns (uint256 collateralOut) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) revert TradingNotOpen();

        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);
        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);
        _ensureOperatorPAMM();

        collateralOut = isYes
            ? PAMM.sellYes(
                marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, block.timestamp
            )
            : PAMM.sellNo(
                marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, block.timestamp
            );
    }

    /*//////////////////////////////////////////////////////////////
                            ZAMM SWAPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap YES<->NO shares via ZAMM AMM.
    /// @param marketId Prediction market
    /// @param yesForNo True to swap YES->NO, false for NO->YES
    /// @param amountIn Amount of shares to swap
    /// @param minOut Minimum output shares
    /// @param feeOrHook Pool fee tier
    /// @param to Recipient
    function swapShares(
        uint256 marketId,
        bool yesForNo,
        uint256 amountIn,
        uint256 minOut,
        uint256 feeOrHook,
        address to
    ) public nonReentrant returns (uint256 amountOut) {
        if (to == address(0)) to = msg.sender;
        _validateAndGetCollateral(marketId);

        uint256 yesId = marketId;
        uint256 noId = PAMM.getNoId(marketId);

        uint256 tokenIn = yesForNo ? yesId : noId;
        uint256 tokenOut = yesForNo ? noId : yesId;

        PAMM.transferFrom(msg.sender, address(this), tokenIn, amountIn);
        _ensureOperatorPAMM();

        amountOut = ZAMM.swap(
            address(PAMM),
            tokenIn,
            address(PAMM),
            tokenOut,
            amountIn,
            minOut,
            feeOrHook,
            to,
            block.timestamp
        );
    }

    /// @notice Swap shares directly to collateral via ZAMM AMM (not PAMM).
    /// @dev Uses ZAMM's share/collateral pools if they exist.
    function swapSharesToCollateral(
        uint256 marketId,
        bool isYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to
    ) public nonReentrant returns (uint256 collateralOut) {
        if (to == address(0)) to = msg.sender;
        address collateral = _validateAndGetCollateral(marketId);
        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);

        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);
        _ensureOperatorPAMM();

        collateralOut = ZAMM.swap(
            address(PAMM),
            tokenId,
            collateral,
            0,
            sharesIn,
            minCollateralOut,
            feeOrHook,
            to,
            block.timestamp
        );
    }

    /// @notice Swap collateral directly to shares via ZAMM AMM (not PAMM).
    function swapCollateralToShares(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to
    ) public payable nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;
        address collateral = _validateAndGetCollateral(marketId);
        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralIn) revert InvalidETHAmount();
            sharesOut = ZAMM.swap{value: collateralIn}(
                ETH,
                0,
                address(PAMM),
                tokenId,
                collateralIn,
                minSharesOut,
                feeOrHook,
                to,
                block.timestamp
            );
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(ZAMM));
            sharesOut = ZAMM.swap(
                collateral,
                0,
                address(PAMM),
                tokenId,
                collateralIn,
                minSharesOut,
                feeOrHook,
                to,
                block.timestamp
            );
        }
    }

    /// @notice Fill orders then swap remainder via AMM.
    /// @dev Attempts to fill provided orders first, then routes remaining to ZAMM AMM.
    /// @param marketId Prediction market
    /// @param isYes True for YES shares, false for NO
    /// @param isBuy True to buy shares, false to sell
    /// @param totalAmount Total shares (if selling) or collateral (if buying) to trade
    /// @param minOutput Minimum output (collateral if selling, shares if buying)
    /// @param orderHashes Orders to try filling first
    /// @param feeOrHook AMM fee tier for remainder
    /// @param to Recipient
    function fillOrdersThenSwap(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint256 totalAmount,
        uint256 minOutput,
        bytes32[] calldata orderHashes,
        uint256 feeOrHook,
        address to
    ) public payable nonReentrant returns (uint256 totalOutput) {
        if (to == address(0)) to = msg.sender;
        address collateral = _validateAndGetCollateral(marketId);
        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);
        uint256 remaining = totalAmount;

        if (isBuy) {
            // Buying shares with collateral
            if (collateral == ETH) {
                if (msg.value != totalAmount) revert InvalidETHAmount();
            } else {
                if (msg.value != 0) revert InvalidETHAmount();
                _safeTransferFrom(collateral, msg.sender, address(this), totalAmount);
                _ensureApproval(collateral, address(ZAMM));
            }
            _ensureOperatorPAMM();

            // Try filling orders (orders where maker is selling shares)
            for (uint256 i; i < orderHashes.length && remaining > 0; ++i) {
                Order storage order = orders[orderHashes[i]];
                if (
                    order.owner == address(0) || order.marketId != marketId || order.isYes != isYes
                        || order.isBuy
                ) continue;

                (, uint56 deadline, uint96 inDone,) = ZAMM.orders(orderHashes[i]);
                if (deadline == 0 || block.timestamp > deadline) continue;

                uint96 sharesAvail = order.shares - inDone;
                if (sharesAvail == 0) continue;

                uint96 collateralNeeded =
                    uint96(uint256(order.collateral) * sharesAvail / order.shares);
                uint96 collateralToUse =
                    remaining >= collateralNeeded ? collateralNeeded : uint96(remaining);
                uint96 sharesToFill =
                    uint96(uint256(order.shares) * collateralToUse / order.collateral);
                if (sharesToFill == 0 || (!order.partialFill && sharesToFill != sharesAvail)) {
                    continue;
                }

                uint96 filled;
                if (collateral == ETH) {
                    filled = ZAMM.fillOrder{value: collateralToUse}(
                        address(this),
                        address(PAMM),
                        tokenId,
                        order.shares,
                        ETH,
                        0,
                        order.collateral,
                        order.deadline,
                        order.partialFill,
                        sharesToFill
                    );
                } else {
                    filled = ZAMM.fillOrder(
                        address(this),
                        address(PAMM),
                        tokenId,
                        order.shares,
                        collateral,
                        0,
                        order.collateral,
                        order.deadline,
                        order.partialFill,
                        sharesToFill
                    );
                }

                // Transfer shares to buyer, collateral to seller
                PAMM.transfer(to, tokenId, filled);
                uint96 collateralFilled = uint96(uint256(order.collateral) * filled / order.shares);
                if (collateral == ETH) {
                    _safeTransferETH(order.owner, collateralFilled);
                } else {
                    _safeTransfer(collateral, order.owner, collateralFilled);
                }

                emit OrderFilled(orderHashes[i], msg.sender, filled, collateralFilled);

                totalOutput += filled;
                remaining -= collateralFilled;
            }

            // Swap remainder via AMM
            if (remaining > 0) {
                totalOutput += collateral == ETH
                    ? ZAMM.swap{value: remaining}(
                        ETH, 0, address(PAMM), tokenId, remaining, 0, feeOrHook, to, block.timestamp
                    )
                    : ZAMM.swap(
                        collateral,
                        0,
                        address(PAMM),
                        tokenId,
                        remaining,
                        0,
                        feeOrHook,
                        to,
                        block.timestamp
                    );
            }
        } else {
            // Selling shares for collateral
            if (msg.value != 0) revert InvalidETHAmount();
            PAMM.transferFrom(msg.sender, address(this), tokenId, totalAmount);
            _ensureOperatorPAMM();

            // Try filling orders (orders where maker is buying shares)
            for (uint256 i; i < orderHashes.length && remaining > 0; ++i) {
                Order storage order = orders[orderHashes[i]];
                if (
                    order.owner == address(0) || order.marketId != marketId || order.isYes != isYes
                        || !order.isBuy
                ) continue;

                (, uint56 deadline,, uint96 outDone) = ZAMM.orders(orderHashes[i]);
                if (deadline == 0 || block.timestamp > deadline) continue;

                uint96 sharesAvail = order.shares - outDone;
                if (sharesAvail == 0) continue;

                uint96 sharesToFill = remaining >= sharesAvail ? sharesAvail : uint96(remaining);
                if (!order.partialFill && sharesToFill != sharesAvail) continue;

                uint96 filled = ZAMM.fillOrder(
                    address(this),
                    collateral,
                    0,
                    order.collateral,
                    address(PAMM),
                    tokenId,
                    order.shares,
                    order.deadline,
                    order.partialFill,
                    sharesToFill
                );

                // Transfer collateral to seller, shares to buyer
                uint96 collateralFilled = uint96(uint256(order.collateral) * filled / order.shares);
                if (collateral == ETH) {
                    _safeTransferETH(to, collateralFilled);
                } else {
                    _safeTransfer(collateral, to, collateralFilled);
                }
                PAMM.transfer(order.owner, tokenId, filled);

                emit OrderFilled(orderHashes[i], msg.sender, filled, collateralFilled);

                totalOutput += collateralFilled;
                remaining -= filled;
            }

            // Swap remainder via AMM
            if (remaining > 0) {
                totalOutput += ZAMM.swap(
                    address(PAMM),
                    tokenId,
                    collateral,
                    0,
                    remaining,
                    0,
                    feeOrHook,
                    to,
                    block.timestamp
                );
            }
        }

        if (totalOutput < minOutput) revert SlippageExceeded();
    }

    /*//////////////////////////////////////////////////////////////
                         COLLATERAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Split collateral into YES + NO shares.
    function split(uint256 marketId, uint256 amount, address to) public payable nonReentrant {
        if (to == address(0)) to = msg.sender;
        (,,,,, address collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != amount) revert InvalidETHAmount();
            PAMM.split{value: amount}(marketId, amount, to);
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            _safeTransferFrom(collateral, msg.sender, address(this), amount);
            _ensureApproval(collateral, address(PAMM));
            PAMM.split(marketId, amount, to);
        }
    }

    /// @notice Merge YES + NO shares back into collateral.
    function merge(uint256 marketId, uint256 amount, address to) public nonReentrant {
        if (to == address(0)) to = msg.sender;
        uint256 noId = PAMM.getNoId(marketId);

        PAMM.transferFrom(msg.sender, address(this), marketId, amount);
        PAMM.transferFrom(msg.sender, address(this), noId, amount);
        _ensureOperatorPAMM();

        PAMM.merge(marketId, amount, to);
    }

    /// @notice Claim winnings from resolved market.
    function claim(uint256 marketId, address to) public nonReentrant returns (uint256 payout) {
        if (to == address(0)) to = msg.sender;
        uint256 noId = PAMM.getNoId(marketId);

        // Transfer any shares user has
        uint256 yesBal = PAMM.balanceOf(msg.sender, marketId);
        uint256 noBal = PAMM.balanceOf(msg.sender, noId);

        if (yesBal > 0) PAMM.transferFrom(msg.sender, address(this), marketId, yesBal);
        if (noBal > 0) PAMM.transferFrom(msg.sender, address(this), noId, noBal);

        payout = PAMM.claim(marketId, to);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get order details with fill state.
    function getOrder(bytes32 orderHash)
        public
        view
        returns (
            Order memory order,
            uint96 sharesFilled,
            uint96 sharesRemaining,
            uint96 collateralFilled,
            uint96 collateralRemaining,
            bool active
        )
    {
        order = orders[orderHash];
        if (order.owner == address(0)) return (order, 0, 0, 0, 0, false);

        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);

        if (order.isBuy) {
            collateralFilled = inDone;
            sharesFilled = outDone;
        } else {
            sharesFilled = inDone;
            collateralFilled = outDone;
        }

        sharesRemaining = order.shares - sharesFilled;
        collateralRemaining = order.collateral - collateralFilled;
        active = deadline != 0 && block.timestamp <= deadline && sharesRemaining > 0;
    }

    function isOrderActive(bytes32 orderHash) public view returns (bool) {
        Order storage order = orders[orderHash];
        if (order.owner == address(0)) return false;
        (, uint56 deadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);
        uint96 done = order.isBuy ? outDone : inDone;
        return deadline != 0 && block.timestamp <= deadline && done < order.shares;
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER DISCOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Get total number of orders for a market (including inactive).
    function getMarketOrderCount(uint256 marketId) public view returns (uint256) {
        return _marketOrders[marketId].length;
    }

    /// @notice Get total number of orders for a user (including inactive).
    function getUserOrderCount(address user) public view returns (uint256) {
        return _userOrders[user].length;
    }

    /// @notice Get order hashes for a market with pagination.
    /// @param marketId Market to query
    /// @param offset Starting index
    /// @param limit Max orders to return
    function getMarketOrderHashes(uint256 marketId, uint256 offset, uint256 limit)
        public
        view
        returns (bytes32[] memory orderHashes)
    {
        bytes32[] storage allOrders = _marketOrders[marketId];
        uint256 len = allOrders.length;
        if (offset >= len) return new bytes32[](0);

        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 count = end - offset;

        orderHashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            orderHashes[i] = allOrders[offset + i];
        }
    }

    /// @notice Get order hashes for a user with pagination.
    function getUserOrderHashes(address user, uint256 offset, uint256 limit)
        public
        view
        returns (bytes32[] memory orderHashes)
    {
        bytes32[] storage allOrders = _userOrders[user];
        uint256 len = allOrders.length;
        if (offset >= len) return new bytes32[](0);

        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 count = end - offset;

        orderHashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            orderHashes[i] = allOrders[offset + i];
        }
    }

    /// @notice Get active orders for a market, filtered by side.
    /// @param marketId Market to query
    /// @param isYes Filter for YES (true) or NO (false) shares
    /// @param isBuy Filter for buy (true) or sell (false) orders
    /// @param limit Max orders to return
    /// @return orderHashes Active order hashes matching criteria
    /// @return orderDetails Corresponding order details
    function getActiveOrders(uint256 marketId, bool isYes, bool isBuy, uint256 limit)
        public
        view
        returns (bytes32[] memory orderHashes, Order[] memory orderDetails)
    {
        bytes32[] storage allOrders = _marketOrders[marketId];
        uint256 len = allOrders.length;

        // Single pass: collect matching active orders up to limit
        bytes32[] memory tempHashes = new bytes32[](limit);
        Order[] memory tempOrders = new Order[](limit);
        uint256 count;

        for (uint256 i; i < len && count < limit; ++i) {
            bytes32 hash = allOrders[i];
            Order storage o = orders[hash];
            if (o.isYes == isYes && o.isBuy == isBuy && isOrderActive(hash)) {
                tempHashes[count] = hash;
                tempOrders[count] = o;
                ++count;
            }
        }

        // Trim to actual size
        orderHashes = new bytes32[](count);
        orderDetails = new Order[](count);
        for (uint256 i; i < count; ++i) {
            orderHashes[i] = tempHashes[i];
            orderDetails[i] = tempOrders[i];
        }
    }

    /// @notice Get best (highest for buys, lowest for sells) orders for filling.
    /// @dev Returns orders sorted by price, best first. Price = collateral/shares.
    /// @param marketId Market to query
    /// @param isYes YES or NO shares
    /// @param isBuy Get buy orders (to sell into) or sell orders (to buy from)
    /// @param limit Max orders to return
    function getBestOrders(uint256 marketId, bool isYes, bool isBuy, uint256 limit)
        public
        view
        returns (bytes32[] memory orderHashes)
    {
        // Get active orders (fetch up to 2x limit for sorting buffer)
        uint256 fetchLimit = limit > type(uint256).max / 2 ? type(uint256).max : limit * 2;
        (bytes32[] memory active, Order[] memory activeOrders) =
            getActiveOrders(marketId, isYes, isBuy, fetchLimit);
        uint256 len = active.length;
        if (len == 0) return new bytes32[](0);

        // Cache prices in memory to avoid repeated storage reads during sort
        uint256[] memory prices = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            prices[i] = uint256(activeOrders[i].collateral) * 1e18 / activeOrders[i].shares;
        }

        // Simple insertion sort by price (fine for small arrays)
        // For buys: higher price = better (they pay more)
        // For sells: lower price = better (they accept less)
        for (uint256 i = 1; i < len; ++i) {
            bytes32 keyHash = active[i];
            uint256 keyPrice = prices[i];

            uint256 j = i;
            while (j > 0) {
                bool shouldSwap = isBuy ? (keyPrice > prices[j - 1]) : (keyPrice < prices[j - 1]);
                if (!shouldSwap) break;

                active[j] = active[j - 1];
                prices[j] = prices[j - 1];
                --j;
            }
            active[j] = keyHash;
            prices[j] = keyPrice;
        }

        // Return up to limit
        uint256 resultLen = len < limit ? len : limit;
        orderHashes = new bytes32[](resultLen);
        for (uint256 i; i < resultLen; ++i) {
            orderHashes[i] = active[i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                             UX HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get bid/ask spread for a share type.
    /// @param marketId Market to query
    /// @param isYes True for YES shares, false for NO
    /// @return bidPrice Best buy order price (highest) - 18 decimals
    /// @return askPrice Best sell order price (lowest) - 18 decimals
    /// @return bidCount Number of active buy orders
    /// @return askCount Number of active sell orders
    function getBidAsk(uint256 marketId, bool isYes)
        public
        view
        returns (uint256 bidPrice, uint256 askPrice, uint256 bidCount, uint256 askCount)
    {
        bytes32[] storage allOrders = _marketOrders[marketId];
        uint256 len = allOrders.length;

        for (uint256 i; i < len; ++i) {
            bytes32 hash = allOrders[i];
            Order storage o = orders[hash];
            if (o.isYes != isYes || !isOrderActive(hash)) continue;

            uint256 price = uint256(o.collateral) * 1e18 / o.shares;

            if (o.isBuy) {
                ++bidCount;
                if (price > bidPrice) bidPrice = price;
            } else {
                ++askCount;
                if (askPrice == 0 || price < askPrice) askPrice = price;
            }
        }
    }

    /// @notice Get full orderbook for a share type (for CEX-style UI).
    /// @param marketId Market to query
    /// @param isYes True for YES shares, false for NO
    /// @param depth Max orders per side
    /// @return bidHashes Buy order hashes (best price first)
    /// @return bidPrices Buy order prices (18 decimals)
    /// @return bidSizes Buy order sizes (shares)
    /// @return askHashes Sell order hashes (best price first)
    /// @return askPrices Sell order prices (18 decimals)
    /// @return askSizes Sell order sizes (shares)
    function getOrderbook(uint256 marketId, bool isYes, uint256 depth)
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
        bidHashes = getBestOrders(marketId, isYes, true, depth);
        askHashes = getBestOrders(marketId, isYes, false, depth);

        uint256 bidLen = bidHashes.length;
        uint256 askLen = askHashes.length;

        bidPrices = new uint256[](bidLen);
        bidSizes = new uint256[](bidLen);
        askPrices = new uint256[](askLen);
        askSizes = new uint256[](askLen);

        for (uint256 i; i < bidLen; ++i) {
            Order storage o = orders[bidHashes[i]];
            bidPrices[i] = uint256(o.collateral) * 1e18 / o.shares;
            (,,, uint96 outDone) = ZAMM.orders(bidHashes[i]);
            bidSizes[i] = o.shares - outDone; // Remaining shares wanted
        }

        for (uint256 i; i < askLen; ++i) {
            Order storage o = orders[askHashes[i]];
            askPrices[i] = uint256(o.collateral) * 1e18 / o.shares;
            (,, uint96 inDone,) = ZAMM.orders(askHashes[i]);
            askSizes[i] = o.shares - inDone; // Remaining shares available
        }
    }

    /// @notice Get user's share positions across multiple markets.
    /// @param user User address
    /// @param marketIds Markets to query
    /// @return yesBalances YES share balances
    /// @return noBalances NO share balances
    function getUserPositions(address user, uint256[] calldata marketIds)
        public
        view
        returns (uint256[] memory yesBalances, uint256[] memory noBalances)
    {
        uint256 len = marketIds.length;
        yesBalances = new uint256[](len);
        noBalances = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            yesBalances[i] = PAMM.balanceOf(user, marketIds[i]);
            noBalances[i] = PAMM.balanceOf(user, PAMM.getNoId(marketIds[i]));
        }
    }

    /// @notice Get user's active orders for a specific market.
    /// @param user User address
    /// @param marketId Market to filter by (0 = all markets)
    /// @param limit Max orders to return
    function getUserActiveOrders(address user, uint256 marketId, uint256 limit)
        public
        view
        returns (bytes32[] memory orderHashes, Order[] memory orderDetails)
    {
        bytes32[] storage allOrders = _userOrders[user];
        uint256 len = allOrders.length;

        bytes32[] memory tempHashes = new bytes32[](limit);
        Order[] memory tempOrders = new Order[](limit);
        uint256 count;

        for (uint256 i; i < len && count < limit; ++i) {
            bytes32 hash = allOrders[i];
            Order storage o = orders[hash];
            if ((marketId == 0 || o.marketId == marketId) && isOrderActive(hash)) {
                tempHashes[count] = hash;
                tempOrders[count] = o;
                ++count;
            }
        }

        orderHashes = new bytes32[](count);
        orderDetails = new Order[](count);
        for (uint256 i; i < count; ++i) {
            orderHashes[i] = tempHashes[i];
            orderDetails[i] = tempOrders[i];
        }
    }

    /// @notice Cancel multiple orders in one transaction.
    /// @param orderHashesToCancel Orders to cancel (skips orders not owned by sender)
    /// @return cancelled Number of orders successfully cancelled
    function batchCancelOrders(bytes32[] calldata orderHashesToCancel)
        public
        nonReentrant
        returns (uint256 cancelled)
    {
        for (uint256 i; i < orderHashesToCancel.length; ++i) {
            bytes32 orderHash = orderHashesToCancel[i];
            Order storage order = orders[orderHash];
            if (order.owner != msg.sender) continue;

            (,,,,, address collateralToken,) = PAMM.markets(order.marketId);
            uint256 tokenId = order.isYes ? order.marketId : PAMM.getNoId(order.marketId);
            (, uint56 zammDeadline, uint96 inDone,) = ZAMM.orders(orderHash);

            if (order.isBuy) {
                ZAMM.cancelOrder(
                    collateralToken,
                    0,
                    order.collateral,
                    address(PAMM),
                    tokenId,
                    order.shares,
                    order.deadline,
                    order.partialFill
                );
                if (zammDeadline != 0) {
                    uint96 remaining = order.collateral - inDone;
                    if (remaining > 0) {
                        if (collateralToken == ETH) {
                            _safeTransferETH(msg.sender, remaining);
                        } else {
                            _safeTransfer(collateralToken, msg.sender, remaining);
                        }
                    }
                }
            } else {
                ZAMM.cancelOrder(
                    address(PAMM),
                    tokenId,
                    order.shares,
                    collateralToken,
                    0,
                    order.collateral,
                    order.deadline,
                    order.partialFill
                );
                if (zammDeadline != 0) {
                    uint96 remaining = order.shares - inDone;
                    if (remaining > 0) {
                        PAMM.transfer(msg.sender, tokenId, remaining);
                    }
                }
            }

            delete orders[orderHash];
            emit OrderCancelled(orderHash);
            ++cancelled;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Validate market and return collateral token.
    function _validateAndGetCollateral(uint256 marketId) private view returns (address collateral) {
        address resolver;
        (resolver,,,,, collateral,) = PAMM.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        if (!PAMM.tradingOpen(marketId)) revert TradingNotOpen();
    }

    /// @dev Transfer ETH to recipient.
    function _safeTransferETH(address to, uint256 amount) private {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                revert(0, 0)
            }
        }
    }

    /// @dev Transfer ERC20 tokens to recipient.
    function _safeTransfer(address token, address to, uint256 amount) private {
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

    /// @dev Transfer ERC20 tokens from sender to recipient.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
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

    /// @dev Ensure max approval for spender if not already set.
    function _ensureApproval(address token, address spender) private {
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

    /// @dev Ensure ZAMM is operator for this contract on PAMM.
    function _ensureOperatorPAMM() private {
        if (!PAMM.isOperator(address(this), address(ZAMM))) {
            PAMM.setOperator(address(ZAMM), true);
        }
    }
}
