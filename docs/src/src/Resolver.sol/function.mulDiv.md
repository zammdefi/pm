# mulDiv
[Git Source](https://github.com/zammdefi/pm/blob/6409aa225054aeb8e5eb04dafccaae59a1d0f4cc/src/Resolver.sol)

Returns `floor(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.


```solidity
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z);
```

