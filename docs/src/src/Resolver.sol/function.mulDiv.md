# mulDiv
[Git Source](https://github.com/zammdefi/pm/blob/ce684918478040f32fcb3c1d78c854dba9e39411/src/Resolver.sol)

Returns `floor(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.


```solidity
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z);
```

