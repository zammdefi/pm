/**
 * Chainlink Oracle Integration Test Suite
 *
 * This test suite verifies the Chainlink UNI/USD oracle integration
 * for prediction markets. Tests can be run in the browser console
 * after loading uniPM.html.
 *
 * Usage:
 * 1. Open uniPM.html in browser
 * 2. Open browser console (F12)
 * 3. Copy and paste this entire file
 * 4. Run: await runChainlinkTests()
 */

// ======================== TEST FRAMEWORK ========================

let testsPassed = 0;
let testsFailed = 0;
const failedTests = [];

function assert(condition, message) {
    if (!condition) {
        throw new Error(`Assertion failed: ${message}`);
    }
}

function assertEqual(actual, expected, message) {
    if (actual !== expected) {
        throw new Error(`${message}\n  Expected: ${expected}\n  Actual: ${actual}`);
    }
}

async function runTest(category, testName, testFn) {
    try {
        await testFn();
        testsPassed++;
        console.log(`✅ [${category}] ${testName}`);
        return true;
    } catch (error) {
        testsFailed++;
        const failInfo = {
            category,
            name: testName,
            error: error.message
        };
        failedTests.push(failInfo);
        console.error(`❌ [${category}] ${testName}\n   ${error.message}`);
        return false;
    }
}

// ======================== ORACLE CONSTANT TESTS ========================

async function runOracleConstantTests() {
    console.log('\n🧪 Testing Oracle Constants...');

    await runTest('Constants', 'CHAINLINK_UNI_USD_ORACLE address is defined', async () => {
        assert(typeof CHAINLINK_UNI_USD_ORACLE !== 'undefined', 'Oracle address should be defined');
        assertEqual(
            CHAINLINK_UNI_USD_ORACLE.toLowerCase(),
            '0x553303d460EE0afB37EdFf9bE42922D8FF63220e'.toLowerCase(),
            'Oracle address should match expected value'
        );
    });

    await runTest('Constants', 'LATEST_ANSWER_SELECTOR is correct', async () => {
        assert(typeof LATEST_ANSWER_SELECTOR !== 'undefined', 'Selector should be defined');
        assertEqual(
            LATEST_ANSWER_SELECTOR.toLowerCase(),
            '0x50d25bcd',
            'latestAnswer() selector should be 0x50d25bcd'
        );
    });

    await runTest('Constants', 'Function selector calculation is correct', async () => {
        // Verify the selector matches keccak256('latestAnswer()')[:4]
        const expectedSelector = '0x50d25bcd';
        assertEqual(
            LATEST_ANSWER_SELECTOR.toLowerCase(),
            expectedSelector,
            'Selector should match keccak256 hash of latestAnswer()'
        );
    });

    await runTest('Constants', 'UNI_PRICE_USD market type exists', async () => {
        assert(typeof MARKET_TYPE !== 'undefined', 'MARKET_TYPE should be defined');
        assert(typeof MARKET_TYPE.UNI_PRICE_USD !== 'undefined', 'UNI_PRICE_USD type should exist');
        assertEqual(
            MARKET_TYPE.UNI_PRICE_USD,
            'UNI_PRICE_USD',
            'Market type value should be correct'
        );
    });
}

// ======================== PRICE FORMATTING TESTS ========================

async function runPriceFormattingTests() {
    console.log('\n🧪 Testing Price Formatting...');

    await runTest('Formatting', 'formatOraclePrice() handles 8 decimals correctly', async () => {
        assert(typeof formatOraclePrice === 'function', 'formatOraclePrice should be defined');

        // Test case 1: $6.19655811
        const price1 = formatOraclePrice(619655811n);
        assertEqual(price1, '6.20', 'Should format 619655811 as $6.20');

        // Test case 2: $10.00
        const price2 = formatOraclePrice(1000000000n);
        assertEqual(price2, '10.00', 'Should format 1000000000 as $10.00');

        // Test case 3: $15.50
        const price3 = formatOraclePrice(1550000000n);
        assertEqual(price3, '15.50', 'Should format 1550000000 as $15.50');

        // Test case 4: $5.00
        const price4 = formatOraclePrice(500000000n);
        assertEqual(price4, '5.00', 'Should format 500000000 as $5.00');
    });

    await runTest('Formatting', 'usdToOracleThreshold() converts USD to 8 decimals', async () => {
        assert(typeof usdToOracleThreshold === 'function', 'usdToOracleThreshold should be defined');

        // Test case 1: $10.00
        const threshold1 = usdToOracleThreshold(10.00);
        assertEqual(threshold1, 1000000000n, 'Should convert $10.00 to 1000000000');

        // Test case 2: $5.50
        const threshold2 = usdToOracleThreshold(5.50);
        assertEqual(threshold2, 550000000n, 'Should convert $5.50 to 550000000');

        // Test case 3: $15.99
        const threshold3 = usdToOracleThreshold(15.99);
        assertEqual(threshold3, 1599000000n, 'Should convert $15.99 to 1599000000');
    });

    await runTest('Formatting', 'Round-trip conversion is consistent', async () => {
        const originalUSD = 12.34;
        const threshold = usdToOracleThreshold(originalUSD);
        const roundTrip = formatOraclePrice(threshold);
        assertEqual(roundTrip, originalUSD.toFixed(2), 'Round-trip conversion should match');
    });

    await runTest('Formatting', 'Handles edge cases', async () => {
        // Very small price
        const small = formatOraclePrice(100000n); // $0.001
        assertEqual(small, '0.00', 'Should handle very small prices');

        // Large price
        const large = formatOraclePrice(10000000000n); // $100.00
        assertEqual(large, '100.00', 'Should handle large prices');
    });
}

