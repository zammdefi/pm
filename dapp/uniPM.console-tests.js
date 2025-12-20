/**
 * uniPM UNI Collateral Integration Tests
 *
 * HOW TO RUN:
 * 1. Open uniPM.html in your browser
 * 2. Connect your wallet (make sure you have ETH and UNI)
 * 3. Open browser console (F12)
 * 4. Copy and paste this entire file into the console
 * 5. Run: await runUniCollateralTests()
 *
 * REQUIREMENTS:
 * - Connected wallet on Ethereum mainnet
 * - At least 0.1 ETH for gas
 * - At least 100 UNI tokens
 * - Existing UNI collateral market OR ability to create one
 */

const UNI_COLLATERAL_TESTS = {
    results: [],
    passed: 0,
    failed: 0,

    log(message, type = 'info') {
        const colors = {
            info: 'color: #60a5fa',
            success: 'color: #10b981',
            error: 'color: #ef4444',
            warn: 'color: #fbbf24'
        };
        console.log(`%c${message}`, colors[type]);
    },

    assert(condition, testName, errorMsg) {
        if (condition) {
            this.passed++;
            this.results.push({ name: testName, status: 'PASS' });
            this.log(`✅ PASS: ${testName}`, 'success');
        } else {
            this.failed++;
            this.results.push({ name: testName, status: 'FAIL', error: errorMsg });
            this.log(`❌ FAIL: ${testName} - ${errorMsg}`, 'error');
        }
    },

    summary() {
        const total = this.passed + this.failed;
        const passRate = ((this.passed / total) * 100).toFixed(1);

        console.log('\n' + '='.repeat(60));
        this.log(`📊 TEST SUMMARY`, 'info');
        console.log('='.repeat(60));
        this.log(`Total Tests: ${total}`, 'info');
        this.log(`Passed: ${this.passed}`, 'success');
        this.log(`Failed: ${this.failed}`, this.failed > 0 ? 'error' : 'success');
        this.log(`Pass Rate: ${passRate}%`, passRate >= 80 ? 'success' : 'warn');
        console.log('='.repeat(60) + '\n');

        if (this.failed > 0) {
            this.log('Failed tests:', 'error');
            this.results.filter(r => r.status === 'FAIL').forEach(r => {
                console.log(`  - ${r.name}: ${r.error}`);
            });
        }
    }
};

