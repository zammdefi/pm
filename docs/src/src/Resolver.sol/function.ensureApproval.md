# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/ce684918478040f32fcb3c1d78c854dba9e39411/src/Resolver.sol)

Sets max approval if allowance < uint128.max. USDT-compatible (approves once).


```solidity
function ensureApproval(address token, address spender) ;
```