// ======================== MARKET TYPE DETECTION TESTS ========================

async function runMarketTypeDetectionTests() {
    console.log('\n🧪 Testing Market Type Detection...');

    await runTest('Detection', 'detectMarketType() identifies UNI_PRICE_USD markets', async () => {
        assert(typeof detectMarketType === 'function', 'detectMarketType should be defined');

        const condition = {
            targetA: CHAINLINK_UNI_USD_ORACLE,
            callDataA: LATEST_ANSWER_SELECTOR,
            threshold: 1000000000n,
            op: 3 // GTE
        };

        const marketType = detectMarketType(condition);
        assertEqual(
            marketType,
            MARKET_TYPE.UNI_PRICE_USD,
            'Should detect UNI_PRICE_USD market type'
        );
    });

    await runTest('Detection', 'Case-insensitive address matching', async () => {
        const condition = {
            targetA: CHAINLINK_UNI_USD_ORACLE.toUpperCase(),
            callDataA: LATEST_ANSWER_SELECTOR.toLowerCase(),
            threshold: 1000000000n,
            op: 3
        };

        const marketType = detectMarketType(condition);
        assertEqual(
            marketType,
            MARKET_TYPE.UNI_PRICE_USD,
            'Should match addresses case-insensitively'
        );
    });

    await runTest('Detection', 'Rejects wrong oracle address', async () => {
        const condition = {
            targetA: '0x0000000000000000000000000000000000000000',
            callDataA: LATEST_ANSWER_SELECTOR,
            threshold: 1000000000n,
            op: 3
        };

        const marketType = detectMarketType(condition);
        assert(
            marketType !== MARKET_TYPE.UNI_PRICE_USD,
            'Should not detect UNI_PRICE_USD with wrong address'
        );
    });

    await runTest('Detection', 'Rejects wrong function selector', async () => {
        const condition = {
            targetA: CHAINLINK_UNI_USD_ORACLE,
            callDataA: '0x12345678', // Wrong selector
            threshold: 1000000000n,
            op: 3
        };

        const marketType = detectMarketType(condition);
        assert(
            marketType !== MARKET_TYPE.UNI_PRICE_USD,
            'Should not detect UNI_PRICE_USD with wrong selector'
        );
    });
}

// ======================== MARKET DESCRIPTION TESTS ========================

async function runMarketDescriptionTests() {
    console.log('\n🧪 Testing Market Descriptions...');

    await runTest('Description', 'getMarketTypeLabel() returns UNI-PRICE', async () => {
        assert(typeof getMarketTypeLabel === 'function', 'getMarketTypeLabel should be defined');

        const label = getMarketTypeLabel(MARKET_TYPE.UNI_PRICE_USD);
        assertEqual(label, 'UNI-PRICE', 'Should return UNI-PRICE label');
    });

    await runTest('Description', 'getMarketTypeDescription() formats price correctly', async () => {
        assert(typeof getMarketTypeDescription === 'function', 'getMarketTypeDescription should be defined');

        const condition = {
            targetA: CHAINLINK_UNI_USD_ORACLE,
            callDataA: LATEST_ANSWER_SELECTOR,
            threshold: 1000000000n, // $10.00
            op: 3 // GTE
        };

        const description = getMarketTypeDescription(MARKET_TYPE.UNI_PRICE_USD, condition);
        assert(description.includes('$10.00'), 'Description should include $10.00');
        assert(description.includes('>='), 'Description should include >= operator');
    });

    await runTest('Description', 'Handles all operators correctly', async () => {
        const operators = [
            { op: 0, symbol: '<' },
            { op: 1, symbol: '>' },
            { op: 2, symbol: '<=' },
            { op: 3, symbol: '>=' }
        ];

        for (const { op, symbol } of operators) {
            const condition = {
                targetA: CHAINLINK_UNI_USD_ORACLE,
                callDataA: LATEST_ANSWER_SELECTOR,
                threshold: 1500000000n,
                op
            };

            const description = getMarketTypeDescription(MARKET_TYPE.UNI_PRICE_USD, condition);
            assert(
                description.includes(symbol),
                `Description should include ${symbol} for op=${op}`
            );
        }
    });
}

