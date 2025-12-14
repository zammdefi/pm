# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/6409aa225054aeb8e5eb04dafccaae59a1d0f4cc/src/Resolver.sol)

Sets max approval once if allowance <= uint128.max. Does NOT support tokens requiring approve(0) first.


```solidity
function ensureApproval(address token, address spender) ;
```

