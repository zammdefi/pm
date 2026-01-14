# mulDiv
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/Resolver.sol)

Returns `floor(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.


```solidity
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z);
```

