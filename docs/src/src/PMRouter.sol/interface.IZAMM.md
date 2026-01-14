# IZAMM
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMRouter.sol)

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
) external payable;
```

### orders


```solidity
function orders(bytes32 orderHash)
    external
    view
    returns (bool partialFill, uint56 deadline, uint96 inDone, uint96 outDone);
```

### swapExactIn


```solidity
function swapExactIn(
    PoolKey calldata poolKey,
    uint256 amountIn,
    uint256 amountOutMin,
    bool zeroForOne,
    address to,
    uint256 deadline
) external payable returns (uint256 amountOut);
```

### deposit


```solidity
function deposit(address token, uint256 id, uint256 amount) external payable;
```

### recoverTransientBalance


```solidity
function recoverTransientBalance(address token, uint256 id, address to)
    external
    returns (uint256 amount);
```

## Structs
### PoolKey

```solidity
struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}
```

