# mulDiv
[Git Source](https://github.com/zammdefi/pm/blob/fd85de4cbb2d992be3173c764eca542e83197ee2/src/Resolver.sol)

Returns `floor(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.


```solidity
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z);
```

