# IPAMM
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/MasterRouter.sol)

PAMM interface


## Functions
### markets


```solidity
function markets(uint256 marketId)
    external
    view
    returns (
        address resolver,
        bool resolved,
        bool outcome,
        bool canClose,
        uint64 close,
        address collateral,
        uint256 collateralLocked
    );
```

### tradingOpen


```solidity
function tradingOpen(uint256 marketId) external view returns (bool);
```

### transfer


```solidity
function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
```

### transferFrom


```solidity
function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    external
    returns (bool);
```

### setOperator


```solidity
function setOperator(address operator, bool approved) external returns (bool);
```

### split


```solidity
function split(uint256 marketId, uint256 amount, address to) external payable;
```

