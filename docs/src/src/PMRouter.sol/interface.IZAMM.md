# IZAMM
[Git Source](https://github.com/zammdefi/pm/blob/d39f4d0711d78f2e49cc15977d08b491f84e0abe/src/PMRouter.sol)

ZAMM orderbook + AMM interface.


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

### swap


```solidity
function swap(
    address tokenIn,
    uint256 idIn,
    address tokenOut,
    uint256 idOut,
    uint256 amountIn,
    uint256 minOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) external payable returns (uint256 amountOut);
```

