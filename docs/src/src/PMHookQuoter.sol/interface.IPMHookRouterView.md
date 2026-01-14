# IPMHookRouterView
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMHookQuoter.sol)


## Functions
### canonicalPoolId


```solidity
function canonicalPoolId(uint256 marketId) external view returns (uint256);
```

### canonicalFeeOrHook


```solidity
function canonicalFeeOrHook(uint256 marketId) external view returns (uint256);
```

### bootstrapVaults


```solidity
function bootstrapVaults(uint256 marketId) external view returns (uint112, uint112, uint32);
```

### twapObservations


```solidity
function twapObservations(uint256 marketId)
    external
    view
    returns (uint32, uint32, uint32, uint32, uint256, uint256);
```

### totalYesVaultShares


```solidity
function totalYesVaultShares(uint256 marketId) external view returns (uint256);
```

### totalNoVaultShares


```solidity
function totalNoVaultShares(uint256 marketId) external view returns (uint256);
```

## Structs
### BootstrapVault

```solidity
struct BootstrapVault {
    uint112 yesShares;
    uint112 noShares;
    uint32 lastActivity;
}
```

### TWAPObservations

```solidity
struct TWAPObservations {
    uint32 timestamp0;
    uint32 timestamp1;
    uint32 cacheBlockNum;
    uint32 cachedTwapBps;
    uint256 cumulative0;
    uint256 cumulative1;
}
```

