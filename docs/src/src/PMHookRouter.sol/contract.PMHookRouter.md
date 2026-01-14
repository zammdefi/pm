# PMHookRouter
[Git Source](https://github.com/zammdefi/pm/blob/6156944a878712f207af01bad454c3401a603fc3/src/PMHookRouter.sol)

**Title:**
PMHookRouter

Prediction market router with vault market-making

Execution: best of (vault OTC vs AMM) first, then remainder to other venue, then mint fallback
LPs earn principal (seller-side) + spread fees (90% when balanced, 70% when imbalanced).
Only markets created via bootstrapMarket() are supported.

REQUIRES EIP-1153 (transient storage) - only deploy on chains with Cancun support


## State Variables
### ETH

```solidity
address constant ETH = address(0)
```


### FLAG_BEFORE

```solidity
uint256 constant FLAG_BEFORE = 1 << 255
```


### FLAG_AFTER

```solidity
uint256 constant FLAG_AFTER = 1 << 254
```


### ERR_SHARES

```solidity
bytes4 constant ERR_SHARES = 0x9325dafd
```


### ERR_VALIDATION

```solidity
bytes4 constant ERR_VALIDATION = 0x077a9c33
```


### ERR_TIMING

```solidity
bytes4 constant ERR_TIMING = 0x3703bac9
```


### ERR_STATE

```solidity
bytes4 constant ERR_STATE = 0xd06e7808
```


### ERR_REENTRANCY

```solidity
bytes4 constant ERR_REENTRANCY = 0xab143c06
```


### ERR_WITHDRAWAL_TOO_SOON

```solidity
bytes4 constant ERR_WITHDRAWAL_TOO_SOON = 0xff56d9bd
```


### SELECTOR_POOLS_SHIFTED

```solidity
uint256 constant SELECTOR_POOLS_SHIFTED = 0xac4afa38 << 224
```


### SELECTOR_MARKETS_SHIFTED

```solidity
uint256 constant SELECTOR_MARKETS_SHIFTED = 0xb1283e77 << 224
```


### REENTRANCY_SLOT

```solidity
uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268
```


### ETH_SPENT_SLOT

```solidity
uint256 constant ETH_SPENT_SLOT = 0x929eee149b4bd21269
```


### MULTICALL_DEPTH_SLOT

```solidity
uint256 constant MULTICALL_DEPTH_SLOT = 0x929eee149b4bd2126a
```


### SRC_OTC

```solidity
bytes4 constant SRC_OTC = 0x6f746300
```


### SRC_AMM

```solidity
bytes4 constant SRC_AMM = 0x616d6d00
```


### SRC_MINT

```solidity
bytes4 constant SRC_MINT = 0x6d696e74
```


### SRC_MULT

```solidity
bytes4 constant SRC_MULT = 0x6d756c74
```


### ZAMM

```solidity
IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD)
```


### PAMM

```solidity
IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0)
```


### DAO

```solidity
address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E
```


### canonicalPoolId

```solidity
mapping(uint256 => uint256) public canonicalPoolId
```


### canonicalFeeOrHook

```solidity
mapping(uint256 => uint256) public canonicalFeeOrHook
```


### bootstrapVaults

```solidity
mapping(uint256 => BootstrapVault) public bootstrapVaults
```


### rebalanceCollateralBudget

```solidity
mapping(uint256 => uint256) public rebalanceCollateralBudget
```


### twapObservations

```solidity
mapping(uint256 => TWAPObservations) public twapObservations
```


### MIN_TWAP_UPDATE_INTERVAL

```solidity
uint32 constant MIN_TWAP_UPDATE_INTERVAL = 30 minutes
```


### totalYesVaultShares

```solidity
mapping(uint256 => uint256) public totalYesVaultShares
```


### totalNoVaultShares

```solidity
mapping(uint256 => uint256) public totalNoVaultShares
```


### accYesCollateralPerShare

```solidity
mapping(uint256 => uint256) public accYesCollateralPerShare
```


### accNoCollateralPerShare

```solidity
mapping(uint256 => uint256) public accNoCollateralPerShare
```


### vaultPositions

```solidity
mapping(uint256 => mapping(address => UserVaultPosition)) public vaultPositions
```


### MIN_ABSOLUTE_SPREAD_BPS

```solidity
uint256 constant MIN_ABSOLUTE_SPREAD_BPS = 20
```


### MAX_SPREAD_BPS

```solidity
uint256 constant MAX_SPREAD_BPS = 500
```


### DEFAULT_FEE_BPS

```solidity
uint256 constant DEFAULT_FEE_BPS = 30
```


### LP_FEE_SPLIT_BPS_BALANCED

```solidity
uint256 constant LP_FEE_SPLIT_BPS_BALANCED = 9000
```


### LP_FEE_SPLIT_BPS_IMBALANCED

```solidity
uint256 constant LP_FEE_SPLIT_BPS_IMBALANCED = 7000
```


### BOOTSTRAP_WINDOW

```solidity
uint256 constant BOOTSTRAP_WINDOW = 4 hours
```


### BPS_DENOM

```solidity
uint256 constant BPS_DENOM = 10_000
```


### MAX_COLLATERAL_IN

```solidity
uint256 constant MAX_COLLATERAL_IN = type(uint256).max / BPS_DENOM
```


### MAX_ACC_PER_SHARE

```solidity
uint256 constant MAX_ACC_PER_SHARE = type(uint256).max / type(uint112).max
```


### MAX_UINT112

```solidity
uint256 constant MAX_UINT112 = 0xffffffffffffffffffffffffffff
```


### MASK_LOWER_224

```solidity
uint256 constant MASK_LOWER_224 =
    0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff
```


## Functions
### _guardEnter


```solidity
function _guardEnter() internal;
```

### _guardExit


```solidity
function _guardExit() internal;
```

### _derivePoolId

Helper to derive pool ID from key


```solidity
function _derivePoolId(IZAMM.PoolKey memory k) internal pure returns (uint256 id);
```

### _checkU112Overflow

Helper to check uint112 overflow


```solidity
function _checkU112Overflow(uint256 a, uint256 b) internal pure;
```

### _revert

Generic revert helper - consolidated for bytecode savings


```solidity
function _revert(bytes4 selector, uint8 code) internal pure;
```

### _staticUint

Low-level staticcall helper for uint256 returns (avoids try/catch overhead)


```solidity
function _staticUint(address target, bytes4 sel, uint256 arg)
    internal
    view
    returns (bool ok, uint256 out);
```

### _staticPools

Low-level staticcall helper for ZAMM.pools (avoids try/catch overhead)


```solidity
function _staticPools(uint256 poolId)
    internal
    view
    returns (
        bool ok,
        uint112 r0,
        uint112 r1,
        uint32 blockTimestampLast,
        uint256 price0,
        uint256 price1
    );
```

### _staticMarkets

Low-level staticcall helper for PAMM.markets (avoids tuple destructuring overhead)


```solidity
function _staticMarkets(uint256 marketId)
    internal
    view
    returns (bool resolved, bool outcome, bool canClose, uint64 close, address collateral);
```

### _refundExcessETH


```solidity
function _refundExcessETH(address collateral, uint256 amountValidated) internal;
```

### _validateETHAmount


```solidity
function _validateETHAmount(address collateral, uint256 requiredAmount) internal;
```

### _transferCollateral

Helper to transfer collateral (handles ETH vs ERC20)


```solidity
function _transferCollateral(address collateral, address to, uint256 amount) internal;
```

### _refundCollateralToCaller

Refund unused collateral to caller, adjusting multicall ETH tracking

Use this when returning collateral that was previously validated via _validateETHAmount


```solidity
function _refundCollateralToCaller(address collateral, uint256 amount) internal;
```

### _splitShares

Helper to split shares via PAMM (handles ETH vs ERC20)


```solidity
function _splitShares(uint256 marketId, uint256 amount, address collateral) internal;
```

### _calculateFeeSplit

Calculate LP vs budget allocation based on imbalance


```solidity
function _calculateFeeSplit(
    uint112 preYes,
    uint112 preNo,
    bool buyYes,
    uint64 close,
    uint256 feeAmount
) internal view returns (uint256 toLPs, uint256 toRemaining);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`preYes`|`uint112`|YES inventory|
|`preNo`|`uint112`|NO inventory|
|`buyYes`|`bool`|Side being bought|
|`close`|`uint64`|Market close timestamp|
|`feeAmount`|`uint256`|Amount to split|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`toLPs`|`uint256`|Amount allocated to LPs|
|`toRemaining`|`uint256`|Amount allocated to budget|


### _distributeFeesSplit

Split fees between LPs and rebalance budget using pre-trade snapshot


```solidity
function _distributeFeesSplit(
    uint256 marketId,
    uint256 feeAmount,
    uint112 preYes,
    uint112 preNo,
    uint256 twap
) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`feeAmount`|`uint256`|Total fees to distribute|
|`preYes`|`uint112`|Pre-merge YES inventory|
|`preNo`|`uint112`|Pre-merge NO inventory|
|`twap`|`uint256`|P(YES) = NO/(YES+NO) from TWAP [1-9999]|


### _accountVaultOTCProceeds

Split OTC proceeds into principal and spread


```solidity
function _accountVaultOTCProceeds(
    uint256 marketId,
    bool buyYes,
    uint256 sharesOut,
    uint256 collateralUsed,
    uint256 pYes,
    uint112 preYesInv,
    uint112 preNoInv
) internal returns (uint256 principal, uint256 spreadFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`buyYes`|`bool`|True for YES, false for NO|
|`sharesOut`|`uint256`|Shares sold by vault|
|`collateralUsed`|`uint256`|Total collateral paid|
|`pYes`|`uint256`|P(YES) = NO/(YES+NO) from TWAP [1-9999]|
|`preYesInv`|`uint112`|YES inventory before trade|
|`preNoInv`|`uint112`|NO inventory before trade|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`principal`|`uint256`|Fair value at TWAP|
|`spreadFee`|`uint256`|Spread above TWAP|


### _depositToVaultSide


```solidity
function _depositToVaultSide(uint256 marketId, bool isYes, uint256 shares, address receiver)
    internal
    returns (uint256 vaultSharesMinted);
```

### constructor


```solidity
constructor() payable;
```

### receive


```solidity
receive() external payable;
```

### _requireRegistered

Revert if market is not registered


```solidity
function _requireRegistered(uint256 marketId) internal view;
```

### _requireMarketOpen

Revert if market is resolved or closed, return close time and collateral


```solidity
function _requireMarketOpen(uint256 marketId)
    internal
    view
    returns (uint64 close, address collateral);
```

### _checkDeadline

Revert if deadline expired


```solidity
function _checkDeadline(uint256 deadline) internal view;
```

### _checkWithdrawalCooldown

Check withdrawal cooldown (shared by withdraw and harvest)

Normal deposits: 6h cooldown. Late deposits (within 12h of close): 24h cooldown

Enforced even after market close to prevent end-of-market fee sniping


```solidity
function _checkWithdrawalCooldown(uint256 marketId) internal view;
```

### _getNoId

Get NO token ID matching PAMM's formula: keccak256("PMARKET:NO", marketId)


```solidity
function _getNoId(uint256 marketId) internal pure returns (uint256 noId);
```

### _getCollateral

Get collateral address for a market


```solidity
function _getCollateral(uint256 marketId) internal view returns (address collateral);
```

### _getClose

Get close time for a market


```solidity
function _getClose(uint256 marketId) internal view returns (uint64 close);
```

### _getReserves

Get pool reserves


```solidity
function _getReserves(uint256 poolId) internal view returns (uint112 r0, uint112 r1);
```

### _getShiftMask

Helper to get shift and mask for vault shares based on isYes flag


```solidity
function _getShiftMask(bool isYes) internal pure returns (uint256 shift, uint256 mask);
```

### _addVaultShares

Add shares to vault (isYes ? yesShares : noShares)


```solidity
function _addVaultShares(BootstrapVault storage vault, bool isYes, uint256 amount) internal;
```

### _subVaultShares

Subtract shares from vault (isYes ? yesShares : noShares)


```solidity
function _subVaultShares(BootstrapVault storage vault, bool isYes, uint256 amount) internal;
```

### _decrementBothShares

Decrement both yes and no shares (for merge operations)


```solidity
function _decrementBothShares(BootstrapVault storage vault, uint256 amount) internal;
```

### _requireResolved

Revert if market is not resolved, return outcome and collateral


```solidity
function _requireResolved(uint256 marketId)
    internal
    view
    returns (bool outcome, address collateral);
```

### _isInCloseWindow

Check if market is in close window

Uses hook's closeWindow if available and non-zero, otherwise defaults to 1 hour


```solidity
function _isInCloseWindow(uint256 marketId) internal view returns (bool inWindow);
```

### multicall

Execute multiple calls in a single transaction


```solidity
function multicall(bytes[] calldata data) public payable returns (bytes[] memory results);
```

### permit

EIP-2612 permit for ERC20 tokens (use in multicall before operations)


```solidity
function permit(
    address token,
    address owner,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) public;
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

DAI-style permit (use in multicall before operations)


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
) public;
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


