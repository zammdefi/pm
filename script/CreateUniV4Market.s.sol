// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {Resolver} from "../src/Resolver.sol";

/// @notice Script to create a Uniswap V4 fee switch prediction market
/// @dev Usage: forge script script/CreateUniV4Market.s.sol --rpc-url $RPC_URL --broadcast --verify
contract CreateUniV4Market is Script {
    // Mainnet addresses
    Resolver constant resolver = Resolver(payable(0x00000000002205020E387b6a378c05639047BcFB));
    address constant UNIV4 = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // Market parameters
    bytes4 constant SELECTOR = bytes4(keccak256("protocolFeeController()"));
    uint64 constant DEADLINE_2025 = 1767225599; // Year end 2025

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Creating UniV4 fee switch market...");
        console.log("Deployer:", deployer);
        console.log("Target contract:", UNIV4);
        console.log("Deadline:", DEADLINE_2025);

        vm.startBroadcast(deployerPrivateKey);

        // Example 1: Create market without initial liquidity
        (uint256 marketId1, uint256 noId1) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController()",
            address(0), // ETH collateral
            UNIV4,
            SELECTOR,
            Resolver.Op.NEQ, // != 0
            0, // threshold
            DEADLINE_2025,
            true // canClose early
        );

        console.log("\nMarket 1 (no seed) created:");
        console.log("Market ID:", marketId1);
        console.log("No ID:", noId1);

        // Example 2: Create market with initial liquidity (0.1 ETH)
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 0.1 ether,
            feeOrHook: 0, // No custom fee/hook
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: deployer,
            deadline: block.timestamp + 1 hours
        });

        (uint256 marketId2, uint256 noId2, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeedSimple{
            value: 0.1 ether
        }(
            "Uniswap V4 protocolFeeController()",
            address(0),
            UNIV4,
            SELECTOR,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true,
            seed
        );

        console.log("\nMarket 2 (with 0.1 ETH seed) created:");
        console.log("Market ID:", marketId2);
        console.log("No ID:", noId2);
        console.log("Shares:", shares);
        console.log("Liquidity:", liquidity);

        vm.stopBroadcast();

        console.log("\nMarkets created successfully!");
        console.log(
            "Users can now trade on whether Uniswap V4 will activate protocol fees by end of 2025"
        );
    }

    // Alternative: Create with custom parameters
    function createCustomMarket(uint64 customDeadline, uint256 seedAmount, bool withSeed) public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        if (withSeed) {
            Resolver.SeedParams memory seed = Resolver.SeedParams({
                collateralIn: seedAmount,
                feeOrHook: 0,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                lpRecipient: deployer,
                deadline: block.timestamp + 1 hours
            });

            resolver.createNumericMarketAndSeedSimple{value: seedAmount}(
                "Uniswap V4 protocolFeeController()",
                address(0),
                UNIV4,
                SELECTOR,
                Resolver.Op.NEQ,
                0,
                customDeadline,
                true,
                seed
            );
        } else {
            resolver.createNumericMarketSimple(
                "Uniswap V4 protocolFeeController()",
                address(0),
                UNIV4,
                SELECTOR,
                Resolver.Op.NEQ,
                0,
                customDeadline,
                true
            );
        }

        vm.stopBroadcast();
    }
}
