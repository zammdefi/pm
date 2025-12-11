# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/957f9e7e15f0bf2d2d674d07f7173d49bf9249ba/src/Resolver.sol)

Sets max approval if allowance < uint128.max. USDT-compatible (approves once).


```solidity
function ensureApproval(address token, address spender) ;
```

