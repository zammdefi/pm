# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/fd85de4cbb2d992be3173c764eca542e83197ee2/src/Resolver.sol)

Sets max approval once if allowance <= uint128.max. Does NOT support tokens requiring approve(0) first.


```solidity
function ensureApproval(address token, address spender) ;
```

