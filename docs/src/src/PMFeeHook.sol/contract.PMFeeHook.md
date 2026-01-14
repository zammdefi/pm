# PMFeeHook
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMFeeHook.sol)

**Inherits:**
[IZAMMHook](/src/PMFeeHook.sol/interface.IZAMMHook.md)

Dynamic-fee hook for prediction markets

Features: bootstrap decay, skew protection, asymmetric fees, volatility fees, price impact limits

Hook design: Always uses FLAG_BEFORE | FLAG_AFTER for stable poolId. Config toggles features.

Close modes: 0=halt, 1=fixed fee, 2=min fee, 3=dynamic. Swaps respect close/resolution, LPs always allowed.

SECURITY: Requires registered pools only. Unregistered pools revert on swaps to prevent post-resolution trading.

REQUIRES: EIP-1153 (transient storage) - only deploy on chains with Cancun/Dencun support


## State Variables
### FLAG_BEFORE

```solidity
uint256 constant FLAG_BEFORE = 1 << 255
```


### FLAG_AFTER

```solidity
uint256 constant FLAG_AFTER = 1 << 254
```


### BPS_DENOMINATOR

```solidity
uint256 constant BPS_DENOMINATOR = 10_000
```


### BPS_SQUARED

```solidity
uint256 constant BPS_SQUARED = 100_000_000
```


### BPS_CUBED

```solidity
uint256 constant BPS_CUBED = 1_000_000_000_000
```


### BPS_QUARTIC

```solidity
uint256 constant BPS_QUARTIC = 10_000_000_000_000_000
```


### REENTRANCY_SLOT

```solidity
uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268
```


### TS_RESERVES_DOMAIN

```solidity
uint256 constant TS_RESERVES_DOMAIN =
    0x7f9c2e2f7d8a4c6b3a1d9e0f11223344556677889900aabbccddeeff00112233
```


### TS_RESERVES_PRESENT_BIT

```solidity
uint256 constant TS_RESERVES_PRESENT_BIT = 1 << 224
```


### TS_META_DOMAIN

```solidity
uint256 constant TS_META_DOMAIN =
    0x8e1d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2
```


### TS_FLAGS_DOMAIN

```solidity
uint256 constant TS_FLAGS_DOMAIN =
    0x9f2e4f5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3
```


### SWAP_EXACT_IN

```solidity
bytes4 constant SWAP_EXACT_IN = IZAMM.swapExactIn.selector
```


### SWAP_EXACT_OUT

```solidity
bytes4 constant SWAP_EXACT_OUT = IZAMM.swapExactOut.selector
```


### SWAP_LOWLEVEL

```solidity
bytes4 constant SWAP_LOWLEVEL = IZAMM.swap.selector
```


### FLAG_SKEW

```solidity
uint16 constant FLAG_SKEW = 0x01
```


### FLAG_BOOTSTRAP

```solidity
uint16 constant FLAG_BOOTSTRAP = 0x02
```


### FLAG_ASYMMETRIC

```solidity
uint16 constant FLAG_ASYMMETRIC = 0x10
```


### FLAG_PRICE_IMPACT

```solidity
uint16 constant FLAG_PRICE_IMPACT = 0x20
```


### FLAG_VOLATILITY

```solidity
uint16 constant FLAG_VOLATILITY = 0x40
```


### FLAG_NEEDS_RESERVES

```solidity
uint16 constant FLAG_NEEDS_RESERVES = FLAG_SKEW | FLAG_ASYMMETRIC
```


### ZAMM

```solidity
IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD)
```


### PAMM

```solidity
IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0)
```


### REGISTRAR

```solidity
address public constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e
```


### poolToMarket

```solidity
mapping(uint256 poolId => uint256 marketId) public poolToMarket
```


### meta

```solidity
mapping(uint256 poolId => Meta) public meta
```


### defaultConfig

```solidity
Config internal defaultConfig
```


### marketConfig

```solidity
mapping(uint256 marketId => Config) internal marketConfig
```


### priceHistory

```solidity
mapping(uint256 poolId => PriceSnapshot[10]) public priceHistory
```


### priceHistoryIndex

```solidity
mapping(uint256 poolId => uint8) public priceHistoryIndex
```


