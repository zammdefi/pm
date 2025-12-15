# PMRouter
[Git Source](https://github.com/zammdefi/pm/blob/fd85de4cbb2d992be3173c764eca542e83197ee2/src/PMRouter.sol)

**Title:**
PMRouter

Limit order and trading router for PAMM prediction markets.

Handles YES/NO share limit orders via ZAMM, market orders via PAMM, and collateral ops.
Operational Requirements (not enforced on-chain):
- Collateral tokens must have >= 6 decimals (ETH, USDC, DAI, etc.)
- Fee-on-transfer and rebasing tokens are not supported
- Tokens requiring approve(0) before approve(n) (e.g., USDT) are not supported as collateral
- Markets with unsupported collateral should be marked unsafe in UIs/indexers
Trust Model:
- ZAMM is trusted infrastructure with operator privileges over router-held PAMM shares
- Orders can be filled directly on ZAMM (bypassing router); makers should cancel promptly
on market resolution to avoid stale order exploitation
Behavioral Notes:
- Deadline semantics: Swap functions (swapShares, swapSharesToCollateral, swapCollateralToShares,
fillOrdersThenSwap) treat `deadline == 0` as `block.timestamp` (execute now). Market order
functions (buy, sell) pass deadline through to PAMM unchanged. For limit orders, deadlines
are capped to the market's close time.
- Expired orders: Orders that have expired (deadline passed) can still be cancelled to
reclaim escrowed funds. Users should call `cancelOrder` to recover collateral/shares.
- ERC20 compatibility: The safe transfer functions support non-standard ERC20s that don't
return a boolean value. Standard ERC20s returning false will revert.
- Partial fill rounding: ZAMM uses floor division for partial fills, which can result in
negligible dust (at most 1 smallest unit per fill). For orders filled in N fragments,
maximum dust is N units - sub-cent for supported tokens. This is protocol-acceptable
precision loss, not a loss of funds. Direct ZAMM fills have the same rounding behavior.


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


### claimedOut

```solidity
mapping(bytes32 => uint96) public claimedOut
```


### REENTRANCY_SLOT

```solidity
uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268
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

For ETH operations, msg.value must equal the exact amount needed by the single
payable call in the batch. Cannot batch multiple ETH operations together.


```solidity
function multicall(bytes[] calldata data) public payable returns (bytes[] memory results);
```

### permit

ERC20Permit (EIP-2612) - approve via signature.

Use with multicall: [permit, placeOrder] in single tx.


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

DAI-style permit - approve via signature with nonce.

DAI uses: permit(holder, spender, nonce, expiry, allowed, v, r, s)


```solidity
function permitDAI(
    address token,
    address holder,
    uint256 nonce,
    uint256 expiry,
    bool allowed,
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

Cancel order and reclaim escrowed tokens plus any unclaimed proceeds.

Can be called even after order expires to recover funds. Unfilled/partially
filled orders will return remaining collateral (buy) or shares (sell) to owner.


```solidity
function cancelOrder(bytes32 orderHash) public nonReentrant;
```

### claimProceeds

Claim proceeds from orders filled directly on ZAMM.

If someone fills your order directly on ZAMM (bypassing PMRouter), your proceeds
accumulate in PMRouter. Call this to withdraw them. Also called automatically
during cancelOrder.


```solidity
function claimProceeds(bytes32 orderHash, address to)
    public
    nonReentrant
    returns (uint96 amount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`orderHash`|`bytes32`|Order to claim proceeds from|
|`to`|`address`|Recipient of proceeds|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint96`|Amount of proceeds claimed (shares for BUY orders, collateral for SELL)|


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
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 sharesOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`||
|`isYes`|`bool`||
|`collateralIn`|`uint256`||
|`minSharesOut`|`uint256`||
|`feeOrHook`|`uint256`||
|`to`|`address`||
|`deadline`|`uint256`|Timestamp after which tx reverts (passed to PAMM as-is)|


### sell

Sell YES or NO shares via PAMM AMM.


```solidity
function sell(
    uint256 marketId,
    bool isYes,
    uint256 sharesIn,
    uint256 minCollateralOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 collateralOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`||
|`isYes`|`bool`||
|`sharesIn`|`uint256`||
|`minCollateralOut`|`uint256`||
|`feeOrHook`|`uint256`||
|`to`|`address`||
|`deadline`|`uint256`|Timestamp after which tx reverts (passed to PAMM as-is)|


### swapShares

Swap YES<->NO shares via ZAMM AMM.


```solidity
function swapShares(
    uint256 marketId,
    bool yesForNo,
    uint256 amountIn,
    uint256 minOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
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
|`deadline`|`uint256`|Timestamp after which tx reverts (0 = execute immediately)|


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
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 collateralOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`||
|`isYes`|`bool`||
|`sharesIn`|`uint256`||
|`minCollateralOut`|`uint256`||
|`feeOrHook`|`uint256`||
|`to`|`address`||
|`deadline`|`uint256`|Timestamp after which tx reverts (0 = execute immediately)|


### swapCollateralToShares

Swap collateral directly to shares via ZAMM AMM (not PAMM).


```solidity
function swapCollateralToShares(
    uint256 marketId,
    bool isYes,
    uint256 collateralIn,
    uint256 minSharesOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 sharesOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`||
|`isYes`|`bool`||
|`collateralIn`|`uint256`||
|`minSharesOut`|`uint256`||
|`feeOrHook`|`uint256`||
|`to`|`address`||
|`deadline`|`uint256`|Timestamp after which tx reverts (0 = execute immediately)|


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
    address to,
    uint256 deadline
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
|`deadline`|`uint256`|Timestamp after which tx reverts (0 = execute immediately)|


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


### getOrderbook

Get combined orderbook (bids + asks) for a market.


```solidity
function getOrderbook(uint256 marketId, bool isYes, uint256 depth)
    external
    view
    returns (
        bytes32[] memory bidHashes,
        Order[] memory bidOrders,
        bytes32[] memory askHashes,
        Order[] memory askOrders
    );
```

### _claimProceeds

Claim any unclaimed proceeds for an order and transfer to recipient.


```solidity
function _claimProceeds(bytes32 orderHash, Order storage order, address to)
    private
    returns (uint96 amount);
```

### _cancelOrder

Cancel order: claim proceeds, cancel on ZAMM if live, refund principal, cleanup.


```solidity
function _cancelOrder(bytes32 orderHash, Order storage order, address to) private;
```

### _validateAndGetCollateral

Validate market and return collateral token.
Inlines tradingOpen check to avoid duplicate external call.


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

### _poolKey

Build ZAMM pool key with proper token ordering.
ZAMM requires token0 < token1, or if same token, id0 < id1.


```solidity
function _poolKey(address tokenA, uint256 idA, address tokenB, uint256 idB, uint256 feeOrHook)
    private
    pure
    returns (IZAMM.PoolKey memory key);
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

### ProceedsClaimed

```solidity
event ProceedsClaimed(bytes32 indexed orderHash, address indexed to, uint96 amount);
```

## Errors
### AmountZero

```solidity
error AmountZero();
```

### Reentrancy

```solidity
error Reentrancy();
```

### MustFillAll

```solidity
error MustFillAll();
```

### OrderExists

```solidity
error OrderExists();
```

### HashMismatch

```solidity
error HashMismatch();
```

### MarketClosed

```solidity
error MarketClosed();
```

### ApproveFailed

```solidity
error ApproveFailed();
```

### NotOrderOwner

```solidity
error NotOrderOwner();
```

### OrderInactive

```solidity
error OrderInactive();
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

### TransferFailed

```solidity
error TransferFailed();
```

### DeadlineExpired

```solidity
error DeadlineExpired();
```

### InvalidETHAmount

```solidity
error InvalidETHAmount();
```

### SlippageExceeded

```solidity
error SlippageExceeded();
```

### ETHTransferFailed

```solidity
error ETHTransferFailed();
```

### InvalidFillAmount

```solidity
error InvalidFillAmount();
```

### TransferFromFailed

```solidity
error TransferFromFailed();
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

