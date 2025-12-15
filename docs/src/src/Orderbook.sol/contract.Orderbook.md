# Orderbook
[Git Source](https://github.com/zammdefi/pm/blob/6409aa225054aeb8e5eb04dafccaae59a1d0f4cc/src/Orderbook.sol)

**Title:**
Orderbook

Complete orderbook for PAMM prediction markets using ZAMM backend.

Features: limit orders, market orders, batch operations, discoverability, fills.
Compatible with all PAMM markets including those created via Resolver and GasPM.


## State Variables
### pamm

```solidity
IPAMM public immutable pamm
```


### ZAMM

```solidity
IZAMMOrderbook public constant ZAMM =
    IZAMMOrderbook(0x000000000000040470635EB91b7CE4D132D616eD)
```


### ETH

```solidity
address internal constant ETH = address(0)
```


### _marketOrders
Order hashes per market for discoverability.


```solidity
mapping(uint256 marketId => bytes32[]) internal _marketOrders
```


### limitOrders
Order metadata by hash (owner, market, params).


```solidity
mapping(bytes32 orderHash => LimitOrder) public limitOrders
```


### _userOrders
Orders by user for discoverability.


```solidity
mapping(address user => bytes32[]) internal _userOrders
```


### activeOrderCount
Active order count per market (for efficient filtering).


```solidity
mapping(uint256 marketId => uint256) public activeOrderCount
```


### _locked
Reentrancy lock.


```solidity
uint256 private _locked = 1
```


## Functions
### nonReentrant


```solidity
modifier nonReentrant() ;
```

### constructor


```solidity
constructor(address _pamm) ;
```

### receive


```solidity
receive() external payable;
```

### multicall

Batch multiple calls in a single transaction.

Non-payable to prevent msg.value reuse. Use specific ETH functions.


```solidity
function multicall(bytes[] calldata data) public returns (bytes[] memory results);
```

### permit

EIP-2612 permit for gasless ERC20 approvals.


```solidity
function permit(
    address token,
    address owner,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) public;
```

### permitDAI

DAI-style permit for gasless approvals.


```solidity
function permitDAI(
    address token,
    address owner,
    uint256 nonce,
    uint256 deadline,
    bool allowed,
    uint8 v,
    bytes32 r,
    bytes32 s
) public;
```

### placeLimitOrder

Place a limit order to buy or sell YES/NO shares.

Uses this contract as maker on ZAMM; escrows tokens and tracks ownership.
For BUY orders: user provides collateral (ETH via msg.value or ERC20).
For SELL orders: user provides shares (must have approved this contract).


```solidity
function placeLimitOrder(
    uint256 marketId,
    bool isYes,
    bool isBuy,
    uint96 shares,
    uint96 collateral,
    uint56 deadline,
    bool partialFill
) public payable nonReentrant returns (bytes32 orderHash);
```

### batchPlaceLimitOrders

Place multiple limit orders in a single transaction.

All orders must be for ERC20 collateral markets (no ETH).


```solidity
function batchPlaceLimitOrders(PlaceOrderParams[] calldata orders)
    public
    nonReentrant
    returns (bytes32[] memory orderHashes);
```

### _placeLimitOrder


```solidity
function _placeLimitOrder(
    address owner,
    uint256 marketId,
    bool isYes,
    bool isBuy,
    uint96 shares,
    uint96 collateral,
    uint56 deadline,
    bool partialFill
) internal returns (bytes32 orderHash);
```

### cancelLimitOrder

Cancel own limit order and reclaim escrowed assets.


```solidity
function cancelLimitOrder(bytes32 orderHash) public nonReentrant;
```

### batchCancelLimitOrders

Cancel multiple limit orders.


```solidity
function batchCancelLimitOrders(bytes32[] calldata orderHashes) public nonReentrant;
```

### _cancelLimitOrder


```solidity
function _cancelLimitOrder(bytes32 orderHash) internal;
```

### fillOrder

Fill a limit order (as taker).


```solidity
function fillOrder(bytes32 orderHash, uint96 sharesToFill, address to)
    public
    payable
    nonReentrant
    returns (uint96 sharesFilled, uint96 collateralTransferred);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`orderHash`|`bytes32`|The order to fill|
|`sharesToFill`|`uint96`|Amount of shares to fill (0 = fill all available)|
|`to`|`address`|Recipient of output tokens (address(0) = msg.sender)|


### batchFillOrders

Fill multiple orders in sequence.


```solidity
function batchFillOrders(bytes32[] calldata orderHashes, uint96[] calldata amounts, address to)
    public
    payable
    nonReentrant
    returns (uint96 totalSharesFilled, uint96 totalCollateral);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`orderHashes`|`bytes32[]`|Orders to fill|
|`amounts`|`uint96[]`|Amounts to fill per order (0 = fill all)|
|`to`|`address`|Recipient of output tokens|


### marketBuyYes

Execute a market buy order for YES shares via PAMM's AMM.


```solidity
function marketBuyYes(
    uint256 marketId,
    uint256 collateralIn,
    uint256 minSharesOut,
    uint256 feeOrHook,
    address to
) public payable nonReentrant returns (uint256 sharesOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to trade|
|`collateralIn`|`uint256`|Amount of collateral to spend|
|`minSharesOut`|`uint256`|Minimum shares to receive (slippage protection)|
|`feeOrHook`|`uint256`|Pool fee tier|
|`to`|`address`|Recipient of shares|


### marketBuyNo

Execute a market buy order for NO shares via PAMM's AMM.


```solidity
function marketBuyNo(
    uint256 marketId,
    uint256 collateralIn,
    uint256 minSharesOut,
    uint256 feeOrHook,
    address to
) public payable nonReentrant returns (uint256 sharesOut);
```

### marketSellYes

Execute a market sell order for YES shares via PAMM's AMM.


```solidity
function marketSellYes(
    uint256 marketId,
    uint256 sharesIn,
    uint256 minCollateralOut,
    uint256 feeOrHook,
    address to
) public nonReentrant returns (uint256 collateralOut);
```

### marketSellNo

Execute a market sell order for NO shares via PAMM's AMM.


```solidity
function marketSellNo(
    uint256 marketId,
    uint256 sharesIn,
    uint256 minCollateralOut,
    uint256 feeOrHook,
    address to
) public nonReentrant returns (uint256 collateralOut);
```

### getMarketOrders

Get all order hashes for a market.


```solidity
function getMarketOrders(uint256 marketId) public view returns (bytes32[] memory);
```

### getUserOrders

Get all order hashes for a user.


```solidity
function getUserOrders(address user) public view returns (bytes32[] memory);
```

### getActiveMarketOrders

Get only active orders for a market.


```solidity
function getActiveMarketOrders(uint256 marketId)
    public
    view
    returns (bytes32[] memory activeHashes);
```

### getActiveUserOrders

Get only active orders for a user.


```solidity
function getActiveUserOrders(address user) public view returns (bytes32[] memory activeHashes);
```

### getOrderDetails

Get order details with current fill state from ZAMM.


```solidity
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
    );
