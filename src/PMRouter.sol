// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice ZAMM orderbook + AMM interface.
interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

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
    ) external payable;

    function orders(bytes32 orderHash)
        external
        view
        returns (bool partialFill, uint56 deadline, uint96 inDone, uint96 outDone);

    // AMM
    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function deposit(address token, uint256 id, uint256 amount) external payable;

    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount);
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
///
/// Behavioral Notes:
/// - Deadline semantics: Swap functions (swapShares, swapSharesToCollateral, swapCollateralToShares,
///   fillOrdersThenSwap) treat `deadline == 0` as `block.timestamp` (execute now). Market order
///   functions (buy, sell) pass deadline through to PAMM unchanged. For limit orders, deadlines
///   are capped to the market's close time.
/// - Expired orders: Orders that have expired (deadline passed) can still be cancelled to
///   reclaim escrowed funds. Users should call `cancelOrder` to recover collateral/shares.
/// - ERC20 compatibility: The safe transfer functions support non-standard ERC20s (like USDT)
///   that don't return a boolean value. Standard ERC20s returning false will revert.
/// - Partial fill rounding: ZAMM uses floor division for partial fills, which can result in
///   negligible dust (at most 1 wei per fill). For orders filled in N fragments, maximum dust
///   is N wei - effectively zero for 18-decimal tokens. This is protocol-acceptable precision
///   loss, not a loss of funds.
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

    error AmountZero();
    error Reentrancy();
    error MustFillAll();
    error OrderExists();
    error HashMismatch();
    error MarketClosed();
    error ApproveFailed();
    error NotOrderOwner();
    error OrderInactive();
    error OrderNotFound();
    error MarketNotFound();
    error TradingNotOpen();
    error TransferFailed();
    error DeadlineExpired();
    error InvalidETHAmount();
    error SlippageExceeded();
    error ETHTransferFailed();
    error InvalidFillAmount();
    error TransferFromFailed();

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

    event ProceedsClaimed(bytes32 indexed orderHash, address indexed to, uint96 amount);

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
    mapping(bytes32 => uint96) public claimedOut; // proceeds already forwarded to owner

    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() payable {
        // Allow ZAMM to pull PAMM shares from this contract for order fills and swaps
        PAMM.setOperator(address(ZAMM), true);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               MULTICALL
    //////////////////////////////////////////////////////////////*/

    /// @dev For ETH operations, msg.value must equal the exact amount needed by the single
    ///      payable call in the batch. Cannot batch multiple ETH operations together.
    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
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

    /// @notice ERC20Permit (EIP-2612) - approve via signature.
    /// @dev Use with multicall: [permit, placeOrder] in single tx.
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

    /// @notice DAI-style permit - approve via signature with nonce.
    /// @dev DAI uses: permit(holder, spender, nonce, expiry, allowed, v, r, s)
    function permitDAI(
        address token,
        address holder,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x8fcbaf0c00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), holder)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), nonce)
            mstore(add(m, 0x64), expiry)
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

        // Precompute orderHash to prevent reuse while local state exists
        // ZAMM hash: keccak256(abi.encode(maker, tokenIn, idIn, amtIn, tokenOut, idOut, amtOut, deadline, partialFill))
        address pamm = address(PAMM);
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, address())
            switch isBuy
            case 1 {
                // BUY: collateral -> shares
                mstore(add(m, 0x20), collateralToken)
                mstore(add(m, 0x40), 0)
                mstore(add(m, 0x60), collateral)
                mstore(add(m, 0x80), pamm)
                mstore(add(m, 0xa0), tokenId)
                mstore(add(m, 0xc0), shares)
            }
            default {
                // SELL: shares -> collateral
                mstore(add(m, 0x20), pamm)
                mstore(add(m, 0x40), tokenId)
                mstore(add(m, 0x60), shares)
                mstore(add(m, 0x80), collateralToken)
                mstore(add(m, 0xa0), 0)
                mstore(add(m, 0xc0), collateral)
            }
            mstore(add(m, 0xe0), deadline)
            mstore(add(m, 0x100), partialFill)
            orderHash := keccak256(m, 0x120)
        }
        if (orders[orderHash].owner != address(0)) revert OrderExists();

        // Create order on ZAMM and verify hash matches
        bytes32 zammHash;
        if (isBuy) {
            // BUY: escrow collateral, receive shares on fill
            if (collateralToken == ETH) {
                if (msg.value != collateral) revert InvalidETHAmount();
                zammHash = ZAMM.makeOrder{value: collateral}(
                    ETH, 0, collateral, address(PAMM), tokenId, shares, deadline, partialFill
                );
            } else {
                if (msg.value != 0) revert InvalidETHAmount();
                _safeTransferFrom(collateralToken, msg.sender, address(this), collateral);
                _ensureApproval(collateralToken, address(ZAMM));
                zammHash = ZAMM.makeOrder(
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
            zammHash = ZAMM.makeOrder(
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
        if (zammHash != orderHash) revert HashMismatch();

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

    /// @notice Cancel order and reclaim escrowed tokens plus any unclaimed proceeds.
    /// @dev Can be called even after order expires to recover funds. Unfilled/partially
    ///      filled orders will return remaining collateral (buy) or shares (sell) to owner.
    function cancelOrder(bytes32 orderHash) public nonReentrant {
        Order storage order = orders[orderHash];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert NotOrderOwner();
        _cancelOrder(orderHash, order, msg.sender);
    }

    /// @notice Claim proceeds from orders filled directly on ZAMM.
    /// @dev If someone fills your order directly on ZAMM (bypassing PMRouter), your proceeds
    ///      accumulate in PMRouter. Call this to withdraw them. Also called automatically
    ///      during cancelOrder.
    /// @param orderHash Order to claim proceeds from
    /// @param to Recipient of proceeds
    /// @return amount Amount of proceeds claimed (shares for BUY orders, collateral for SELL)
    function claimProceeds(bytes32 orderHash, address to)
        public
        nonReentrant
        returns (uint96 amount)
    {
        Order storage order = orders[orderHash];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (to == address(0)) to = msg.sender;

        amount = _claimProceeds(orderHash, order, to);
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
        Order storage order = orders[orderHash];
        if (order.owner == address(0)) revert OrderNotFound();
        if (to == address(0)) to = msg.sender;

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

        if (order.isBuy) {
            // Maker buying shares: taker sells shares, receives collateral
            // BUY order: tokenIn=collateral, tokenOut=shares, fillPart=shares (output)
            if (msg.value != 0) revert InvalidETHAmount();
            PAMM.transferFrom(msg.sender, address(this), tokenId, sharesToFill);

            ZAMM.fillOrder(
                address(this),
                collateralToken,
                0,
                order.collateral,
                address(PAMM),
                tokenId,
                order.shares,
                order.deadline,
                order.partialFill,
                sharesToFill // fillPart = output amount (shares)
            );

            // Calculate actual fill from state diff (order may be deleted if fully filled)
            (, uint56 deadlineAfter, uint96 inDoneAfter, uint96 outDoneAfter) =
                ZAMM.orders(orderHash);
            if (deadlineAfter == 0) {
                // Order was fully filled and deleted - use total amounts
                sharesFilled = order.shares - outDone;
                collateralFilled = order.collateral - inDone;
            } else {
                sharesFilled = outDoneAfter - outDone;
                collateralFilled = inDoneAfter - inDone;
            }

            // Collateral to taker
            if (collateralToken == ETH) {
                _safeTransferETH(to, collateralFilled);
            } else {
                _safeTransfer(collateralToken, to, collateralFilled);
            }
            // Shares to order owner
            PAMM.transfer(order.owner, tokenId, sharesFilled);
            claimedOut[orderHash] += sharesFilled;
        } else {
            // Maker selling shares: taker buys shares, provides collateral
            // SELL order: tokenIn=shares, tokenOut=collateral, fillPart=collateral (output)
            uint96 expectedCollateral =
                uint96(uint256(order.collateral) * sharesToFill / order.shares);
            // Prevent fillPart=0 being interpreted as "fill all" by ZAMM when partialFill=true
            if (order.partialFill && expectedCollateral == 0) revert InvalidFillAmount();
            if (collateralToken == ETH) {
                if (msg.value < expectedCollateral) revert InvalidETHAmount();
                ZAMM.fillOrder{value: expectedCollateral}(
                    address(this),
                    address(PAMM),
                    tokenId,
                    order.shares,
                    ETH,
                    0,
                    order.collateral,
                    order.deadline,
                    order.partialFill,
                    expectedCollateral // fillPart = output amount (collateral)
                );

                // Calculate actual fill from state diff (order may be deleted if fully filled)
                (, uint56 deadlineAfter, uint96 inDoneAfter, uint96 outDoneAfter) =
                    ZAMM.orders(orderHash);
                if (deadlineAfter == 0) {
                    // Order was fully filled and deleted
                    sharesFilled = order.shares - inDone;
                    collateralFilled = order.collateral - outDone;
                } else {
                    sharesFilled = inDoneAfter - inDone;
                    collateralFilled = outDoneAfter - outDone;
                }
                if (msg.value > collateralFilled) {
                    _safeTransferETH(msg.sender, msg.value - collateralFilled);
                }
            } else {
                if (msg.value != 0) revert InvalidETHAmount();
                _safeTransferFrom(collateralToken, msg.sender, address(this), expectedCollateral);
                _ensureApproval(collateralToken, address(ZAMM));
                ZAMM.fillOrder(
                    address(this),
                    address(PAMM),
                    tokenId,
                    order.shares,
                    collateralToken,
                    0,
                    order.collateral,
                    order.deadline,
                    order.partialFill,
                    expectedCollateral // fillPart = output amount (collateral)
                );

                // Calculate actual fill from state diff (order may be deleted if fully filled)
                (, uint56 deadlineAfter, uint96 inDoneAfter, uint96 outDoneAfter) =
                    ZAMM.orders(orderHash);
                if (deadlineAfter == 0) {
                    // Order was fully filled and deleted
                    sharesFilled = order.shares - inDone;
                    collateralFilled = order.collateral - outDone;
                } else {
                    sharesFilled = inDoneAfter - inDone;
                    collateralFilled = outDoneAfter - outDone;
                }
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
            claimedOut[orderHash] += collateralFilled;
        }

        emit OrderFilled(orderHash, msg.sender, sharesFilled, collateralFilled);
    }

    /*//////////////////////////////////////////////////////////////
                           MARKET ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy YES or NO shares via PAMM AMM.
    /// @param deadline Timestamp after which tx reverts (passed to PAMM as-is)
    function buy(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) revert TradingNotOpen();

        (,,,,, address collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralIn) revert InvalidETHAmount();
            sharesOut = isYes
                ? PAMM.buyYes{value: collateralIn}(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, deadline
                )
                : PAMM.buyNo{value: collateralIn}(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, deadline
                );
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(PAMM));
            sharesOut = isYes
                ? PAMM.buyYes(marketId, collateralIn, minSharesOut, 0, feeOrHook, to, deadline)
                : PAMM.buyNo(marketId, collateralIn, minSharesOut, 0, feeOrHook, to, deadline);
        }
    }

    /// @notice Sell YES or NO shares via PAMM AMM.
    /// @param deadline Timestamp after which tx reverts (passed to PAMM as-is)
    function sell(
        uint256 marketId,
        bool isYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 collateralOut) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) revert TradingNotOpen();

        uint256 noId = PAMM.getNoId(marketId);
        uint256 tokenId = isYes ? marketId : noId;

        // Track balances BEFORE user transfer to forward leftovers after
        address pamm = address(PAMM);
        uint256 yesBefore;
        uint256 noBefore;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x00fdd58e00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), address())
            mstore(add(m, 0x24), marketId)
            if iszero(staticcall(gas(), pamm, m, 0x44, 0x00, 0x20)) { revert(0, 0) }
            yesBefore := mload(0x00)
            mstore(add(m, 0x24), noId)
            if iszero(staticcall(gas(), pamm, m, 0x44, 0x00, 0x20)) { revert(0, 0) }
            noBefore := mload(0x00)
        }

        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);

        collateralOut = isYes
            ? PAMM.sellYes(marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, deadline)
            : PAMM.sellNo(marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, deadline);

        // Forward any leftovers to user (balance above pre-transfer level)
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x00fdd58e00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), address())
            mstore(add(m, 0x24), marketId)
            if iszero(staticcall(gas(), pamm, m, 0x44, 0x00, 0x20)) { revert(0, 0) }
            let yesAfter := mload(0x00)
            if gt(yesAfter, yesBefore) {
                let leftoverYes := sub(yesAfter, yesBefore)
                mstore(m, 0x095bcdb600000000000000000000000000000000000000000000000000000000)
                mstore(add(m, 0x04), to)
                mstore(add(m, 0x24), marketId)
                mstore(add(m, 0x44), leftoverYes)
                if iszero(call(gas(), pamm, 0, m, 0x64, 0, 0)) { revert(0, 0) }
            }
            mstore(m, 0x00fdd58e00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), address())
            mstore(add(m, 0x24), noId)
            if iszero(staticcall(gas(), pamm, m, 0x44, 0x00, 0x20)) { revert(0, 0) }
            let noAfter := mload(0x00)
            if gt(noAfter, noBefore) {
                let leftoverNo := sub(noAfter, noBefore)
                mstore(m, 0x095bcdb600000000000000000000000000000000000000000000000000000000)
                mstore(add(m, 0x04), to)
                mstore(add(m, 0x24), noId)
                mstore(add(m, 0x44), leftoverNo)
                if iszero(call(gas(), pamm, 0, m, 0x64, 0, 0)) { revert(0, 0) }
            }
        }
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
    /// @param deadline Timestamp after which tx reverts (0 = execute immediately)
    function swapShares(
        uint256 marketId,
        bool yesForNo,
        uint256 amountIn,
        uint256 minOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 amountOut) {
        if (to == address(0)) to = msg.sender;
        _validateAndGetCollateral(marketId);

        uint256 yesId = marketId;
        uint256 noId = PAMM.getNoId(marketId);

        uint256 tokenIn = yesForNo ? yesId : noId;

        PAMM.transferFrom(msg.sender, address(this), tokenIn, amountIn);

        IZAMM.PoolKey memory key = _poolKey(address(PAMM), yesId, address(PAMM), noId, feeOrHook);
        bool zeroForOne = key.id0 == tokenIn;
        uint256 dl = deadline == 0 ? block.timestamp : deadline;

        ZAMM.deposit(address(PAMM), tokenIn, amountIn);
        amountOut = ZAMM.swapExactIn(key, amountIn, minOut, zeroForOne, to, dl);
        ZAMM.recoverTransientBalance(address(PAMM), tokenIn, address(this));
    }

    /// @notice Swap shares directly to collateral via ZAMM AMM (not PAMM).
    /// @dev Uses ZAMM's share/collateral pools if they exist.
    /// @param deadline Timestamp after which tx reverts (0 = execute immediately)
    function swapSharesToCollateral(
        uint256 marketId,
        bool isYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 collateralOut) {
        if (to == address(0)) to = msg.sender;
        address collateral = _validateAndGetCollateral(marketId);
        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);

        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);

        IZAMM.PoolKey memory key = _poolKey(address(PAMM), tokenId, collateral, 0, feeOrHook);
        bool zeroForOne = key.token0 == address(PAMM) && key.id0 == tokenId;
        uint256 dl = deadline == 0 ? block.timestamp : deadline;

        ZAMM.deposit(address(PAMM), tokenId, sharesIn);
        collateralOut = ZAMM.swapExactIn(key, sharesIn, minCollateralOut, zeroForOne, to, dl);
        ZAMM.recoverTransientBalance(address(PAMM), tokenId, address(this));
    }

    /// @notice Swap collateral directly to shares via ZAMM AMM (not PAMM).
    /// @param deadline Timestamp after which tx reverts (0 = execute immediately)
    function swapCollateralToShares(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;
        address collateral = _validateAndGetCollateral(marketId);
        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);

        IZAMM.PoolKey memory key = _poolKey(collateral, 0, address(PAMM), tokenId, feeOrHook);
        bool zeroForOne = key.token0 == collateral && key.id0 == 0;
        uint256 dl = deadline == 0 ? block.timestamp : deadline;

        if (collateral == ETH) {
            if (msg.value != collateralIn) revert InvalidETHAmount();
            ZAMM.deposit{value: collateralIn}(ETH, 0, collateralIn);
            sharesOut = ZAMM.swapExactIn(key, collateralIn, minSharesOut, zeroForOne, to, dl);
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(ZAMM));
            ZAMM.deposit(collateral, 0, collateralIn);
            sharesOut = ZAMM.swapExactIn(key, collateralIn, minSharesOut, zeroForOne, to, dl);
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
    /// @param deadline Timestamp after which tx reverts (0 = execute immediately)
    function fillOrdersThenSwap(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint256 totalAmount,
        uint256 minOutput,
        bytes32[] calldata orderHashes,
        uint256 feeOrHook,
        address to,
        uint256 deadline
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

            // Try filling orders (orders where maker is selling shares)
            // SELL orders: tokenIn=shares, tokenOut=collateral, fillPart=collateral (output to maker)
            for (uint256 i; i < orderHashes.length && remaining > 0; ++i) {
                Order storage order = orders[orderHashes[i]];
                if (
                    order.owner == address(0) || order.marketId != marketId || order.isYes != isYes
                        || order.isBuy
                ) continue;

                (, uint56 orderDeadline, uint96 inDone, uint96 outDone) =
                    ZAMM.orders(orderHashes[i]);
                if (orderDeadline == 0 || block.timestamp > orderDeadline) continue;

                uint96 sharesAvail = order.shares - inDone;
                if (sharesAvail == 0) continue;

                uint96 collateralNeeded =
                    uint96(uint256(order.collateral) * sharesAvail / order.shares);
                uint96 collateralToUse =
                    remaining >= collateralNeeded ? collateralNeeded : uint96(remaining);
                if (
                    collateralToUse == 0
                        || (!order.partialFill && collateralToUse != collateralNeeded)
                ) {
                    continue;
                }

                if (collateral == ETH) {
                    ZAMM.fillOrder{value: collateralToUse}(
                        address(this),
                        address(PAMM),
                        tokenId,
                        order.shares,
                        ETH,
                        0,
                        order.collateral,
                        order.deadline,
                        order.partialFill,
                        collateralToUse // fillPart = output amount (collateral to maker)
                    );
                } else {
                    ZAMM.fillOrder(
                        address(this),
                        address(PAMM),
                        tokenId,
                        order.shares,
                        collateral,
                        0,
                        order.collateral,
                        order.deadline,
                        order.partialFill,
                        collateralToUse // fillPart = output amount (collateral to maker)
                    );
                }

                // Calculate actual fill from state diff (order may be deleted if fully filled)
                (, uint56 deadlineAfter, uint96 inDoneAfter, uint96 outDoneAfter) =
                    ZAMM.orders(orderHashes[i]);
                uint96 filled;
                uint96 collateralFilled;
                if (deadlineAfter == 0) {
                    // Order was fully filled and deleted
                    filled = order.shares - inDone;
                    collateralFilled = order.collateral - outDone;
                } else {
                    filled = inDoneAfter - inDone;
                    collateralFilled = outDoneAfter - outDone;
                }

                // Transfer shares to buyer, collateral to seller
                PAMM.transfer(to, tokenId, filled);
                if (collateral == ETH) {
                    _safeTransferETH(order.owner, collateralFilled);
                } else {
                    _safeTransfer(collateral, order.owner, collateralFilled);
                }
                claimedOut[orderHashes[i]] += collateralFilled;

                emit OrderFilled(orderHashes[i], msg.sender, filled, collateralFilled);

                totalOutput += filled;
                remaining -= collateralFilled;
            }

            // Swap remainder via AMM
            if (remaining > 0) {
                IZAMM.PoolKey memory key =
                    _poolKey(collateral, 0, address(PAMM), tokenId, feeOrHook);
                bool zeroForOne = key.token0 == collateral && key.id0 == 0;
                uint256 dl = deadline == 0 ? block.timestamp : deadline;
                if (collateral == ETH) {
                    ZAMM.deposit{value: remaining}(ETH, 0, remaining);
                } else {
                    ZAMM.deposit(collateral, 0, remaining);
                }
                totalOutput += ZAMM.swapExactIn(key, remaining, 0, zeroForOne, to, dl);
            }
        } else {
            // Selling shares for collateral
            if (msg.value != 0) revert InvalidETHAmount();
            PAMM.transferFrom(msg.sender, address(this), tokenId, totalAmount);

            // Try filling orders (orders where maker is buying shares)
            // BUY orders: tokenIn=collateral, tokenOut=shares, fillPart=shares (output to maker)
            for (uint256 i; i < orderHashes.length && remaining > 0; ++i) {
                Order storage order = orders[orderHashes[i]];
                if (
                    order.owner == address(0) || order.marketId != marketId || order.isYes != isYes
                        || !order.isBuy
                ) continue;

                (, uint56 orderDeadline, uint96 inDone, uint96 outDone) =
                    ZAMM.orders(orderHashes[i]);
                if (orderDeadline == 0 || block.timestamp > orderDeadline) continue;

                uint96 sharesAvail = order.shares - outDone;
                if (sharesAvail == 0) continue;

                uint96 sharesToFill = remaining >= sharesAvail ? sharesAvail : uint96(remaining);
                if (!order.partialFill && sharesToFill != sharesAvail) continue;

                ZAMM.fillOrder(
                    address(this),
                    collateral,
                    0,
                    order.collateral,
                    address(PAMM),
                    tokenId,
                    order.shares,
                    order.deadline,
                    order.partialFill,
                    sharesToFill // fillPart = output amount (shares to maker)
                );

                // Calculate actual fill from state diff (order may be deleted if fully filled)
                (, uint56 deadlineAfter, uint96 inDoneAfter, uint96 outDoneAfter) =
                    ZAMM.orders(orderHashes[i]);
                uint96 filled;
                uint96 collateralFilled;
                if (deadlineAfter == 0) {
                    // Order was fully filled and deleted
                    filled = order.shares - outDone;
                    collateralFilled = order.collateral - inDone;
                } else {
                    filled = outDoneAfter - outDone;
                    collateralFilled = inDoneAfter - inDone;
                }

                // Transfer collateral to seller, shares to buyer
                if (collateral == ETH) {
                    _safeTransferETH(to, collateralFilled);
                } else {
                    _safeTransfer(collateral, to, collateralFilled);
                }
                PAMM.transfer(order.owner, tokenId, filled);
                claimedOut[orderHashes[i]] += filled;

                emit OrderFilled(orderHashes[i], msg.sender, filled, collateralFilled);

                totalOutput += collateralFilled;
                remaining -= filled;
            }

            // Swap remainder via AMM
            if (remaining > 0) {
                IZAMM.PoolKey memory key =
                    _poolKey(address(PAMM), tokenId, collateral, 0, feeOrHook);
                bool zeroForOne = key.token0 == address(PAMM) && key.id0 == tokenId;
                uint256 dl = deadline == 0 ? block.timestamp : deadline;
                ZAMM.deposit(address(PAMM), tokenId, remaining);
                totalOutput += ZAMM.swapExactIn(key, remaining, 0, zeroForOne, to, dl);
                ZAMM.recoverTransientBalance(address(PAMM), tokenId, address(this));
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

        PAMM.merge(marketId, amount, to);
    }

    /// @notice Claim winnings from resolved market.
    function claim(uint256 marketId, address to) public nonReentrant returns (uint256 payout) {
        if (to == address(0)) to = msg.sender;
        address pamm = address(PAMM);
        assembly ("memory-safe") {
            let m := mload(0x40)
            // getNoId(marketId) - selector 0x4076ac51
            mstore(m, 0x4076ac5100000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), marketId)
            if iszero(staticcall(gas(), pamm, m, 0x24, 0x00, 0x20)) { revert(0, 0) }
            let noId := mload(0x00)
            // balanceOf(msg.sender, marketId) - selector 0x00fdd58e
            mstore(m, 0x00fdd58e00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), caller())
            mstore(add(m, 0x24), marketId)
            if iszero(staticcall(gas(), pamm, m, 0x44, 0x00, 0x20)) { revert(0, 0) }
            let yesBal := mload(0x00)
            // balanceOf(msg.sender, noId)
            mstore(add(m, 0x24), noId)
            if iszero(staticcall(gas(), pamm, m, 0x44, 0x00, 0x20)) { revert(0, 0) }
            let noBal := mload(0x00)
            // transferFrom(msg.sender, this, marketId, yesBal) if yesBal > 0 - selector 0xfe99049a
            if yesBal {
                mstore(m, 0xfe99049a00000000000000000000000000000000000000000000000000000000)
                mstore(add(m, 0x04), caller())
                mstore(add(m, 0x24), address())
                mstore(add(m, 0x44), marketId)
                mstore(add(m, 0x64), yesBal)
                if iszero(call(gas(), pamm, 0, m, 0x84, 0, 0)) { revert(0, 0) }
            }
            // transferFrom(msg.sender, this, noId, noBal) if noBal > 0
            if noBal {
                mstore(m, 0xfe99049a00000000000000000000000000000000000000000000000000000000)
                mstore(add(m, 0x04), caller())
                mstore(add(m, 0x24), address())
                mstore(add(m, 0x44), noId)
                mstore(add(m, 0x64), noBal)
                if iszero(call(gas(), pamm, 0, m, 0x84, 0, 0)) { revert(0, 0) }
            }
            // claim(marketId, to) - selector 0xddd5e1b2
            mstore(m, 0xddd5e1b200000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), marketId)
            mstore(add(m, 0x24), to)
            if iszero(call(gas(), pamm, 0, m, 0x44, 0x00, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            payout := mload(0x00)
        }
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

        // ZAMM deletes fully-filled orders (returns deadline=0, inDone=0, outDone=0)
        // If our local order exists but ZAMM's is deleted, treat as fully filled
        if (deadline == 0) {
            return (order, order.shares, 0, order.collateral, 0, false);
        }

        if (order.isBuy) {
            collateralFilled = inDone;
            sharesFilled = outDone;
        } else {
            sharesFilled = inDone;
            collateralFilled = outDone;
        }

        sharesRemaining = order.shares - sharesFilled;
        collateralRemaining = order.collateral - collateralFilled;
        active = block.timestamp <= deadline && sharesRemaining > 0;
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

        // Iterate backwards: newer orders more likely to be active
        bytes32[] memory tempHashes = new bytes32[](limit);
        Order[] memory tempOrders = new Order[](limit);
        uint256 count;

        for (uint256 i = len; i > 0 && count < limit;) {
            --i;
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

    /*//////////////////////////////////////////////////////////////
                             UX HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get combined orderbook (bids + asks) for a market.
    function getOrderbook(uint256 marketId, bool isYes, uint256 depth)
        external
        view
        returns (
            bytes32[] memory bidHashes,
            Order[] memory bidOrders,
            bytes32[] memory askHashes,
            Order[] memory askOrders
        )
    {
        (bidHashes, bidOrders) = getActiveOrders(marketId, isYes, true, depth);
        (askHashes, askOrders) = getActiveOrders(marketId, isYes, false, depth);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Claim any unclaimed proceeds for an order and transfer to recipient.
    function _claimProceeds(bytes32 orderHash, Order storage order, address to)
        private
        returns (uint96 amount)
    {
        (, uint56 deadline,, uint96 out) = ZAMM.orders(orderHash);
        uint96 outDoneTotal = deadline == 0 ? (order.isBuy ? order.shares : order.collateral) : out;
        uint96 already = claimedOut[orderHash];
        if (outDoneTotal <= already) return 0;

        amount = outDoneTotal - already;
        claimedOut[orderHash] = outDoneTotal;

        (,,,,, address collateralToken,) = PAMM.markets(order.marketId);
        uint256 tokenId = order.isYes ? order.marketId : PAMM.getNoId(order.marketId);

        if (order.isBuy) {
            PAMM.transfer(to, tokenId, amount);
        } else if (collateralToken == ETH) {
            _safeTransferETH(to, amount);
        } else {
            _safeTransfer(collateralToken, to, amount);
        }

        emit ProceedsClaimed(orderHash, to, amount);
    }

    /// @dev Cancel order: claim proceeds, cancel on ZAMM if live, refund principal, cleanup.
    function _cancelOrder(bytes32 orderHash, Order storage order, address to) private {
        (,,,,, address collateralToken,) = PAMM.markets(order.marketId);
        uint256 tokenId = order.isYes ? order.marketId : PAMM.getNoId(order.marketId);
        (, uint56 zammDeadline, uint96 inDone, uint96 outDone) = ZAMM.orders(orderHash);

        // Claim any unclaimed proceeds
        uint96 outDoneTotal =
            zammDeadline == 0 ? (order.isBuy ? order.shares : order.collateral) : outDone;
        uint96 already = claimedOut[orderHash];
        if (outDoneTotal > already) {
            uint96 claimAmount = outDoneTotal - already;
            claimedOut[orderHash] = outDoneTotal;

            if (order.isBuy) {
                PAMM.transfer(to, tokenId, claimAmount);
            } else if (collateralToken == ETH) {
                _safeTransferETH(to, claimAmount);
            } else {
                _safeTransfer(collateralToken, to, claimAmount);
            }

            emit ProceedsClaimed(orderHash, to, claimAmount);
        }

        // Cancel on ZAMM and refund principal if order still exists
        if (zammDeadline != 0) {
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
                uint96 remaining = order.collateral - inDone;
                if (remaining > 0) {
                    if (collateralToken == ETH) {
                        _safeTransferETH(to, remaining);
                    } else {
                        _safeTransfer(collateralToken, to, remaining);
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
                uint96 remaining = order.shares - inDone;
                if (remaining > 0) {
                    PAMM.transfer(to, tokenId, remaining);
                }
            }
        }

        delete orders[orderHash];
        delete claimedOut[orderHash];
        emit OrderCancelled(orderHash);
    }

    /// @dev Validate market and return collateral token.
    /// @dev Inlines tradingOpen check to avoid duplicate external call.
    function _validateAndGetCollateral(uint256 marketId) private view returns (address collateral) {
        address resolver;
        bool resolved;
        uint64 close;
        (resolver, resolved,, , close, collateral,) = PAMM.markets(marketId);
        if (resolver == address(0)) revert MarketNotFound();
        // Inline tradingOpen: resolver != 0 (checked above) && !resolved && timestamp < close
        if (resolved || block.timestamp >= close) revert TradingNotOpen();
    }

    /// @dev Transfer ETH to recipient.
    function _safeTransferETH(address to, uint256 amount) private {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Transfer ERC20 tokens to recipient.
    function _safeTransfer(address token, address to, uint256 amount) private {
        assembly ("memory-safe") {
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0xa9059cbb000000000000000000000000) // transfer(address,uint256)
            let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, 0x90b8ec18) // TransferFailed()
                    revert(0x1c, 0x04)
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
            mstore(0x0c, 0x23b872dd000000000000000000000000) // transferFrom(address,address,uint256)
            let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, 0x7939f424) // TransferFromFailed()
                    revert(0x1c, 0x04)
                }
            }
            mstore(0x60, 0)
            mstore(0x40, m)
        }
    }

    /// @dev Ensure max approval for spender if not already set.
    function _ensureApproval(address token, address spender) private {
        assembly ("memory-safe") {
            mstore(0x00, 0xdd62ed3e000000000000000000000000) // allowance(address,address)
            mstore(0x14, address())
            mstore(0x34, spender)
            let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)
            // If allowance <= uint128.max, set max approval
            if iszero(and(success, gt(mload(0x00), 0xffffffffffffffffffffffffffffffff))) {
                mstore(0x14, spender)
                mstore(0x34, not(0))
                mstore(0x00, 0x095ea7b3000000000000000000000000)
                success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                        mstore(0x00, 0x3e3f8f73)
                        revert(0x1c, 0x04)
                    }
                }
            }
            mstore(0x34, 0)
        }
    }

    /// @dev Build ZAMM pool key with proper token ordering.
    /// ZAMM requires token0 < token1, or if same token, id0 < id1.
    function _poolKey(address tokenA, uint256 idA, address tokenB, uint256 idB, uint256 feeOrHook)
        private
        pure
        returns (IZAMM.PoolKey memory key)
    {
        if (tokenA < tokenB || (tokenA == tokenB && idA < idB)) {
            key = IZAMM.PoolKey({
                id0: idA, id1: idB, token0: tokenA, token1: tokenB, feeOrHook: feeOrHook
            });
        } else {
            key = IZAMM.PoolKey({
                id0: idB, id1: idA, token0: tokenB, token1: tokenA, feeOrHook: feeOrHook
            });
        }
    }
}
