# PAMM
[Git Source](https://github.com/zammdefi/pm/blob/6409aa225054aeb8e5eb04dafccaae59a1d0f4cc/src/PAMM.sol)

**Inherits:**
[ERC6909Minimal](/src/PAMM.sol/abstract.ERC6909Minimal.md)

**Title:**
PAMM V1

Prediction-market collateral vault with per-market collateral:
- Supports ETH (address(0)) and any ERC20 with varying decimals
- Fully-collateralised YES/NO shares (ERC6909)
- Shares are 1:1 with collateral wei (1 share = 1 wei of collateral)

Trading/LP happens on a separate AMM (e.g. ZAMM).


## State Variables
### ETH
ETH sentinel value.


```solidity
address constant ETH = address(0)
```


### ZAMM
ZAMM singleton for liquidity pools.


```solidity
IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD)
```


### allMarkets
All market ids.


```solidity
uint256[] public allMarkets
```


### markets
Market by YES-id.


```solidity
mapping(uint256 => Market) public markets
```


### descriptions
Description per market.


```solidity
mapping(uint256 => string) public descriptions
```


### totalSupplyId
Supply per token id (YES or NO).


```solidity
mapping(uint256 => uint256) public totalSupplyId
```


### resolverFeeBps
Resolver fee in basis points (max 1000 = 10%).


```solidity
mapping(address => uint16) public resolverFeeBps
```


### REENTRANCY_SLOT

```solidity
uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268
```


## Functions
### name

Token name for ERC6909 metadata.


```solidity
function name(uint256 id) public pure returns (string memory);
```

### symbol

Token symbol for ERC6909 metadata.


```solidity
function symbol(uint256) public pure returns (string memory);
```

### tokenURI

NFT-compatible metadata URI for a token id.

Returns data URI with JSON. Works for YES (marketId) tokens; NO tokens return minimal info.


```solidity
function tokenURI(uint256 id) public view returns (string memory);
```

### _toString

Converts uint256 to string (from Solady).


```solidity
function _toString(uint256 value) internal pure returns (string memory result);
```

### constructor


```solidity
constructor() payable;
```

### transferFrom

Override to skip allowance check for ZAMM pulling from this contract.


```solidity
function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    public
    returns (bool);
```

### receive


```solidity
receive() external payable;
```

### multicall

Batch multiple calls in a single transaction.


```solidity
function multicall(bytes[] calldata data) public returns (bytes[] memory results);
```

### permit

EIP-2612 permit for ERC20 tokens (use in multicall before split).


```solidity
function permit(
    address token,
    address owner,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) public nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The ERC20 token with permit support|
|`owner`|`address`|The token owner who signed the permit|
|`value`|`uint256`|Amount to approve to this contract|
|`deadline`|`uint256`|Permit deadline|
|`v`|`uint8`|Signature v|
|`r`|`bytes32`|Signature r|
|`s`|`bytes32`|Signature s|


### permitDAI

DAI-style permit (use in multicall before split).


```solidity
function permitDAI(
    address token,
    address owner,
    uint256 nonce,
    uint256 deadline,
    bool allowed,
    uint8 v,
    bytes32 r,
    bytes32 s
) public nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The DAI-like token with permit support|
|`owner`|`address`|The token owner who signed the permit|
|`nonce`|`uint256`|Owner's current nonce|
|`deadline`|`uint256`|Permit deadline (0 = no expiry)|
|`allowed`|`bool`|True to approve max, false to revoke|
|`v`|`uint8`|Signature v|
|`r`|`bytes32`|Signature r|
|`s`|`bytes32`|Signature s|


### nonReentrant


```solidity
modifier nonReentrant() ;
```

### getMarketId

YES-id from (description, resolver, collateral).


```solidity
function getMarketId(string calldata description, address resolver, address collateral)
    public
    pure
    returns (uint256);
```

### getNoId

NO-id from YES-id.


```solidity
function getNoId(uint256 marketId) public pure returns (uint256);
```

### createMarket

Create a new YES/NO market.

Description is stored as-is and used in tokenURI JSON. Avoid special characters
(quotes, backslashes, newlines) as they are not escaped and may break metadata rendering.


```solidity
function createMarket(
    string calldata description,
    address resolver,
    address collateral,
    uint64 close,
    bool canClose
) public nonReentrant returns (uint256 marketId, uint256 noId);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`description`|`string`|Used in id derivation and tokenURI metadata|
|`resolver`|`address`|Can call resolve()|
|`collateral`|`address`|Collateral token (address(0) for ETH)|
|`close`|`uint64`|Resolve allowed after this timestamp|
|`canClose`|`bool`|If true, resolver can early-close|


### createMarketAndSeed

Create a market and seed it with initial liquidity in one tx.

For ETH markets, send ETH with the call (collateralIn can be 0 or must equal msg.value).
Description is stored as-is; avoid special characters (quotes, backslashes, newlines).


```solidity
function createMarketAndSeed(
    string calldata description,
    address resolver,
    address collateral,
    uint64 close,
    bool canClose,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 minLiquidity,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 marketId, uint256 noId, uint256 liquidity);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`description`|`string`|Used in id derivation and tokenURI metadata|
|`resolver`|`address`|Can call resolve()|
|`collateral`|`address`|Collateral token (address(0) for ETH)|
|`close`|`uint64`|Resolve allowed after this timestamp|
|`canClose`|`bool`|If true, resolver can early-close|
|`collateralIn`|`uint256`|Amount of collateral to split into shares|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`minLiquidity`|`uint256`|Minimum LP tokens to receive|
|`to`|`address`|Recipient of LP tokens|
|`deadline`|`uint256`|Timestamp after which the tx reverts|


### _createMarket

Internal create logic (no reentrancy guard).


```solidity
function _createMarket(
    string calldata description,
    address resolver,
    address collateral,
    uint64 close,
    bool canClose
) internal returns (uint256 marketId, uint256 noId);
```

### closeMarket

Early-close a market (only resolver, only if canClose).


```solidity
function closeMarket(uint256 marketId) public nonReentrant;
```

### resolve

Set winning outcome (only resolver, after close).


```solidity
function resolve(uint256 marketId, bool outcome) public nonReentrant;
```

### setResolverFeeBps

Set resolver fee (caller sets their own fee).


```solidity
function setResolverFeeBps(uint16 bps) public;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`bps`|`uint16`|Fee in basis points (max 1000 = 10%).|


### split

Lock collateral -> mint YES+NO pair (1:1).

For ETH markets, send ETH with the call.


```solidity
function split(uint256 marketId, uint256 collateralIn, address to)
    public
    payable
    nonReentrant
    returns (uint256 shares, uint256 used);
```

### merge

Burn YES+NO pair -> unlock collateral.

Allowed until market is resolved (not just until close). Merges min(shares, yesBalance, noBalance).


```solidity
function merge(uint256 marketId, uint256 shares, address to)
    public
    nonReentrant
    returns (uint256 merged, uint256 collateralOut);
```

### claim

Burn winning shares -> collateral (minus resolver fee).


```solidity
function claim(uint256 marketId, address to)
    public
    nonReentrant
    returns (uint256 shares, uint256 payout);
```

### claimMany

Batch claim from multiple resolved markets.

Skips markets where user has no winning balance (no revert).


```solidity
function claimMany(uint256[] calldata marketIds, address to)
    public
    nonReentrant
    returns (uint256 totalPayout);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketIds`|`uint256[]`|Array of market ids to claim from|
|`to`|`address`|Recipient of all payouts|


### _claimCore

Core claim logic - returns (0,0) if no balance.


```solidity
function _claimCore(Market storage m, uint256 marketId, address to)
    internal
    returns (uint256 shares, uint256 payout);
```

### _pullToThis

Pull shares from msg.sender into contract with Transfer event.


```solidity
function _pullToThis(uint256 id, uint256 amount) internal;
```

### poolKey

PoolKey for market's YES/NO pair.


```solidity
function poolKey(uint256 marketId, uint256 feeOrHook)
    public
    view
    returns (IZAMM.PoolKey memory key);
```

### _poolKey

Internal poolKey with pre-computed noId to avoid redundant hashing.


```solidity
function _poolKey(uint256 marketId, uint256 noId, uint256 feeOrHook)
    internal
    view
    returns (IZAMM.PoolKey memory key);
```

### splitAndAddLiquidity

Split collateral -> YES+NO -> LP in one tx.

Seeds new pool or adds to existing. Unused tokens returned.


```solidity
function splitAndAddLiquidity(
    uint256 marketId,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 minLiquidity,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 shares, uint256 liquidity);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to add liquidity for|
|`collateralIn`|`uint256`|Amount of collateral to split|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`amount0Min`|`uint256`|Minimum amount of token0 to add (slippage protection)|
|`amount1Min`|`uint256`|Minimum amount of token1 to add (slippage protection)|
|`minLiquidity`|`uint256`|Minimum LP tokens to receive|
|`to`|`address`|Recipient of LP tokens|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = current block)|


