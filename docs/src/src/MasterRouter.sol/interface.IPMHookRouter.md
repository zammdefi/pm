# IPMHookRouter
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/MasterRouter.sol)

PMHookRouter vault interface


## Functions
### depositToVault


```solidity
function depositToVault(
    uint256 marketId,
    bool isYes,
    uint256 shares,
    address receiver,
    uint256 deadline
) external returns (uint256 vaultShares);
```

### provideLiquidity


```solidity
function provideLiquidity(
    uint256 marketId,
    uint256 collateralAmount,
    uint256 vaultYesShares,
    uint256 vaultNoShares,
    uint256 ammLPShares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver,
    uint256 deadline
)
    external
    payable
    returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity);
```

### buyWithBootstrap


```solidity
function buyWithBootstrap(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 minSharesOut,
    address to,
    uint256 deadline
) external payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted);
```

### sellWithBootstrap


```solidity
function sellWithBootstrap(
    uint256 marketId,
    bool sellYes,
    uint256 sharesIn,
    uint256 minCollateralOut,
    address to,
    uint256 deadline
) external returns (uint256 collateralOut, bytes4 source);
```

