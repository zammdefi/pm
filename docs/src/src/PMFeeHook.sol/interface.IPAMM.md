# IPAMM
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMFeeHook.sol)


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

### poolKey


```solidity
function poolKey(uint256 marketId, uint256 feeOrHook) external view returns (PoolKey memory);
```

## Structs
### PoolKey

```solidity
struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}
```