### _buildKey


```solidity
function _buildKey(uint256 yesId, uint256 noId, uint256 feeOrHook)
    internal
    pure
    returns (IZAMM.PoolKey memory k, bool yesIsId0);
```

### _selectTokenIds

Helper to select token IDs based on buy direction


```solidity
function _selectTokenIds(uint256 yesId, uint256 noId, bool buyYes)
    internal
    pure
    returns (uint256 swapId, uint256 desiredId);
```

### _registerMarket


```solidity
function _registerMarket(address hook, uint256 marketId)
    internal
    returns (uint256 poolId, uint256 feeOrHook);
```

### bootstrapMarket

Bootstrap market with initial liquidity and optional trade


```solidity
function bootstrapMarket(
    string calldata description,
    address resolver,
    address collateral,
    uint64 close,
    bool canClose,
    address hook,
    uint256 collateralForLP,
    bool buyYes,
    uint256 collateralForBuy,
    uint256 minSharesOut,
    address to,
    uint256 deadline
)
    public
    payable
    returns (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`description`|`string`||
|`resolver`|`address`||
|`collateral`|`address`||
|`close`|`uint64`||
|`canClose`|`bool`||
|`hook`|`address`||
|`collateralForLP`|`uint256`|Liquidity for 50/50 AMM pool|
|`buyYes`|`bool`||
|`collateralForBuy`|`uint256`|Optional initial trade|
|`minSharesOut`|`uint256`||
|`to`|`address`||
|`deadline`|`uint256`||


### _bootstrapBuy


```solidity
function _bootstrapBuy(
    uint256 marketId,
    address hook,
    address collateral,
    bool buyYes,
    uint256 collateralForBuy,
    uint256 minSharesOut,
    address to,
    uint256 deadline
) internal returns (uint256 sharesOut);
```

### buyWithBootstrap

Buy shares via best-execution routing: (vault OTC vs AMM) => remainder => mint fallback


```solidity
function buyWithBootstrap(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 minSharesOut,
    address to,
    uint256 deadline
) public payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`buyYes`|`bool`|True for YES, false for NO|
|`collateralIn`|`uint256`|Collateral to spend|
|`minSharesOut`|`uint256`|Minimum shares (all venues combined)|
|`to`|`address`|Recipient|
|`deadline`|`uint256`|Deadline|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sharesOut`|`uint256`|Total shares acquired|
|`source`|`bytes4`|Venue used ("otc"/"mint"/"amm"/"mult")|
|`vaultSharesMinted`|`uint256`|Vault shares from mint path|


### sellWithBootstrap

Sell shares with optimal routing: compares vault OTC vs AMM


```solidity
function sellWithBootstrap(
    uint256 marketId,
    bool sellYes,
    uint256 sharesIn,
    uint256 minOut,
    address to,
    uint256 deadline
) public returns (uint256 collateralOut, bytes4 source);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`collateralOut`|`uint256`|Total collateral received|
|`source`|`bytes4`|Execution source ("otc", "amm", or "mult")|


