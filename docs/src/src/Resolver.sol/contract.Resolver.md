# Resolver
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/Resolver.sol)

**Title:**
Resolver

On-chain oracle for PAMM markets based on arbitrary staticcall reads.

Scalar: value = staticcall(target, callData). Ratio: value = A * 1e18 / B.
Outcome determined by condition value when resolveMarket() is called.
canClose=true allows early resolution when condition becomes true.


## State Variables
### PAMM

```solidity
address public constant PAMM = 0x000000000044bfe6c2BBFeD8862973E0612f07C0
```


### REENTRANCY_SLOT

```solidity
uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21269
```


### conditions

```solidity
mapping(uint256 marketId => Condition) public conditions
```


## Functions
### receive


```solidity
receive() external payable;
```

### constructor


```solidity
constructor() payable;
```

### nonReentrant


```solidity
modifier nonReentrant() ;
```

### multicall


```solidity
function multicall(bytes[] calldata data) public payable returns (bytes[] memory results);
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
) public nonReentrant;
```

### permitDAI


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

### createNumericMarketSimple


```solidity
function createNumericMarketSimple(
    string calldata observable,
    address collateral,
    address target,
    bytes4 selector,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose
) public returns (uint256 marketId, uint256 noId);
```

### createNumericMarket


```solidity
function createNumericMarket(
    string calldata observable,
    address collateral,
    address target,
    bytes calldata callData,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose
) public returns (uint256 marketId, uint256 noId);
```

### _createNumericMarket


```solidity
function _createNumericMarket(
    string calldata observable,
    address collateral,
    address target,
    bytes memory callData,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose
) internal returns (uint256 marketId, uint256 noId);
```

### createNumericMarketAndSeedSimple


```solidity
function createNumericMarketAndSeedSimple(
    string calldata observable,
    address collateral,
    address target,
    bytes4 selector,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    SeedParams calldata seed
)
    public
    payable
    nonReentrant
    returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity);
```

### createNumericMarketAndSeed


```solidity
function createNumericMarketAndSeed(
    string calldata observable,
    address collateral,
    address target,
    bytes calldata callData,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    SeedParams calldata seed
)
    public
    payable
    nonReentrant
    returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity);
```

### createRatioMarketSimple


```solidity
function createRatioMarketSimple(
    string calldata observable,
    address collateral,
    address targetA,
    bytes4 selectorA,
    address targetB,
    bytes4 selectorB,
    Op op,
    uint256 threshold, // 1e18-scaled
    uint64 close,
    bool canClose
) public returns (uint256 marketId, uint256 noId);
```

### createRatioMarket


```solidity
function createRatioMarket(
    string calldata observable,
    address collateral,
    address targetA,
    bytes calldata callDataA,
    address targetB,
    bytes calldata callDataB,
    Op op,
    uint256 threshold, // 1e18-scaled
    uint64 close,
    bool canClose
) public returns (uint256 marketId, uint256 noId);
```

### _createRatioMarket


```solidity
function _createRatioMarket(
    string calldata observable,
    address collateral,
    address targetA,
    bytes memory callDataA,
    address targetB,
    bytes memory callDataB,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose
) internal returns (uint256 marketId, uint256 noId);
```

### createRatioMarketAndSeedSimple


```solidity
function createRatioMarketAndSeedSimple(
    string calldata observable,
    address collateral,
    address targetA,
    bytes4 selectorA,
    address targetB,
    bytes4 selectorB,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    SeedParams calldata seed
)
    public
    payable
    nonReentrant
    returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity);
```

### createRatioMarketAndSeed


```solidity
function createRatioMarketAndSeed(
    string calldata observable,
    address collateral,
    address targetA,
    bytes calldata callDataA,
    address targetB,
    bytes calldata callDataB,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    SeedParams calldata seed
)
    public
    payable
    nonReentrant
    returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity);
```

### createNumericMarketSeedAndBuy

Creates market, seeds LP, and executes buyYes/buyNo to take initial position.

Does NOT set a specific target probability. The resulting odds depend on
pool size, swap amount, and fees. Use for convenience when you want to
seed liquidity and immediately take a position in one transaction.


```solidity
function createNumericMarketSeedAndBuy(
    string calldata observable,
    address collateral,
    address target,
    bytes calldata callData,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    SeedParams calldata seed,
    SwapParams calldata swap
)
    public
    payable
    nonReentrant
    returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut);
```

### createRatioMarketSeedAndBuy

Creates ratio market, seeds LP, and executes buyYes/buyNo to take initial position.

Does NOT set a specific target probability. The resulting odds depend on
pool size, swap amount, and fees. Use for convenience when you want to
seed liquidity and immediately take a position in one transaction.


```solidity
function createRatioMarketSeedAndBuy(
    string calldata observable,
    address collateral,
    address targetA,
    bytes calldata callDataA,
    address targetB,
    bytes calldata callDataB,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    SeedParams calldata seed,
    SwapParams calldata swap
)
    public
    payable
    nonReentrant
    returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut);
```

### registerConditionForExistingMarket


