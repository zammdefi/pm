// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PMHookRouter
/// @notice Advanced routing contract for PAMM prediction markets with PredictionMarketHook integration
/// @dev Leverages ZAMM's low-level swap() calldata to enable:
///      - Arbitrary token -> collateral conversion
///      - Auto-registration of markets with hooks
///      - Limit order filling via PMRouter
///      - Multi-market arbitrage
///      - Combined orderbook + AMM routing
contract PMHookRouter {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
                            //////////////////////////////////////////////////////////////*/

    address internal constant ETH = address(0);

    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMRouter public constant PM_ROUTER = IPMRouter(address(0)); // TODO: Set actual address

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
                            //////////////////////////////////////////////////////////////*/

    error AmountZero();
    error Reentrancy();
    error InvalidAction();
    error SlippageExceeded();
    error InvalidETHAmount();
    error TransferFailed();
    error ApprovalFailed();
    error SwapFailed();
    error UnsupportedToken();
    error Unauthorized();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
                            //////////////////////////////////////////////////////////////*/

    event ComplexSwap(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 indexed marketId,
        uint256 sharesOut,
        ActionType action
    );

    event MarketRegistered(uint256 indexed marketId, address indexed hook, uint256 poolId);

    /*//////////////////////////////////////////////////////////////
                            ENUMS & STRUCTS
                            //////////////////////////////////////////////////////////////*/

    /// @notice Type of routing action to perform
    enum ActionType {
        NONE, // No special action, just swap
        REGISTER_MARKET, // Register market with hook
        FILL_LIMIT_ORDERS, // Fill limit orders from PMRouter
        SWAP_TO_COLLATERAL, // Convert arbitrary token to collateral first
        SPLIT_AND_SWAP, // Split collateral into shares then swap
        FLASH_ARBITRAGE, // Multi-market arbitrage
        FLASH_SWAP, // Flash swap via callback (borrow, execute, repay)
        JIT_LIQUIDITY // Just-in-time liquidity provision
    }

    /// @notice Type of flash swap callback action
    enum FlashAction {
        LEVERAGE, // Create leveraged position (borrow shares, sell, buy more = 2x exposure)
        CUSTOM // Custom callback logic (for external protocol integrations)
    }

    /// @notice Routing instruction data
    struct RouteData {
        ActionType action;
        bytes params; // ABI-encoded params specific to each action
    }

    /// @notice Parameters for FILL_LIMIT_ORDERS action
    struct FillOrdersParams {
        bytes32[] orderHashes; // Orders to try filling
        uint256 minFromOrders; // Minimum amount to fill from orders (rest goes to AMM)
    }

    /// @notice Parameters for SWAP_TO_COLLATERAL action
    struct SwapToCollateralParams {
        address tokenIn; // Arbitrary input token
        address[] swapPath; // Path to convert tokenIn -> collateral (e.g., via Uniswap)
        address swapRouter; // DEX router address
        bytes swapData; // Encoded swap call
    }

    /// @notice Parameters for SPLIT_AND_SWAP action
    struct SplitAndSwapParams {
        bool keepYes; // True to keep YES and swap NO, false to keep NO and swap YES
        uint256 minSharesOut; // Minimum shares to receive after swap
        bool usePMRouter; // True to route through PMRouter for limit orders
        bytes32[] orderHashes; // Optional limit orders to fill (if usePMRouter=true)
    }

    /// @notice Parameters for FLASH_ARBITRAGE action
    struct FlashArbParams {
        uint256[] marketIds; // Markets to arbitrage across
        bool[] directions; // True for YES->NO, false for NO->YES for each hop
        uint256[] feeOrHooks; // Fee tiers for each market
        uint256 minProfit; // Minimum profit in collateral terms
    }

    /// @notice Parameters for FLASH_SWAP action
    struct FlashSwapParams {
        FlashAction action; // Type of flash swap
        uint256 marketId; // Market to flash swap on
        uint256 feeOrHook; // Pool fee/hook
        bool zeroForOne; // Swap direction
        uint256 amountOut; // Amount to borrow
        bytes callback; // Callback data (action-specific)
    }

    /// @notice Callback data for flash swap execution
    struct FlashCallbackData {
        FlashAction action;
        address sender;
        uint256 marketId;
        bytes params;
    }

    /// @notice Aggregated market state
    struct MarketState {
        uint256 marketId;
        address resolver;
        address collateral;
        uint64 deadline;
        bool resolved;
        bool outcome;
        bool canClose;
        uint256 collateralLocked;
        uint256 poolReserve0;
        uint256 poolReserve1;
        bool poolExists;
        bool hasHook;
        uint256 currentFee;
        uint256 impliedProbability; // In basis points (5000 = 50%)
    }

    /// @notice Liquidity depth information
    struct LiquidityDepth {
        uint256 poolLiquidity;
        uint256 orderbookBuyDepth;
        uint256 orderbookSellDepth;
        uint256 totalLiquidity;
    }

    /// @notice Market info for UI
    struct MarketInfo {
        uint256 marketId;
        address collateral;
        uint64 deadline;
        bool resolved;
        bool outcome;
        uint256 impliedProbability;
        uint256 tvl;
        uint256 volume24h;
        bool poolExists;
        bool hasHook;
        uint256 currentFee;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
                            //////////////////////////////////////////////////////////////*/

    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21269;
    uint256 constant ACTUAL_USER_SLOT = 0x929eee149b4bd21270; // Hook reads this to get real user

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, 1)
            // Store actual user for hook callbacks
            tstore(ACTUAL_USER_SLOT, caller())
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
            tstore(ACTUAL_USER_SLOT, 0)
        }
    }

    /// @notice Get actual user from transient storage (for hook callbacks)
    /// @dev Hook can call this to get real user instead of router address
    function getActualUser() external view returns (address user) {
        assembly ("memory-safe") {
            user := tload(ACTUAL_USER_SLOT)
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
                            //////////////////////////////////////////////////////////////*/

    constructor() payable {
        // Approve ZAMM and PAMM for common operations
        PAMM.setOperator(address(ZAMM), true);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               MULTICALL
                            //////////////////////////////////////////////////////////////*/

    /// @notice Execute multiple calls in a single transaction
    /// @dev For ETH operations, msg.value must equal the exact amount needed by the single
    ///      payable call in the batch. Cannot batch multiple ETH operations together.
    /// @param data Array of encoded function calls to execute
    /// @return results Array of return data from each call
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                PERMIT
                            //////////////////////////////////////////////////////////////*/

    /// @notice ERC20Permit (EIP-2612) - approve via signature
    /// @dev Use with multicall: [permit, complexSwap] in single tx
    function permit(
        address token,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), value)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), v)
            mstore(add(m, 0xa4), r)
            mstore(add(m, 0xc4), s)
            if iszero(call(gas(), token, 0, m, 0xe4, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /// @notice DAI-style permit - approve via signature with nonce
    /// @dev DAI uses: permit(holder, spender, nonce, expiry, allowed, v, r, s)
    function permitDAI(
        address token,
        address holder,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x8fcbaf0c00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), holder)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), nonce)
            mstore(add(m, 0x64), expiry)
            mstore(add(m, 0x84), allowed)
            mstore(add(m, 0xa4), v)
            mstore(add(m, 0xc4), r)
            mstore(add(m, 0xe4), s)
            if iszero(call(gas(), token, 0, m, 0x104, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MAIN ROUTING
                            //////////////////////////////////////////////////////////////*/

    /// @notice Execute complex swap with optional routing actions
    /// @param tokenIn Input token (ETH if address(0))
    /// @param amountIn Amount of input token
    /// @param marketId Target prediction market
    /// @param isYes True for YES shares, false for NO
    /// @param minSharesOut Minimum shares to receive
    /// @param feeOrHook Pool fee tier or hook address
    /// @param to Recipient of shares
    /// @param deadline Expiration timestamp
    /// @param routeData Routing instructions
    /// @return sharesOut Amount of shares received
    function complexSwap(
        address tokenIn,
        uint256 amountIn,
        uint256 marketId,
        bool isYes,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline,
        RouteData calldata routeData
    ) external payable nonReentrant returns (uint256 sharesOut) {
        if (amountIn == 0) revert AmountZero();
        if (to == address(0)) to = msg.sender;
        if (deadline > 0 && block.timestamp > deadline) revert SlippageExceeded();

        // Get market collateral
        (,,,,, address collateral,) = PAMM.markets(marketId);

        // Handle different action types
        if (routeData.action == ActionType.REGISTER_MARKET) {
            _handleRegisterMarket(marketId, feeOrHook);
        } else if (routeData.action == ActionType.SWAP_TO_COLLATERAL) {
            SwapToCollateralParams memory params =
                abi.decode(routeData.params, (SwapToCollateralParams));
            amountIn = _swapToCollateral(tokenIn, amountIn, collateral, params);
            tokenIn = collateral;
        }

        // If tokenIn is already collateral, use it directly
        if (tokenIn == collateral || (tokenIn == ETH && collateral == ETH)) {
            // Handle ETH vs ERC20
            if (tokenIn == ETH) {
                if (msg.value != amountIn) revert InvalidETHAmount();
            } else {
                _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
            }

            // Route based on action type
            if (routeData.action == ActionType.FILL_LIMIT_ORDERS) {
                FillOrdersParams memory params = abi.decode(routeData.params, (FillOrdersParams));
                sharesOut = _fillOrdersThenSwap(
                    marketId, isYes, amountIn, minSharesOut, params, feeOrHook, to
                );
            } else if (routeData.action == ActionType.SPLIT_AND_SWAP) {
                SplitAndSwapParams memory params =
                    abi.decode(routeData.params, (SplitAndSwapParams));
                sharesOut = _splitAndSwap(
                    marketId, amountIn, params, feeOrHook, to
                );
            } else {
                // Direct swap via PAMM
                sharesOut = _buyShares(marketId, isYes, amountIn, minSharesOut, feeOrHook, to);
            }
        } else {
            revert UnsupportedToken();
        }

        emit ComplexSwap(msg.sender, tokenIn, amountIn, marketId, sharesOut, routeData.action);
    }

    /// @notice Swap YES<->NO with optional actions via ZAMM's low-level swap()
    /// @dev This function uses ZAMM.swap() which passes calldata to hooks
    /// @param marketId Prediction market
    /// @param yesForNo True to swap YES->NO, false for NO->YES
    /// @param amountIn Amount of shares to swap
    /// @param minOut Minimum output shares
    /// @param feeOrHook Pool fee tier or hook address
    /// @param to Recipient
    /// @param routeData Routing instructions (passed to hook via calldata)
    /// @return amountOut Amount of shares received
    function swapWithHook(
        uint256 marketId,
        bool yesForNo,
        uint256 amountIn,
        uint256 minOut,
        uint256 feeOrHook,
        address to,
        RouteData calldata routeData
    ) external nonReentrant returns (uint256 amountOut) {
        if (to == address(0)) to = msg.sender;

        uint256 yesId = marketId;
        uint256 noId = PAMM.getNoId(marketId);
        uint256 tokenIn = yesForNo ? yesId : noId;
        uint256 tokenOut = yesForNo ? noId : yesId;

        // Transfer shares from user
        PAMM.transferFrom(msg.sender, address(this), tokenIn, amountIn);

        // Deposit to ZAMM
        ZAMM.deposit(address(PAMM), tokenIn, amountIn);

        // Build pool key
        IZAMM.PoolKey memory key;
        if (yesId < noId) {
            key = IZAMM.PoolKey({
                id0: yesId,
                id1: noId,
                token0: address(PAMM),
                token1: address(PAMM),
                feeOrHook: feeOrHook
            });
        } else {
            key = IZAMM.PoolKey({
                id0: noId,
                id1: yesId,
                token0: address(PAMM),
                token1: address(PAMM),
                feeOrHook: feeOrHook
            });
        }

        uint256 amount0Out = (tokenOut == key.id0) ? minOut : 0;
        uint256 amount1Out = (tokenOut == key.id1) ? minOut : 0;

        // Encode routeData to pass to hook
        bytes memory hookData = abi.encode(routeData);

        // Call low-level swap with hookData
        ZAMM.swap(key, amount0Out, amount1Out, to, hookData);

        // Recover any leftover transient balance
        amountOut = ZAMM.recoverTransientBalance(address(PAMM), tokenOut, to);

        if (amountOut < minOut) revert SlippageExceeded();
    }

    /*//////////////////////////////////////////////////////////////
                        COLLATERAL OPERATIONS
                        //////////////////////////////////////////////////////////////*/

    /// @notice Split collateral into YES + NO shares
    function split(uint256 marketId, uint256 amount, address to)
        external
        payable
        nonReentrant
    {
        if (to == address(0)) to = msg.sender;
        (,,,,, address collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != amount) revert InvalidETHAmount();
            PAMM.split{value: amount}(marketId, amount, to);
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            _safeTransferFrom(collateral, msg.sender, address(this), amount);
            _ensureApproval(collateral, address(PAMM));
            PAMM.split(marketId, amount, to);
        }
    }

    /// @notice Merge YES + NO shares back into collateral
    function merge(uint256 marketId, uint256 amount, address to) external nonReentrant {
        if (to == address(0)) to = msg.sender;
        uint256 noId = PAMM.getNoId(marketId);

        PAMM.transferFrom(msg.sender, address(this), marketId, amount);
        PAMM.transferFrom(msg.sender, address(this), noId, amount);

        PAMM.merge(marketId, amount, to);
    }

    /// @notice Claim winnings from resolved market
    function claim(uint256 marketId, address to) external nonReentrant returns (uint256 payout) {
        if (to == address(0)) to = msg.sender;

        uint256 noId = PAMM.getNoId(marketId);
        uint256 yesBalance = PAMM.balanceOf(msg.sender, marketId);
        uint256 noBalance = PAMM.balanceOf(msg.sender, noId);

        if (yesBalance > 0) {
            PAMM.transferFrom(msg.sender, address(this), marketId, yesBalance);
        }
        if (noBalance > 0) {
            PAMM.transferFrom(msg.sender, address(this), noId, noBalance);
        }

        payout = PAMM.claim(marketId, to);
    }

    /*//////////////////////////////////////////////////////////////
                        CROSS-MARKET SWAPS
                        //////////////////////////////////////////////////////////////*/

    /// @notice Swap shares from one market to shares in another market
    /// @dev Example: Swap YES in "ETH > $3000" for NO in "BTC > $50000"
    /// @param fromMarketId Source market
    /// @param fromIsYes True if selling YES shares, false for NO shares
    /// @param amount Amount of shares to swap
    /// @param toMarketId Destination market
    /// @param toIsYes True to receive YES shares, false for NO shares
    /// @param minOut Minimum shares to receive in destination market
    /// @param to Recipient
    /// @return sharesOut Amount of destination shares received
    function swapCrossMarket(
        uint256 fromMarketId,
        bool fromIsYes,
        uint256 amount,
        uint256 toMarketId,
        bool toIsYes,
        uint256 minOut,
        address to
    ) external nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;
        if (amount == 0) revert AmountZero();

        // Verify both markets use same collateral
        (,,,,, address fromCollateral,) = PAMM.markets(fromMarketId);
        (,,,,, address toCollateral,) = PAMM.markets(toMarketId);
        if (fromCollateral != toCollateral) revert UnsupportedToken();

        // Take source shares from user
        uint256 fromTokenId = fromIsYes ? fromMarketId : PAMM.getNoId(fromMarketId);
        PAMM.transferFrom(msg.sender, address(this), fromTokenId, amount);

        // Sell source shares for collateral via PAMM
        _ensureApprovalPAMM();
        uint256 collateralOut = fromIsYes
            ? PAMM.sellYes(fromMarketId, amount, 0, 0, 0, 0, address(this), 0)
            : PAMM.sellNo(fromMarketId, amount, 0, 0, 0, 0, address(this), 0);

        // Buy destination shares with collateral
        _ensureApproval(fromCollateral, address(PAMM));
        sharesOut = toIsYes
            ? PAMM.buyYes(toMarketId, collateralOut, minOut, 0, 0, to, 0)
            : PAMM.buyNo(toMarketId, collateralOut, minOut, 0, 0, to, 0);

        if (sharesOut < minOut) revert SlippageExceeded();
    }

    /// @notice Swap shares across markets with DIFFERENT collaterals via PMHOOK intermediary
    /// @dev Routes: fromMarket → fromCollateral → PMHOOK → toCollateral → toMarket
    ///      This is the KEY function that makes "all tokens liq for each other"
    /// @param fromMarketId Source market
    /// @param fromIsYes True if selling YES shares, false for NO shares
    /// @param amount Amount of shares to swap
    /// @param toMarketId Destination market (must have different collateral)
    /// @param toIsYes True to receive YES shares, false for NO shares
    /// @param pmhookToken Address of PMHOOK ERC20 token
    /// @param dexRouter Address of DEX router (e.g., Uniswap V2/V3)
    /// @param pathFromToPMHOOK Encoded swap path: fromCollateral → PMHOOK
    /// @param pathPMHOOKToTo Encoded swap path: PMHOOK → toCollateral
    /// @param minOut Minimum shares to receive in destination market
    /// @param to Recipient
    /// @return sharesOut Amount of destination shares received
    function swapCrossCollateral(
        uint256 fromMarketId,
        bool fromIsYes,
        uint256 amount,
        uint256 toMarketId,
        bool toIsYes,
        address pmhookToken,
        address dexRouter,
        bytes calldata pathFromToPMHOOK,
        bytes calldata pathPMHOOKToTo,
        uint256 minOut,
        address to
    ) external nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;
        if (amount == 0) revert AmountZero();

        // Get collateral types
        (,,,,, address fromCollateral,) = PAMM.markets(fromMarketId);
        (,,,,, address toCollateral,) = PAMM.markets(toMarketId);

        // If same collateral, use regular swapCrossMarket instead
        if (fromCollateral == toCollateral) revert InvalidAction();

        // STEP 1: Sell fromMarket position → get fromCollateral
        uint256 fromTokenId = fromIsYes ? fromMarketId : PAMM.getNoId(fromMarketId);
        PAMM.transferFrom(msg.sender, address(this), fromTokenId, amount);

        _ensureApprovalPAMM();
        uint256 collateralOut = fromIsYes
            ? PAMM.sellYes(fromMarketId, amount, 0, 0, 0, 0, address(this), 0)
            : PAMM.sellNo(fromMarketId, amount, 0, 0, 0, 0, address(this), 0);

        // STEP 2: Swap fromCollateral → PMHOOK (via DEX)
        _ensureApproval(fromCollateral, dexRouter);

        uint256 pmhookBalanceBefore = IERC20(pmhookToken).balanceOf(address(this));
        (bool success1,) = dexRouter.call(pathFromToPMHOOK);
        if (!success1) revert SwapFailed();
        uint256 pmhookOut = IERC20(pmhookToken).balanceOf(address(this)) - pmhookBalanceBefore;

        // STEP 3: Swap PMHOOK → toCollateral (via DEX)
        _ensureApproval(pmhookToken, dexRouter);

        uint256 toCollateralBalanceBefore = toCollateral == ETH
            ? address(this).balance
            : IERC20(toCollateral).balanceOf(address(this));

        (bool success2,) = dexRouter.call(pathPMHOOKToTo);
        if (!success2) revert SwapFailed();

        uint256 toCollateralOut = toCollateral == ETH
            ? address(this).balance - toCollateralBalanceBefore
            : IERC20(toCollateral).balanceOf(address(this)) - toCollateralBalanceBefore;

        // STEP 4: Buy toMarket position with toCollateral
        _ensureApproval(toCollateral, address(PAMM));
        sharesOut = toIsYes
            ? PAMM.buyYes(toMarketId, toCollateralOut, minOut, 0, 0, to, 0)
            : PAMM.buyNo(toMarketId, toCollateralOut, minOut, 0, 0, to, 0);

        if (sharesOut < minOut) revert SlippageExceeded();
    }

    /// @notice Simplified cross-collateral swap using Uniswap V2-style routing
    /// @dev Auto-constructs paths: fromCollateral → PMHOOK → toCollateral
    ///      Assumes PMHOOK/collateral pools exist on the specified DEX
    /// @param fromMarketId Source market
    /// @param fromIsYes True if selling YES shares, false for NO shares
    /// @param amount Amount of shares to swap
    /// @param toMarketId Destination market (must have different collateral)
    /// @param toIsYes True to receive YES shares, false for NO shares
    /// @param pmhookToken Address of PMHOOK ERC20 token
    /// @param dexRouter Address of Uniswap V2-compatible router
    /// @param minOut Minimum shares to receive in destination market
    /// @param deadline Swap deadline
    /// @param to Recipient
    /// @return sharesOut Amount of destination shares received
    function swapCrossCollateralSimple(
        uint256 fromMarketId,
        bool fromIsYes,
        uint256 amount,
        uint256 toMarketId,
        bool toIsYes,
        address pmhookToken,
        address dexRouter,
        uint256 minOut,
        uint256 deadline,
        address to
    ) external nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;
        if (amount == 0) revert AmountZero();

        // Get collateral types
        (,,,,, address fromCollateral,) = PAMM.markets(fromMarketId);
        (,,,,, address toCollateral,) = PAMM.markets(toMarketId);

        // If same collateral, use regular swapCrossMarket instead
        if (fromCollateral == toCollateral) revert InvalidAction();

        // STEP 1: Sell fromMarket position → get fromCollateral
        uint256 fromTokenId = fromIsYes ? fromMarketId : PAMM.getNoId(fromMarketId);
        PAMM.transferFrom(msg.sender, address(this), fromTokenId, amount);

        _ensureApprovalPAMM();
        uint256 collateralOut = fromIsYes
            ? PAMM.sellYes(fromMarketId, amount, 0, 0, 0, 0, address(this), 0)
            : PAMM.sellNo(fromMarketId, amount, 0, 0, 0, 0, address(this), 0);

        // STEP 2 & 3: Swap fromCollateral → PMHOOK → toCollateral via Uniswap V2
        _ensureApproval(fromCollateral, dexRouter);

        // Build path array [fromCollateral, PMHOOK, toCollateral]
        address[] memory path = new address[](3);
        path[0] = fromCollateral;
        path[1] = pmhookToken;
        path[2] = toCollateral;

        // Call swapExactTokensForTokens
        bytes memory swapCall = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            collateralOut,
            0, // Accept any amount from DEX (we check PM slippage at end)
            path,
            address(this),
            deadline
        );

        (bool success,) = dexRouter.call(swapCall);
        if (!success) revert SwapFailed();

        // Get toCollateral balance
        uint256 toCollateralOut = toCollateral == ETH
            ? address(this).balance
            : IERC20(toCollateral).balanceOf(address(this));

        // STEP 4: Buy toMarket position with toCollateral
        _ensureApproval(toCollateral, address(PAMM));
        sharesOut = toIsYes
            ? PAMM.buyYes(toMarketId, toCollateralOut, minOut, 0, 0, to, 0)
            : PAMM.buyNo(toMarketId, toCollateralOut, minOut, 0, 0, to, 0);

        if (sharesOut < minOut) revert SlippageExceeded();
    }

    /// @notice Migrate liquidity from one market pool to another
    /// @dev Removes LP from source market, adds to destination market
    /// @param fromMarketId Source market
    /// @param fromFeeOrHook Source pool fee/hook
    /// @param liquidity Amount of LP tokens to migrate
    /// @param toMarketId Destination market
    /// @param toFeeOrHook Destination pool fee/hook
    /// @param minLiquidity Minimum LP tokens to receive in destination
    /// @param to Recipient of new LP tokens
    /// @return liquidityOut LP tokens received in destination pool
    function migrateLiquidity(
        uint256 fromMarketId,
        uint256 fromFeeOrHook,
        uint256 liquidity,
        uint256 toMarketId,
        uint256 toFeeOrHook,
        uint256 minLiquidity,
        address to
    ) external nonReentrant returns (uint256 liquidityOut) {
        if (to == address(0)) to = msg.sender;
        if (liquidity == 0) revert AmountZero();

        // Verify markets use same collateral
        (,,,,, address fromCollateral,) = PAMM.markets(fromMarketId);
        (,,,,, address toCollateral,) = PAMM.markets(toMarketId);
        if (fromCollateral != toCollateral) revert UnsupportedToken();

        // Build pool keys
        uint256 fromNoId = PAMM.getNoId(fromMarketId);
        uint256 toNoId = PAMM.getNoId(toMarketId);
        IZAMM.PoolKey memory fromKey = _buildPoolKey(fromMarketId, fromNoId, fromFeeOrHook);
        IZAMM.PoolKey memory toKey = _buildPoolKey(toMarketId, toNoId, toFeeOrHook);
        uint256 fromPoolId = _getPoolId(fromKey);

        // Transfer LP tokens from user to router
        ZAMM.transferFrom(msg.sender, address(this), fromPoolId, liquidity);

        // Remove liquidity from source pool (get YES + NO shares back)
        (uint256 amount0, uint256 amount1) =
            ZAMM.removeLiquidity(fromKey, liquidity, 0, 0, address(this), block.timestamp);

        // If same market, just different pool (e.g., different hook), can directly add liquidity
        if (fromMarketId == toMarketId) {
            // Direct add to new pool with same shares
            uint256 amt0;
            uint256 amt1;
            (amt0, amt1, liquidityOut) = ZAMM.addLiquidity(
                toKey,
                amount0, // amount0Desired
                amount1, // amount1Desired
                0, // amount0Min
                0, // amount1Min
                to,
                block.timestamp
            );
        } else {
            // Different markets - need to merge source shares, split into destination shares
            // Merge source shares to collateral
            uint256 mergeAmount = amount0 < amount1 ? amount0 : amount1;
            PAMM.merge(fromMarketId, mergeAmount, address(this));

            // Any leftover shares need to be sold for collateral
            uint256 leftover0 = amount0 > mergeAmount ? amount0 - mergeAmount : 0;
            uint256 leftover1 = amount1 > mergeAmount ? amount1 - mergeAmount : 0;

            if (leftover0 > 0) {
                _ensureApprovalPAMM();
                PAMM.sellYes(fromMarketId, leftover0, 0, 0, 0, 0, address(this), 0);
            }
            if (leftover1 > 0) {
                _ensureApprovalPAMM();
                PAMM.sellNo(fromMarketId, leftover1, 0, 0, 0, 0, address(this), 0);
            }

            // Get total collateral balance
            uint256 totalCollateral = fromCollateral == ETH
                ? address(this).balance
                : IERC20(fromCollateral).balanceOf(address(this));

            // Split collateral into destination market shares
            _ensureApproval(fromCollateral, address(PAMM));
            PAMM.split(toMarketId, totalCollateral, address(this));

            // Add liquidity to destination pool
            (,, liquidityOut) = ZAMM.addLiquidity(
                toKey,
                totalCollateral, // amount0Desired
                totalCollateral, // amount1Desired
                0, // amount0Min
                0, // amount1Min
                to,
                block.timestamp
            );
        }

        if (liquidityOut < minLiquidity) revert SlippageExceeded();
    }

    /*//////////////////////////////////////////////////////////////
                        FLASH SWAPS & CALLBACKS
                        //////////////////////////////////////////////////////////////*/

    /// @notice Execute a flash swap with callback-based arbitrage/strategy
    /// @dev Borrows shares from ZAMM, executes callback logic, repays in same transaction
    /// @param params Flash swap parameters
    /// @return profit Amount of profit generated (in shares or collateral)
    function flashSwap(FlashSwapParams calldata params)
        external
        nonReentrant
        returns (uint256 profit)
    {
        uint256 yesId = params.marketId;
        uint256 noId = PAMM.getNoId(params.marketId);

        // Build pool key
        IZAMM.PoolKey memory key = _buildPoolKey(yesId, noId, params.feeOrHook);

        // Encode callback data
        FlashCallbackData memory cbData = FlashCallbackData({
            action: params.action,
            sender: msg.sender,
            marketId: params.marketId,
            params: params.callback
        });

        bytes memory data = abi.encode(cbData);

        // Initiate flash swap - ZAMM will call us back via zammCall()
        uint256 amount0Out = params.zeroForOne ? params.amountOut : 0;
        uint256 amount1Out = params.zeroForOne ? 0 : params.amountOut;

        ZAMM.swap(key, amount0Out, amount1Out, address(this), data);

        // Profit is calculated in the callback
        profit = 0; // TODO: Track profit from callback
    }

    /// @notice ZAMM flash swap callback - called by ZAMM during swap execution
    /// @dev Only callable by ZAMM contract
    /// @param poolId Pool identifier
    /// @param sender Original swap initiator
    /// @param amount0 Amount of token0 sent to this contract
    /// @param amount1 Amount of token1 sent to this contract
    /// @param data Encoded FlashCallbackData
    function zammCall(
        uint256 poolId,
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        // Only ZAMM can call this
        if (msg.sender != address(ZAMM)) revert Unauthorized();

        // Decode callback data
        FlashCallbackData memory cbData = abi.decode(data, (FlashCallbackData));

        // Verify sender matches
        if (cbData.sender != sender) revert Unauthorized();

        // Execute callback based on action type
        if (cbData.action == FlashAction.LEVERAGE) {
            _flashLeverage(cbData, amount0, amount1);
        } else if (cbData.action == FlashAction.CUSTOM) {
            _flashCustom(cbData, amount0, amount1);
        }

        // Note: We don't repay here - ZAMM handles the accounting
        // We just need to ensure we have enough shares to complete the swap
    }

    /// @notice Create leveraged position - borrow shares, sell for collateral, buy more shares
    /// @dev Example: Start with 100 YES, flash borrow 100 NO, merge to 100 collateral,
    ///      buy 200 YES total = 2x leverage
    function _flashLeverage(
        FlashCallbackData memory cbData,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // Decode params: leverage ratio (2x, 3x, etc), isYes
        (uint256 leverageRatio, bool isYes) = abi.decode(cbData.params, (uint256, bool));

        uint256 borrowedAmount = amount0 > 0 ? amount0 : amount1;

        // User should have sent initial shares to this contract before calling flashSwap
        // Flash borrowed opposite shares to merge with user's shares
        // Merge creates collateral, use to buy more of desired direction

        // TODO: Full leverage implementation
        // For now, revert to prevent accidental use
        revert InvalidAction();
    }

    /// @notice Custom flash swap callback - delegates to user-provided contract
    /// @dev User must deploy a contract implementing IFlashCallback interface
    /// @param cbData Callback data containing user contract address
    /// @param amount0 Amount of token0 borrowed
    /// @param amount1 Amount of token1 borrowed
    function _flashCustom(
        FlashCallbackData memory cbData,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // Decode params: callback contract address, custom params
        (address callbackContract, bytes memory customParams) =
            abi.decode(cbData.params, (address, bytes));

        // Verify callback contract exists
        if (callbackContract.code.length == 0) revert InvalidAction();

        // Prepare callback parameters
        uint256 yesId = cbData.marketId;
        uint256 noId = PAMM.getNoId(cbData.marketId);

        // Call user's callback contract
        // User is responsible for:
        // 1. Using borrowed shares productively
        // 2. Ensuring enough shares to repay ZAMM
        // 3. Handling any profit/loss
        (bool success, bytes memory result) = callbackContract.call(
            abi.encodeWithSignature(
                "executeFlashCallback(address,uint256,uint256,uint256,uint256,bytes)",
                cbData.sender,
                yesId,
                noId,
                amount0,
                amount1,
                customParams
            )
        );

        if (!success) {
            // Bubble up the revert reason
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }

        // User's callback should have ensured we have enough shares to repay ZAMM
        // ZAMM will verify this when swap() completes
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH MULTI-MARKET OPERATIONS
                        //////////////////////////////////////////////////////////////*/

    /// @notice Batch buy shares across multiple markets with single collateral input
    /// @dev Splits collateral proportionally across markets for diversified exposure
    /// @param markets Array of market IDs
    /// @param isYes Array of YES/NO flags for each market
    /// @param collateralAmounts Array of collateral amounts for each market
    /// @param feeOrHooks Array of pool fee/hook for each market
    /// @param to Recipient of all shares
    /// @return sharesOut Array of shares received for each market
    function batchBuy(
        uint256[] calldata markets,
        bool[] calldata isYes,
        uint256[] calldata collateralAmounts,
        uint256[] calldata feeOrHooks,
        address to
    ) external payable nonReentrant returns (uint256[] memory sharesOut) {
        if (to == address(0)) to = msg.sender;
        uint256 len = markets.length;
        if (len != isYes.length || len != collateralAmounts.length || len != feeOrHooks.length) {
            revert InvalidAction();
        }

        sharesOut = new uint256[](len);
        uint256 totalCollateral;

        for (uint256 i; i < len; ++i) {
            totalCollateral += collateralAmounts[i];
        }

        // Verify ETH amount if needed
        (,,,,, address firstCollateral,) = PAMM.markets(markets[0]);
        if (firstCollateral == ETH && msg.value != totalCollateral) {
            revert InvalidETHAmount();
        }

        // Execute all buys
        for (uint256 i; i < len; ++i) {
            (,,,,, address collateral,) = PAMM.markets(markets[i]);
            if (collateral != firstCollateral) revert UnsupportedToken();

            if (collateral == ETH) {
                sharesOut[i] = isYes[i]
                    ? PAMM.buyYes{value: collateralAmounts[i]}(
                        markets[i], collateralAmounts[i], 0, 0, feeOrHooks[i], to, 0
                    )
                    : PAMM.buyNo{value: collateralAmounts[i]}(
                        markets[i], collateralAmounts[i], 0, 0, feeOrHooks[i], to, 0
                    );
            } else {
                _safeTransferFrom(collateral, msg.sender, address(this), collateralAmounts[i]);
                _ensureApproval(collateral, address(PAMM));
                sharesOut[i] = isYes[i]
                    ? PAMM.buyYes(markets[i], collateralAmounts[i], 0, 0, feeOrHooks[i], to, 0)
                    : PAMM.buyNo(markets[i], collateralAmounts[i], 0, 0, feeOrHooks[i], to, 0);
            }
        }
    }

    /// @notice Rebalance portfolio across multiple markets in single transaction
    /// @dev Sells unwanted positions and buys desired positions atomically
    /// @param sellMarkets Markets to sell shares from
    /// @param sellIsYes Array of YES/NO flags for sells
    /// @param sellAmounts Array of share amounts to sell
    /// @param buyMarkets Markets to buy shares in
    /// @param buyIsYes Array of YES/NO flags for buys
    /// @param minBuyAmounts Minimum shares to receive for each buy
    /// @param feeOrHooks Pool fee/hook for all operations
    /// @return collateralRecovered Total collateral from sells
    /// @return sharesBought Array of shares bought
    function rebalancePortfolio(
        uint256[] calldata sellMarkets,
        bool[] calldata sellIsYes,
        uint256[] calldata sellAmounts,
        uint256[] calldata buyMarkets,
        bool[] calldata buyIsYes,
        uint256[] calldata minBuyAmounts,
        uint256 feeOrHooks
    ) external nonReentrant returns (uint256 collateralRecovered, uint256[] memory sharesBought) {
        // Sell all unwanted positions
        for (uint256 i; i < sellMarkets.length; ++i) {
            uint256 tokenId = sellIsYes[i] ? sellMarkets[i] : PAMM.getNoId(sellMarkets[i]);
            PAMM.transferFrom(msg.sender, address(this), tokenId, sellAmounts[i]);

            _ensureApprovalPAMM();
            collateralRecovered += sellIsYes[i]
                ? PAMM.sellYes(sellMarkets[i], sellAmounts[i], 0, 0, 0, feeOrHooks, address(this), 0)
                : PAMM.sellNo(sellMarkets[i], sellAmounts[i], 0, 0, 0, feeOrHooks, address(this), 0);
        }

        // Buy all desired positions with recovered collateral
        sharesBought = new uint256[](buyMarkets.length);
        (,,,,, address collateral,) = PAMM.markets(buyMarkets[0]);
        _ensureApproval(collateral, address(PAMM));

        for (uint256 i; i < buyMarkets.length; ++i) {
            uint256 buyAmount = (collateralRecovered * minBuyAmounts[i]) / 10000; // Proportional allocation
            sharesBought[i] = buyIsYes[i]
                ? PAMM.buyYes(buyMarkets[i], buyAmount, minBuyAmounts[i], 0, feeOrHooks, msg.sender, 0)
                : PAMM.buyNo(buyMarkets[i], buyAmount, minBuyAmounts[i], 0, feeOrHooks, msg.sender, 0);
        }
    }

    /// @notice Execute circular arbitrage across multiple markets
    /// @dev Example: Market A YES → Market B NO → Market C YES → back to Market A
    /// @param route Array of markets to arbitrage through
    /// @param directions Array of buy directions (true = YES, false = NO)
    /// @param feeOrHooks Pool configurations for each hop
    /// @param collateralIn Initial collateral to start arbitrage
    /// @param minProfit Minimum profit required
    /// @return profit Profit from arbitrage cycle
    function circularArbitrage(
        uint256[] calldata route,
        bool[] calldata directions,
        uint256[] calldata feeOrHooks,
        uint256 collateralIn,
        uint256 minProfit
    ) external payable nonReentrant returns (uint256 profit) {
        if (route.length < 2 || route.length != directions.length) revert InvalidAction();

        (,,,,, address collateral,) = PAMM.markets(route[0]);

        // Handle ETH
        if (collateral == ETH) {
            if (msg.value != collateralIn) revert InvalidETHAmount();
        } else {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
        }

        uint256 amount = collateralIn;

        // Execute arbitrage cycle
        for (uint256 i; i < route.length; ++i) {
            _ensureApproval(collateral, address(PAMM));

            // Buy shares
            uint256 shares = directions[i]
                ? PAMM.buyYes(route[i], amount, 0, 0, feeOrHooks[i], address(this), 0)
                : PAMM.buyNo(route[i], amount, 0, 0, feeOrHooks[i], address(this), 0);

            // If not last iteration, sell shares for collateral for next hop
            if (i < route.length - 1) {
                _ensureApprovalPAMM();
                amount = directions[i]
                    ? PAMM.sellYes(route[i], shares, 0, 0, 0, feeOrHooks[i], address(this), 0)
                    : PAMM.sellNo(route[i], shares, 0, 0, 0, feeOrHooks[i], address(this), 0);
            } else {
                // Last iteration - sell back for final collateral
                _ensureApprovalPAMM();
                amount = directions[i]
                    ? PAMM.sellYes(route[i], shares, 0, 0, 0, feeOrHooks[i], msg.sender, 0)
                    : PAMM.sellNo(route[i], shares, 0, 0, 0, feeOrHooks[i], msg.sender, 0);
            }
        }

        profit = amount > collateralIn ? amount - collateralIn : 0;
        if (profit < minProfit) revert SlippageExceeded();
    }


    /*//////////////////////////////////////////////////////////////
                        SMART ORDER ROUTING
                        //////////////////////////////////////////////////////////////*/

    /// @notice Smart buy - automatically routes through best liquidity sources
    /// @dev Tries: 1) Limit orders 2) Hook pool AMM 3) Default pool AMM
    /// @param marketId Prediction market
    /// @param isYes True for YES shares, false for NO
    /// @param collateralIn Amount of collateral to spend
    /// @param minSharesOut Minimum shares to receive (slippage protection)
    /// @param feeOrHook Preferred pool (hook address or fee tier)
    /// @param to Recipient of shares
    /// @return sharesOut Shares received
    function smartBuy(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to
    ) external payable nonReentrant returns (uint256 sharesOut) {
        if (to == address(0)) to = msg.sender;

        (,,,,, address collateral,) = PAMM.markets(marketId);

        // Get available orderbook liquidity
        (bytes32[] memory sellOrders, uint256 availableFromOrders) =
            _getAvailableSellOrders(marketId, isYes, collateralIn);

        // Route through orders first if available and profitable
        if (availableFromOrders > 0 && address(PM_ROUTER) != address(0)) {
            if (collateral == ETH) {
                if (msg.value != collateralIn) revert InvalidETHAmount();
                sharesOut = PM_ROUTER.fillOrdersThenSwap{value: collateralIn}(
                    marketId, isYes, true, collateralIn, minSharesOut,
                    sellOrders, feeOrHook, to, 0
                );
            } else {
                if (msg.value != 0) revert InvalidETHAmount();
                _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
                _ensureApproval(collateral, address(PM_ROUTER));
                sharesOut = PM_ROUTER.fillOrdersThenSwap(
                    marketId, isYes, true, collateralIn, minSharesOut,
                    sellOrders, feeOrHook, to, 0
                );
            }
        } else {
            // Direct AMM route
            sharesOut = _buyShares(marketId, isYes, collateralIn, minSharesOut, feeOrHook, to);
        }

        if (sharesOut < minSharesOut) revert SlippageExceeded();
    }

    /// @notice Smart sell - automatically routes through best liquidity sources
    /// @param marketId Prediction market
    /// @param isYes True for YES shares, false for NO
    /// @param sharesIn Amount of shares to sell
    /// @param minCollateralOut Minimum collateral to receive
    /// @param feeOrHook Preferred pool
    /// @param to Recipient of collateral
    /// @return collateralOut Collateral received
    function smartSell(
        uint256 marketId,
        bool isYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to
    ) external nonReentrant returns (uint256 collateralOut) {
        if (to == address(0)) to = msg.sender;

        (,,,,, address collateral,) = PAMM.markets(marketId);
        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);

        // Transfer shares from user
        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);

        // Get available orderbook liquidity
        (bytes32[] memory buyOrders, uint256 availableFromOrders) =
            _getAvailableBuyOrders(marketId, isYes, sharesIn);

        // Route through orders first if available
        if (availableFromOrders > 0 && address(PM_ROUTER) != address(0)) {
            _ensureApprovalPAMM();
            collateralOut = PM_ROUTER.fillOrdersThenSwap(
                marketId, isYes, false, sharesIn, minCollateralOut,
                buyOrders, feeOrHook, to, 0
            );
        } else {
            // Direct AMM route
            _ensureApprovalPAMM();
            collateralOut = isYes
                ? PAMM.sellYes(marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, 0)
                : PAMM.sellNo(marketId, sharesIn, 0, minCollateralOut, 0, feeOrHook, to, 0);
        }

        if (collateralOut < minCollateralOut) revert SlippageExceeded();
    }

    /*//////////////////////////////////////////////////////////////
                        AGGREGATED STATE VIEWS
                        //////////////////////////////////////////////////////////////*/

    /// @notice Get complete market state from all sources
    /// @param marketId Prediction market
    /// @param feeOrHook Pool to query
    /// @return state Aggregated market information
    function getMarketState(uint256 marketId, uint256 feeOrHook)
        external
        view
        returns (MarketState memory state)
    {
        // PAMM state
        (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        ) = PAMM.markets(marketId);

        state.marketId = marketId;
        state.resolver = resolver;
        state.resolved = resolved;
        state.outcome = outcome;
        state.canClose = canClose;
        state.deadline = close;
        state.collateral = collateral;
        state.collateralLocked = collateralLocked;

        // ZAMM pool state
        uint256 noId = PAMM.getNoId(marketId);
        IZAMM.PoolKey memory key = _buildPoolKey(marketId, noId, feeOrHook);
        uint256 poolId = _getPoolId(key);

        // Try to get pool reserves (may not exist)
        try this.getPoolReserves(poolId) returns (uint256 r0, uint256 r1) {
            state.poolReserve0 = r0;
            state.poolReserve1 = r1;
            state.poolExists = r0 > 0 || r1 > 0;
        } catch {
            state.poolExists = false;
        }

        // Hook state (if applicable)
        if (feeOrHook > type(uint160).max) {
            address hook = address(uint160(feeOrHook & type(uint160).max));
            try this.getHookFee(hook, poolId) returns (uint256 fee) {
                state.currentFee = fee;
                state.hasHook = true;
            } catch {
                state.hasHook = false;
            }
        }

        // Calculate implied probability from pool
        if (state.poolExists && state.poolReserve0 > 0 && state.poolReserve1 > 0) {
            state.impliedProbability = (state.poolReserve1 * 10000) /
                (state.poolReserve0 + state.poolReserve1);
        } else {
            state.impliedProbability = 5000; // 50% default
        }
    }

    /// @notice Get liquidity depth across all sources
    /// @param marketId Prediction market
    /// @param isYes True for YES, false for NO
    /// @param feeOrHook Pool to check
    /// @return depth Liquidity information
    function getLiquidityDepth(uint256 marketId, bool isYes, uint256 feeOrHook)
        external
        view
        returns (LiquidityDepth memory depth)
    {
        uint256 noId = PAMM.getNoId(marketId);
        IZAMM.PoolKey memory key = _buildPoolKey(marketId, noId, feeOrHook);
        uint256 poolId = _getPoolId(key);

        // Pool liquidity
        try this.getPoolReserves(poolId) returns (uint256 r0, uint256 r1) {
            depth.poolLiquidity = isYes ? r0 : r1;
        } catch {}

        // Orderbook depth (if PMRouter available)
        if (address(PM_ROUTER) != address(0)) {
            depth.orderbookBuyDepth = 0; // TODO: Query PM_ROUTER for orderbook depth
            depth.orderbookSellDepth = 0;
        }

        depth.totalLiquidity = depth.poolLiquidity + depth.orderbookBuyDepth + depth.orderbookSellDepth;
    }

    /// @notice Simulate trade to calculate expected output and price impact
    /// @param marketId Prediction market
    /// @param isYes True for YES, false for NO
    /// @param isBuy True for buying shares, false for selling
    /// @param amountIn Amount of input (collateral if buying, shares if selling)
    /// @param feeOrHook Pool to use
    /// @return amountOut Expected output amount
    /// @return priceImpact Price impact in basis points (10000 = 100%)
    function simulateTrade(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint256 amountIn,
        uint256 feeOrHook
    ) external view returns (uint256 amountOut, uint256 priceImpact) {
        uint256 noId = PAMM.getNoId(marketId);
        IZAMM.PoolKey memory key = _buildPoolKey(marketId, noId, feeOrHook);
        uint256 poolId = _getPoolId(key);

        // Get pool reserves
        (uint256 r0, uint256 r1) = this.getPoolReserves(poolId);
        if (r0 == 0 || r1 == 0) return (0, 0);

        uint256 reserveIn;
        uint256 reserveOut;

        if (isBuy) {
            // Buying shares with collateral - use PAMM split pricing
            // 1 collateral = 1 YES + 1 NO, so effective reserves are different
            reserveIn = r0 + r1; // Total collateral in pool
            reserveOut = isYes ? r0 : r1;
        } else {
            // Selling shares for shares (YES<->NO swap)
            reserveIn = isYes ? r0 : r1;
            reserveOut = isYes ? r1 : r0;
        }

        // Constant product formula: x * y = k
        // amountOut = (reserveOut * amountIn) / (reserveIn + amountIn)
        uint256 amountInWithFee = (amountIn * 997) / 1000; // 0.3% fee
        amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);

        // Calculate price impact
        // impact = (1 - (amountOut / reserveOut) / (amountIn / reserveIn)) * 10000
        uint256 expectedRate = (reserveOut * 10000) / reserveIn;
        uint256 actualRate = (amountOut * 10000) / amountIn;
        priceImpact = expectedRate > actualRate
            ? expectedRate - actualRate
            : 0;
    }

    /// @notice Get comprehensive market info for UI display
    /// @param marketId Prediction market
    /// @param feeOrHook Pool to query
    /// @return info Formatted market information
    function getMarketInfo(uint256 marketId, uint256 feeOrHook)
        external
        view
        returns (MarketInfo memory info)
    {
        MarketState memory state = this.getMarketState(marketId, feeOrHook);

        info.marketId = marketId;
        info.collateral = state.collateral;
        info.deadline = state.deadline;
        info.resolved = state.resolved;
        info.outcome = state.outcome;
        info.impliedProbability = state.impliedProbability;
        info.tvl = state.collateralLocked;
        info.volume24h = 0; // Use indexer
        info.poolExists = state.poolExists;
        info.hasHook = state.hasHook;
        info.currentFee = state.currentFee;
    }


    /*//////////////////////////////////////////////////////////////
                        VIEW HELPER FUNCTIONS
                        //////////////////////////////////////////////////////////////*/

    /// @notice Get pool reserves (public for try/catch in views)
    function getPoolReserves(uint256 poolId) external view returns (uint256 r0, uint256 r1) {
        (uint112 reserve0, uint112 reserve1,,,,,) = ZAMM.pools(poolId);
        return (uint256(reserve0), uint256(reserve1));
    }

    /// @notice Get current hook fee (public for try/catch in views)
    function getHookFee(address hook, uint256 poolId) external view returns (uint256) {
        // Call hook's getCurrentFee if it exists
        (bool success, bytes memory result) = hook.staticcall(
            abi.encodeWithSignature("getCurrentFee(uint256,bool)", poolId, true)
        );
        if (success && result.length >= 32) {
            return abi.decode(result, (uint256));
        }
        return 30; // Default 0.3%
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL ACTIONS
                            //////////////////////////////////////////////////////////////*/

    /// @notice Register a market with its hook
    function _handleRegisterMarket(uint256 marketId, uint256 feeOrHook) internal {
        // Extract hook address from feeOrHook (mask to 160 bits to remove flags)
        address hook = address(uint160(feeOrHook & type(uint160).max));

        // Call hook's registerMarket function
        (bool success, bytes memory result) =
            hook.call(abi.encodeWithSignature("registerMarket(uint256)", marketId));

        if (!success) revert InvalidAction();

        uint256 poolId = abi.decode(result, (uint256));
        emit MarketRegistered(marketId, hook, poolId);
    }

    /// @notice Convert arbitrary token to collateral via external DEX
    function _swapToCollateral(
        address tokenIn,
        uint256 amountIn,
        address collateral,
        SwapToCollateralParams memory params
    ) internal returns (uint256 collateralOut) {
        // Transfer input token from user
        if (tokenIn == ETH) {
            if (msg.value != amountIn) revert InvalidETHAmount();
        } else {
            _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
            _ensureApproval(tokenIn, params.swapRouter);
        }

        // Execute swap via external router
        uint256 balanceBefore = collateral == ETH
            ? address(this).balance
            : IERC20(collateral).balanceOf(address(this));

        (bool success,) = params.swapRouter.call{value: tokenIn == ETH ? amountIn : 0}(
            params.swapData
        );
        if (!success) revert SwapFailed();

        uint256 balanceAfter = collateral == ETH
            ? address(this).balance
            : IERC20(collateral).balanceOf(address(this));

        collateralOut = balanceAfter - balanceBefore;
        if (collateralOut == 0) revert AmountZero();
    }

    /// @notice Fill limit orders then swap remainder via AMM
    function _fillOrdersThenSwap(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        FillOrdersParams memory params,
        uint256 feeOrHook,
        address to
    ) internal returns (uint256 sharesOut) {
        (,,,,, address collateral,) = PAMM.markets(marketId);

        // Approve PM_ROUTER to spend collateral
        if (collateral != ETH) {
            _ensureApproval(collateral, address(PM_ROUTER));
        }

        // Use PMRouter's fillOrdersThenSwap if orders provided
        if (params.orderHashes.length > 0) {
            if (collateral == ETH) {
                sharesOut = PM_ROUTER.fillOrdersThenSwap{value: collateralIn}(
                    marketId,
                    isYes,
                    true, // isBuy
                    collateralIn,
                    minSharesOut,
                    params.orderHashes,
                    feeOrHook,
                    to,
                    0 // deadline = now
                );
            } else {
                sharesOut = PM_ROUTER.fillOrdersThenSwap(
                    marketId,
                    isYes,
                    true, // isBuy
                    collateralIn,
                    minSharesOut,
                    params.orderHashes,
                    feeOrHook,
                    to,
                    0 // deadline = now
                );
            }
        } else {
            // No orders, just buy via PAMM
            sharesOut = _buyShares(marketId, isYes, collateralIn, minSharesOut, feeOrHook, to);
        }
    }

    /// @notice Buy shares via PAMM
    function _buyShares(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to
    ) internal returns (uint256 sharesOut) {
        (,,,,, address collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            sharesOut = isYes
                ? PAMM.buyYes{value: collateralIn}(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, 0
                )
                : PAMM.buyNo{value: collateralIn}(
                    marketId, collateralIn, minSharesOut, 0, feeOrHook, to, 0
                );
        } else {
            _ensureApproval(collateral, address(PAMM));
            sharesOut = isYes
                ? PAMM.buyYes(marketId, collateralIn, minSharesOut, 0, feeOrHook, to, 0)
                : PAMM.buyNo(marketId, collateralIn, minSharesOut, 0, feeOrHook, to, 0);
        }
    }

    /// @notice Split collateral and swap one side for leveraged position
    /// @dev Example: 100 collateral → 100 YES + 100 NO → swap NO for more YES → end with ~195 YES
    function _splitAndSwap(
        uint256 marketId,
        uint256 collateralIn,
        SplitAndSwapParams memory params,
        uint256 feeOrHook,
        address to
    ) internal returns (uint256 sharesOut) {
        (,,,,, address collateral,) = PAMM.markets(marketId);

        // Split collateral into YES + NO
        _ensureApproval(collateral, address(PAMM));
        PAMM.split(marketId, collateralIn, address(this));

        // Determine which side to swap
        uint256 yesId = marketId;
        uint256 noId = PAMM.getNoId(marketId);
        uint256 tokenToSwap = params.keepYes ? noId : yesId;
        uint256 tokenToKeep = params.keepYes ? yesId : noId;

        // Swap the unwanted side via ZAMM or PMRouter
        if (params.usePMRouter && address(PM_ROUTER) != address(0) && params.orderHashes.length > 0) {
            // Route through PMRouter for limit orders
            _ensureApprovalPAMM();
            sharesOut = PM_ROUTER.fillOrdersThenSwap(
                marketId,
                !params.keepYes, // opposite of what we're keeping
                false, // isSell
                collateralIn, // we have this many shares to sell
                params.minSharesOut,
                params.orderHashes,
                feeOrHook,
                address(this),
                0
            );
        } else {
            // Swap on ZAMM
            ZAMM.deposit(address(PAMM), tokenToSwap, collateralIn);

            IZAMM.PoolKey memory key = _buildPoolKey(yesId, noId, feeOrHook);
            bool zeroForOne = key.id0 == tokenToSwap;

            sharesOut = ZAMM.swapExactIn(
                key, collateralIn, params.minSharesOut, zeroForOne, address(this), block.timestamp
            );
            ZAMM.recoverTransientBalance(address(PAMM), tokenToSwap, address(this));
        }

        // Transfer total shares to user (kept shares + swapped shares)
        uint256 keptShares = PAMM.balanceOf(address(this), tokenToKeep);
        PAMM.transfer(to, tokenToKeep, keptShares);

        sharesOut = keptShares; // Total shares in the side we're keeping
    }

    /// @notice Build ZAMM pool key with proper token ordering
    function _buildPoolKey(uint256 id0, uint256 id1, uint256 feeOrHook)
        internal
        pure
        returns (IZAMM.PoolKey memory key)
    {
        address pamm = address(PAMM);
        if (id0 < id1) {
            key = IZAMM.PoolKey({
                id0: id0,
                id1: id1,
                token0: pamm,
                token1: pamm,
                feeOrHook: feeOrHook
            });
        } else {
            key = IZAMM.PoolKey({
                id0: id1,
                id1: id0,
                token0: pamm,
                token1: pamm,
                feeOrHook: feeOrHook
            });
        }
    }

    /// @notice Get pool ID from pool key
    function _getPoolId(IZAMM.PoolKey memory key) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));
    }

    /// @notice Ensure PAMM has operator approval
    function _ensureApprovalPAMM() internal {
        if (!PAMM.isOperator(address(this), address(PAMM))) {
            PAMM.setOperator(address(PAMM), true);
        }
    }

    /// @notice Get available sell orders from orderbook
    /// @dev Placeholder - would need PMRouter interface expansion
    function _getAvailableSellOrders(uint256 marketId, bool isYes, uint256 collateralIn)
        internal
        view
        returns (bytes32[] memory orders, uint256 availableShares)
    {
        // Return empty for now - PMRouter would need getActiveOrders view function
        orders = new bytes32[](0);
        availableShares = 0;
    }

    /// @notice Get available buy orders from orderbook
    /// @dev Placeholder - would need PMRouter interface expansion
    function _getAvailableBuyOrders(uint256 marketId, bool isYes, uint256 sharesIn)
        internal
        view
        returns (bytes32[] memory orders, uint256 availableCollateral)
    {
        // Return empty for now - PMRouter would need getActiveOrders view function
        orders = new bytes32[](0);
        availableCollateral = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            TOKEN HELPERS
                            //////////////////////////////////////////////////////////////*/

    /// @dev Transfer ERC20 tokens from sender
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x60, amount)
            mstore(0x40, to)
            mstore(0x2c, shl(96, from))
            mstore(0x0c, 0x23b872dd000000000000000000000000)
            let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, 0x7939f424) // TransferFromFailed()
                    revert(0x1c, 0x04)
                }
            }
            mstore(0x60, 0)
            mstore(0x40, m)
        }
    }

    /// @dev Ensure max approval for spender
    function _ensureApproval(address token, address spender) internal {
        assembly ("memory-safe") {
            mstore(0x00, 0xdd62ed3e000000000000000000000000)
            mstore(0x14, address())
            mstore(0x34, spender)
            let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(success, gt(mload(0x00), 0xffffffffffffffffffffffffffffffff))) {
                mstore(0x14, spender)
                mstore(0x34, not(0))
                mstore(0x00, 0x095ea7b3000000000000000000000000)
                success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                        mstore(0x00, 0x3e3f8f73) // ApproveFailed()
                        revert(0x1c, 0x04)
                    }
                }
            }
            mstore(0x34, 0)
        }
    }
}

