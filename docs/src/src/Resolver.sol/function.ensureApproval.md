# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/Resolver.sol)

Sets max approval once if allowance <= uint128.max. Does NOT support tokens requiring approve(0) first.


```solidity
function ensureApproval(address token, address spender) ;
```