```

### getOrderbookSorted

Get sorted orderbook for a market (bids high→low, asks low→high).


```solidity
function getOrderbookSorted(uint256 marketId, uint256 maxLevels)
    public
    view
    returns (OrderbookState memory state);
```

### _buildSortedSide


```solidity
function _buildSortedSide(bytes32[] memory allHashes, uint256 count, bool isBidSide)
    internal
    view
    returns (bytes32[] memory hashes, uint256[] memory prices, uint256[] memory sizes);
```

### _buildPriceLevels


```solidity
function _buildPriceLevels(
    PriceLevel[] memory levels,
    bytes32[] memory hashes,
    uint256[] memory prices,
    uint256[] memory sizes,
    uint256 count
) internal pure;
```

### getOrderbook

Get orderbook summary for a market (bids and asks for YES).


```solidity
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
    );
```

### _countBidsAsks


```solidity
function _countBidsAsks(bytes32[] memory allHashes)
    internal
    view
    returns (uint256 bidCount, uint256 askCount);
```

### _fillOrderbookArrays


```solidity
function _fillOrderbookArrays(
    bytes32[] memory allHashes,
    bytes32[] memory bidHashes,
    uint256[] memory bidPrices,
    uint256[] memory bidSizes,
    bytes32[] memory askHashes,
    uint256[] memory askPrices,
    uint256[] memory askSizes
) internal view;
```

### _getOrderPriceInfo


```solidity
function _getOrderPriceInfo(bytes32 h)
    internal
    view
    returns (uint256 price, uint96 remaining, bool isBid);
```

### getBestBidAsk

Get best bid and ask prices for a market.


```solidity
function getBestBidAsk(uint256 marketId)
    public
    view
    returns (uint256 bestBid, uint256 bestAsk, bytes32 bestBidHash, bytes32 bestAskHash);
