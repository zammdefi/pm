# IMasterRouter
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMHookQuoter.sol)

MasterRouter interface for pool data access


## Functions
### pools


```solidity
function pools(bytes32 poolId) external view returns (uint256, uint256, uint256, address);
```

### bidPools


```solidity
function bidPools(bytes32 bidPoolId) external view returns (uint256, uint256, uint256, address);
```

### priceBitmap


```solidity
function priceBitmap(bytes32 key, uint256 bucket) external view returns (uint256);
```

### getPoolId


```solidity
function getPoolId(uint256 marketId, bool isYes, uint256 priceInBps)
    external
    pure
    returns (bytes32);
```

### getBidPoolId


```solidity
function getBidPoolId(uint256 marketId, bool buyYes, uint256 priceInBps)
    external
    pure
    returns (bytes32);
```

### positions


```solidity
function positions(bytes32 poolId, address user)
    external
    view
    returns (uint256 scaled, uint256 collDebt);
```

### bidPositions


```solidity
function bidPositions(bytes32 bidPoolId, address user)
    external
    view
    returns (uint256 scaled, uint256 sharesDebt);
```