### _splitAndAddLiquidity

Internal splitAndAddLiquidity logic (no reentrancy guard).


```solidity
function _splitAndAddLiquidity(
    uint256 marketId,
    uint256 collateralIn,
    uint256 feeOrHook,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 minLiquidity,
    address to,
    uint256 deadline
) internal returns (uint256 shares, uint256 liquidity);
```

### _splitInternal

Internal split logic for buy helpers - mints to address(this).


```solidity
function _splitInternal(Market storage m, uint256 marketId, uint256 collateralIn)
    internal
    returns (uint256 shares);
```

### removeLiquidityToCollateral

Remove LP position and convert to collateral in one tx.

User must approve PAMM on ZAMM to pull LP tokens (via ZAMM.setOperator or approve).
- Unresolved markets: Burns balanced YES/NO pairs, refunds leftover shares.
- Resolved markets: Claims winning shares, refunds losing shares as dust.


```solidity
function removeLiquidityToCollateral(
    uint256 marketId,
    uint256 feeOrHook,
    uint256 liquidity,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 minCollateralOut,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 collateralOut, uint256 leftoverYes, uint256 leftoverNo);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to remove liquidity from|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`liquidity`|`uint256`|Amount of LP tokens to burn|
|`amount0Min`|`uint256`|Minimum amount of token0 from LP removal (slippage protection)|
|`amount1Min`|`uint256`|Minimum amount of token1 from LP removal (slippage protection)|
|`minCollateralOut`|`uint256`|Minimum collateral to receive (merged amount or claim payout)|
|`to`|`address`|Recipient of collateral|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = current block)|


### buyYes

Buy YES shares with collateral (split + swap NO→YES).


```solidity
function buyYes(
    uint256 marketId,
    uint256 collateralIn,
    uint256 minYesOut,
    uint256 minSwapOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 yesOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to buy YES for|
|`collateralIn`|`uint256`|Amount of collateral to spend|
|`minYesOut`|`uint256`|Minimum total YES shares to receive|
|`minSwapOut`|`uint256`|Minimum YES from swap leg (sandwich protection)|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`to`|`address`|Recipient of YES shares|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = no deadline)|


