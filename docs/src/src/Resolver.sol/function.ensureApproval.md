# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/d39f4d0711d78f2e49cc15977d08b491f84e0abe/src/Resolver.sol)

Sets max approval once if allowance <= uint128.max. Does NOT support tokens requiring approve(0) first.


```solidity
function ensureApproval(address token, address spender) ;
```