### _quoteAMMBuy


```solidity
function _quoteAMMBuy(uint256 marketId, bool buyYes, uint256 collateralIn)
    internal
    view
    returns (uint256 totalShares);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalShares`|`uint256`|Shares from split + swap|


### _findMaxAMMUnderImpact

Find maximum collateral for AMM that stays under price impact limit

Uses binary search with cached reserves (16 iterations = precision to 1/65536)


```solidity
function _findMaxAMMUnderImpact(
    uint256 marketId,
    bool buyYes,
    uint256 maxCollateral,
    uint256 feeBps,
    uint256 maxImpactBps
) internal view returns (uint256 safeCollateral);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`safeCollateral`|`uint256`|Max collateral that keeps impact <= maxImpactBps (0 if none)|


### _getMaxPriceImpactBps

Get max price impact limit from hook (0 if disabled or no hook)


```solidity
function _getMaxPriceImpactBps(uint256 marketId) internal view returns (uint256);
```

### depositToVault


```solidity
function depositToVault(
    uint256 marketId,
    bool isYes,
    uint256 shares,
    address receiver,
    uint256 deadline
) public returns (uint256 vaultSharesMinted);
```

### withdrawFromVault

Withdraw vault shares and claim fees


```solidity
function withdrawFromVault(
    uint256 marketId,
    bool isYes,
    uint256 vaultSharesToRedeem,
    address receiver,
    uint256 deadline
) public returns (uint256 sharesReturned, uint256 feesEarned);
```

### harvestVaultFees

Claim pending fees without withdrawing vault shares


```solidity
function harvestVaultFees(uint256 marketId, bool isYes) public returns (uint256 feesEarned);
```

### provideLiquidity

Split collateral and provide liquidity to vaults and/or AMM


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
    public
    payable
    returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`collateralAmount`|`uint256`|Collateral to split|
|`vaultYesShares`|`uint256`|YES shares to deposit to vault|
|`vaultNoShares`|`uint256`|NO shares to deposit to vault|
|`ammLPShares`|`uint256`|YES+NO shares to add to AMM|
|`minAmount0`|`uint256`|Minimum amount0 (lower token ID) to AMM|
|`minAmount1`|`uint256`|Minimum amount1 (higher token ID) to AMM|
|`receiver`|`address`|Recipient|
|`deadline`|`uint256`|Deadline|


### settleRebalanceBudget

Settle rebalance budget by distributing to LPs


```solidity
function settleRebalanceBudget(uint256 marketId)
    public
    returns (uint256 budgetDistributed, uint256 sharesMerged);