### buyNo

Buy NO shares with collateral (split + swap YES→NO).


```solidity
function buyNo(
    uint256 marketId,
    uint256 collateralIn,
    uint256 minNoOut,
    uint256 minSwapOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public payable nonReentrant returns (uint256 noOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to buy NO for|
|`collateralIn`|`uint256`|Amount of collateral to spend|
|`minNoOut`|`uint256`|Minimum total NO shares to receive|
|`minSwapOut`|`uint256`|Minimum NO from swap leg (sandwich protection)|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`to`|`address`|Recipient of NO shares|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = no deadline)|


### sellYes

Sell YES shares for collateral (swap some YES→NO + merge).


```solidity
function sellYes(
    uint256 marketId,
    uint256 yesAmount,
    uint256 swapAmount,
    uint256 minCollateralOut,
    uint256 minSwapOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 collateralOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to sell YES from|
|`yesAmount`|`uint256`|Amount of YES shares to sell|
|`swapAmount`|`uint256`|Amount of YES to swap (0 = default 50%)|
|`minCollateralOut`|`uint256`|Minimum collateral to receive|
|`minSwapOut`|`uint256`|Minimum NO from swap leg (sandwich protection)|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`to`|`address`|Recipient of collateral|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = no deadline)|


### sellNo

Sell NO shares for collateral (swap some NO→YES + merge).