### lastSnapshotBlock

```solidity
mapping(uint256 poolId => uint256) public lastSnapshotBlock
```


### owner

```solidity
address public owner
```


## Functions
### constructor


```solidity
constructor() payable;
```

### setDefaultConfig


```solidity
function setDefaultConfig(Config calldata cfg) public payable onlyOwner;
```

### setMarketConfig


```solidity
function setMarketConfig(uint256 marketId, Config calldata cfg) public payable onlyOwner;
```

### clearMarketConfig


```solidity
function clearMarketConfig(uint256 marketId) public payable onlyOwner;
```

### adjustBootstrapStart

Adjust bootstrap start time for a pool (owner only)

Can only delay start (oldStart <= newStart <= block.timestamp), requires zero liquidity


```solidity
function adjustBootstrapStart(uint256 poolId, uint64 newStart) public payable onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`uint256`|The pool to adjust|
|`newStart`|`uint64`|New bootstrap start timestamp|


### getMarketConfig


```solidity
function getMarketConfig(uint256 marketId) public view returns (Config memory);
```

### getDefaultConfig


```solidity
function getDefaultConfig() public view returns (Config memory);
```

### getCloseWindow

Get close window for a market

Returns the hook's close window setting. 0 = no close window logic in hook.
Router may read this value and apply its own default (typically 1 hour) when 0.


```solidity
function getCloseWindow(uint256 marketId) public view returns (uint256);
```

### getMaxPriceImpactBps

Get max price impact for a market (0 if disabled)

Returns 0 if price impact check is disabled (flag bit 5 = 0)


```solidity
function getMaxPriceImpactBps(uint256 marketId) public view returns (uint256);
```

### rescueETH

Rescue accidentally sent ETH (owner only)


```solidity
function rescueETH(address to, uint256 amount) public payable onlyOwner;
```

### transferOwnership

Transfer ownership (ERC173)


```solidity
function transferOwnership(address newOwner) public payable onlyOwner;
```

### feeOrHook

Get canonical feeOrHook value (always FLAG_BEFORE | FLAG_AFTER for stable poolId)


```solidity
function feeOrHook() public view returns (uint256);
```

### registerMarket

Register market (router or owner only)


```solidity
function registerMarket(uint256 marketId) public returns (uint256 poolId);
```

### getCurrentFeeBps

View current fee for a pool (returns 10001 sentinel if halted)


```solidity
function getCurrentFeeBps(uint256 poolId) public view returns (uint256);
```

### onlyOwner


```solidity
modifier onlyOwner() ;
```

### nonReentrant


```solidity
modifier nonReentrant() ;
```

### _reservesSlot

Collision-resistant transient slot via keccak(poolId, domain)


```solidity
function _reservesSlot(uint256 poolId) internal pure returns (uint256 slot);
```

### _metaSlot

Get transient slot for Meta cache


```solidity
function _metaSlot(uint256 poolId) internal pure returns (uint256 slot);
```

### _tstoreMeta

Store Meta to transient storage (packs into single uint256)

Layout: bits 0-63: start, bit 64: active, bit 65: yesIsToken0


```solidity
function _tstoreMeta(uint256 poolId, Meta memory m) internal;
```

### _tloadMeta

Load Meta from transient storage


```solidity
function _tloadMeta(uint256 poolId) internal view returns (Meta memory m);
```

### _flagsSlot

Get transient slot for flags cache


```solidity
function _flagsSlot(uint256 poolId) internal pure returns (uint256 slot);
```

### _tstoreFlags

Store flags to transient storage


```solidity
function _tstoreFlags(uint256 poolId, uint16 flags) internal;
```

### _tloadFlags

Load flags from transient storage


```solidity
function _tloadFlags(uint256 poolId) internal view returns (uint16 flags);
```

### _tstoreReservesAt

Store reserves to transient storage


```solidity
function _tstoreReservesAt(uint256 slot, uint112 r0, uint112 r1) internal;
```

### _tloadReservesAt

Load cached reserves from transient storage


```solidity
function _tloadReservesAt(uint256 slot)
    internal
    view
    returns (bool ok, uint112 r0, uint112 r1);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`ok`|`bool`|True if cached reserves found|
