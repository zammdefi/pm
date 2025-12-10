# ensureApproval
[Git Source](https://github.com/zammdefi/pm/blob/e53dcab813204ae1d44f9448625afd8c4dac0c71/src/Resolver.sol)

Sets max approval if allowance < uint128.max. USDT-compatible (approves once).


```solidity
function ensureApproval(address token, address spender) ;
```