```solidity
function sellNo(
    uint256 marketId,
    uint256 noAmount,
    uint256 swapAmount,
    uint256 minCollateralOut,
    uint256 minSwapOut,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 collateralOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to sell NO from|
|`noAmount`|`uint256`|Amount of NO shares to sell|
|`swapAmount`|`uint256`|Amount of NO to swap (0 = default 50%)|
|`minCollateralOut`|`uint256`|Minimum collateral to receive|
|`minSwapOut`|`uint256`|Minimum YES from swap leg (sandwich protection)|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`to`|`address`|Recipient of collateral|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = no deadline)|


### sellYesForExactCollateral

Sell YES shares for exact collateral amount (swap YES→NO using exactOut + merge).


```solidity
function sellYesForExactCollateral(
    uint256 marketId,
    uint256 collateralOut,
    uint256 maxYesIn,
    uint256 maxSwapIn,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 yesSpent);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to sell YES from|
|`collateralOut`|`uint256`|Exact collateral amount to receive|
|`maxYesIn`|`uint256`|Maximum YES shares willing to spend|
|`maxSwapIn`|`uint256`|Maximum YES to swap (slippage protection on swap leg)|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`to`|`address`|Recipient of collateral|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = no deadline)|


### sellNoForExactCollateral

Sell NO shares for exact collateral amount (swap NO→YES using exactOut + merge).


```solidity
function sellNoForExactCollateral(
    uint256 marketId,
    uint256 collateralOut,
    uint256 maxNoIn,
    uint256 maxSwapIn,
    uint256 feeOrHook,
    address to,
    uint256 deadline
) public nonReentrant returns (uint256 noSpent);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|The market to sell NO from|
|`collateralOut`|`uint256`|Exact collateral amount to receive|
|`maxNoIn`|`uint256`|Maximum NO shares willing to spend|
|`maxSwapIn`|`uint256`|Maximum NO to swap (slippage protection on swap leg)|
|`feeOrHook`|`uint256`|Pool fee tier (bps) or hook address|
|`to`|`address`|Recipient of collateral|
|`deadline`|`uint256`|Timestamp after which the tx reverts (0 = no deadline)|


### marketCount

Number of markets.


```solidity
function marketCount() public view returns (uint256);
```

### tradingOpen

Check if market is open for trading (split/buy/sell allowed).

Merge is allowed until resolved, not just until close.


```solidity
function tradingOpen(uint256 marketId) public view returns (bool);
```

### winningId

Winning token id (0 if unresolved or not found).


```solidity
function winningId(uint256 marketId) public view returns (uint256);
```

### getMarket

Full market state.


```solidity
function getMarket(uint256 marketId)
    public
    view
    returns (
        address resolver,
        address collateral,
        bool resolved,
        bool outcome,
        bool canClose,
        uint64 close,
        uint256 collateralLocked,
        uint256 yesSupply,
        uint256 noSupply,
        string memory description
    );
```

### getPoolState

Pool reserves and implied probability.


```solidity
function getPoolState(uint256 marketId, uint256 feeOrHook)
    public
    view
    returns (uint256 rYes, uint256 rNo, uint256 pYesNum, uint256 pYesDen);
```

### getMarkets

Paginated batch read of all markets.


```solidity
function getMarkets(uint256 start, uint256 count)
    public
    view
    returns (
        uint256[] memory marketIds,
        address[] memory resolvers,
        address[] memory collaterals,
        uint8[] memory states,
        uint64[] memory closes,
        uint256[] memory collateralAmounts,
        uint256[] memory yesSupplies,
        uint256[] memory noSupplies,
        string[] memory descs,
        uint256 next
    );