```

### _clearVaultWinningShares

Helper to clear vault winning shares - called by redeem and finalize


```solidity
function _clearVaultWinningShares(uint256 marketId, bool outcome)
    internal
    returns (uint256 payout, uint256 winningShares);
```

### redeemVaultWinningShares

Redeem vault winning shares and send to DAO

Requires no user LPs exist


```solidity
function redeemVaultWinningShares(uint256 marketId) public returns (uint256 payout);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`payout`|`uint256`|Collateral sent to DAO|


### finalizeMarket

Finalize market - extract all vault value to DAO

Returns 0 silently if user LPs still exist (vs redeemVaultWinningShares which reverts).
This allows batch finalization where some markets are ready and others aren't.


```solidity
function finalizeMarket(uint256 marketId) public returns (uint256 totalToDAO);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market to finalize|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalToDAO`|`uint256`|Collateral sent to DAO (0 if LPs exist or nothing to finalize)|


### _finalizeMarket


```solidity
function _finalizeMarket(uint256 marketId) internal returns (uint256 totalToDAO);
```

### _validateRebalanceConditions

Validate TWAP and spot price for rebalancing


```solidity
function _validateRebalanceConditions(uint256 marketId, uint256 canonical, uint256 twapBps)
    internal
    view
    returns (RebalanceValidation memory validation);
```