// ======================== UI ELEMENT TESTS ========================

async function runUIElementTests() {
    console.log('\n🧪 Testing UI Elements...');

    await runTest('UI', 'UNI Price tab button exists', async () => {
        const tab = document.getElementById('tabUniPrice');
        assert(tab !== null, 'UNI Price tab should exist');
        assert(tab.textContent.includes('UNI Price'), 'Tab should have correct label');
    });

    await runTest('UI', 'UNI Price creator card exists', async () => {
        const creator = document.getElementById('creatorUniPrice');
        assert(creator !== null, 'UNI Price creator should exist');
    });

    await runTest('UI', 'Current price display exists', async () => {
        const priceEl = document.getElementById('currentUniPrice');
        assert(priceEl !== null, 'Current price display should exist');
    });

    await runTest('UI', 'Target price input exists', async () => {
        const input = document.getElementById('createTargetPrice');
        assert(input !== null, 'Target price input should exist');
        assertEqual(input.type, 'number', 'Should be a number input');
    });

    await runTest('UI', 'Price operator selector exists', async () => {
        const select = document.getElementById('createPriceOperator');
        assert(select !== null, 'Operator selector should exist');
        assert(select.options.length >= 4, 'Should have at least 4 operator options');
    });

    await runTest('UI', 'Collateral selector exists', async () => {
        const select = document.getElementById('createCollateralUniPrice');
        assert(select !== null, 'Collateral selector should exist');
    });

    await runTest('UI', 'Preview element exists', async () => {
        const preview = document.getElementById('createPreviewUniPrice');
        assert(preview !== null, 'Preview element should exist');
    });
}

// ======================== FUNCTION AVAILABILITY TESTS ========================

async function runFunctionAvailabilityTests() {
    console.log('\n🧪 Testing Function Availability...');

    const requiredFunctions = [
        'formatOraclePrice',
        'usdToOracleThreshold',
        'fetchCurrentUniPrice',
        'fetchAndDisplayCurrentUniPrice',
        'updateUniPricePreview',
        'createUniPriceMarket',
        'detectMarketType',
        'getMarketTypeLabel',
        'getMarketTypeDescription',
        'switchMarketTab'
    ];

    for (const fnName of requiredFunctions) {
        await runTest('Functions', `${fnName}() is defined`, async () => {
            assert(
                typeof window[fnName] === 'function' || typeof eval(fnName) === 'function',
                `${fnName} should be a defined function`
            );
        });
    }
}

// ======================== ORACLE CONNECTIVITY TEST ========================

async function runOracleConnectivityTest() {
    console.log('\n🧪 Testing Oracle Connectivity...');

    await runTest('Oracle', 'fetchCurrentUniPrice() retrieves price', async () => {
        assert(typeof fetchCurrentUniPrice === 'function', 'fetchCurrentUniPrice should be defined');

        // Note: This test requires network connectivity
        try {
            const price = await fetchCurrentUniPrice();
            assert(price !== null, 'Should retrieve a price');
            assert(!isNaN(parseFloat(price)), 'Price should be a valid number');
            assert(parseFloat(price) > 0, 'Price should be positive');
            console.log(`   ℹ️  Current UNI price: $${price}`);
        } catch (error) {
            console.warn('   ⚠️  Skipping oracle connectivity test (network required)');
            throw new Error('Skip: Network connectivity required');
        }
    });
}

// ======================== INTEGRATION TESTS ========================

async function runIntegrationTests() {
    console.log('\n🧪 Testing Integration...');

    await runTest('Integration', 'switchMarketTab() activates UNI Price tab', async () => {
        assert(typeof switchMarketTab === 'function', 'switchMarketTab should be defined');

        // Switch to UNI Price tab
        switchMarketTab('uniPrice');

        const tab = document.getElementById('tabUniPrice');
        const creator = document.getElementById('creatorUniPrice');

        assert(tab.classList.contains('active'), 'Tab should be active');
        assert(
            creator.style.display === 'block' || !creator.style.display,
            'Creator should be visible'
        );
    });

    await runTest('Integration', 'updateUniPricePreview() updates preview text', async () => {
        // Set input values
        const targetInput = document.getElementById('createTargetPrice');
        const operatorSelect = document.getElementById('createPriceOperator');

        if (targetInput && operatorSelect) {
            targetInput.value = '12.50';
            operatorSelect.value = '3'; // GTE

            updateUniPricePreview();

            const preview = document.getElementById('createPreviewUniPrice');
            const previewText = preview.textContent;

            assert(previewText.includes('$12.50'), 'Preview should include target price');
            assert(previewText.includes('>='), 'Preview should include operator');
        }
    });
}