```

### getMarketsByIds

Batch read specific markets by ID.

Skips invalid market IDs (resolver == address(0)).


```solidity
function getMarketsByIds(uint256[] calldata ids)
    public
    view
    returns (
        address[] memory resolvers,
        address[] memory collaterals,
        uint8[] memory states,
        uint64[] memory closes,
        uint256[] memory collateralAmounts,
        uint256[] memory yesSupplies,
        uint256[] memory noSupplies,
        string[] memory descs
    );
```

### getUserPositions

Paginated batch read of user positions.


```solidity
function getUserPositions(address user, uint256 start, uint256 count)
    public
    view
    returns (
        uint256[] memory marketIds,
        uint256[] memory noIds,
        address[] memory collaterals,
        uint256[] memory yesBalances,
        uint256[] memory noBalances,
        uint256[] memory claimables,
        bool[] memory isResolved,
        bool[] memory isOpen,
        uint256 next
    );
```

## Events
### Created

```solidity
event Created(
    uint256 indexed marketId,
    uint256 indexed noId,
    string description,
    address resolver,
    address collateral,
    uint64 close,
    bool canClose
);
```

### Closed

```solidity
event Closed(uint256 indexed marketId, uint256 ts, address indexed by);
```

### Split

```solidity
event Split(
    address indexed user, uint256 indexed marketId, uint256 shares, uint256 collateralIn
);
```

### Merged

```solidity
event Merged(
    address indexed user, uint256 indexed marketId, uint256 shares, uint256 collateralOut
);
```

### Resolved

```solidity
event Resolved(uint256 indexed marketId, bool outcome);
```

### Claimed

```solidity
event Claimed(address indexed user, uint256 indexed marketId, uint256 shares, uint256 payout);
```

### ResolverFeeSet

```solidity
event ResolverFeeSet(address indexed resolver, uint16 bps);
```

## Errors
### Reentrancy

```solidity
error Reentrancy();
```

### AmountZero

```solidity
error AmountZero();
```

### FeeOverflow

```solidity
error FeeOverflow();
```

### NotClosable

```solidity
error NotClosable();
```

### InvalidClose

```solidity
error InvalidClose();
```

### MarketClosed

```solidity
error MarketClosed();
```

### MarketExists

```solidity
error MarketExists();
```

### OnlyResolver

```solidity
error OnlyResolver();
```

### TransferFailed

```solidity
error TransferFailed();
```

### ExcessiveInput

```solidity
error ExcessiveInput();
```

### MarketNotFound

```solidity
error MarketNotFound();
```

### DeadlineExpired

```solidity
error DeadlineExpired();
```

### InvalidReceiver

```solidity
error InvalidReceiver();
```

### InvalidResolver

```solidity
error InvalidResolver();
```

### AlreadyResolved

```solidity
error AlreadyResolved();
```

### MarketNotClosed

```solidity
error MarketNotClosed();
```

### InvalidETHAmount

```solidity
error InvalidETHAmount();
```

### ETHTransferFailed

```solidity
error ETHTransferFailed();
```

### InvalidSwapAmount

```solidity
error InvalidSwapAmount();
```

### InsufficientOutput

```solidity
error InsufficientOutput();
```

### TransferFromFailed

```solidity
error TransferFromFailed();
```

### WrongCollateralType

```solidity
error WrongCollateralType();
```

## Structs
### Market

```solidity
struct Market {
    address resolver; // who can resolve (20 bytes)
    bool resolved; // outcome set? (1 byte)
    bool outcome; // YES wins if true (1 byte)
    bool canClose; // resolver can early-close (1 byte)
    uint64 close; // resolve allowed after (8 bytes) -- slot 1: 31 bytes
    address collateral; // collateral token (address(0) = ETH) -- slot 2
    uint256 collateralLocked; // collateral locked for market -- slot 3
}
```