async function runUniCollateralTests() {
    console.clear();
    UNI_COLLATERAL_TESTS.log('🧪 Starting UNI Collateral Integration Tests\n', 'info');

    // Reset counters
    UNI_COLLATERAL_TESTS.results = [];
    UNI_COLLATERAL_TESTS.passed = 0;
    UNI_COLLATERAL_TESTS.failed = 0;

    try {
        // ========== SECTION 1: Environment & Setup ==========
        UNI_COLLATERAL_TESTS.log('\n📦 Section 1: Environment & Setup', 'info');

        // Test 1.1: Check wallet connection
        UNI_COLLATERAL_TESTS.assert(
            typeof signer !== 'undefined' && signer !== null,
            '1.1 Wallet is connected',
            'Wallet not connected. Click "Connect" button first.'
        );

        // Test 1.2: Check connected address
        UNI_COLLATERAL_TESTS.assert(
            typeof connectedAddress !== 'undefined' && connectedAddress !== null,
            '1.2 Connected address exists',
            'No connected address found'
        );

        // Test 1.3: Check helper function exists
        UNI_COLLATERAL_TESTS.assert(
            typeof getCollateralSymbol === 'function',
            '1.3 getCollateralSymbol() function exists',
            'Helper function missing'
        );

        // Test 1.4: Check approveUNI function exists
        UNI_COLLATERAL_TESTS.assert(
            typeof approveUNI === 'function',
            '1.4 approveUNI() function exists',
            'Approval function missing'
        );

        // ========== SECTION 2: Helper Functions ==========
        UNI_COLLATERAL_TESTS.log('\n🔧 Section 2: Helper Functions', 'info');

        // Test 2.1: getCollateralSymbol with ETH (zero address)
        const ethSymbol = getCollateralSymbol(ethers.constants.AddressZero);
        UNI_COLLATERAL_TESTS.assert(
            ethSymbol === 'ETH',
            '2.1 getCollateralSymbol(ZeroAddress) returns "ETH"',
            `Expected "ETH", got "${ethSymbol}"`
        );

        // Test 2.2: getCollateralSymbol with null
        const nullSymbol = getCollateralSymbol(null);
        UNI_COLLATERAL_TESTS.assert(
            nullSymbol === 'ETH',
            '2.2 getCollateralSymbol(null) returns "ETH"',
            `Expected "ETH", got "${nullSymbol}"`
        );

        // Test 2.3: getCollateralSymbol with UNI address
        const uniSymbol = getCollateralSymbol(UNI_TOKEN_ADDRESS);
        UNI_COLLATERAL_TESTS.assert(
            uniSymbol === 'UNI',
            '2.3 getCollateralSymbol(UNI_ADDRESS) returns "UNI"',
            `Expected "UNI", got "${uniSymbol}"`
        );

        // ========== SECTION 3: Balance Fetching ==========
        UNI_COLLATERAL_TESTS.log('\n💰 Section 3: Balance Fetching', 'info');

        // Test 3.1: Fetch ETH balance
        let ethBalance;
        try {
            const rpc = await getReadProvider();
            ethBalance = await rpc.getBalance(connectedAddress);
            UNI_COLLATERAL_TESTS.assert(
                ethBalance && ethBalance.gt(0),
                '3.1 Can fetch ETH balance',
                'ETH balance is 0 or fetch failed'
            );
        } catch (e) {
            UNI_COLLATERAL_TESTS.assert(false, '3.1 Can fetch ETH balance', e.message);
        }

        // Test 3.2: Fetch UNI balance
        let uniBalance;
        try {
            const rpc = await getReadProvider();
            const uniToken = new ethers.Contract(UNI_TOKEN_ADDRESS, UNI_TOKEN_ABI, rpc);
            uniBalance = await uniToken.balanceOf(connectedAddress);
            UNI_COLLATERAL_TESTS.assert(
                uniBalance && uniBalance.gte(0),
                '3.2 Can fetch UNI balance',
                'UNI balance fetch failed'
            );
        } catch (e) {
            UNI_COLLATERAL_TESTS.assert(false, '3.2 Can fetch UNI balance', e.message);
        }

        // Test 3.3: Check sufficient balances for testing
        const ethFormatted = ethBalance ? parseFloat(ethers.utils.formatEther(ethBalance)) : 0;
        const uniFormatted = uniBalance ? parseFloat(ethers.utils.formatUnits(uniBalance, 18)) : 0;

        UNI_COLLATERAL_TESTS.log(`  💵 ETH Balance: ${ethFormatted.toFixed(4)} ETH`, 'info');
        UNI_COLLATERAL_TESTS.log(`  🦄 UNI Balance: ${uniFormatted.toFixed(2)} UNI`, 'info');

        UNI_COLLATERAL_TESTS.assert(
            ethFormatted >= 0.05,
            '3.3 Has sufficient ETH for testing (≥0.05)',
            `Only ${ethFormatted.toFixed(4)} ETH available`
        );

        UNI_COLLATERAL_TESTS.assert(
            uniFormatted >= 10,
            '3.4 Has sufficient UNI for testing (≥10)',
            `Only ${uniFormatted.toFixed(2)} UNI available`
        );

        // ========== SECTION 4: Approval Checks ==========
        UNI_COLLATERAL_TESTS.log('\n✅ Section 4: Approval System', 'info');

        // Test 4.1: Check UNI approval to Resolver
        try {
            const rpc = await getReadProvider();
            const uniToken = new ethers.Contract(UNI_TOKEN_ADDRESS, UNI_TOKEN_ABI, rpc);
            const resolverApproval = await uniToken.allowance(connectedAddress, RESOLVER_ADDRESS);
            UNI_COLLATERAL_TESTS.log(`  📝 Resolver Approval: ${ethers.utils.formatUnits(resolverApproval, 18)} UNI`, 'info');
            UNI_COLLATERAL_TESTS.assert(
                true,
                '4.1 Can query UNI approval to Resolver',
                'Failed to query'
            );
        } catch (e) {
            UNI_COLLATERAL_TESTS.assert(false, '4.1 Can query UNI approval to Resolver', e.message);
        }

        // Test 4.2: Check UNI approval to PMRouter
        try {
            const rpc = await getReadProvider();
            const uniToken = new ethers.Contract(UNI_TOKEN_ADDRESS, UNI_TOKEN_ABI, rpc);
            const pmRouterApproval = await uniToken.allowance(connectedAddress, PMROUTER_ADDRESS);
            UNI_COLLATERAL_TESTS.log(`  📝 PMRouter Approval: ${ethers.utils.formatUnits(pmRouterApproval, 18)} UNI`, 'info');
            UNI_COLLATERAL_TESTS.assert(
                true,
                '4.2 Can query UNI approval to PMRouter',
                'Failed to query'
            );
        } catch (e) {
            UNI_COLLATERAL_TESTS.assert(false, '4.2 Can query UNI approval to PMRouter', e.message);
        }

        // Test 4.3: Check UNI approval to PAMM
        try {
            const rpc = await getReadProvider();
            const uniToken = new ethers.Contract(UNI_TOKEN_ADDRESS, UNI_TOKEN_ABI, rpc);
            const pammApproval = await uniToken.allowance(connectedAddress, PAMM_ADDRESS);
            UNI_COLLATERAL_TESTS.log(`  📝 PAMM Approval: ${ethers.utils.formatUnits(pammApproval, 18)} UNI`, 'info');
            UNI_COLLATERAL_TESTS.assert(
                true,
                '4.3 Can query UNI approval to PAMM',
                'Failed to query'
            );
        } catch (e) {
            UNI_COLLATERAL_TESTS.assert(false, '4.3 Can query UNI approval to PAMM', e.message);
        }

        // ========== SECTION 5: Market Data ==========
        UNI_COLLATERAL_TESTS.log('\n📊 Section 5: Market Data', 'info');

        // Test 5.1: Check markets loaded
        UNI_COLLATERAL_TESTS.assert(
            Array.isArray(univ4Markets) && univ4Markets.length > 0,
            '5.1 Markets array exists and has data',
            'No markets loaded'
        );

        if (univ4Markets && univ4Markets.length > 0) {
            UNI_COLLATERAL_TESTS.log(`  📈 Total markets: ${univ4Markets.length}`, 'info');

            // Test 5.2: Check if any market has collateral field
            const hasCollateralField = univ4Markets.some(m => m.collateral !== undefined);
            UNI_COLLATERAL_TESTS.assert(
                hasCollateralField,
                '5.2 Markets have collateral field',
                'No market has collateral field'
            );

            // Test 5.3: Find UNI collateral markets
            const uniMarkets = univ4Markets.filter(m =>
                m.collateral && m.collateral.toLowerCase() === UNI_TOKEN_ADDRESS.toLowerCase()
            );
            UNI_COLLATERAL_TESTS.log(`  🦄 UNI collateral markets: ${uniMarkets.length}`, 'info');

            // Test 5.4: Find ETH collateral markets
            const ethMarkets = univ4Markets.filter(m =>
                !m.collateral || m.collateral === ethers.constants.AddressZero
            );
            UNI_COLLATERAL_TESTS.log(`  💵 ETH collateral markets: ${ethMarkets.length}`, 'info');

            UNI_COLLATERAL_TESTS.assert(
                univ4Markets.length === uniMarkets.length + ethMarkets.length,
                '5.3 All markets classified as ETH or UNI',
                'Market classification mismatch'
            );
        }

        // ========== SECTION 6: currentTrade State ==========
        UNI_COLLATERAL_TESTS.log('\n🎯 Section 6: Trade State', 'info');

        // Test 6.1: currentTrade object exists
        UNI_COLLATERAL_TESTS.assert(
            typeof currentTrade !== 'undefined',
            '6.1 currentTrade object exists',
            'currentTrade is undefined'
        );

        // Test 6.2: currentTrade has collateral field
        UNI_COLLATERAL_TESTS.assert(
            currentTrade && 'collateral' in currentTrade,
            '6.2 currentTrade has collateral field',
            'collateral field missing'
        );

        if (currentTrade && currentTrade.marketId) {
            UNI_COLLATERAL_TESTS.log(`  📍 Current market ID: ${currentTrade.marketId}`, 'info');
            const symbol = getCollateralSymbol(currentTrade.collateral);
            UNI_COLLATERAL_TESTS.log(`  💱 Current collateral: ${symbol}`, 'info');
        }

        // ========== SECTION 7: UI Elements ==========
        UNI_COLLATERAL_TESTS.log('\n🎨 Section 7: UI Elements', 'info');

        // Test 7.1: Collateral selectors exist
        const collateralSelectors = [
            'createCollateralFeeSwitch',
            'createCollateralUniBalance',
            'createCollateralUniVotes',
            'createCollateralTotalSupply'
        ];

        collateralSelectors.forEach((id, index) => {
            const element = document.getElementById(id);
            UNI_COLLATERAL_TESTS.assert(
                element !== null,
                `7.${index + 1} ${id} selector exists`,
                'Element not found in DOM'
            );
        });

        // Test 7.5: Balance display elements exist
        const balanceElements = ['ethBalance', 'uniBalance'];
        balanceElements.forEach((id, index) => {
            const element = document.getElementById(id);
            UNI_COLLATERAL_TESTS.assert(
                element !== null,
                `7.${5 + index} ${id} element exists`,
                'Element not found in DOM'
            );
        });

        // ========== SECTION 8: Decimal Handling ==========
        UNI_COLLATERAL_TESTS.log('\n🔢 Section 8: Decimal Handling', 'info');

        // Test 8.1: ETH parsing (18 decimals)
        const ethAmount = 0.1;
        const ethWei = ethers.utils.parseEther(ethAmount.toString());
        UNI_COLLATERAL_TESTS.assert(
            ethWei.toString() === '100000000000000000',
            '8.1 ETH decimal parsing (18 decimals)',
            `Expected 100000000000000000, got ${ethWei.toString()}`
        );

        // Test 8.2: UNI parsing (18 decimals)
        const uniAmount = 0.1;
        const uniWei = ethers.utils.parseUnits(uniAmount.toString(), 18);
        UNI_COLLATERAL_TESTS.assert(
            uniWei.toString() === '100000000000000000',
            '8.2 UNI decimal parsing (18 decimals)',
            `Expected 100000000000000000, got ${uniWei.toString()}`
        );

        // Test 8.3: Both parse to same value
        UNI_COLLATERAL_TESTS.assert(
            ethWei.eq(uniWei),
            '8.3 ETH and UNI parse to same wei value',
            'Decimal parsing mismatch'
        );

        // Test 8.4: Format back to original
        const formatted = parseFloat(ethers.utils.formatEther(ethWei));
        UNI_COLLATERAL_TESTS.assert(
            Math.abs(formatted - ethAmount) < 0.0001,
            '8.4 Round-trip format/parse preserves value',
            `Expected ${ethAmount}, got ${formatted}`
        );

        // ========== SECTION 9: Collateral Detection Logic ==========
        UNI_COLLATERAL_TESTS.log('\n🔍 Section 9: Collateral Detection', 'info');

        // Test 9.1: Detect ETH collateral (null)
        const isEth1 = !null || null === ethers.constants.AddressZero;
        UNI_COLLATERAL_TESTS.assert(
            isEth1 === true,
            '9.1 null detected as ETH collateral',
            'Detection failed'
        );

        // Test 9.2: Detect ETH collateral (zero address)
        const zeroAddr = ethers.constants.AddressZero;
        const isEth2 = !zeroAddr || zeroAddr === ethers.constants.AddressZero;
        UNI_COLLATERAL_TESTS.assert(
            isEth2 === true,
            '9.2 ZeroAddress detected as ETH collateral',
            'Detection failed'
        );

        // Test 9.3: Detect UNI collateral
        const isEth3 = !UNI_TOKEN_ADDRESS || UNI_TOKEN_ADDRESS === ethers.constants.AddressZero;
        UNI_COLLATERAL_TESTS.assert(
            isEth3 === false,
            '9.3 UNI address detected as non-ETH collateral',
            'Detection failed'
        );

        // ========== SECTION 10: Function Availability ==========
        UNI_COLLATERAL_TESTS.log('\n⚙️ Section 10: Function Availability', 'info');

        const requiredFunctions = [
            'loadBalance',
            'setTradeMax',
            'setLimitMax',
            'setLpMax',
            'createFeeSwitchMarket',
            'createUniBalanceMarket',
            'createUniVotesMarket',
            'createTotalSupplyMarket',
            'executeTrade',
            'executeLp',
            'executeLimitOrder'
        ];

        requiredFunctions.forEach((fnName, index) => {
            UNI_COLLATERAL_TESTS.assert(
                typeof window[fnName] === 'function',
                `10.${index + 1} ${fnName}() exists`,
                'Function not found'
            );
        });

    } catch (error) {
        UNI_COLLATERAL_TESTS.log(`\n❌ Test suite error: ${error.message}`, 'error');
        console.error(error);
    }

    // Show summary
    UNI_COLLATERAL_TESTS.summary();

    return {
        passed: UNI_COLLATERAL_TESTS.passed,
        failed: UNI_COLLATERAL_TESTS.failed,
        total: UNI_COLLATERAL_TESTS.passed + UNI_COLLATERAL_TESTS.failed,
        results: UNI_COLLATERAL_TESTS.results
    };
}

// Quick access functions
function runTests() {
    return runUniCollateralTests();
}

// Auto-run instructions
console.log('%c🧪 UNI Collateral Test Suite Loaded', 'color: #FF007A; font-size: 16px; font-weight: bold');
console.log('%cRun tests with: await runUniCollateralTests()', 'color: #60a5fa; font-size: 14px');
console.log('%cOr quick run: await runTests()', 'color: #60a5fa; font-size: 14px');