|`r0`|`uint112`|Reserve0|
|`r1`|`uint112`|Reserve1|


### _tloadReserves

Wrapper that computes slot and loads


```solidity
function _tloadReserves(uint256 poolId)
    internal
    view
    returns (bool ok, uint112 r0, uint112 r1);
```

### beforeAction


```solidity
function beforeAction(
    bytes4 sig,
    uint256 poolId,
    address,
    /* sender */
    bytes calldata /* data */
)
    public
    payable
    override(IZAMMHook)
    nonReentrant
    returns (uint256 feeBps);
```

### afterAction

Post-trade hook: enforces price impact limits and records volatility

Deltas: positive = added to pool, negative = removed


```solidity
function afterAction(
    bytes4 sig,
    uint256 poolId,
    address, /* sender */
    int256 d0,
    int256 d1,
    int256, /* dLiq */
    bytes calldata /* data */
) public payable override(IZAMMHook) nonReentrant;
```

### _getCloseWindowMode

Extract closeWindowMode from bits 2-3 of flags (0-3)


```solidity
function _getCloseWindowMode(uint16 flags) internal pure returns (uint8);
```

### _getSkewCurveExponent

Extract skew curve exponent from bits 0-1 of extraFlags (0-3)


```solidity
function _getSkewCurveExponent(Config storage c) internal view returns (uint8);
```

### _getBootstrapDecayMode

Extract bootstrap decay mode from bits 2-3 of extraFlags (0-3)


```solidity
function _getBootstrapDecayMode(Config storage c) internal view returns (uint8);
```

### _getNoId

Get NO token ID matching PAMM's formula: keccak256("PMARKET:NO", marketId)


```solidity
function _getNoId(uint256 marketId) internal pure returns (uint256 noId);
```

### _getReserves

Get YES/NO reserves based on ZAMM's canonical ordering (id0 < id1)

Takes yesIsToken0 from caller to avoid redundant storage reads


```solidity
function _getReserves(bool yesIsToken0, uint256 r0, uint256 r1)
    internal
    pure
    returns (uint256 yesReserve, uint256 noReserve);
```

### _getProbability

Calculate market probability in basis points (P(YES) = NO_reserve / total)


```solidity
function _getProbability(uint256 yesReserve, uint256 noReserve)
    internal
    pure
    returns (uint256);
```

### _isSwap

Check if selector is a swap operation

Assumes ZAMM is immutable with only these 3 swap entrypoints (swapExactIn, swapExactOut, swap)

Non-swap operations (addLiquidity/removeLiquidity) return 0 fee and skip enforcement


```solidity
function _isSwap(bytes4 sig) internal pure returns (bool);
```

### _cfg


```solidity
function _cfg(uint256 marketId) internal view returns (Config storage c);
```

### _enforceOpenCached

Reverts if market closed/resolved, or in close window with mode 0


```solidity
function _enforceOpenCached(Config storage c, uint16 flags, bool resolved, uint64 close)
    internal
    view;
```

### _computeFee


```solidity
function _computeFee(uint256 poolId) internal view returns (uint256);
```

### _computeFeeCachedWithPoolData

Optimized fee computation that accepts pre-loaded pool data and flags

Avoids redundant c.flags SLOAD and transient cache reads

Used by beforeAction after reserves are cached


```solidity
function _computeFeeCachedWithPoolData(
    uint256 poolId,
    Meta memory m,
    Config storage c,
    uint16 flags,
    bool resolved,
    uint64 close,
    PoolData memory poolData,
    bool hasPoolData
) internal view returns (uint256);
```

### _getPoolData

Fetch pool data once to avoid multiple external calls

Prefers transient cache if available (set in beforeAction when afterAction will also need reserves)


```solidity
function _getPoolData(uint256 poolId) internal view returns (PoolData memory data);
```

### _bootstrapFee

Bootstrap fee with configurable decay curve (linear/cubic/sqrt/ease-in)


```solidity
function _bootstrapFee(uint256 start, uint256 nowTs, Config storage c)
    internal
    view
    returns (uint256);
```

### _sqrt


```solidity
function _sqrt(uint256 x) internal pure returns (uint256 z);
```

### _min