### _calculateRebalanceMinOut

Calculate minimum swap output for rebalance


```solidity
function _calculateRebalanceMinOut(
    uint256 collateralUsed,
    uint256 reserveIn,
    uint256 reserveOut,
    uint256 feeBps
) internal pure returns (uint256 minOut);
```

### _getPoolFeeBps

Get fee basis points for a pool


```solidity
function _getPoolFeeBps(uint256 feeOrHook, uint256 canonical)
    internal
    view
    returns (uint256 feeBps);
```

### _calcSwapAmountForMerge

Calculate optimal swap amount to balance shares for merge
Given `sharesIn` of one type, calculates how much to swap to end up with
approximately equal amounts of both types (for merging back to collateral).
Uses quadratic formula to solve: sharesIn - X = X * rOut * fm / (rIn * 10000 + X * fm)
where fm = 10000 - feeBps (fee multiplier)


```solidity
function _calcSwapAmountForMerge(uint256 sharesIn, uint256 rIn, uint256 rOut, uint256 feeBps)
    internal
    pure
    returns (uint256 swapAmount);
```

### rebalanceBootstrapVault

Rebalance vault using budget collateral


```solidity
function rebalanceBootstrapVault(uint256 marketId, uint256 deadline)
    public
    returns (uint256 collateralUsed);
```

### _rebalanceBootstrapVault


```solidity
function _rebalanceBootstrapVault(uint256 marketId, uint256 deadline)
    internal
    returns (uint256 collateralUsed);
```

### _executeVaultOTCFill

Execute vault OTC fill and account proceeds


```solidity
function _executeVaultOTCFill(
    uint256 marketId,
    bool buyYes,
    uint256 remainingCollateral,
    uint256 pYes,
    address to,
    uint256 noId
) internal returns (uint256 sharesOut, uint256 collateralUsed, uint8 venueIncrement);
```

