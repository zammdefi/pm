# GasPM
[Git Source](https://github.com/zammdefi/pm/blob/ce684918478040f32fcb3c1d78c854dba9e39411/src/GasPM.sol)

**Title:**
GasPM

Gas price prediction markets with integrated base fee oracle.

Tracks cumulative base fee, historical max/min. Anyone can update(); rewards optional.
Creates prediction markets via Resolver: directional, range, breakout, peak, trough,
volatility, stability, spot, comparison. Window variants track metrics since market creation.


## State Variables
### PAMM

```solidity
address public constant PAMM = 0x0000000000F8bA51d6e987660D3e455ac2c4BE9d
```


### RESOLVER

```solidity
address payable public constant RESOLVER = payable(0x0000000000b0ba1b2bb3AF96FbB893d835970ec4)
```


### OP_LTE

```solidity
uint8 internal constant OP_LTE = 2
```


### OP_GTE

```solidity
uint8 internal constant OP_GTE = 3
```


### OP_EQ

```solidity
uint8 internal constant OP_EQ = 4
```


### MARKET_TYPE_RANGE

```solidity
uint8 internal constant MARKET_TYPE_RANGE = 4
```


### MARKET_TYPE_BREAKOUT

```solidity
uint8 internal constant MARKET_TYPE_BREAKOUT = 5
```


### MARKET_TYPE_PEAK

```solidity
uint8 internal constant MARKET_TYPE_PEAK = 6
```


### MARKET_TYPE_TROUGH

```solidity
uint8 internal constant MARKET_TYPE_TROUGH = 7
```


### MARKET_TYPE_VOLATILITY

```solidity
uint8 internal constant MARKET_TYPE_VOLATILITY = 8
```


### MARKET_TYPE_STABILITY

```solidity
uint8 internal constant MARKET_TYPE_STABILITY = 9
```


### MARKET_TYPE_SPOT

```solidity
uint8 internal constant MARKET_TYPE_SPOT = 10
```


### MARKET_TYPE_COMPARISON

```solidity
uint8 internal constant MARKET_TYPE_COMPARISON = 11
```


### cumulativeBaseFee

```solidity
uint256 public cumulativeBaseFee
```


### lastBaseFee

```solidity
uint256 public lastBaseFee
```


### lastUpdateTime

```solidity
uint64 public lastUpdateTime
```


### startTime

```solidity
uint64 public startTime
```


### maxBaseFee

```solidity
uint128 public maxBaseFee
```


### minBaseFee

```solidity
uint128 public minBaseFee
```


### owner

```solidity
address public owner
```


### rewardAmount

```solidity
uint256 public rewardAmount
```


### cooldown

```solidity
uint256 public cooldown
```


### _markets

```solidity
uint256[] internal _markets
```


### isOurMarket

```solidity
mapping(uint256 => bool) public isOurMarket
```


### publicCreation

```solidity
bool public publicCreation
```


### marketSnapshots

```solidity
mapping(uint256 => Snapshot) public marketSnapshots
```


### windowSpreads

```solidity
mapping(uint256 => WindowSpread) public windowSpreads
```


### comparisonStartValue
Starting TWAP for comparison markets.


```solidity
mapping(uint256 => uint256) public comparisonStartValue
```


## Functions
### onlyOwner


```solidity
modifier onlyOwner() ;
```

### canCreate


```solidity
modifier canCreate() ;
```

### constructor


```solidity
constructor() payable;
```

### receive


```solidity
receive() external payable;
```

### update

Record current base fee. Pays reward if funded and cooldown passed.


```solidity
function update() public;
```

### baseFeeAverage

TWAP since deployment in wei.


```solidity
function baseFeeAverage() public view returns (uint256);
```

### baseFeeAverageGwei

TWAP since deployment in gwei.


```solidity
function baseFeeAverageGwei() public view returns (uint256);
```

### baseFeeCurrent

Current spot base fee in wei.


```solidity
function baseFeeCurrent() public view returns (uint256);
```

### baseFeeCurrentGwei

Current spot base fee in gwei.


```solidity
function baseFeeCurrentGwei() public view returns (uint256);
```

### trackingDuration

Seconds since oracle started.


```solidity
function trackingDuration() public view returns (uint256);
```

### baseFeeInRange

Returns 1 if TWAP is within [lower, upper], 0 otherwise.


```solidity
function baseFeeInRange(uint256 lower, uint256 upper) public view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei (inclusive)|
|`upper`|`uint256`|Upper bound in wei (inclusive)|


### baseFeeOutOfRange

Returns 1 if TWAP is outside (lower, upper), 0 otherwise.


```solidity
function baseFeeOutOfRange(uint256 lower, uint256 upper) public view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei|
|`upper`|`uint256`|Upper bound in wei|


### baseFeeMax

Highest base fee recorded since deployment (wei). Updated via update().


```solidity
function baseFeeMax() public view returns (uint256);
```

### baseFeeMin

Lowest base fee recorded since deployment (wei). Updated via update().


```solidity
function baseFeeMin() public view returns (uint256);
```

### baseFeeSpread

Spread between highest and lowest base fee since deployment (wei).


```solidity
function baseFeeSpread() public view returns (uint256);
```

### baseFeeAverageSince

TWAP since a specific market was created.


```solidity
function baseFeeAverageSince(uint256 marketId) public view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID to get the window average for|


### baseFeeInRangeSince

Returns 1 if window TWAP is within [lower, upper], 0 otherwise.


```solidity
function baseFeeInRangeSince(uint256 marketId, uint256 lower, uint256 upper)
    public
    view
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID for the window|
|`lower`|`uint256`|Lower bound in wei (inclusive)|
|`upper`|`uint256`|Upper bound in wei (inclusive)|


### baseFeeOutOfRangeSince

Returns 1 if window TWAP is outside (lower, upper), 0 otherwise.


```solidity
function baseFeeOutOfRangeSince(uint256 marketId, uint256 lower, uint256 upper)
    public
    view
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID for the window|
|`lower`|`uint256`|Lower bound in wei|
|`upper`|`uint256`|Upper bound in wei|


### baseFeeSpreadSince

Absolute spread (max - min) during the market window.

Call pokeWindowVolatility() regularly to keep tracking accurate.


```solidity
function baseFeeSpreadSince(uint256 marketId) public view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID to get the window spread for|


### baseFeeHigherThanStart

Returns 1 if current TWAP > starting TWAP, 0 otherwise.


```solidity
function baseFeeHigherThanStart(uint256 marketId) public view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The comparison market ID|


### pokeWindowVolatility

Update a window volatility market's max/min to include current basefee.

Call this periodically to ensure baseFeeSpreadSince() captures all extremes.
The view function includes current basefee, but poke persists historical extremes.


```solidity
function pokeWindowVolatility(uint256 marketId) public;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market ID to update|


### pokeWindowVolatilityBatch

Batch update multiple window volatility markets.


```solidity
function pokeWindowVolatilityBatch(uint256[] calldata marketIds) public;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketIds`|`uint256[]`|Array of market IDs to update|


### createMarket

Create directional TWAP market: "Will avg gas be <=/>= X?"


```solidity
function createMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint8 op,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when condition met|
|`op`|`uint8`|2=LTE, 3=GTE|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createMarketAndBuy

Create directional market + seed LP + take initial position.

yesForNo=false buys YES (raises YES price), yesForNo=true buys NO.


```solidity
function createMarketAndBuy(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint8 op,
    SeedParams calldata seed,
    SwapParams calldata swap
) public payable canCreate returns (uint256 marketId, uint256 swapOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when condition met|
|`op`|`uint8`|2=LTE, 3=GTE|
|`seed`|`SeedParams`|Liquidity parameters|
|`swap`|`SwapParams`|Position parameters|


### createRangeMarket

Create range market: "Will avg gas be between X and Y?"


```solidity
function createRangeMarket(
    uint256 lower,
    uint256 upper,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei (inclusive)|
|`upper`|`uint256`|Upper bound in wei (inclusive)|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when in range|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createRangeMarketAndBuy

Create range market + seed LP + take initial position.


```solidity
function createRangeMarketAndBuy(
    uint256 lower,
    uint256 upper,
    address collateral,
    uint64 close,
    bool canClose,
    SeedParams calldata seed,
    SwapParams calldata swap
) public payable canCreate returns (uint256 marketId, uint256 swapOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei (inclusive)|
|`upper`|`uint256`|Upper bound in wei (inclusive)|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when in range|
|`seed`|`SeedParams`|Liquidity parameters|
|`swap`|`SwapParams`|Position parameters|


### createBreakoutMarket

Create breakout market: "Will avg gas leave the X-Y range?"


```solidity
function createBreakoutMarket(
    uint256 lower,
    uint256 upper,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei|
|`upper`|`uint256`|Upper bound in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when out of range|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createPeakMarket

Create peak market: "Will gas spike to X?" (lifetime high)


```solidity
function createPeakMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target peak in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when threshold reached|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createTroughMarket

Create trough market: "Will gas dip to X?" (lifetime low)


```solidity
function createTroughMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target trough in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when threshold reached|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createVolatilityMarket

Create volatility market: "Will gas swing by X?" (lifetime spread)


```solidity
function createVolatilityMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target spread in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when spread reached|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createStabilityMarket

Create stability market: "Will gas stay calm?" (spread < threshold)


```solidity
function createStabilityMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Max spread in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|Generally false; YES wins only if spread stays low at close|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createSpotMarket

Create spot market: "Will gas be >= X at resolution?" (instant, not TWAP)

More manipulation-susceptible than TWAP. Best for extreme thresholds.


```solidity
function createSpotMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target spot price in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when threshold reached|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createComparisonMarket

Create comparison market: "Will TWAP be higher at close than now?"

Snapshots current TWAP. YES wins if TWAP increases by close.


```solidity
function createComparisonMarket(
    address collateral,
    uint64 close,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createWindowMarket

Create window market: "Will avg gas DURING THIS MARKET be <=/>= X?"


```solidity
function createWindowMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint8 op,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when condition met|
|`op`|`uint8`|2=LTE, 3=GTE|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createWindowMarketAndBuy

Create window market + seed LP + take initial position.


```solidity
function createWindowMarketAndBuy(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint8 op,
    SeedParams calldata seed,
    SwapParams calldata swap
) public payable canCreate returns (uint256 marketId, uint256 swapOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when condition met|
|`op`|`uint8`|2=LTE, 3=GTE|
|`seed`|`SeedParams`|Liquidity parameters|
|`swap`|`SwapParams`|Position parameters|


### createWindowRangeMarket

Create window range market: "Will avg gas DURING THIS MARKET stay between X-Y?"


```solidity
function createWindowRangeMarket(
    uint256 lower,
    uint256 upper,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei (inclusive)|
|`upper`|`uint256`|Upper bound in wei (inclusive)|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when in range|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createWindowRangeMarketAndBuy

Create window range market + seed LP + take initial position.


```solidity
function createWindowRangeMarketAndBuy(
    uint256 lower,
    uint256 upper,
    address collateral,
    uint64 close,
    bool canClose,
    SeedParams calldata seed,
    SwapParams calldata swap
) public payable canCreate returns (uint256 marketId, uint256 swapOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei (inclusive)|
|`upper`|`uint256`|Upper bound in wei (inclusive)|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when in range|
|`seed`|`SeedParams`|Liquidity parameters|
|`swap`|`SwapParams`|Position parameters|


### createWindowBreakoutMarket

Create window breakout market: "Will avg gas DURING THIS MARKET leave X-Y range?"


```solidity
function createWindowBreakoutMarket(
    uint256 lower,
    uint256 upper,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lower`|`uint256`|Lower bound in wei|
|`upper`|`uint256`|Upper bound in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when out of range|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createWindowPeakMarket

Create window peak market: "Will gas spike to X DURING THIS MARKET?"

Reverts if threshold already exceeded (maxBaseFee >= threshold).


```solidity
function createWindowPeakMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target peak in wei (must be > current maxBaseFee)|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when threshold reached|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createWindowTroughMarket

Create window trough market: "Will gas dip to X DURING THIS MARKET?"

Reverts if threshold already reached (minBaseFee <= threshold).


```solidity
function createWindowTroughMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target trough in wei (must be < current minBaseFee)|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when threshold reached|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createWindowVolatilityMarket

Create window volatility market: "Will gas spread exceed X DURING THIS MARKET?"

Tracks absolute spread (max - min) during the market window.
Call pokeWindowVolatility() periodically to capture extremes between blocks.


```solidity
function createWindowVolatilityMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Target spread in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|If true, resolves early when spread reached|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### createWindowStabilityMarket

Create window stability market: "Will gas spread stay below X DURING THIS MARKET?"

YES wins if absolute spread (max - min) stays below threshold.
Call pokeWindowVolatility() periodically to capture extremes between blocks.


```solidity
function createWindowStabilityMarket(
    uint256 threshold,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address lpRecipient
) public payable canCreate returns (uint256 marketId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`threshold`|`uint256`|Max spread in wei|
|`collateral`|`address`|Token (address(0) for ETH)|
|`close`|`uint64`|Resolution timestamp|
|`canClose`|`bool`|Generally false; YES wins only if spread stays low at close|
|`collateralIn`|`uint256`|Liquidity seed amount|
|`feeOrHook`|`uint256`|Pool fee tier|
|`minLiquidity`|`uint256`|Min LP tokens|
|`lpRecipient`|`address`|LP token recipient|


### marketCount

Number of markets created through this oracle.


```solidity
function marketCount() public view returns (uint256);
```

### getMarkets

Get market IDs with pagination.


```solidity
function getMarkets(uint256 start, uint256 count) public view returns (uint256[] memory ids);
```

### getMarketInfos

Get detailed info for markets created through this oracle.


```solidity
function getMarketInfos(uint256 start, uint256 count)
    public
    view
    returns (MarketInfo[] memory infos);
```

### setReward

Configure reward per update.


```solidity
function setReward(uint256 _rewardAmount, uint256 _cooldown) public onlyOwner;
```

### setPublicCreation

Enable/disable public market creation.


```solidity
function setPublicCreation(bool enabled) public onlyOwner;
```

### withdraw

Withdraw funds.


```solidity
function withdraw(address to, uint256 amount) public onlyOwner;
```

### transferOwnership

Transfer ownership (ERC-173).


```solidity
function transferOwnership(address newOwner) public onlyOwner;
```

### multicall

Batch multiple calls in one transaction.

Non-payable to prevent msg.value reuse attacks. Use AndBuy helpers for ETH.


```solidity
function multicall(bytes[] calldata data) public returns (bytes[] memory results);
```

### permit

EIP-2612 permit for gasless approvals.


```solidity
function permit(
    address token,
    address owner_,
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
    address owner_,
    uint256 nonce,
    uint256 deadline,
    bool allowed,
    uint8 v,
    bytes32 r,
    bytes32 s
) public;
```

### _handleCollateral

Validates msg.value for ETH or transfers ERC20. Returns ETH to forward.


```solidity
function _handleCollateral(address collateral, uint256 amount)
    internal
    returns (uint256 ethValue);
```

### _registerMarket

Adds market to _markets array and isOurMarket mapping.


```solidity
function _registerMarket(uint256 marketId) internal;
```

### _safeTransferETH

Transfers ETH, reverts on failure.


```solidity
function _safeTransferETH(address to, uint256 amount) internal;
```

### _toString


```solidity
function _toString(uint256 value) internal pure returns (string memory result);
```

### _toGweiString

Formats wei as gwei string with up to 3 decimals. E.g., 50e9 => "50".


```solidity
function _toGweiString(uint256 wei_) internal pure returns (string memory);
```

### _safeTransferFrom

USDT-compatible transferFrom.


```solidity
function _safeTransferFrom(address token, address from, address to, uint256 amount) internal;
```

### _ensureApproval

USDT-compatible approval. Sets max if allowance < uint128.max.


```solidity
function _ensureApproval(address token, address spender) internal;
```

### _snapshotForMarket

Snapshot cumulative state for window market.


```solidity
function _snapshotForMarket(uint256 marketId) internal;
```

### _computeMarketId

Pre-compute marketId to match Resolver/PAMM derivation.


```solidity
function _computeMarketId(
    string memory observable,
    address collateral,
    uint8 op,
    uint256 threshold,
    uint64 close,
    bool canClose
) internal pure returns (uint256);
```

### _buildObservable


```solidity
function _buildObservable(uint256 threshold, uint8 op) internal pure returns (string memory);
```

### _buildRangeObservable


```solidity
function _buildRangeObservable(uint256 lower, uint256 upper)
    internal
    pure
    returns (string memory);
```

### _buildBreakoutObservable


```solidity
function _buildBreakoutObservable(uint256 lower, uint256 upper)
    internal
    pure
    returns (string memory);
```

### _buildPeakObservable


```solidity
function _buildPeakObservable(uint256 threshold) internal pure returns (string memory);
```

### _buildTroughObservable


```solidity
function _buildTroughObservable(uint256 threshold) internal pure returns (string memory);
```

### _buildWindowObservable


```solidity
function _buildWindowObservable(uint256 threshold, uint8 op)
    internal
    pure
    returns (string memory);
```

### _buildWindowRangeObservable


```solidity
function _buildWindowRangeObservable(uint256 lower, uint256 upper)
    internal
    pure
    returns (string memory);
```

### _buildWindowBreakoutObservable


```solidity
function _buildWindowBreakoutObservable(uint256 lower, uint256 upper)
    internal
    pure
    returns (string memory);
```

### _buildWindowPeakObservable


```solidity
function _buildWindowPeakObservable(uint256 threshold) internal pure returns (string memory);
```

### _buildWindowTroughObservable


```solidity
function _buildWindowTroughObservable(uint256 threshold) internal pure returns (string memory);
```

### _buildVolatilityObservable


```solidity
function _buildVolatilityObservable(uint256 threshold) internal pure returns (string memory);
```

### _buildStabilityObservable


```solidity
function _buildStabilityObservable(uint256 threshold) internal pure returns (string memory);
```

### _buildWindowVolatilityObservable


```solidity
function _buildWindowVolatilityObservable(uint256 threshold)
    internal
    pure
    returns (string memory);
```

### _buildWindowStabilityObservable


```solidity
function _buildWindowStabilityObservable(uint256 threshold)
    internal
    pure
    returns (string memory);
```

### _buildSpotObservable


```solidity
function _buildSpotObservable(uint256 threshold) internal pure returns (string memory);
```

### _buildComparisonObservable


```solidity
function _buildComparisonObservable(uint256 startTwap) internal pure returns (string memory);
```

## Events
### Updated

```solidity
event Updated(
    uint256 baseFee, uint256 cumulativeBaseFee, address indexed updater, uint256 reward
);
```

### MarketCreated

```solidity
event MarketCreated(
    uint256 indexed marketId,
    uint256 threshold,
    uint256 threshold2,
    uint64 close,
    bool canClose,
    uint8 op
);
```

### RewardConfigured

```solidity
event RewardConfigured(uint256 rewardAmount, uint256 cooldown);
```

### PublicCreationSet

```solidity
event PublicCreationSet(bool enabled);
```

### OwnershipTransferred

```solidity
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

## Errors
### InvalidOp

```solidity
error InvalidOp();
```

### InvalidClose

```solidity
error InvalidClose();
```

### Unauthorized

```solidity
error Unauthorized();
```

### AlreadyExceeded

```solidity
error AlreadyExceeded();
```

### InvalidCooldown

```solidity
error InvalidCooldown();
```

### InvalidThreshold

```solidity
error InvalidThreshold();
```

### InvalidETHAmount

```solidity
error InvalidETHAmount();
```

### ResolverCallFailed

```solidity
error ResolverCallFailed();
```

### AlreadyBelowThreshold

```solidity
error AlreadyBelowThreshold();
```

## Structs
### Snapshot
Snapshot of cumulative state at market creation (for window markets).


```solidity
struct Snapshot {
    uint192 cumulative;
    uint64 timestamp;
}
```

### WindowSpread
Per-market max/min tracking for window volatility/stability markets.
Updated via pokeWindowVolatility() to track spread during the market window.


```solidity
struct WindowSpread {
    uint128 windowMax;
    uint128 windowMin;
}
```

### SeedParams

```solidity
struct SeedParams {
    uint256 collateralIn;
    uint256 feeOrHook;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 minLiquidity;
    address lpRecipient;
    uint256 deadline;
}
```

### SwapParams

```solidity
struct SwapParams {
    uint256 collateralForSwap;
    uint256 minOut;
    bool yesForNo; // true = buyNo (swap yes for no), false = buyYes (swap no for yes)
}
```

### MarketInfo

```solidity
struct MarketInfo {
    uint256 marketId;
    uint64 close;
    bool resolved;
    bool outcome;
    uint256 currentValue;
    bool conditionMet;
    bool ready;
}
```

