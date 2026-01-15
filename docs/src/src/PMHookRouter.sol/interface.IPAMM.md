# IPAMM
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMHookRouter.sol)


## Functions
### balanceOf


```solidity
function balanceOf(address account, uint256 id) external view returns (uint256);
```

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

### setOperator


```solidity
function setOperator(address operator, bool approved) external returns (bool);
```

### transferFrom


```solidity
function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    external
    returns (bool);
```

### split


```solidity
function split(uint256 marketId, uint256 amount, address to) external payable;
```

### merge


```solidity
function merge(uint256 marketId, uint256 amount, address to) external;
```

### transfer


```solidity
function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
```

### claim


```solidity
function claim(uint256 marketId, address to) external returns (uint256 shares, uint256 payout);
```