// ======================== MARKET CONFIGURATION TESTS ========================

async function runMarketConfigurationTests() {
    console.log('\n🧪 Testing Market Configuration...');

    await runTest('Config', 'Example: "UNI >= $10 by end of 2026" configuration', async () => {
        const targetPrice = 10.00;
        const operator = 3; // GTE
        const threshold = usdToOracleThreshold(targetPrice);

        assertEqual(threshold, 1000000000n, 'Threshold should be 1000000000');
        assertEqual(operator, 3, 'Operator should be GTE (3)');

        const config = {
            target: CHAINLINK_UNI_USD_ORACLE,
            callData: LATEST_ANSWER_SELECTOR,
            op: operator,
            threshold: threshold
        };

        const marketType = detectMarketType(config);
        assertEqual(marketType, MARKET_TYPE.UNI_PRICE_USD, 'Should be detected as UNI_PRICE_USD');

        const description = getMarketTypeDescription(marketType, config);
        assert(description.includes('$10.00'), 'Description should include $10.00');
        assert(description.includes('>='), 'Description should include >=');
    });

    await runTest('Config', 'Example: "UNI < $5 by Q2 2027" configuration', async () => {
        const targetPrice = 5.00;
        const operator = 0; // LT
        const threshold = usdToOracleThreshold(targetPrice);

        assertEqual(threshold, 500000000n, 'Threshold should be 500000000');

        const config = {
            target: CHAINLINK_UNI_USD_ORACLE,
            callData: LATEST_ANSWER_SELECTOR,
            op: operator,
            threshold: threshold
        };

        const description = getMarketTypeDescription(MARKET_TYPE.UNI_PRICE_USD, config);
        assert(description.includes('$5.00'), 'Description should include $5.00');
        assert(description.includes('<'), 'Description should include <');
    });

    await runTest('Config', 'Validates decimal precision', async () => {
        // Test that 8 decimal precision is maintained
        const prices = [6.19, 10.00, 15.50, 0.99, 99.99];

        for (const price of prices) {
            const threshold = usdToOracleThreshold(price);
            const roundTrip = formatOraclePrice(threshold);
            assertEqual(
                parseFloat(roundTrip),
                parseFloat(price.toFixed(2)),
                `Precision should be maintained for $${price}`
            );
        }
    });
}

// ======================== MAIN TEST RUNNER ========================

async function runChainlinkTests() {
    console.clear();
    console.log('═══════════════════════════════════════════════════════');
    console.log('🔗 Chainlink Oracle Integration Test Suite');
    console.log('═══════════════════════════════════════════════════════\n');

    testsPassed = 0;
    testsFailed = 0;
    failedTests.length = 0;

    const startTime = Date.now();

    // Run all test suites
    await runOracleConstantTests();
    await runPriceFormattingTests();
    await runMarketTypeDetectionTests();
    await runMarketDescriptionTests();
    await runUIElementTests();
    await runFunctionAvailabilityTests();
    await runOracleConnectivityTest();
    await runIntegrationTests();
    await runMarketConfigurationTests();

    const endTime = Date.now();
    const duration = ((endTime - startTime) / 1000).toFixed(2);

    // Print summary
    console.log('\n═══════════════════════════════════════════════════════');
    console.log('📊 Test Summary');
    console.log('═══════════════════════════════════════════════════════');
    console.log(`✅ Passed: ${testsPassed}`);
    console.log(`❌ Failed: ${testsFailed}`);
    console.log(`⏱️  Duration: ${duration}s`);
    console.log(`📈 Success Rate: ${((testsPassed / (testsPassed + testsFailed)) * 100).toFixed(1)}%`);

    if (failedTests.length > 0) {
        console.log('\n❌ Failed Tests:');
        failedTests.forEach(({ category, name, error }) => {
            console.log(`   [${category}] ${name}`);
            console.log(`   └─ ${error}`);
        });
    }

    console.log('\n═══════════════════════════════════════════════════════\n');

    return {
        passed: testsPassed,
        failed: testsFailed,
        total: testsPassed + testsFailed,
        duration,
        failedTests
    };
}

// Export for console usage
console.log('✅ Chainlink Oracle Test Suite loaded');
console.log('📝 Run tests with: await runChainlinkTests()');