```

### quoteOrder

Quote the effective price for filling an order.


```solidity
function quoteOrder(bytes32 orderHash, uint96 sharesToFill)
    public
    view
    returns (uint256 pricePerShare, uint256 totalCollateral, uint96 sharesAvailable);
```

### getFillParams

Get ZAMM fill params for an order (for direct ZAMM.fillOrder calls).


```solidity
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
    );
```

### isOrderActive

Check if an order is currently active.


```solidity
function isOrderActive(bytes32 orderHash) public view returns (bool);
```

### _isOrderActive


```solidity
function _isOrderActive(bytes32 orderHash) internal view returns (bool);
```

### pruneMarketOrders

Prune inactive orders from market's order list.

Anyone can call to clean up storage. Does not affect ZAMM state.


```solidity
function pruneMarketOrders(uint256 marketId, uint256 maxToPrune)
    public
    returns (uint256 pruned);
```

### pruneUserOrders

Prune inactive orders from user's order list.


```solidity
function pruneUserOrders(address user, uint256 maxToPrune) public returns (uint256 pruned);
```

### safeTransferETH


```solidity
function safeTransferETH(address to, uint256 amount) internal;
```

### safeTransfer


```solidity
function safeTransfer(address token, address to, uint256 amount) internal;
```

### safeTransferFrom


```solidity
function safeTransferFrom(address token, address from, address to, uint256 amount) internal;
```

### _ensureApproval

Ensure max approval to spender if needed.


```solidity
function _ensureApproval(address token, address spender) internal;
```

### _ensureApprovalPAMM

Ensure this contract is operator on PAMM for ZAMM pulls.


```solidity
function _ensureApprovalPAMM() internal;
```

## Events
### LimitOrderPlaced

```solidity
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
```

### LimitOrderFilled

```solidity
event LimitOrderFilled(
    uint256 indexed marketId,
    bytes32 indexed orderHash,
    address indexed taker,
    uint96 sharesFilled,
    uint96 collateralTransferred
);
```

### LimitOrderCancelled

```solidity
event LimitOrderCancelled(uint256 indexed marketId, bytes32 indexed orderHash);
```

### MarketOrderExecuted

```solidity
event MarketOrderExecuted(
    uint256 indexed marketId,
    address indexed trader,
    bool isYes,
    bool isBuy,
    uint256 amountIn,
    uint256 amountOut
);
```

## Errors
### AmountZero

```solidity
error AmountZero();
```

### ArrayMismatch

```solidity
error ArrayMismatch();
```

### OrderNotFound

```solidity
error OrderNotFound();
```

### OrderInactive

```solidity
error OrderInactive();
```

### NotOrderOwner

```solidity
error NotOrderOwner();
```

### MustFillAll

```solidity
error MustFillAll();
```

### NothingToFill

```solidity
error NothingToFill();
```

### MarketNotFound

```solidity
error MarketNotFound();
```

### MarketClosed

```solidity
error MarketClosed();
```

### MarketResolved

```solidity
error MarketResolved();
```

### DeadlineExpired

```solidity
error DeadlineExpired();
```

### InvalidETHAmount

```solidity
error InvalidETHAmount();
```

### WrongCollateralType

```solidity
error WrongCollateralType();
```

### TradingNotOpen

```solidity
error TradingNotOpen();
```

### Reentrancy

```solidity
error Reentrancy();
```

## Structs
### LimitOrder
Limit order metadata for discoverability (actual order state in ZAMM).

Packed into 3 storage slots (was 4). Order: owner+deadline+flags | shares+collateral | marketId


```solidity
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
```

### PlaceOrderParams
Parameters for placing a batch of orders.


```solidity
struct PlaceOrderParams {
    uint256 marketId;
    bool isYes;
    bool isBuy;
    uint96 shares;
    uint96 collateral;
    uint56 deadline;
    bool partialFill;
}
```

### PriceLevel
Orderbook level with aggregated size.


```solidity
struct PriceLevel {
    uint256 price; // 1e18-scaled price
    uint256 size; // total shares at this price
    bytes32[] orderHashes; // orders at this level
}
```

### OrderbookState
Full orderbook state for a market.


```solidity
struct OrderbookState {
    PriceLevel[] bids; // sorted highest to lowest price
    PriceLevel[] asks; // sorted lowest to highest price
    uint256 bestBid; // highest bid price (0 if no bids)
    uint256 bestAsk; // lowest ask price (type(uint256).max if no asks)
    uint256 spread; // bestAsk - bestBid (0 if no spread or crossed)
    uint256 midPrice; // (bestBid + bestAsk) / 2
}
```

