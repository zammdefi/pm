# IZAMM
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMHookQuoter.sol)


## Functions
### pools


```solidity
function pools(uint256 poolId)
    external
    view
    returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast,
        uint256 price0CumulativeLast,
        uint256 price1CumulativeLast,
        uint256 kLast,
        uint256 supply
    );
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