```solidity
function registerConditionForExistingMarket(
    uint256 marketId,
    address target,
    bytes calldata callData,
    Op op,
    uint256 threshold
) public;
```

### registerConditionForExistingMarketSimple


```solidity
function registerConditionForExistingMarketSimple(
    uint256 marketId,
    address target,
    bytes4 selector,
    Op op,
    uint256 threshold
) public;
```

### _registerScalarCondition


```solidity
function _registerScalarCondition(
    uint256 marketId,
    address target,
    bytes memory callData,
    Op op,
    uint256 threshold
) internal;
```

### registerRatioConditionForExistingMarket


```solidity
function registerRatioConditionForExistingMarket(
    uint256 marketId,
    address targetA,
    bytes calldata callDataA,
    address targetB,
    bytes calldata callDataB,
    Op op,
    uint256 threshold
) public;
```

### registerRatioConditionForExistingMarketSimple


```solidity
function registerRatioConditionForExistingMarketSimple(
    uint256 marketId,
    address targetA,
    bytes4 selectorA,
    address targetB,
    bytes4 selectorB,
    Op op,
    uint256 threshold
) public;
```

### _registerRatioCondition


```solidity
function _registerRatioCondition(
    uint256 marketId,
    address targetA,
    bytes memory callDataA,
    address targetB,
    bytes memory callDataB,
    Op op,
    uint256 threshold
) internal;
```

### resolveMarket


```solidity
function resolveMarket(uint256 marketId) public nonReentrant;
```

### preview


```solidity
function preview(uint256 marketId)
    public
    view
    returns (uint256 value, bool condTrue, bool ready);
```

### buildDescription


```solidity
function buildDescription(
    string calldata observable,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose
) public pure returns (string memory);
```

### _currentValue


```solidity
function _currentValue(Condition storage c) internal view returns (uint256 value);
```

### _readUint


```solidity
function _readUint(address target, bytes memory callData) internal view returns (uint256 v);
```

### _compare


```solidity
function _compare(uint256 value, Op op, uint256 threshold) internal pure returns (bool);
```

### _opSymbol


```solidity
function _opSymbol(Op op) internal pure returns (string memory);
```

### _buildDescription


```solidity
function _buildDescription(
    string calldata observable,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose
) internal pure returns (string memory);
```

### _seedLiquidity


```solidity
function _seedLiquidity(
    address collateral,
    uint256 marketId,
    SeedParams calldata p,
    uint256 extraETH
) internal returns (uint256 shares, uint256 liquidity);
```

### _flushLeftoverShares


```solidity
function _flushLeftoverShares(uint256 marketId) internal;
```

### _refundDust

Refunds any dust collateral (ETH or ERC20) to msg.sender.


```solidity
function _refundDust(address collateral) internal;
```

### _buyToSkewOdds

Executes buyYes or buyNo to skew pool odds. Does NOT set a target probability.


```solidity
function _buyToSkewOdds(
    address collateral,
    uint256 marketId,
    uint256 feeOrHook,
    uint256 deadline,
    SwapParams calldata s
) internal returns (uint256 amountOut);
```

### _toString


```solidity
function _toString(uint256 value) internal pure returns (string memory result);
```

## Events
### ConditionCreated

```solidity
event ConditionCreated(
    uint256 indexed marketId,
    address indexed targetA,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    bool isRatio,
    string description
);
```

### ConditionRegistered

```solidity
event ConditionRegistered(
    uint256 indexed marketId,
    address indexed targetA,
    Op op,
    uint256 threshold,
    uint64 close,
    bool canClose,
    bool isRatio
);
```

### MarketSeeded

```solidity
event MarketSeeded(
    uint256 indexed marketId,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 shares,
    uint256 liquidity,
    address lpRecipient
);
```

## Errors
### Unknown

```solidity
error Unknown();
```

### Pending

```solidity
error Pending();
```

### Reentrancy

```solidity
error Reentrancy();
```

### MulDivFailed

```solidity
error MulDivFailed();
```

### InvalidTarget

```solidity
error InvalidTarget();
```

### ApproveFailed

```solidity
error ApproveFailed();
```

### MarketResolved

```solidity
error MarketResolved();
```

### TransferFailed

```solidity
error TransferFailed();
```

### ConditionExists

```solidity
error ConditionExists();
```

### InvalidDeadline

```solidity
error InvalidDeadline();
```

### InvalidETHAmount

```solidity
error InvalidETHAmount();
```

### TargetCallFailed

```solidity
error TargetCallFailed();
```

### ETHTransferFailed

```solidity
error ETHTransferFailed();
```

### NotResolverMarket

```solidity
error NotResolverMarket();
```

### TransferFromFailed

```solidity
error TransferFromFailed();
```

## Structs
### Condition

```solidity
struct Condition {
    address targetA;
    address targetB;
    Op op;
    bool isRatio;
    uint256 threshold;
    bytes callDataA;
    bytes callDataB;
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
    bool yesForNo; // true = buyNo, false = buyYes
    address recipient; // recipient of swapped shares (use address(0) for msg.sender)
}
```

## Enums
### Op

```solidity
enum Op {
    LT,
    GT,
    LTE,
    GTE,
    EQ,
    NEQ
}
```