### _executeAMMSwap

Execute AMM swap


```solidity
function _executeAMMSwap(
    uint256 marketId,
    bool buyYes,
    uint256 collateralToSwap,
    address to,
    uint256 deadline,
    uint256 noId,
    uint256 feeOrHook,
    address collateral
) internal returns (uint256 ammSharesOut);
```

### _shouldUseVaultMint


```solidity
function _shouldUseVaultMint(uint256 marketId, BootstrapVault memory vault, bool buyYes)
    internal
    view
    returns (bool);
```

### _getCurrentCumulative

Get current cumulative price from ZAMM pool


```solidity
function _getCurrentCumulative(uint256 marketId)
    internal
    view
    returns (uint256 cumulative, bool success);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`cumulative`|`uint256`|Cumulative price in UQ112x112|
|`success`|`bool`|Whether computation succeeded|


### updateTWAPObservation

Update TWAP observation (permissionless)


```solidity
function updateTWAPObservation(uint256 marketId) public;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|


### _getTWAPPrice

Get TWAP P(YES) for a market


```solidity
function _getTWAPPrice(uint256 marketId) internal view returns (uint256 twapBps);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`twapBps`|`uint256`|P(YES) = NO/(YES+NO) in basis points [1-9999], or 0 if unavailable|


### _updateTWAPObservation

Update TWAP observation with new cumulative value


```solidity
function _updateTWAPObservation(TWAPObservations storage obs, uint256 currentCumulative)
    internal;
```

### _convertUQ112x112ToBps

Convert UQ112x112 NO/YES ratio to P(YES) in basis points

Formula: 10000 * r / (1 + r) = 10000 * NO / (YES + NO), where r = NO/YES

This matches PMFeeHook._getProbability: P(YES) = NO_reserve / total


```solidity
function _convertUQ112x112ToBps(uint256 twapUQ112x112) internal pure returns (uint256 twapBps);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`twapUQ112x112`|`uint256`|NO/YES ratio in UQ112x112 fixed-point format|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`twapBps`|`uint256`|P(YES) in basis points [1-9999]|


### _addVaultFeesWithSnapshot


```solidity
function _addVaultFeesWithSnapshot(
    uint256 marketId,
    bool isYes,
    uint256 feeAmount,
    uint256 totalSharesSnapshot
) internal;
```

### _distributeOtcSpreadScarcityCapped

Distribute OTC spread with scarcity weighting (40-60% cap)