```solidity
function _min(uint256 a, uint256 b) internal pure returns (uint256);
```

### _skewFee

Skew fee with configurable curve (linear/quadratic/cubic/quartic)


```solidity
function _skewFee(bool yesIsToken0, Config storage c, PoolData memory poolData)
    internal
    view
    returns (uint256);
```

### _asymmetricFee

Linear fee scaling with pool imbalance (complements non-linear skewFee)


```solidity
function _asymmetricFee(bool yesIsToken0, Config storage c, PoolData memory poolData)
    internal
    view
    returns (uint256);
```

### _volatilityFee

Extra fee during high volatility (uses recent snapshots within volatilityWindow)

Optimized: single-pass assembly scan (10 SLOADs) with algebraic variance formula

Assumes PriceSnapshot packing: uint64 timestamp (bits 0-63) + uint32 priceBps (bits 64-95)


```solidity
function _volatilityFee(uint256 poolId, Config storage c) internal view returns (uint256);
```

### _recordPriceSnapshot

Record current price snapshot for volatility tracking (with MEV protection)

Only records one snapshot per block to prevent intra-block manipulation


```solidity
function _recordPriceSnapshot(uint256 poolId, bool yesIsToken0, PoolData memory poolData)
    internal;
```

### _calculatePriceImpactFromReserves

Calculate price impact as probability delta from provided reserves


