# PM
[Git Source](https://github.com/zammdefi/pm/blob/006ba95d7cfd5dfbd631c3f6ce5b2bedefc25ed2/src/PM.sol)

**Inherits:**
[ERC6909](/src/PM.sol/abstract.ERC6909.md)


## State Variables
### Q

```solidity
uint256 constant Q = 1e18
```


### allMarkets

```solidity
uint256[] public allMarkets
```


### totalSupply

```solidity
mapping(uint256 id => uint256) public totalSupply
```


### markets

```solidity
mapping(uint256 marketId => Market) public markets
```


### descriptions

```solidity
mapping(uint256 marketId => string) public descriptions
```


### resolverFeeBps

```solidity
mapping(address resolver => uint16) public resolverFeeBps
```


### REENTRANCY_GUARD_SLOT

```solidity
uint256 constant REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268
```


## Functions
### constructor


```solidity
constructor() payable;
```

### getMarketId


```solidity
function getMarketId(string calldata description, address resolver)
    public
    pure
    returns (uint256);
```

### getNoId


```solidity
function getNoId(uint256 marketId) public pure returns (uint256);
```

### name


```solidity
function name(uint256 id) public pure returns (string memory);
```

### symbol


```solidity
function symbol(uint256) public pure returns (string memory);
```

### _toString


```solidity
function _toString(uint256 value) internal pure returns (string memory result);
```

### createMarket


```solidity
function createMarket(
    string calldata description,
    address resolver,
    uint72 close,
    bool canClose
) public returns (uint256 marketId, uint256 noId);
```

### closeMarket


```solidity
function closeMarket(uint256 marketId) public nonReentrant;
```

### buyYes


```solidity
function buyYes(uint256 marketId, uint256 amount, address to)
    public
    payable
    nonReentrant
    returns (uint256 wstIn);
```

### buyNo


```solidity
function buyNo(uint256 marketId, uint256 amount, address to)
    public
    payable
    nonReentrant
    returns (uint256 wstIn);
```

### sellYes


```solidity
function sellYes(uint256 marketId, uint256 amount, address to) public nonReentrant;
```

### sellNo


```solidity
function sellNo(uint256 marketId, uint256 amount, address to) public nonReentrant;
```

### resolve


```solidity
function resolve(uint256 marketId, bool outcome) public nonReentrant;
```

### setResolverFeeBps


```solidity
function setResolverFeeBps(uint16 bps) public;
```

### claim


```solidity
function claim(uint256 marketId, address to) public nonReentrant;
```

### marketCount


```solidity
function marketCount() public view returns (uint256);
```

### getMarket


```solidity
function getMarket(uint256 marketId)
    public
    view
    returns (
        uint256 yesSupply,
        uint256 noSupply,
        address resolver,
        bool resolved,
        bool outcome,
        uint256 pot,
        uint256 payoutPerShare,
        string memory desc
    );
```

### getMarkets


```solidity
function getMarkets(uint256 start, uint256 count)
    public
    view
    returns (
        uint256[] memory marketIds,
        uint256[] memory yesSupplies,
        uint256[] memory noSupplies,
        address[] memory resolvers,
        bool[] memory resolved,
        bool[] memory outcome,
        uint256[] memory pot,
        uint256[] memory payoutPerShare,
        string[] memory descs,
        uint256 next
    );
```

### getUserMarkets


```solidity
function getUserMarkets(address user, uint256 start, uint256 count)
    public
    view
    returns (
        uint256[] memory yesIds,
        uint256[] memory noIds,
        uint256[] memory yesBalances,
        uint256[] memory noBalances,
        uint256[] memory claimables,
        bool[] memory isResolved,
        bool[] memory tradingOpen_,
        uint256 next
    );
```

### tradingOpen


```solidity
function tradingOpen(uint256 marketId) public view returns (bool);
```

### impliedYesOdds


```solidity
function impliedYesOdds(uint256 marketId)
    public
    view
    returns (uint256 numerator, uint256 denominator);
```

### winningId


```solidity
function winningId(uint256 marketId) public view returns (uint256 id);
```

### nonReentrant


```solidity
modifier nonReentrant() ;
```

## Events
### Resolved

```solidity
event Resolved(uint256 indexed marketId, bool outcome);
```

### Bought

```solidity
event Bought(address indexed buyer, uint256 indexed id, uint256 amount);
```

### Sold

```solidity
event Sold(address indexed seller, uint256 indexed id, uint256 amount);
```

### Claimed

```solidity
event Claimed(address indexed claimer, uint256 indexed id, uint256 shares, uint256 payout);
```

### Created

```solidity
event Created(
    uint256 indexed marketId, uint256 indexed noId, string description, address resolver
);
```

### Closed

```solidity
event Closed(uint256 indexed marketId, uint256 closedAt, address indexed by);
```

### ResolverFeeSet

```solidity
event ResolverFeeSet(address indexed resolver, uint16 bps);
```

## Errors
### MarketExists

```solidity
error MarketExists();
```

### MarketClosed

```solidity
error MarketClosed();
```

### MarketNotFound

```solidity
error MarketNotFound();
```

### MarketResolved

```solidity
error MarketResolved();
```

### MarketNotClosed

```solidity
error MarketNotClosed();
```

### MarketNotResolved

```solidity
error MarketNotResolved();
```

### OnlyResolver

```solidity
error OnlyResolver();
```

### InvalidResolver

```solidity
error InvalidResolver();
```

### AlreadyResolved

```solidity
error AlreadyResolved();
```

### NoWinningShares

```solidity
error NoWinningShares();
```

### AmountZero

```solidity
error AmountZero();
```

### CannotClose

```solidity
error CannotClose();
```

### InvalidClose

```solidity
error InvalidClose();
```

### FeeOverflow

```solidity
error FeeOverflow();
```

### Reentrancy

```solidity
error Reentrancy();
```

## Structs
### Market

```solidity
struct Market {
    address resolver;
    bool resolved;
    bool outcome;
    bool canClose;
    uint72 close;
    uint256 pot;
    uint256 payoutPerShare;
}
```