```solidity
function _distributeOtcSpreadScarcityCapped(
    uint256 marketId,
    uint256 amount,
    uint112 preYesInv,
    uint112 preNoInv
) internal returns (bool distributed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`amount`|`uint256`|Spread to distribute|
|`preYesInv`|`uint112`|YES inventory before trade|
|`preNoInv`|`uint112`|NO inventory before trade|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`distributed`|`bool`|True if LPs exist|


### _addVaultFeesSymmetricWithSnapshot

Distribute fees symmetrically using pre-trade snapshot


```solidity
function _addVaultFeesSymmetricWithSnapshot(
    uint256 marketId,
    uint256 feeAmount,
    uint112 yesInv,
    uint112 noInv,
    uint256 pYes
) internal returns (bool distributed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|Market ID|
|`feeAmount`|`uint256`|Fees to distribute|
|`yesInv`|`uint112`|Pre-trade YES inventory|
|`noInv`|`uint112`|Pre-trade NO inventory|
|`pYes`|`uint256`|P(YES) = NO/(YES+NO) in bps [1-9999]|


### _calculateDynamicSpread

Calculate dynamic spread based on inventory imbalance

Returns relative spread boosts that will be applied multiplicatively


```solidity
function _calculateDynamicSpread(uint256 yesShares, uint256 noShares, bool buyYes, uint64 close)
    internal
    view
    returns (uint256 relativeSpreadBps, uint256 imbalanceBps);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`yesShares`|`uint256`|YES inventory|
|`noShares`|`uint256`|NO inventory|
|`buyYes`|`bool`|True if buying YES|
|`close`|`uint64`|Market close time|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`relativeSpreadBps`|`uint256`|Relative spread to apply (base + boosts)|
|`imbalanceBps`|`uint256`|Inventory imbalance in bps (for dynamic budget split)|


### _tryVaultOTCFill

Try vault OTC fill (supports partial)


```solidity
function _tryVaultOTCFill(
    uint256 marketId,
    bool buyYes,
    uint256 collateralIn,
    uint256 pYesTwapBps
) internal view returns (uint256 sharesOut, uint256 collateralUsed, bool filled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`||
|`buyYes`|`bool`||
|`collateralIn`|`uint256`||
|`pYesTwapBps`|`uint256`|P(YES) = NO/(YES+NO) from TWAP [1-9999]|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sharesOut`|`uint256`|Shares filled (0 if none)|
|`collateralUsed`|`uint256`|Collateral consumed (0 if none)|
|`filled`|`bool`|True if vault participated|


## Events
### VaultDeposit

```solidity
event VaultDeposit(
    uint256 indexed marketId,
    address indexed user,
    bool isYes,
    uint256 sharesDeposited,
    uint256 vaultSharesMinted
);
```

### VaultWithdraw

```solidity
event VaultWithdraw(
    uint256 indexed marketId,
    address indexed user,
    bool isYes,
    uint256 vaultSharesBurned,
    uint256 sharesReturned,
    uint256 feesEarned
);
```

### VaultFeesHarvested

```solidity
event VaultFeesHarvested(
    uint256 indexed marketId, address indexed user, bool isYes, uint256 feesEarned
);
```

### VaultOTCFill

```solidity
event VaultOTCFill(
    uint256 indexed marketId,
    address indexed trader,
    address recipient,
    bool buyYes,
    uint256 collateralIn,
    uint256 sharesOut,
    uint256 effectivePriceBps,
    uint256 principal,
    uint256 spreadFee
);
```

### BudgetSettled

```solidity
event BudgetSettled(uint256 indexed marketId, uint256 budgetDistributed, uint256 sharesMerged);
```

### VaultWinningSharesRedeemed

```solidity
event VaultWinningSharesRedeemed(
    uint256 indexed marketId, bool outcome, uint256 sharesRedeemed, uint256 payoutToDAO
);
```

### MarketFinalized

```solidity
event MarketFinalized(
    uint256 indexed marketId,
    uint256 totalToDAO,
    uint256 sharesRedeemed,
    uint256 budgetDistributed
);
```

### Rebalanced

```solidity
event Rebalanced(
    uint256 indexed marketId, uint256 collateralUsed, uint256 sharesAcquired, bool yesWasLower
);
```

## Errors
### WithdrawalTooSoon

```solidity
error WithdrawalTooSoon(uint256 remainingSeconds);
```

### ComputationError

```solidity
error ComputationError(uint8 code);
```

### ValidationError

```solidity
error ValidationError(uint8 code);
```

### TransferError

```solidity
error TransferError(uint8 code);
```

### TimingError

```solidity
error TimingError(uint8 code);
```

### SharesError

```solidity
error SharesError(uint8 code);
```

### StateError

```solidity
error StateError(uint8 code);
```

### ApproveFailed

```solidity
error ApproveFailed();
```

### Reentrancy

```solidity
error Reentrancy();
```

## Structs
### BootstrapVault

```solidity
struct BootstrapVault {
    uint112 yesShares;
    uint112 noShares;
    uint32 lastActivity;
}
```

### TWAPObservations

```solidity
struct TWAPObservations {
    uint32 timestamp0; // Older checkpoint (4 bytes) \
    uint32 timestamp1; // Newer checkpoint (4 bytes)  |
    uint32 cachedTwapBps; // Cached TWAP value [1-9999] or 0 if unavailable (4 bytes) |-- packed in slot 0
    uint32 cacheBlockNum; // Block number of cache (4 bytes)       /
    uint256 cumulative0; // ZAMM's cumulative at timestamp0 (slot 1: 32 bytes)
    uint256 cumulative1; // ZAMM's cumulative at timestamp1 (slot 2: 32 bytes)
}
```

### UserVaultPosition

```solidity
struct UserVaultPosition {
    uint112 yesVaultShares; // 14 bytes  \
    uint112 noVaultShares; // 14 bytes   |-- packed in slot 0
    uint32 lastDepositTime; // 4 bytes   /
    uint256 yesRewardDebt; // 32 bytes -- slot 1
    uint256 noRewardDebt; // 32 bytes -- slot 2
}
```

### RebalanceValidation

```solidity
struct RebalanceValidation {
    uint256 twapBps;
    uint256 yesReserve;
    uint256 noReserve;
}
```