/*//////////////////////////////////////////////////////////////
                            INTERFACES
                        //////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function deposit(address token, uint256 id, uint256 amount) external payable;

    function swap(
        PoolKey calldata poolKey,
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external payable;

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function removeLiquidity(
        PoolKey calldata poolKey,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount);

    function balanceOf(address owner, uint256 poolId) external view returns (uint256);

    function transfer(address to, uint256 poolId, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 poolId, uint256 amount)
        external
        returns (bool);

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

    function poolKey(uint256 marketId, uint256 feeOrHook) external view returns (PoolKey memory);
}

interface IPAMM {
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

    function getNoId(uint256 marketId) external pure returns (uint256);

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);

    function setOperator(address operator, bool approved) external returns (bool);

    function buyYes(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minYesOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 yesOut);

    function buyNo(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minNoOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 noOut);

    function sellYes(
        uint256 marketId,
        uint256 yesAmount,
        uint256 swapAmount,
        uint256 minCollateralOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external returns (uint256 collateralOut);

    function sellNo(
        uint256 marketId,
        uint256 noAmount,
        uint256 swapAmount,
        uint256 minCollateralOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external returns (uint256 collateralOut);

    function split(uint256 marketId, uint256 amount, address to) external payable;

    function merge(uint256 marketId, uint256 amount, address to) external;

    function claim(uint256 marketId, address to) external returns (uint256 payout);

    function balanceOf(address owner, uint256 id) external view returns (uint256);

    function isOperator(address owner, address operator) external view returns (bool);

    function poolKey(uint256 marketId, uint256 feeOrHook)
        external
        view
        returns (IZAMM.PoolKey memory);
}

interface IPMRouter {
    function fillOrdersThenSwap(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint256 totalAmount,
        uint256 minOutput,
        bytes32[] calldata orderHashes,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 totalOutput);
}

/// @notice Interface for custom flash swap callbacks
/// @dev Users implement this interface in their callback contract
///      The router will call executeFlashCallback during flash swap execution
interface IFlashCallback {
    /// @notice Execute custom logic during flash swap callback
    /// @param sender Original flash swap initiator (msg.sender from flashSwap call)
    /// @param yesId YES token ID for the market
    /// @param noId NO token ID for the market
    /// @param amount0 Amount of token0 borrowed (YES shares)
    /// @param amount1 Amount of token1 borrowed (NO shares)
    /// @param params Custom parameters passed from flashSwap call
    /// @dev This function MUST ensure the router has enough shares to repay ZAMM
    ///      Failure to do so will cause the flash swap to revert
    ///      The callback can transfer borrowed shares, swap them, use them in other protocols, etc.
    ///      Any profit should be sent back to 'sender' or handled as specified in params
    function executeFlashCallback(
        address sender,
        uint256 yesId,
        uint256 noId,
        uint256 amount0,
        uint256 amount1,
        bytes calldata params
    ) external;
}
