#!/bin/bash

# E2E Test Script for Encrypted Swaps
# This script orchestrates the full deployment and testing flow

set -e  # Exit on error

echo "🧪 Starting E2E Test for Encrypted Swaps"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if anvil is running
echo "Checking if Anvil is running..."
if ! nc -z localhost 8545 2>/dev/null; then
    echo -e "${RED}❌ Anvil is not running. Starting Anvil...${NC}"
    anvil --chain-id 31337 &
    ANVIL_PID=$!
    sleep 3
else
    echo -e "${GREEN}✅ Anvil is running${NC}"
fi

# Step 1: Deploy AVS contracts (includes CoFHE setup)
echo ""
echo -e "${YELLOW}Step 1: Deploying AVS contracts with npm run deploy:all...${NC}"
cd hello-world-avs

# This deploys AVS contracts, MockPrivacyHook, and sets up CoFHE
npm run deploy:all

cd ..

# Step 2: Deploy Universal Privacy Hook contracts
echo ""
echo -e "${YELLOW}Step 2: Deploying Universal Privacy Hook contracts...${NC}"
cd universal-privacy-hook

# Check if contracts are compiled
if [ ! -d "out" ]; then
    echo "Compiling contracts..."
    forge build --via-ir
fi

# Create deployments directory if it doesn't exist
mkdir -p deployments
# Create empty latest.json to avoid permission issues
echo "{}" > deployments/latest.json

# Deploy using the script with proper hook mining and save output
DEPLOY_OUTPUT=$(forge script script/DeployUniversalPrivacyHook.s.sol:DeployUniversalPrivacyHook \
    --rpc-url http://localhost:8545 \
    --broadcast \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 2>&1)

echo "$DEPLOY_OUTPUT"

# Parse and save deployment addresses from output
echo "$DEPLOY_OUTPUT" | node save-deployment.js

# Verify the deployment file was created
if [ -f "deployments/latest.json" ]; then
    echo "Deployment addresses saved to deployments/latest.json"
    cat deployments/latest.json
else
    echo "Warning: Could not save deployment addresses"
    exit 1
fi

cd ..

# Step 3: Connect UniversalPrivacyHook to AVS
echo ""
echo -e "${YELLOW}Step 3: Connecting UniversalPrivacyHook to AVS...${NC}"
cd hello-world-avs

# Authorize the UniversalPrivacyHook in SwapManager
node -e "
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

async function authorizeHook() {
    const provider = new ethers.JsonRpcProvider('http://localhost:8545');
    const wallet = new ethers.Wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', provider);

    // Load addresses
    const swapManagerData = JSON.parse(fs.readFileSync('./contracts/deployments/swap-manager/31337.json', 'utf8'));
    const hookData = JSON.parse(fs.readFileSync('../universal-privacy-hook/deployments/latest.json', 'utf8'));

    const swapManagerABI = JSON.parse(fs.readFileSync('./abis/SwapManager.json', 'utf8'));
    const swapManager = new ethers.Contract(swapManagerData.addresses.SwapManager, swapManagerABI, wallet);

    console.log('Authorizing UniversalPrivacyHook:', hookData.universalPrivacyHook);
    const tx = await swapManager.authorizeHook(hookData.universalPrivacyHook);
    await tx.wait();
    console.log('✅ UniversalPrivacyHook authorized');
}

authorizeHook().catch(console.error);
"

# Step 4: Check if operator is running, or wait for manual start
echo ""
echo -e "${YELLOW}Step 4: Checking operator status...${NC}"

# Check if operator is already running
if ps aux | grep -E "operator/index.ts" | grep -v grep > /dev/null; then
    echo -e "${GREEN}✅ Operator is already running${NC}"
else
    echo -e "${YELLOW}⚠️  Operator is not running${NC}"
    echo ""
    echo -e "${YELLOW}Please start the operator in a separate terminal:${NC}"
    echo -e "${GREEN}  cd hello-world-avs${NC}"
    echo -e "${GREEN}  npm run start:operator${NC}"
    echo ""
    echo "Press Enter when the operator is running..."
    read -r

    # Verify operator started
    if ps aux | grep -E "operator/index.ts" | grep -v grep > /dev/null; then
        echo -e "${GREEN}✅ Operator detected and running${NC}"
    else
        echo -e "${RED}❌ Operator still not detected. Continuing anyway...${NC}"
    fi
fi

sleep 5

cd ..

# Step 5: Run the integration test
echo ""
echo -e "${YELLOW}Step 5: Running integration test...${NC}"

# Run the integration test
node test-integration.js


# Cleanup
echo ""
echo -e "${YELLOW}Cleaning up...${NC}"

# Note: Not stopping operator since it's managed manually
echo "Note: Operator is running in a separate terminal and will continue running"

if [ ! -z "$ANVIL_PID" ]; then
    echo "Stopping Anvil..."
    kill $ANVIL_PID 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}✅ E2E Test Complete!${NC}"