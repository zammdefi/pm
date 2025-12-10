# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/2a0ee96ce6c6e7628c5020381d1ff0a3fa8b1d73/src/Resolver.sol)

Sets max approval if allowance < uint128.max. USDT-compatible (approves once).


```solidity
function ensureApproval(address token, address spender) ;
```

