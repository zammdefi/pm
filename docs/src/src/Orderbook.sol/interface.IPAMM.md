# IPAMM
[Git Source](https://github.com/zammdefi/pm/blob/6409aa225054aeb8e5eb04dafccaae59a1d0f4cc/src/Orderbook.sol)

Minimal PAMM interface for orderbook operations.


## Functions
### markets


```solidity
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
```

### getNoId


```solidity
function getNoId(uint256 marketId) external pure returns (uint256);
```

### transfer


```solidity
function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
```

### transferFrom


```solidity
function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    external
    returns (bool);
```

### setOperator


```solidity
function setOperator(address operator, bool approved) external returns (bool);
```

### isOperator


```solidity
function isOperator(address owner, address operator) external view returns (bool);
```

### buyYes


```solidity
function buyYes(
    uint256 marketId,
    uint256 collateralIn,
    uint256 minYesOut,
    uint256 minSwapOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) external payable returns (uint256 yesOut);
```

### buyNo


```solidity
function buyNo(
    uint256 marketId,
    uint256 collateralIn,
    uint256 minNoOut,
    uint256 minSwapOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) external payable returns (uint256 noOut);
```

### sellYes


```solidity
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
```

### sellNo


```solidity
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
```

### tradingOpen


```solidity
function tradingOpen(uint256 marketId) external view returns (bool);
```

