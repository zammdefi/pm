# PMHookQuoter
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMHookQuoter.sol)

**Title:**
PMHookQuoter

View-only quoter for PMHookRouter and MasterRouter buy/sell operations

Separate contract to keep routers under bytecode limit


## State Variables
### ERR_COMPUTATION

```solidity
bytes4 constant ERR_COMPUTATION = 0x05832717
```


### FLAG_BEFORE

```solidity
uint256 constant FLAG_BEFORE = 1 << 255
```


### FLAG_AFTER

```solidity
uint256 constant FLAG_AFTER = 1 << 254
```


### DEFAULT_FEE_BPS

```solidity
uint256 constant DEFAULT_FEE_BPS = 30
```


### MIN_TWAP_UPDATE_INTERVAL

```solidity
uint256 constant MIN_TWAP_UPDATE_INTERVAL = 5 minutes
```


### BOOTSTRAP_WINDOW

```solidity
uint256 constant BOOTSTRAP_WINDOW = 7 days
```


### MIN_ABSOLUTE_SPREAD_BPS

```solidity
uint256 constant MIN_ABSOLUTE_SPREAD_BPS = 10
```


### MAX_SPREAD_BPS

```solidity
uint256 constant MAX_SPREAD_BPS = 500
```


### MAX_COLLATERAL_IN

```solidity
uint256 constant MAX_COLLATERAL_IN = type(uint256).max / 10_000
```


### MAX_UINT112

```solidity
uint256 constant MAX_UINT112 = 0xffffffffffffffffffffffffffff
```


### ZAMM

```solidity
IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD)
```


### PAMM

```solidity
IPAMMView constant PAMM = IPAMMView(0x000000000044bfe6c2BBFeD8862973E0612f07C0)
```


### ROUTER

```solidity
IPMHookRouterView public immutable ROUTER
```


### MASTER_ROUTER

```solidity
IMasterRouter public immutable MASTER_ROUTER
```


## Functions
### constructor


```solidity
constructor(address router, address masterRouter) ;
```

### quoteBootstrapBuy

Quote expected output for buyWithBootstrap

Mirrors execution waterfall: compares vault+AMM vs AMM-only, applies price impact limits


```solidity
function quoteBootstrapBuy(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 minSharesOut
)
    public
    view
    returns (uint256 totalSharesOut, bool usesVault, bytes4 source, uint256 vaultSharesMinted);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalSharesOut`|`uint256`|Estimated shares across venues|
|`usesVault`|`bool`|Whether vault OTC or mint will be used|
|`source`|`bytes4`|Primary source ("otc", "mint", "amm", or "mult")|
|`vaultSharesMinted`|`uint256`|Estimated vault shares if mint path used|


### quoteSellWithBootstrap

Quote expected output for sellWithBootstrap (vault OTC + AMM fallback)


```solidity
function quoteSellWithBootstrap(uint256 marketId, bool sellYes, uint256 sharesIn)
    public
    view
    returns (uint256 collateralOut, bytes4 source);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`collateralOut`|`uint256`|Total collateral from sale|
|`source`|`bytes4`|Primary source ("otc", "amm", or "mult")|


### _quoteAMMSell

Quote AMM sell: swap partial shares to balance, then merge to collateral
Mirrors the router's fixed implementation that swaps only enough to balance for merge


```solidity
function _quoteAMMSell(uint256 marketId, bool sellYes, uint256 sharesIn)
    internal
    view
    returns (uint256 collateralOut);
```

### _calcSwapAmountForMerge

Calculate optimal swap amount to balance shares for merge
Solves: sharesIn - X = X * rOut * fm / (rIn * 10000 + X * fm)
where fm = 10000 - feeBps


```solidity
function _calcSwapAmountForMerge(uint256 sharesIn, uint256 rIn, uint256 rOut, uint256 feeBps)
    internal
    pure
    returns (uint256 swapAmount);
```

### _sqrt

Integer square root via Newton's method


```solidity
function _sqrt(uint256 x) internal pure returns (uint256);
```

### _getNoId


```solidity
function _getNoId(uint256 marketId) internal pure returns (uint256 noId);
```

### _getReserves


```solidity
function _getReserves(uint256 poolId) internal view returns (uint112 r0, uint112 r1);
```

### _getPoolFeeBps


```solidity
function _getPoolFeeBps(uint256 feeOrHook, uint256 canonical)
    internal
    view
    returns (uint256 feeBps);
```

### _getMaxPriceImpactBps


```solidity
function _getMaxPriceImpactBps(uint256 marketId) internal view returns (uint256);
```

### _getTWAPPrice


```solidity
function _getTWAPPrice(uint256 marketId) internal view returns (uint256 twapBps);
```

### _tryVaultOTCFill


```solidity
function _tryVaultOTCFill(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 pYesTwapBps
) internal view returns (uint256 sharesOut, uint256 collateralUsed, bool filled);
```

### _quoteAMMBuy


```solidity
function _quoteAMMBuy(uint256 marketId, bool buyYes, uint256 collateralIn)
    internal
    view
    returns (uint256 totalShares);
