# IZAMMOrderbook
[Git Source](https://github.com/zammdefi/pm/blob/6409aa225054aeb8e5eb04dafccaae59a1d0f4cc/src/Orderbook.sol)

ZAMM orderbook interface.


## Functions
### makeOrder


```solidity
function makeOrder(
    address tokenIn,
    uint256 idIn,
    uint96 amtIn,
    address tokenOut,
    uint256 idOut,
    uint96 amtOut,
    uint56 deadline,
    bool partialFill
) external payable returns (bytes32 orderHash);
```

### cancelOrder


```solidity
function cancelOrder(
    address tokenIn,
    uint256 idIn,
    uint96 amtIn,
    address tokenOut,
    uint256 idOut,
    uint96 amtOut,
    uint56 deadline,
    bool partialFill
) external;
```

### fillOrder


```solidity
function fillOrder(
    address maker,
    address tokenIn,
    uint256 idIn,
    uint96 amtIn,
    address tokenOut,
    uint256 idOut,
    uint96 amtOut,
    uint56 deadline,
    bool partialFill,
    uint96 amountToFill
) external payable returns (uint96 filled);
```

### orders


```solidity
function orders(bytes32 orderHash)
    external
    view
    returns (bool partialFill, uint56 deadline, uint96 inDone, uint96 outDone);
```

