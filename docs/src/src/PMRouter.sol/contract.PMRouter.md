# PMRouter
[Git Source](https://github.com/zammdefi/pm/blob/d39f4d0711d78f2e49cc15977d08b491f84e0abe/src/PMRouter.sol)

**Title:**
PMRouter

Limit order and trading router for PAMM prediction markets.

Handles YES/NO share limit orders via ZAMM, market orders via PAMM, and collateral ops.


## State Variables
### ZAMM

```solidity
IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD)
```


### PAMM

```solidity
IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0)
```


### ETH

```solidity
address internal constant ETH = address(0)
```


### orders

```solidity
mapping(bytes32 => Order) public orders
```


### _marketOrders

```solidity
mapping(uint256 => bytes32[]) internal _marketOrders
```


### _userOrders

```solidity
mapping(address => bytes32[]) internal _userOrders
```


### _locked

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
constructor() payable;
```

### receive


```solidity
receive() external payable;
```

### multicall


```solidity
function multicall(bytes[] calldata data) public returns (bytes[] memory results);
```

### permit


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

### placeOrder

Place limit order to buy/sell YES or NO shares.


```solidity
function placeOrder(
    uint256 marketId,
    bool isYes,
    bool isBuy,
    uint96 shares,
    uint96 collateral,
    uint56 deadline,
    bool partialFill
) public payable nonReentrant returns (bytes32 orderHash);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Prediction market ID|
|`isYes`|`bool`|True for YES shares, false for NO|
|`isBuy`|`bool`|True to buy shares with collateral, false to sell shares for collateral|
|`shares`|`uint96`|Amount of shares|
|`collateral`|`uint96`|Amount of collateral|
|`deadline`|`uint56`|Order expiration|
|`partialFill`|`bool`|Allow partial fills|


### cancelOrder

Cancel order and reclaim tokens.


```solidity
function cancelOrder(bytes32 orderHash) public nonReentrant;
```

### fillOrder

Fill a limit order.


```solidity
function fillOrder(bytes32 orderHash, uint96 sharesToFill, address to)
    public
    payable
    nonReentrant
    returns (uint96 sharesFilled, uint96 collateralFilled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`orderHash`|`bytes32`|Order to fill|
|`sharesToFill`|`uint96`|Amount to fill (0 = fill all)|
|`to`|`address`|Recipient|


### buy

Buy YES or NO shares via PAMM AMM.


```solidity
function buy(
    uint256 marketId,
    bool isYes,
    uint256 collateralIn,
    uint256 minSharesOut,
    uint256 feeOrHook,
    address to
) public payable nonReentrant returns (uint256 sharesOut);
```

### sell

Sell YES or NO shares via PAMM AMM.


```solidity
function sell(
    uint256 marketId,
    bool isYes,
    uint256 sharesIn,
    uint256 minCollateralOut,
    uint256 feeOrHook,
    address to
) public nonReentrant returns (uint256 collateralOut);
```

### swapShares

Swap YES<->NO shares via ZAMM AMM.


```solidity
function swapShares(
    uint256 marketId,
    bool yesForNo,
    uint256 amountIn,
    uint256 minOut,
    uint256 feeOrHook,
    address to
) public nonReentrant returns (uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Prediction market|
|`yesForNo`|`bool`|True to swap YES->NO, false for NO->YES|
|`amountIn`|`uint256`|Amount of shares to swap|
|`minOut`|`uint256`|Minimum output shares|
|`feeOrHook`|`uint256`|Pool fee tier|
|`to`|`address`|Recipient|


### swapSharesToCollateral

Swap shares directly to collateral via ZAMM AMM (not PAMM).

Uses ZAMM's share/collateral pools if they exist.


```solidity
function swapSharesToCollateral(
    uint256 marketId,
    bool isYes,
    uint256 sharesIn,
    uint256 minCollateralOut,
    uint256 feeOrHook,
    address to
) public nonReentrant returns (uint256 collateralOut);
```

### swapCollateralToShares

Swap collateral directly to shares via ZAMM AMM (not PAMM).


```solidity
function swapCollateralToShares(
    uint256 marketId,
    bool isYes,
    uint256 collateralIn,
    uint256 minSharesOut,
    uint256 feeOrHook,
    address to
) public payable nonReentrant returns (uint256 sharesOut);
```

### fillOrdersThenSwap

Fill orders then swap remainder via AMM.

Attempts to fill provided orders first, then routes remaining to ZAMM AMM.


```solidity
function fillOrdersThenSwap(
    uint256 marketId,
    bool isYes,
    bool isBuy,
    uint256 totalAmount,
    uint256 minOutput,
    bytes32[] calldata orderHashes,
    uint256 feeOrHook,
    address to
) public payable nonReentrant returns (uint256 totalOutput);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Prediction market|
|`isYes`|`bool`|True for YES shares, false for NO|
|`isBuy`|`bool`|True to buy shares, false to sell|
|`totalAmount`|`uint256`|Total shares (if selling) or collateral (if buying) to trade|
|`minOutput`|`uint256`|Minimum output (collateral if selling, shares if buying)|
|`orderHashes`|`bytes32[]`|Orders to try filling first|
|`feeOrHook`|`uint256`|AMM fee tier for remainder|
|`to`|`address`|Recipient|


### split

Split collateral into YES + NO shares.


```solidity
function split(uint256 marketId, uint256 amount, address to) public payable nonReentrant;
```

### merge

Merge YES + NO shares back into collateral.


```solidity
function merge(uint256 marketId, uint256 amount, address to) public nonReentrant;
```

### claim

Claim winnings from resolved market.


```solidity
function claim(uint256 marketId, address to) public nonReentrant returns (uint256 payout);
```

### getOrder

Get order details with fill state.


```solidity
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
    );
```

### isOrderActive


```solidity
function isOrderActive(bytes32 orderHash) public view returns (bool);
```

### getMarketOrderCount

Get total number of orders for a market (including inactive).


```solidity
function getMarketOrderCount(uint256 marketId) public view returns (uint256);
```

### getUserOrderCount

Get total number of orders for a user (including inactive).


```solidity
function getUserOrderCount(address user) public view returns (uint256);
```

### getMarketOrderHashes

Get order hashes for a market with pagination.


```solidity
function getMarketOrderHashes(uint256 marketId, uint256 offset, uint256 limit)
    public
    view
    returns (bytes32[] memory orderHashes);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to query|
|`offset`|`uint256`|Starting index|
|`limit`|`uint256`|Max orders to return|


### getUserOrderHashes

Get order hashes for a user with pagination.


```solidity
function getUserOrderHashes(address user, uint256 offset, uint256 limit)
    public
    view
    returns (bytes32[] memory orderHashes);
```

### getActiveOrders

Get active orders for a market, filtered by side.


```solidity
function getActiveOrders(uint256 marketId, bool isYes, bool isBuy, uint256 limit)
    public
    view
    returns (bytes32[] memory orderHashes, Order[] memory orderDetails);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to query|
|`isYes`|`bool`|Filter for YES (true) or NO (false) shares|
|`isBuy`|`bool`|Filter for buy (true) or sell (false) orders|
|`limit`|`uint256`|Max orders to return|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`orderHashes`|`bytes32[]`|Active order hashes matching criteria|
|`orderDetails`|`Order[]`|Corresponding order details|


### getBestOrders

Get best (highest for buys, lowest for sells) orders for filling.

Returns orders sorted by price, best first. Price = collateral/shares.


```solidity
function getBestOrders(uint256 marketId, bool isYes, bool isBuy, uint256 limit)
    public
    view
    returns (bytes32[] memory orderHashes);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to query|
|`isYes`|`bool`|YES or NO shares|
|`isBuy`|`bool`|Get buy orders (to sell into) or sell orders (to buy from)|
|`limit`|`uint256`|Max orders to return|


### getBidAsk

Get bid/ask spread for a share type.


```solidity
function getBidAsk(uint256 marketId, bool isYes)
    public
    view
    returns (uint256 bidPrice, uint256 askPrice, uint256 bidCount, uint256 askCount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to query|
|`isYes`|`bool`|True for YES shares, false for NO|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bidPrice`|`uint256`|Best buy order price (highest) - 18 decimals|
|`askPrice`|`uint256`|Best sell order price (lowest) - 18 decimals|
|`bidCount`|`uint256`|Number of active buy orders|
|`askCount`|`uint256`|Number of active sell orders|


### getOrderbook

Get full orderbook for a share type (for CEX-style UI).


```solidity
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
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to query|
|`isYes`|`bool`|True for YES shares, false for NO|
|`depth`|`uint256`|Max orders per side|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bidHashes`|`bytes32[]`|Buy order hashes (best price first)|
|`bidPrices`|`uint256[]`|Buy order prices (18 decimals)|
|`bidSizes`|`uint256[]`|Buy order sizes (shares)|
|`askHashes`|`bytes32[]`|Sell order hashes (best price first)|
|`askPrices`|`uint256[]`|Sell order prices (18 decimals)|
|`askSizes`|`uint256[]`|Sell order sizes (shares)|


### getUserPositions

Get user's share positions across multiple markets.


```solidity
function getUserPositions(address user, uint256[] calldata marketIds)
    public
    view
    returns (uint256[] memory yesBalances, uint256[] memory noBalances);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|User address|
|`marketIds`|`uint256[]`|Markets to query|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`yesBalances`|`uint256[]`|YES share balances|
|`noBalances`|`uint256[]`|NO share balances|


### getUserActiveOrders

Get user's active orders for a specific market.


```solidity
function getUserActiveOrders(address user, uint256 marketId, uint256 limit)
    public
    view
    returns (bytes32[] memory orderHashes, Order[] memory orderDetails);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|User address|
|`marketId`|`uint256`|Market to filter by (0 = all markets)|
|`limit`|`uint256`|Max orders to return|


### batchCancelOrders

Cancel multiple orders in one transaction.


```solidity
function batchCancelOrders(bytes32[] calldata orderHashesToCancel)
    public
    nonReentrant
    returns (uint256 cancelled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`orderHashesToCancel`|`bytes32[]`|Orders to cancel (skips orders not owned by sender)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`cancelled`|`uint256`|Number of orders successfully cancelled|


### _validateAndGetCollateral

Validate market and return collateral token.


```solidity
function _validateAndGetCollateral(uint256 marketId) private view returns (address collateral);
```

### _safeTransferETH

Transfer ETH to recipient.


```solidity
function _safeTransferETH(address to, uint256 amount) private;
```

### _safeTransfer

Transfer ERC20 tokens to recipient.


```solidity
function _safeTransfer(address token, address to, uint256 amount) private;
```

### _safeTransferFrom

Transfer ERC20 tokens from sender to recipient.


```solidity
function _safeTransferFrom(address token, address from, address to, uint256 amount) private;
```

### _ensureApproval

Ensure max approval for spender if not already set.


```solidity
function _ensureApproval(address token, address spender) private;
```

### _ensureOperatorPAMM

Ensure ZAMM is operator for this contract on PAMM.


```solidity
function _ensureOperatorPAMM() private;
```

## Events
### OrderCancelled

```solidity
event OrderCancelled(bytes32 indexed orderHash);
```

### OrderFilled

```solidity
event OrderFilled(
    bytes32 indexed orderHash,
    address indexed taker,
    uint96 sharesFilled,
    uint96 collateralFilled
);
```

### OrderPlaced

```solidity
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
```

## Errors
### Reentrancy

```solidity
error Reentrancy();
```

### AmountZero

```solidity
error AmountZero();
```

### MustFillAll

```solidity
error MustFillAll();
```

### MarketClosed

```solidity
error MarketClosed();
```

### OrderInactive

```solidity
error OrderInactive();
```

### NotOrderOwner

```solidity
error NotOrderOwner();
```

### OrderNotFound

```solidity
error OrderNotFound();
```

### MarketNotFound

```solidity
error MarketNotFound();
```

### TradingNotOpen

```solidity
error TradingNotOpen();
```

### DeadlineExpired

```solidity
error DeadlineExpired();
```

### SlippageExceeded

```solidity
error SlippageExceeded();
```

### InvalidETHAmount

```solidity
error InvalidETHAmount();
```

## Structs
### Order
Limit order for PM shares.


```solidity
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
```