```

### _shouldUseVaultMint


```solidity
function _shouldUseVaultMint(uint256 marketId, bool buyYes) internal view returns (bool);
```

### _findMaxAMMUnderImpact


```solidity
function _findMaxAMMUnderImpact(
    uint256 marketId,
    bool buyYes,
    uint256 maxCollateral,
    uint256 feeBps,
    uint256 maxImpactBps
) internal view returns (uint256 safeCollateral);
```

### _calcPriceImpact


```solidity
function _calcPriceImpact(
    uint256 coll,
    bool buyYes,
    uint256 yesRes,
    uint256 noRes,
    uint256 pBefore,
    uint256 feeMult
) internal pure returns (uint256);
```

### quoteBuyWithSweep

Quote expected output for MasterRouter.buyWithSweep (pools + PMHookRouter)


```solidity
function quoteBuyWithSweep(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 maxPriceBps
)
    external
    view
    returns (
        uint256 totalSharesOut,
        uint256 poolSharesOut,
        uint256 poolLevelsFilled,
        uint256 pmSharesOut,
        bytes4 pmSource
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to buy in|
|`buyYes`|`bool`|True to buy YES shares, false for NO|
|`collateralIn`|`uint256`|Amount of collateral to spend|
|`maxPriceBps`|`uint256`|Maximum price for pool fills (0 = skip pools)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalSharesOut`|`uint256`|Total shares expected across all venues|
|`poolSharesOut`|`uint256`|Shares from pool fills|
|`poolLevelsFilled`|`uint256`|Number of pool price levels touched|
|`pmSharesOut`|`uint256`|Shares from PMHookRouter|
|`pmSource`|`bytes4`|PMHookRouter source ("otc", "amm", "mint", "mult")|


### quoteSellWithSweep

Quote expected output for MasterRouter.sellWithSweep (pools + PMHookRouter)


```solidity
function quoteSellWithSweep(
    uint256 marketId,
    bool sellYes,
    uint256 sharesIn,
    uint256 minPriceBps
)
    external
    view
    returns (
        uint256 totalCollateralOut,
        uint256 poolCollateralOut,
        uint256 poolLevelsFilled,
        uint256 pmCollateralOut,
        bytes4 pmSource
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to sell in|
|`sellYes`|`bool`|True to sell YES shares, false for NO|
|`sharesIn`|`uint256`|Amount of shares to sell|
|`minPriceBps`|`uint256`|Minimum price for pool fills (0 = skip pools)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalCollateralOut`|`uint256`|Total collateral expected across all venues|
|`poolCollateralOut`|`uint256`|Collateral from pool fills|
|`poolLevelsFilled`|`uint256`|Number of pool price levels touched|
|`pmCollateralOut`|`uint256`|Collateral from PMHookRouter|
|`pmSource`|`bytes4`|PMHookRouter source ("otc", "amm", "mult")|


### _lowestSetBit

Find lowest set bit position (isolate lowest bit, then find its position)


```solidity
function _lowestSetBit(uint256 x) internal pure returns (uint256);
```

### _highestSetBit

Find position of highest set bit (0-255), returns 256 for x=0


```solidity
function _highestSetBit(uint256 x) internal pure returns (uint256 r);
```

### getActiveLevels

Get all active price levels with depth (for orderbook UI)


```solidity
function getActiveLevels(uint256 marketId, bool isYes, uint256 maxLevels)
    public
    view
    returns (
        uint256[] memory askPrices,
        uint256[] memory askDepths,
        uint256[] memory bidPrices,
        uint256[] memory bidDepths
    );
```

### getUserActivePositions

Get all active positions for a user on a market side


```solidity
function getUserActivePositions(uint256 marketId, bool isYes, address user)
    public
    view
    returns (
        uint256[] memory askPrices,
        uint256[] memory askShares,
        uint256[] memory askPendingColl,
        uint256[] memory bidPrices,
        uint256[] memory bidCollateral,
        uint256[] memory bidPendingShares
    );
```

### getUserPositionsBatch

Batch query user positions at specific prices


```solidity
function getUserPositionsBatch(
    uint256 marketId,
    bool isYes,
    address user,
    uint256[] calldata prices
)
    public
    view
    returns (
        uint256[] memory askShares,
        uint256[] memory askPending,
        uint256[] memory bidCollateral,
        uint256[] memory bidPending
    );
```

### _getBitmapKey

Compute bitmap key for a market/side/type


```solidity
function _getBitmapKey(uint256 marketId, bool isYes, bool isAsk)
    internal
    pure
    returns (bytes32);
```

### fullMulDiv

Full precision multiply-divide (handles intermediate overflow)


```solidity
function fullMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z);
```

