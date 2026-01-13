#!/bin/bash

# Script to check deployment bytecode size of PMHookRouter.sol
# This script uses Foundry's forge to compile and check bytecode size

set -e

echo "========================================="
echo "  PMHookRouter Bytecode Size Checker"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Maximum bytecode size (24KB as per EIP-170)
MAX_SIZE=24576

# Build the contract
echo -e "${BLUE}Compiling contract...${NC}"
forge build --sizes 2>/dev/null || forge build

# Get the bytecode size from the compiled artifact
ARTIFACT_PATH="out/PMHookRouter.sol/PMHookRouter.json"

if [ ! -f "$ARTIFACT_PATH" ]; then
    echo -e "${RED}Error: PMHookRouter artifact not found at $ARTIFACT_PATH${NC}"
    echo "Make sure the contract compiled successfully."
    exit 1
fi

# Extract deployed bytecode size (the actual deployed code)
DEPLOYED_BYTECODE=$(jq -r '.deployedBytecode.object' "$ARTIFACT_PATH")
DEPLOYED_SIZE=$((${#DEPLOYED_BYTECODE} / 2))

# Extract creation bytecode size (includes constructor)
CREATION_BYTECODE=$(jq -r '.bytecode.object' "$ARTIFACT_PATH")
CREATION_SIZE=$((${#CREATION_BYTECODE} / 2))

echo ""
echo "========================================="
echo -e "${BLUE}Bytecode Size Analysis${NC}"
echo "========================================="
echo ""
echo "Creation bytecode size:  $CREATION_SIZE bytes"
echo "Deployed bytecode size:  $DEPLOYED_SIZE bytes (this is what counts for EIP-170)"
echo ""
echo "Maximum allowed size:    $MAX_SIZE bytes (24 KB)"
echo "Size in KB:              $((DEPLOYED_SIZE / 1024)) KB"
echo "Remaining space:         $((MAX_SIZE - DEPLOYED_SIZE)) bytes"
echo "Usage percentage:        $((DEPLOYED_SIZE * 100 / MAX_SIZE))%"
echo ""

# Check if size exceeds limit
if [ $DEPLOYED_SIZE -gt $MAX_SIZE ]; then
    EXCEEDED=$((DEPLOYED_SIZE - MAX_SIZE))
    echo -e "${RED}❌ ERROR: Contract EXCEEDS maximum bytecode size!${NC}"
    echo -e "${RED}   Exceeds by: $EXCEEDED bytes${NC}"
    echo ""
    echo "Suggestions to reduce size:"
    echo "  - Increase optimizer runs in foundry.toml"
    echo "  - Split contract into multiple contracts"
    echo "  - Use external libraries"
    echo "  - Remove unused code"
    exit 1
else
    REMAINING=$((MAX_SIZE - DEPLOYED_SIZE))
    REMAINING_PERCENT=$((REMAINING * 100 / MAX_SIZE))
    echo -e "${GREEN}✓ SUCCESS: Contract is within bytecode size limit${NC}"
    echo -e "${GREEN}  Remaining capacity: $REMAINING bytes ($REMAINING_PERCENT%)${NC}"

    if [ $REMAINING -lt 2048 ]; then
        echo -e "${YELLOW}⚠ Warning: Less than 2KB remaining. Consider optimization.${NC}"
    fi
fi

echo ""
echo "========================================="
