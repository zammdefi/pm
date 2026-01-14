# IZAMMHook
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMFeeHook.sol)


## Functions
### beforeAction


```solidity
function beforeAction(bytes4 sig, uint256 poolId, address sender, bytes calldata data)
    external
    payable
    returns (uint256 feeBps);
```

### afterAction


```solidity
function afterAction(
    bytes4 sig,
    uint256 poolId,
    address sender,
    int256 d0,
    int256 d1,
    int256 dLiq,
    bytes calldata data
) external payable;
```

