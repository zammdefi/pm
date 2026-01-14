# MasterRouter
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/MasterRouter.sol)

**Title:**
MasterRouter - Complete Abstraction Layer

Pooled orderbook + vault integration for prediction markets

Accumulator-based accounting prevents late joiner theft


## State Variables
### ETH

```solidity
address constant ETH = address(0)
```


### PAMM

```solidity
IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0)
```


### PM_HOOK_ROUTER

```solidity
IPMHookRouter constant PM_HOOK_ROUTER =
    IPMHookRouter(0x0000000000BADa259Cb860c12ccD9500d9496B3e)
```


### REENTRANCY_SLOT

```solidity
uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268
```


### ETH_SPENT_SLOT

```solidity
uint256 constant ETH_SPENT_SLOT = 0x929eee149b4bd21269
```


### MULTICALL_DEPTH_SLOT

```solidity
uint256 constant MULTICALL_DEPTH_SLOT = 0x929eee149b4bd2126a
```


### BPS_DENOM

```solidity
uint256 constant BPS_DENOM = 10000
```


### ACC

```solidity
uint256 constant ACC = 1e18
```


### ERR_VALIDATION

```solidity
bytes4 constant ERR_VALIDATION = 0x077a9c33
```


### ERR_STATE

```solidity
bytes4 constant ERR_STATE = 0xd06e7808
```


### ERR_TRANSFER

```solidity
bytes4 constant ERR_TRANSFER = 0x2929f974
```


### ERR_REENTRANCY

```solidity
bytes4 constant ERR_REENTRANCY = 0xab143c06
```


### ERR_LIQUIDITY

```solidity
bytes4 constant ERR_LIQUIDITY = 0x4dae90b0
```


### ERR_TIMING

```solidity
bytes4 constant ERR_TIMING = 0x3703bac9
```


### ERR_COMPUTATION

```solidity
bytes4 constant ERR_COMPUTATION = 0x05832717
```


### pools

```solidity
mapping(bytes32 => Pool) public pools
```


### positions

```solidity
mapping(bytes32 => mapping(address => UserPosition)) public positions
```


### bidPools

```solidity
mapping(bytes32 => BidPool) public bidPools
```


### bidPositions

```solidity
mapping(bytes32 => mapping(address => BidPosition)) public bidPositions
```


### priceBitmap
Bitmap tracking active price levels
Key: keccak256(marketId, isYes, isAsk) => 40 uint256s covering prices 0-10239
Each bit represents whether a pool exists at that price (1-9999 valid range)


```solidity
mapping(bytes32 => uint256[40]) public priceBitmap
```


## Functions
### constructor


```solidity
constructor() payable;
```

### receive


```solidity
receive() external payable;
```

### nonReentrant


```solidity
modifier nonReentrant() ;
```

### _revert


```solidity
function _revert(bytes4 selector, uint8 code) internal pure;
```

### _validateETHAmount

Validate ETH amount with multicall-aware cumulative tracking


```solidity
function _validateETHAmount(address collateral, uint256 requiredAmount) internal;
```

### _refundETHToCaller

Refund ETH to caller, deferring actual transfer if in multicall


```solidity
function _refundETHToCaller(uint256 amount) internal;
```

### getPoolId


```solidity
function getPoolId(uint256 marketId, bool isYes, uint256 priceInBps)
    public
    pure
    returns (bytes32);
```

### _getNoId

Get NO token ID using PAMM's formula


```solidity
function _getNoId(uint256 marketId) internal pure returns (uint256 noId);
```

### _getTokenId


```solidity
function _getTokenId(uint256 marketId, bool isYes) internal pure returns (uint256);
```

### getUserPosition

Get user's position in a pool

Uses accumulator model: pending = (scaled * acc) / 1e18 - debt


```solidity
function getUserPosition(uint256 marketId, bool isYes, uint256 priceInBps, address user)
    public
    view
    returns (
        uint256 userScaled,
        uint256 userWithdrawableShares,
        uint256 userPendingCollateral,
        uint256 userCollateralDebt
    );
```

