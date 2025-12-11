# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/006ba95d7cfd5dfbd631c3f6ce5b2bedefc25ed2/src/Resolver.sol)

Sets max approval if allowance < uint128.max. USDT-compatible (approves once).


```solidity
function ensureApproval(address token, address spender) ;
```

