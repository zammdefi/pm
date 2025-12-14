# mulDiv
[Git Source](https://github.com/zammdefi/pm/blob/d39f4d0711d78f2e49cc15977d08b491f84e0abe/src/Resolver.sol)

Returns `floor(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.


```solidity
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z);
```