```solidity
function _calculatePriceImpactFromReserves(
    bool yesIsToken0,
    uint112 r0,
    uint112 r1,
    int256 d0,
    int256 d1
) internal pure returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`yesIsToken0`|`bool`|Whether YES token is token0 (from Meta)|
|`r0`|`uint112`|Current reserve0 (after trade)|
|`r1`|`uint112`|Current reserve1 (after trade)|
|`d0`|`int256`|Reserve0 change (positive=added, negative=removed)|
|`d1`|`int256`|Reserve1 change (positive=added, negative=removed)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|impact Impact in bps|


### getMarketProbability

Get market probability in basis points


```solidity
function getMarketProbability(uint256 poolId) public view returns (uint256 probabilityBps);
```

### getPriceHistory

Get volatility price history for a pool


```solidity
function getPriceHistory(uint256 poolId)
    public
    view
    returns (
        uint64[10] memory timestamps,
        uint32[10] memory prices,
        uint8 currentIndex,
        uint8 validCount
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`uint256`|The pool to query|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`timestamps`|`uint64[10]`|Array of 10 snapshot timestamps (0 = empty slot)|
|`prices`|`uint32[10]`|Array of 10 snapshot prices in bps (0-10000)|
|`currentIndex`|`uint8`|Current write position in circular buffer|
|`validCount`|`uint8`|Number of non-empty snapshots|


### getVolatility

Get volatility metrics for a pool


```solidity
function getVolatility(uint256 poolId)
    public
    view
    returns (uint256 volatilityPct, uint8 snapshotCount, uint256 meanPriceBps);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`uint256`|The pool to query|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`volatilityPct`|`uint256`|Coefficient of variation as percentage (0-100+)|
|`snapshotCount`|`uint8`|Number of snapshots used in calculation|
|`meanPriceBps`|`uint256`|Mean price in basis points|


### simulatePriceImpact

Calculate expected price impact for a hypothetical trade as probability delta


```solidity
function simulatePriceImpact(uint256 poolId, uint256 amountIn, bool zeroForOne, uint256 feeBps)
    public
    view
    returns (uint256 impactBps);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`uint256`|The pool to check|
|`amountIn`|`uint256`|Amount of input tokens|
|`zeroForOne`|`bool`|Direction of swap (true = sell token0 for token1)|
|`feeBps`|`uint256`|Fee in basis points to use for calculation|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`impactBps`|`uint256`|Probability change in basis points (10000 = 100%), or sentinel (10001) if fee is invalid|


### _getAmountOutView

View-only version of ZAMM's _getAmountOut for price impact simulation


```solidity
function _getAmountOutView(
    uint256 amountIn,
    uint256 reserveIn,
    uint256 reserveOut,
    uint256 feeBps
) internal pure returns (uint256);
```

### isMarketOpen

Check if market is open for trading


```solidity
function isMarketOpen(uint256 poolId) public view returns (bool);
```

### getMarketStatus

Get market status bundle (for router to avoid multiple PAMM.markets() calls)


```solidity
function getMarketStatus(uint256 marketId)
    public
    view
    returns (bool active, bool resolved, uint64 close, uint16 closeWindow, uint8 closeMode);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID to query|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`active`|`bool`|True if hook has registered pool for this market|
|`resolved`|`bool`|True if market is resolved|
|`close`|`uint64`|Market close timestamp|
|`closeWindow`|`uint16`|Close window duration in seconds|
|`closeMode`|`uint8`|Close window mode (0=halt, 1=fixed, 2=min, 3=dynamic)|


### getPoolState

Get pool state for UIs


```solidity
function getPoolState(uint256 poolId)
    public
    view
    returns (
        uint256 marketId,
        uint112 reserve0,
        uint112 reserve1,
        uint256 currentFeeBps,
        uint64 closeTime,
        bool isActive
    );
```

### _validateConfig


```solidity
function _validateConfig(Config calldata cfg) internal pure;
```

## Events
### BootstrapStartAdjusted

```solidity
event BootstrapStartAdjusted(uint256 indexed poolId, uint64 oldStart, uint64 newStart);
```

### MarketRegistered

```solidity
event MarketRegistered(uint256 indexed marketId, uint256 indexed poolId, uint64 close);
```

### OwnershipTransferred

```solidity
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

### ConfigUpdated

```solidity
event ConfigUpdated(uint256 indexed marketId, Config config);
```

### DefaultConfigUpdated

```solidity
event DefaultConfigUpdated(Config config);
```

## Errors
### Reentrancy

```solidity
error Reentrancy();
```

### MarketClosed

```solidity
error MarketClosed();
```

### Unauthorized

```solidity
error Unauthorized();
```

### InvalidConfig

```solidity
error InvalidConfig();
```

### InvalidMarket

```solidity
error InvalidMarket();
```

### InvalidPoolId

```solidity
error InvalidPoolId();
```

### AlreadyRegistered

```solidity
error AlreadyRegistered();
```

### ETHTransferFailed

```solidity
error ETHTransferFailed();
```

### PriceImpactTooHigh

```solidity
error PriceImpactTooHigh();
```

### InvalidBootstrapStart

```solidity
error InvalidBootstrapStart();
```

## Structs
### Meta

```solidity
struct Meta {
    uint64 start; // When hook registered (bootstrap starts here)
    bool active; // Market is registered
    bool yesIsToken0; // True if YES token is token0 (eliminates PAMM.getNoId() call)
}
```

### Config
Fee config (perfectly packed into 32 bytes). All fees in bps.


```solidity
struct Config {
    uint16 minFeeBps; // Steady-state fee
    uint16 maxFeeBps; // Bootstrap starting fee
    uint16 maxSkewFeeBps; // Max skew fee
    uint16 feeCapBps; // Total fee ceiling
    uint16 skewRefBps; // Skew threshold (0, 5000]
    uint16 asymmetricFeeBps; // Linear imbalance fee
    uint16 closeWindow; // Close window duration (seconds). 0 = no close window logic in hook (router may apply its own default)
    uint16 closeWindowFeeBps; // Mode 1 close fee
    uint16 maxPriceImpactBps; // Max impact (require flag bit 5)
    uint32 bootstrapWindow; // Decay duration (seconds)
    uint16 volatilityFeeBps; // High volatility penalty
    uint32 volatilityWindow; // Volatility staleness window (seconds, 0=no staleness check)
    uint16 flags; // Bits: 0=skew, 1=bootstrap, 2-3=closeMode, 4=asymmetric, 5=priceImpact, 6=volatility, 7-15=reserved
    uint16 extraFlags; // Bits: 0-1=skewCurve, 2-3=decayMode, 4-15=reserved
}
```

### PriceSnapshot

```solidity
struct PriceSnapshot {
    uint64 timestamp;
    uint32 priceBps; // Price in basis points (0-10000)
}
```

### PoolData

```solidity
struct PoolData {
    uint112 reserve0;
    uint112 reserve1;
    bool valid;
}
```

