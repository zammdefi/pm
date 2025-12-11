# mulDiv
[Git Source](https://github.com/zammdefi/pm/blob/006ba95d7cfd5dfbd631c3f6ce5b2bedefc25ed2/src/Resolver.sol)

Returns `floor(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.


```solidity
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z);
```

