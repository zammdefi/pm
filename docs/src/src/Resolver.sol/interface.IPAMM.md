# IPAMM
[Git Source](https://github.com/zammdefi/pm/blob/d39f4d0711d78f2e49cc15977d08b491f84e0abe/src/Resolver.sol)


## Functions
### createMarket


```solidity
function createMarket(
    string calldata description,
    address resolver,
    address collateral,
    uint64 close,
    bool canClose
) external returns (uint256 marketId, uint256 noId);
```

### splitAndAddLiquidity


```solidity
function splitAndAddLiquidity(
    uint256 marketId,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 minLiquidity,
    address to,
    uint256 deadline
) external payable returns (uint256 shares, uint256 liquidity);
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

### closeMarket


```solidity
function closeMarket(uint256 marketId) external;
```

### resolve


```solidity
function resolve(uint256 marketId, bool outcome) external;
```

### getMarket


```solidity
function getMarket(uint256 marketId)
    external
    view
    returns (
        address resolver,
        address collateral,
        bool resolved,
        bool outcome,
        bool canClose,
        uint64 close,
        uint256 collateralLocked,
        uint256 yesSupply,
        uint256 noSupply,
        string memory description
    );
```

### getNoId


```solidity
function getNoId(uint256 marketId) external pure returns (uint256);
```

### balanceOf


```solidity
function balanceOf(address owner, uint256 id) external view returns (uint256);
```

### transfer


```solidity
function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
```