### mintAndPool

Mint shares and pool one side at a specific price

Uses accumulator model to prevent late joiner theft


```solidity
function mintAndPool(
    uint256 marketId,
    uint256 collateralIn,
    bool keepYes,
    uint256 priceInBps,
    address to
) public payable nonReentrant returns (bytes32 poolId);
```

### depositSharesToPool

Deposit existing PM shares to an ASK pool at a specific price

Use this to migrate positions or add shares you already own to a pool


```solidity
function depositSharesToPool(
    uint256 marketId,
    bool isYes,
    uint256 sharesIn,
    uint256 priceInBps,
    address to
) public nonReentrant returns (bytes32 poolId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`isYes`|`bool`|True to deposit YES shares, false for NO shares|
|`sharesIn`|`uint256`|Amount of shares to deposit|
|`priceInBps`|`uint256`|Price to sell at (in basis points, 1-9999)|
|`to`|`address`|Recipient of pool position (LP units)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`bytes32`|The pool identifier|


### migrateAskPosition

Migrate ASK pool position to a new price (no external share custody)

More gas-efficient than withdraw + deposit - shares stay in contract


```solidity
function migrateAskPosition(
    uint256 marketId,
    bool isYes,
    uint256 oldPriceInBps,
    uint256 newPriceInBps,
    uint256 sharesToMigrate,
    address to
) public nonReentrant returns (uint256 sharesMigrated, uint256 collateralClaimed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`isYes`|`bool`|True for YES pool, false for NO pool|
|`oldPriceInBps`|`uint256`|Current price level to migrate from|
|`newPriceInBps`|`uint256`|New price level to migrate to|
|`sharesToMigrate`|`uint256`|Amount of shares to migrate (0 = all)|
|`to`|`address`|Recipient of new position and any claimed collateral|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sharesMigrated`|`uint256`|Shares moved to new pool|
|`collateralClaimed`|`uint256`|Pending collateral from old pool fills|


### migrateBidPosition

Migrate BID pool position to a different price level

Mirror of migrateAskPosition for BID pools


```solidity
function migrateBidPosition(
    uint256 marketId,
    bool buyYes,
    uint256 oldPriceInBps,
    uint256 newPriceInBps,
    uint256 collateralToMigrate,
    address to
) public nonReentrant returns (uint256 collateralMigrated, uint256 sharesClaimed);
```

### _deposit

Internal: Deposit shares into pool (accumulator model)


```solidity
function _deposit(Pool storage p, UserPosition storage u, uint256 sharesIn) internal;
```

### fillFromPool

Fill shares from a pool


```solidity
function fillFromPool(
    uint256 marketId,
    bool isYes,
    uint256 priceInBps,
    uint256 sharesWanted,
    uint256 maxCollateral,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 sharesBought, uint256 collateralPaid);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`isYes`|`bool`|True to buy YES shares, false for NO|
|`priceInBps`|`uint256`|Price level in basis points|
|`sharesWanted`|`uint256`|Amount of shares to buy|
|`maxCollateral`|`uint256`|Maximum collateral willing to pay (slippage protection)|
|`to`|`address`|Recipient of shares|
|`deadline`|`uint256`|Transaction deadline (0 = no deadline)|


### _fill

Internal: Fill from pool (accumulator model)


```solidity
function _fill(Pool storage p, uint256 sharesOut, uint256 collateralIn) internal;
```

### claimProceeds

Claim collateral proceeds from pool fills


```solidity
function claimProceeds(uint256 marketId, bool isYes, uint256 priceInBps, address to)
    public
    nonReentrant
    returns (uint256 collateralClaimed);
```

### _claim

Internal: Claim proceeds (accumulator model)


```solidity
function _claim(Pool storage p, UserPosition storage u) internal returns (uint256 claimable);
```

### withdrawFromPool

Withdraw unfilled shares from pool

Auto-claims any pending proceeds before withdrawing to prevent loss


```solidity
function withdrawFromPool(
    uint256 marketId,
    bool isYes,
    uint256 priceInBps,
    uint256 sharesToWithdraw,
    address to
) public nonReentrant returns (uint256 sharesWithdrawn, uint256 collateralClaimed);
```

### exitDepletedAskPool

Exit a depleted ASK pool - burn LP units when no shares remain

Use when pool is fully filled (totalShares=0) but you still have scaled position


```solidity
function exitDepletedAskPool(uint256 marketId, bool isYes, uint256 priceInBps, address to)
    public
    nonReentrant
    returns (uint256 collateralClaimed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`isYes`|`bool`|True for YES pool, false for NO pool|
|`priceInBps`|`uint256`|Price level in basis points|
|`to`|`address`|Recipient of any remaining collateral proceeds|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`collateralClaimed`|`uint256`|Collateral claimed from pending proceeds|


### _withdraw

Internal: Withdraw shares (accumulator model)


```solidity
function _withdraw(Pool storage p, UserPosition storage u, uint256 sharesWanted)
    internal
    returns (uint256 sharesOut);
```

### mintAndVault

Mint shares and deposit one side to PMHookRouter vault


```solidity
function mintAndVault(uint256 marketId, uint256 collateralIn, bool keepYes, address to)
    public
    payable
    nonReentrant
    returns (uint256 sharesKept, uint256 vaultShares);
```

### mintAndSellOther

Mint and sell other side into bid pools, then PMHookRouter

Recovers collateral instead of vault LP position


```solidity
function mintAndSellOther(
    uint256 marketId,
    uint256 collateralIn,
    bool keepYes,
    uint256 minPriceBps,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 sharesKept, uint256 collateralRecovered);
```

### buy

Buy shares with integrated routing (pool -> PMHookRouter)


```solidity
function buy(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 minSharesOut,
    uint256 poolPriceInBps,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 totalSharesOut, bytes4[] memory sources);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`||
|`buyYes`|`bool`||
|`collateralIn`|`uint256`||
|`minSharesOut`|`uint256`||
|`poolPriceInBps`|`uint256`|Optional: Try pooled orderbook at this price first (0 = skip pool)|
|`to`|`address`||
|`deadline`|`uint256`||


### buyWithSweep

Buy shares with multi-price sweep (fills best-priced pools first)

Sweeps ASK pools from lowest price up to maxPriceBps, then routes remainder to PMHookRouter


```solidity
function buyWithSweep(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 minSharesOut,
    uint256 maxPriceBps,
    address to,
    uint256 deadline
)
    public
    payable
    nonReentrant
    returns (
        uint256 totalSharesOut,
        uint256 poolSharesOut,
        uint256 poolLevelsFilled,
        bytes4[] memory sources
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to buy in|
|`buyYes`|`bool`|True to buy YES shares, false for NO shares|
|`collateralIn`|`uint256`|Amount of collateral to spend|
|`minSharesOut`|`uint256`|Minimum shares to receive (slippage protection)|
|`maxPriceBps`|`uint256`|Maximum price willing to pay from pools (0 = skip pools, use PMHookRouter only)|
|`to`|`address`|Recipient of shares|
|`deadline`|`uint256`|Transaction deadline (0 = no deadline)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalSharesOut`|`uint256`|Total shares received|
|`poolSharesOut`|`uint256`|Shares filled from pools|
|`poolLevelsFilled`|`uint256`|Number of price levels touched|
|`sources`|`bytes4[]`|Execution sources used|


### sell

Sell shares with integrated routing (bid pool -> PMHookRouter)


```solidity
function sell(
    uint256 marketId,
    bool sellYes,
    uint256 sharesIn,
    uint256 minCollateralOut,
    uint256 bidPoolPriceInBps,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 totalCollateralOut, bytes4[] memory sources);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`||
|`sellYes`|`bool`||
|`sharesIn`|`uint256`||
|`minCollateralOut`|`uint256`||
|`bidPoolPriceInBps`|`uint256`|Optional: Try bid pool at this price first (0 = skip pool)|
|`to`|`address`||
|`deadline`|`uint256`||


### sellWithSweep

Sell shares with multi-price sweep (fills best-priced bid pools first)

Sweeps BID pools from highest price down to minPriceBps, then routes remainder to PMHookRouter


```solidity
function sellWithSweep(
    uint256 marketId,
    bool sellYes,
    uint256 sharesIn,
    uint256 minCollateralOut,
    uint256 minPriceBps,
    address to,
    uint256 deadline
)
    public
    nonReentrant
    returns (
        uint256 totalCollateralOut,
        uint256 poolCollateralOut,
        uint256 poolLevelsFilled,
        bytes4[] memory sources
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to sell in|
|`sellYes`|`bool`|True to sell YES shares, false for NO shares|
|`sharesIn`|`uint256`|Amount of shares to sell|
|`minCollateralOut`|`uint256`|Minimum collateral to receive (slippage protection)|
|`minPriceBps`|`uint256`|Minimum price willing to accept from bid pools (0 = skip pools, use PMHookRouter only)|
|`to`|`address`|Recipient of collateral|
|`deadline`|`uint256`|Transaction deadline (0 = no deadline)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalCollateralOut`|`uint256`|Total collateral received|
|`poolCollateralOut`|`uint256`|Collateral from bid pools|
|`poolLevelsFilled`|`uint256`|Number of price levels touched|
|`sources`|`bytes4[]`|Execution sources used|


### getBidPoolId

Get bid pool ID for a market/side/price combination


```solidity
function getBidPoolId(uint256 marketId, bool buyYes, uint256 priceInBps)
    public
    pure
    returns (bytes32);
```

### getBidPosition

Get user's position in a bid pool


```solidity
function getBidPosition(uint256 marketId, bool buyYes, uint256 priceInBps, address user)
    public
    view
    returns (
        uint256 userScaled,
        uint256 userWithdrawableCollateral,
        uint256 userPendingShares,
        uint256 userSharesDebt
    );
```

### createBidPool

Create a bid pool - deposit collateral to buy shares at a specific price


```solidity
function createBidPool(
    uint256 marketId,
    uint256 collateralIn,
    bool buyYes,
    uint256 priceInBps,
    address to
) public payable nonReentrant returns (bytes32 bidPoolId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to bid on|
|`collateralIn`|`uint256`|Collateral to deposit|
|`buyYes`|`bool`|True to bid for YES shares, false for NO shares|
|`priceInBps`|`uint256`|Price willing to pay in basis points (1-9999)|
|`to`|`address`|Recipient of position (and eventually shares)|


### _depositToBidPool

Internal: Deposit collateral into bid pool


```solidity
function _depositToBidPool(BidPool storage p, BidPosition storage u, uint256 collateralIn)
    internal;
```

### sellToPool

Sell shares directly to a bid pool at the pool's price


```solidity
function sellToPool(
    uint256 marketId,
    bool isYes,
    uint256 priceInBps,
    uint256 sharesWanted,
    uint256 minCollateral,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 sharesSold, uint256 collateralReceived);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`isYes`|`bool`|True to sell YES shares, false for NO|
|`priceInBps`|`uint256`|Price level in basis points|
|`sharesWanted`|`uint256`|Amount of shares to sell|
|`minCollateral`|`uint256`|Minimum collateral to receive (slippage protection)|
|`to`|`address`|Recipient of collateral|
|`deadline`|`uint256`|Transaction deadline (0 = no deadline)|


### _fillBidPool

Internal: Fill bid pool (spend collateral, receive shares)


```solidity
function _fillBidPool(BidPool storage p, uint256 sharesIn, uint256 collateralOut) internal;
```

### claimBidShares

Claim shares from bid pool fills


```solidity
function claimBidShares(uint256 marketId, bool isYes, uint256 priceInBps, address to)
    public
    nonReentrant
    returns (uint256 sharesClaimed);
```

### _claimBidShares

Internal: Claim shares from bid pool


```solidity
function _claimBidShares(BidPool storage p, BidPosition storage u)
    internal
    returns (uint256 claimable);
```

### withdrawFromBidPool

Withdraw unfilled collateral from bid pool

Auto-claims any pending shares before withdrawing to prevent loss


```solidity
function withdrawFromBidPool(
    uint256 marketId,
    bool isYes,
    uint256 priceInBps,
    uint256 collateralToWithdraw,
    address to
) public nonReentrant returns (uint256 collateralWithdrawn, uint256 sharesClaimed);
```

### exitDepletedBidPool

Exit a depleted BID pool - burn LP units when no collateral remains

Use when pool is fully spent (totalCollateral=0) but you still have scaled position


```solidity
function exitDepletedBidPool(uint256 marketId, bool isYes, uint256 priceInBps, address to)
    public
    nonReentrant
    returns (uint256 sharesClaimed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`isYes`|`bool`|True for YES bid pool, false for NO bid pool|
|`priceInBps`|`uint256`|Price level in basis points|
|`to`|`address`|Recipient of any pending shares|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sharesClaimed`|`uint256`|Shares claimed from pending fills|


### _withdrawFromBidPool

Internal: Withdraw from bid pool


```solidity
function _withdrawFromBidPool(
    BidPool storage p,
    BidPosition storage u,
    uint256 collateralWanted
) internal returns (uint256 collateralOut);
```

### provideLiquidity

Provide liquidity to vault and/or AMM in one transaction

Splits collateral, deposits to vaults and AMM as specified


```solidity
function provideLiquidity(
    uint256 marketId,
    uint256 collateralAmount,
    uint256 vaultYesShares,
    uint256 vaultNoShares,
    uint256 ammLPShares,
    uint256 minAmount0,
    uint256 minAmount1,
    address to,
    uint256 deadline
)
    public
    payable
    nonReentrant
    returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity);
```

### multicall

Execute multiple calls in a single transaction

Tracks cumulative ETH usage to prevent msg.value double-spend attacks


```solidity
function multicall(bytes[] calldata data) public payable returns (bytes[] memory results);
```

### permit

Standard ERC-2612 permit


```solidity
function permit(
    address token,
    address owner,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) public nonReentrant;
```

### permitDAI

DAI-style permit


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
) public nonReentrant;
```

### getPoolDepths

Get ASK pool depths at multiple price levels for a market/side


```solidity
function getPoolDepths(uint256 marketId, bool isYes, uint256[] calldata pricesInBps)
    public
    view
    returns (uint256[] memory depths);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID|
|`isYes`|`bool`|True for YES pools, false for NO pools|
|`pricesInBps`|`uint256[]`|Array of prices to query (in basis points)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`depths`|`uint256[]`|Array of available shares at each price level|


### getBidPoolDepths

Get BID pool depths at multiple price levels for a market/side


```solidity
function getBidPoolDepths(uint256 marketId, bool buyYes, uint256[] calldata pricesInBps)
    public
    view
    returns (uint256[] memory depths);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID|
|`buyYes`|`bool`|True for YES bid pools, false for NO bid pools|
|`pricesInBps`|`uint256[]`|Array of prices to query (in basis points)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`depths`|`uint256[]`|Array of available collateral at each price level|


### getOrderbook

Get full orderbook view for a market side

Returns both ASK (shares for sale) and BID (collateral to buy) depths


```solidity
function getOrderbook(uint256 marketId, bool isYes, uint256[] calldata pricesInBps)
    public
    view
    returns (uint256[] memory askDepths, uint256[] memory bidDepths);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID|
|`isYes`|`bool`|True for YES side, false for NO side|
|`pricesInBps`|`uint256[]`|Array of prices to query|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`askDepths`|`uint256[]`|Shares available for sale at each price (ASK pools)|
|`bidDepths`|`uint256[]`|Collateral available to buy at each price (BID pools)|


### getPoolInfo

Get detailed pool info for a specific ASK pool


```solidity
function getPoolInfo(uint256 marketId, bool isYes, uint256 priceInBps)
    public
    view
    returns (uint256 totalShares, uint256 totalScaled, uint256 collateralEarned);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalShares`|`uint256`|Remaining shares available|
|`totalScaled`|`uint256`|Total LP units issued|
|`collateralEarned`|`uint256`|Total collateral collected from fills|


### getBidPoolInfo

Get detailed bid pool info for a specific BID pool


```solidity
function getBidPoolInfo(uint256 marketId, bool buyYes, uint256 priceInBps)
    public
    view
    returns (uint256 totalCollateral, uint256 totalScaled, uint256 sharesAcquired);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalCollateral`|`uint256`|Remaining collateral available|
|`totalScaled`|`uint256`|Total LP units issued|
|`sharesAcquired`|`uint256`|Total shares bought from fills|


### getBestAsk

Get best ASK price (lowest price with shares for sale)


```solidity
function getBestAsk(uint256 marketId, bool isYes)
    public
    view
    returns (uint256 price, uint256 depth);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID|
|`isYes`|`bool`|True for YES side, false for NO side|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`price`|`uint256`|Best ask price in bps (0 if no asks)|
|`depth`|`uint256`|Shares available at best price|


### getBestBid

Get best BID price (highest price with collateral to buy)


```solidity
function getBestBid(uint256 marketId, bool buyYes)
    public
    view
    returns (uint256 price, uint256 depth);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID|
|`buyYes`|`bool`|True for YES side, false for NO side|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`price`|`uint256`|Best bid price in bps (0 if no bids)|
|`depth`|`uint256`|Collateral available at best price|


### getSpread

Get market spread (best bid and ask for a side)


```solidity
function getSpread(uint256 marketId, bool isYes)
    public
    view
    returns (
        uint256 bestBidPrice,
        uint256 bestBidDepth,
        uint256 bestAskPrice,
        uint256 bestAskDepth
    );
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bestBidPrice`|`uint256`|Highest bid price (0 if none)|
|`bestBidDepth`|`uint256`|Collateral at best bid|
|`bestAskPrice`|`uint256`|Lowest ask price (0 if none)|
|`bestAskDepth`|`uint256`|Shares at best ask|


### _getBitmapKey

Compute bitmap key for a market/side/type


```solidity
function _getBitmapKey(uint256 marketId, bool isYes, bool isAsk)
    internal
    pure
    returns (bytes32);
```

### _setPriceBit

Set or clear a price bit in the bitmap


```solidity
function _setPriceBit(uint256 marketId, bool isYes, bool isAsk, uint256 priceInBps, bool active)
    internal;
```

### _lowestSetBit

Find position of lowest set bit (0-255)


```solidity
function _lowestSetBit(uint256 x) internal pure returns (uint256);
```

### _highestSetBit

Find position of highest set bit (0-255)


```solidity
function _highestSetBit(uint256 x) internal pure returns (uint256 r);
```

### mulDiv

Multiply then divide with overflow check


```solidity
function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z);
```

### mulDivUp

Returns `ceil(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.

From Solady (https://github.com/Vectorized/solady)


```solidity
function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z);
```

### _safeTransfer


```solidity
function _safeTransfer(address token, address to, uint256 amount) internal;
```

### _safeTransferFrom


```solidity
function _safeTransferFrom(address token, address from, address to, uint256 amount) internal;
```

### _safeTransferETH


```solidity
function _safeTransferETH(address to, uint256 amount) internal;
```

### _getBalance


```solidity
function _getBalance(address token, address account) internal view returns (uint256 bal);
```

### _ensureApproval


```solidity
function _ensureApproval(address token, address spender) internal;
```

## Events
### MintAndPool

```solidity
event MintAndPool(
    uint256 indexed marketId,
    address indexed user,
    bytes32 indexed poolId,
    uint256 collateralIn,
    bool keepYes,
    uint256 priceInBps
);
```

### PoolFilled

```solidity
event PoolFilled(
    bytes32 indexed poolId, address indexed taker, uint256 sharesFilled, uint256 collateralPaid
);
```

### ProceedsClaimed

```solidity
event ProceedsClaimed(bytes32 indexed poolId, address indexed user, uint256 collateralClaimed);
```

### SharesWithdrawn

```solidity
event SharesWithdrawn(bytes32 indexed poolId, address indexed user, uint256 sharesWithdrawn);
```

### SharesDeposited

```solidity
event SharesDeposited(
    uint256 indexed marketId,
    address indexed user,
    bytes32 indexed poolId,
    uint256 sharesIn,
    uint256 priceInBps
);
```

### BidPoolCreated

```solidity
event BidPoolCreated(
    uint256 indexed marketId,
    address indexed user,
    bytes32 indexed bidPoolId,
    uint256 collateralIn,
    bool buyYes,
    uint256 priceInBps
);
```

### BidPoolFilled

```solidity
event BidPoolFilled(
    bytes32 indexed bidPoolId,
    address indexed seller,
    uint256 sharesSold,
    uint256 collateralPaid
);
```

### BidSharesClaimed

```solidity
event BidSharesClaimed(bytes32 indexed bidPoolId, address indexed user, uint256 sharesClaimed);
```

### BidCollateralWithdrawn

```solidity
event BidCollateralWithdrawn(
    bytes32 indexed bidPoolId, address indexed user, uint256 collateralWithdrawn
);
```

### LiquidityProvided

```solidity
event LiquidityProvided(
    uint256 indexed marketId,
    address indexed user,
    uint256 yesVaultShares,
    uint256 noVaultShares,
    uint256 ammLiquidity
);
```

### MintAndVault

```solidity
event MintAndVault(
    uint256 indexed marketId,
    address indexed user,
    uint256 collateralIn,
    bool keepYes,
    uint256 sharesKept,
    uint256 vaultShares
);
```

### MintAndSellOther

```solidity
event MintAndSellOther(
    uint256 indexed marketId,
    address indexed user,
    uint256 collateralIn,
    bool keepYes,
    uint256 collateralRecovered
);
```

## Structs
### Pool
Pool state with accumulator accounting

Uses LP units (scaled) + reward debt pattern to prevent late joiner theft


```solidity
struct Pool {
    uint256 totalShares; // Remaining PM shares available to buy
    uint256 totalScaled; // Total LP units issued
    uint256 accCollPerScaled; // Cumulative collateral per LP unit (scaled by 1e18)
    uint256 collateralEarned; // Total collateral collected (optional tracking)
}
```

### UserPosition
User position in a pool


```solidity
struct UserPosition {
    uint256 scaled; // LP units owned
    uint256 collDebt; // Reward debt (scaled * accCollPerScaled at last update)
}
```

### BidPool
Bid pool state - collateral pool buying shares

Mirror of Pool struct but collateral in, shares out


```solidity
struct BidPool {
    uint256 totalCollateral; // Remaining collateral available to spend
    uint256 totalScaled; // Total LP units issued
    uint256 accSharesPerScaled; // Cumulative shares per LP unit (scaled by 1e18)
    uint256 sharesAcquired; // Total shares bought (optional tracking)
}
```

### BidPosition
User position in a bid pool


```solidity
struct BidPosition {
    uint256 scaled; // LP units owned
    uint256 sharesDebt; // Reward debt (scaled * accSharesPerScaled at last update)
}
```

