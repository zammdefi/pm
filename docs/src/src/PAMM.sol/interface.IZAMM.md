# IZAMM
[Git Source](https://github.com/zammdefi/pm/blob/fd85de4cbb2d992be3173c764eca542e83197ee2/src/PAMM.sol)

ZAMM interface for LP operations.


## Functions
### pools


```solidity
function pools(uint256 poolId)
    external
    view
    returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast,
        uint256 price0CumulativeLast,
        uint256 price1CumulativeLast,
        uint256 kLast,
        uint256 supply
    );
```

### addLiquidity


```solidity
function addLiquidity(
    PoolKey calldata poolKey,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
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

### swapExactIn


```solidity
function swapExactIn(
    PoolKey calldata poolKey,
    uint256 amountIn,
    uint256 amountOutMin,
    bool zeroForOne,
    address to,
    uint256 deadline
) external returns (uint256 amountOut);
```

### swapExactOut


```solidity
function swapExactOut(
    PoolKey calldata poolKey,
    uint256 amountOut,
    uint256 amountInMax,
    bool zeroForOne,
    address to,
    uint256 deadline
) external returns (uint256 amountIn);
```

### removeLiquidity


```solidity
function removeLiquidity(
    PoolKey calldata poolKey,
    uint256 liquidity,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) external returns (uint256 amount0, uint256 amount1);
```

### transferFrom


```solidity
function transferFrom(address from, address to, uint256 id, uint256 amount)
    external
    returns (bool);
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

