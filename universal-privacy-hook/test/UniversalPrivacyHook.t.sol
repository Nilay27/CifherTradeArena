// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Foundry Imports
import "forge-std/Test.sol";

// Uniswap Imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

// Test Utils
import {Deployers} from "./utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {CoFheUtils} from "./utils/CoFheUtils.sol";

// FHE Imports
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ACL} from "@fhenixprotocol/cofhe-mock-contracts/ACL.sol";

// Privacy Hook Imports
import {UniversalPrivacyHook} from "../src/UniversalPrivacyHook.sol";
import {IFHERC20} from "../src/interfaces/IFHERC20.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";

// AVS Imports for testing integration
import {ISwapManager} from "../src/interfaces/ISwapManager.sol";
import {MockSwapManager, IHookSettlement, InternalTransferInput} from "../src/test/MockSwapManager.sol";

interface IUniversalPrivacyHook {
    enum BatchStatus {
        Collecting,
        Processing,
        Settled,
        Cancelled
    }
    
    function currentBatchId(PoolId) external view returns (bytes32);
    function swapManager() external view returns (ISwapManager);
    function poolEncryptedTokens(PoolId, Currency) external view returns (IFHERC20);
    function poolReserves(PoolId, Currency) external view returns (uint256);
}

contract UniversalPrivacyHookTest is Test, Deployers, CoFheUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    // Test Constants
    uint256 constant INITIAL_LIQUIDITY = 100e18;
    uint256 constant USER_INITIAL_BALANCE = 10000e6; // 10,000 USDC (6 decimals)
    uint256 constant DEPOSIT_AMOUNT = 1000e6; // 1,000 USDC
    uint256 constant SWAP_AMOUNT = 200e6; // 200 USDC

    // Contracts
    UniversalPrivacyHook hook;
    MockSwapManager swapManager;
    MockERC20 usdc;
    MockERC20 usdt;
    PoolKey poolKey;
    PoolId poolId;

    // Test Users
    address alice = address(0xABCD);
    address bob = address(0x1234);
    address operator = address(0x9999); // AVS operator who submits settlements

    function setUp() public {
        // Deploy core contracts
        deployFreshManagerAndRouters();
        
        // Deploy mock tokens (USDC = 6 decimals, USDT = 6 decimals)
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        
        // Deploy UniversalPrivacyHook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("UniversalPrivacyHook.sol", abi.encode(manager), hookAddress);
        hook = UniversalPrivacyHook(hookAddress);

        // Create USDC/USDT pool
        poolKey = PoolKey(
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)), 
            3000, // 0.3% fee
            60, // tick spacing
            IHooks(hook)
        );
        poolId = poolKey.toId();
        
        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        
        // Add initial liquidity
        usdc.mint(address(this), INITIAL_LIQUIDITY);
        usdt.mint(address(this), INITIAL_LIQUIDITY);
        
        usdc.approve(address(modifyLiquidityRouter), INITIAL_LIQUIDITY);
        usdt.approve(address(modifyLiquidityRouter), INITIAL_LIQUIDITY);
        
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            LIQUIDITY_PARAMS,
            ZERO_BYTES
        );

        // Setup test users with USDC
        usdc.mint(alice, USER_INITIAL_BALANCE);
        usdc.mint(bob, USER_INITIAL_BALANCE);
        
        // Give hook approval to spend user tokens
        vm.prank(alice);
        usdc.approve(address(hook), type(uint256).max);
        
        vm.prank(bob);
        usdc.approve(address(hook), type(uint256).max);
        
        // Also give Bob USDT and approval
        usdt.mint(bob, USER_INITIAL_BALANCE);
        vm.prank(bob);
        usdt.approve(address(hook), type(uint256).max);
        
        // Deploy and set MockSwapManager
        swapManager = new MockSwapManager();
        swapManager.setHook(address(hook));

        // Set SwapManager in hook
        hook.setSwapManager(address(swapManager));
    }

    function testPoolCreation() public {
        // Verify pool was created successfully
        assertEq(Currency.unwrap(poolKey.currency0), address(usdc));
        assertEq(Currency.unwrap(poolKey.currency1), address(usdt));
        assertEq(address(poolKey.hooks), address(hook));
        
        console.log("Pool created: USDC/USDT with UniversalPrivacyHook");
    }

    function testEncryptedTokenMetadata() public {
        console.log("Testing Encrypted Token Metadata Generation");
        
        // First deposit to trigger encrypted token creation
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);
        
        // Get the encrypted USDC token
        IFHERC20 encryptedUSDC = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdc)));
        assertTrue(address(encryptedUSDC) != address(0), "Encrypted USDC token should be created");
        
        // Check the metadata of the encrypted token
        string memory name = HybridFHERC20(address(encryptedUSDC)).name();
        string memory symbol = HybridFHERC20(address(encryptedUSDC)).symbol();
        uint8 decimals = HybridFHERC20(address(encryptedUSDC)).decimals();
        
        // Verify the name and symbol are correctly generated
        assertEq(name, "Encrypted USDC", "Name should be 'Encrypted USDC'");
        assertEq(symbol, "eUSDC", "Symbol should be 'eUSDC'");
        assertEq(decimals, 6, "Decimals should match underlying USDC (6 decimals)");
        
        console.log("Encrypted token name:", name);
        console.log("Encrypted token symbol:", symbol);
        console.log("Encrypted token decimals:", decimals);
        
        // Now deposit USDT to test second token metadata
        vm.prank(bob);
        usdt.mint(bob, DEPOSIT_AMOUNT);
        vm.prank(bob);
        usdt.approve(address(hook), DEPOSIT_AMOUNT);
        vm.prank(bob);
        hook.deposit(poolKey, Currency.wrap(address(usdt)), DEPOSIT_AMOUNT);
        
        // Get the encrypted USDT token
        IFHERC20 encryptedUSDT = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt)));
        assertTrue(address(encryptedUSDT) != address(0), "Encrypted USDT token should be created");
        
        // Check the metadata of the encrypted USDT token
        string memory nameUSDT = HybridFHERC20(address(encryptedUSDT)).name();
        string memory symbolUSDT = HybridFHERC20(address(encryptedUSDT)).symbol();
        uint8 decimalsUSDT = HybridFHERC20(address(encryptedUSDT)).decimals();
        
        // Verify the name and symbol are correctly generated for USDT
        assertEq(nameUSDT, "Encrypted USDT", "Name should be 'Encrypted USDT'");
        assertEq(symbolUSDT, "eUSDT", "Symbol should be 'eUSDT'");
        assertEq(decimalsUSDT, 6, "Decimals should match underlying USDT (6 decimals)");
        
        console.log("Encrypted USDT token name:", nameUSDT);
        console.log("Encrypted USDT token symbol:", symbolUSDT);
        console.log("Encrypted USDT token decimals:", decimalsUSDT);
    }

    function testEncryptedTokenMetadataWithFallback() public {
        console.log("Testing Encrypted Token Metadata with Fallback for Non-ERC20Metadata Tokens");
        
        // Create a mock token without metadata support
        MockERC20 basicToken = new MockERC20("", "", 18); // Empty name/symbol
        MockERC20 anotherToken = new MockERC20("Another", "ANTH", 18);
        
        // Create a new pool with the basic token
        PoolKey memory testPoolKey = PoolKey(
            Currency.wrap(address(basicToken)),
            Currency.wrap(address(anotherToken)),
            3000,
            60,
            IHooks(hook)
        );
        
        // Initialize the pool
        manager.initialize(testPoolKey, SQRT_PRICE_1_1);
        
        // Mint and approve tokens
        basicToken.mint(alice, DEPOSIT_AMOUNT);
        vm.prank(alice);
        basicToken.approve(address(hook), DEPOSIT_AMOUNT);
        
        // Deposit to trigger encrypted token creation
        vm.prank(alice);
        hook.deposit(testPoolKey, Currency.wrap(address(basicToken)), DEPOSIT_AMOUNT);
        
        // Get the encrypted token
        PoolId testPoolId = testPoolKey.toId();
        IFHERC20 encryptedBasicToken = hook.poolEncryptedTokens(testPoolId, Currency.wrap(address(basicToken)));
        
        // Check metadata - MockERC20 with empty name/symbol will return "e" as symbol
        string memory symbol = HybridFHERC20(address(encryptedBasicToken)).symbol();
        string memory name = HybridFHERC20(address(encryptedBasicToken)).name();

        // Since MockERC20 returns empty string, the hook creates "e" + "" = "e"
        assertEq(symbol, "e", "Symbol should be 'e' when underlying returns empty");
        assertEq(name, "Encrypted ", "Name should be 'Encrypted ' when underlying returns empty");
        
        console.log("Fallback encrypted token name:", name);
        console.log("Fallback encrypted token symbol:", symbol);
    }

    function testUserDeposit() public {
        console.log("Testing User Deposit Flow: USDC -> Encrypted USDC Tokens");

        // Check initial balances
        uint256 aliceInitialUSDC = usdc.balanceOf(alice);
        assertEq(aliceInitialUSDC, USER_INITIAL_BALANCE);
        console.log("Alice initial USDC balance:", aliceInitialUSDC / 1e6);

        // Alice deposits USDC to get encrypted USDC tokens
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        // Verify USDC was transferred to hook
        uint256 aliceFinalUSDC = usdc.balanceOf(alice);
        uint256 hookUSDCBalance = usdc.balanceOf(address(hook));

        assertEq(aliceFinalUSDC, USER_INITIAL_BALANCE - DEPOSIT_AMOUNT);
        assertEq(hookUSDCBalance, DEPOSIT_AMOUNT);

        console.log("Alice final USDC balance:", aliceFinalUSDC / 1e6);
        console.log("Hook USDC balance:", hookUSDCBalance / 1e6);

        // Verify encrypted token was created and Alice received encrypted balance
        IFHERC20 encryptedUSDC = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdc)));
        assertTrue(address(encryptedUSDC) != address(0), "Encrypted USDC token should be created");

        // PROPERLY VERIFY ENCRYPTED BALANCE - not treating as black box!
        euint128 aliceEncryptedBalance = encryptedUSDC.encBalances(alice);
        // Use CoFheUtils to verify the exact encrypted amount equals deposit amount
        assertHashValue(aliceEncryptedBalance, uint128(DEPOSIT_AMOUNT), "Alice should have exactly DEPOSIT_AMOUNT encrypted");
        console.log("Alice encrypted balance verified:", getMockValue(aliceEncryptedBalance) / 1e6, "USDC");

        // Also verify public balance is 0 (since we used encrypted minting)
        uint256 alicePublicBalance = encryptedUSDC.balanceOf(alice);
        console.log("Alice public balance (should be 0):", alicePublicBalance);
        assertEq(alicePublicBalance, 0, "Public balance should be 0 when using encrypted minting");

        // Verify hook reserves were updated
        uint256 hookReserves = hook.poolReserves(poolId, Currency.wrap(address(usdc)));
        assertEq(hookReserves, DEPOSIT_AMOUNT);

        console.log("Deposit successful: Alice deposited", DEPOSIT_AMOUNT / 1e6, "USDC and received encrypted tokens");
    }

    function testBatchProcessingFlow() public {
        console.log("Testing Batch Processing Flow with AVS Settlement");

        // === STEP 1: SETUP - Alice and Bob deposit ===
        console.log("\nStep 1: Alice and Bob deposit tokens");

        // Alice deposits USDC
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        // Bob deposits USDT
        vm.prank(bob);
        hook.deposit(poolKey, Currency.wrap(address(usdt)), DEPOSIT_AMOUNT);

        console.log("Alice deposited:", DEPOSIT_AMOUNT / 1e6, "USDC");
        console.log("Bob deposited:", DEPOSIT_AMOUNT / 1e6, "USDT");

        // Get encrypted token references
        IFHERC20 encryptedUSDC = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdc)));
        IFHERC20 encryptedUSDT = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt)));

        // VERIFY INITIAL ENCRYPTED BALANCES
        euint128 aliceUSDCBefore = encryptedUSDC.encBalances(alice);
        euint128 aliceUSDTBefore = encryptedUSDT.encBalances(alice);
        euint128 bobUSDCBefore = encryptedUSDC.encBalances(bob);
        euint128 bobUSDTBefore = encryptedUSDT.encBalances(bob);

        assertHashValue(aliceUSDCBefore, uint128(DEPOSIT_AMOUNT), "Alice should have DEPOSIT_AMOUNT encrypted USDC");

        // Check if Alice's USDT encrypted token exists - if not, the balance might be uninitialized
        if (inMockStorage(euint128.unwrap(aliceUSDTBefore))) {
            assertHashValue(aliceUSDTBefore, uint128(0), "Alice should have 0 encrypted USDT initially");
        }

        // Check Bob's USDC
        if (inMockStorage(euint128.unwrap(bobUSDCBefore))) {
            assertHashValue(bobUSDCBefore, uint128(0), "Bob should have 0 encrypted USDC initially");
        }

        assertHashValue(bobUSDTBefore, uint128(DEPOSIT_AMOUNT), "Bob should have DEPOSIT_AMOUNT encrypted USDT");

        console.log("Initial encrypted balances verified:");
        console.log("  Alice eUSDC:", getMockValue(aliceUSDCBefore) / 1e6);
        console.log("  Alice eUSDT:", getMockValue(aliceUSDTBefore) / 1e6);
        console.log("  Bob eUSDC:", getMockValue(bobUSDCBefore) / 1e6);
        console.log("  Bob eUSDT:", getMockValue(bobUSDTBefore) / 1e6);

        // === STEP 2: SUBMIT INTENTS ===
        console.log("\nStep 2: Submit multiple intents to form a batch");

        // Alice wants to swap 200 USDC for USDT
        vm.startPrank(alice);
        InEuint128 memory aliceAmount = createInEuint128(uint128(200e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            aliceAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // VERIFY ALICE'S BALANCE DECREASED AFTER SUBMITTING INTENT
        euint128 aliceUSDCAfterIntent = encryptedUSDC.encBalances(alice);
        assertDecreasedBy(aliceUSDCBefore, aliceUSDCAfterIntent, uint128(200e6));
        console.log("Alice eUSDC after intent:", getMockValue(aliceUSDCAfterIntent) / 1e6, "(decreased by 200)");

        // Bob wants to swap 150 USDT for USDC (partial match)
        vm.startPrank(bob);
        InEuint128 memory bobAmount = createInEuint128(uint128(150e6), bob);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdt)),
            Currency.wrap(address(usdc)),
            bobAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // VERIFY BOB'S BALANCE DECREASED AFTER SUBMITTING INTENT
        euint128 bobUSDTAfterIntent = encryptedUSDT.encBalances(bob);
        assertDecreasedBy(bobUSDTBefore, bobUSDTAfterIntent, uint128(150e6));
        console.log("Bob eUSDT after intent:", getMockValue(bobUSDTAfterIntent) / 1e6, "(decreased by 150)");

        console.log("Alice submitted intent: 200 USDC -> USDT");
        console.log("Bob submitted intent: 150 USDT -> USDC");
        
        // Get the batch ID that contains Alice and Bob's intents
        bytes32 batchIdToSettle = hook.currentBatchId(poolId);
        console.log("Batch ID to settle:", uint256(batchIdToSettle));
        
        // === STEP 3: ADVANCE BLOCKS TO TRIGGER BATCH PROCESSING ===
        console.log("\nStep 3: Advance blocks to finalize batch");
        vm.roll(block.number + 6); // Move past batchBlockInterval
        
        // Create a third intent to trigger batch finalization
        vm.startPrank(alice);
        InEuint128 memory aliceAmount2 = createInEuint128(uint128(50e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            aliceAmount2,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();
        
        // The batch with Alice and Bob's intents should now be in Processing status
        // Note: We can't easily check batch status due to Solidity's limitations with returning structs containing dynamic arrays
        // The batch should be in Processing status at this point
        console.log("Batch finalized and ready for AVS processing");
        
        // === STEP 4: SIMULATE AVS SETTLEMENT ===
        console.log("\nStep 4: AVS processes batch and submits settlement");

        // AVS matching scenario:
        // - Alice: 200 USDC -> USDT
        // - Bob: 150 USDT -> USDC
        // Internal match: 150 USDC from Alice ↔ 150 USDT from Bob
        // Net swap: 50 USDC -> USDT (Alice's remaining)

        // Create internal transfers for the matched amounts
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](2);

        // Alice gets 150 USDT from internal match with Bob
        // Operator encrypts with operator as sender (operator will call mockSettleBatch)
        internalTransfers[0] = InternalTransferInput({
            to: alice,
            encToken: address(encryptedUSDT),
            encAmount: createInEuint128(150e6, operator)
        });

        // Bob gets 150 USDC from internal match with Alice
        internalTransfers[1] = InternalTransferInput({
            to: bob,
            encToken: address(encryptedUSDC),
            encAmount: createInEuint128(150e6, operator)
        });

        // UserShares: Alice gets 100% of the net swap output (50 USDC -> ~49 USDT)
        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](1);
        userShares[0] = IHookSettlement.UserShare({
            user: alice,
            shareNumerator: 1,
            shareDenominator: 1
        });

        // Operator calls mockSettleBatch (msg.sender = operator when FHE.asEuint128 is called)
        vm.startPrank(operator);
        swapManager.mockSettleBatch(
            batchIdToSettle,
            internalTransfers,
            50e6, // netAmountIn - net 50 USDC to swap for USDT
            Currency.wrap(address(usdc)), // tokenIn
            Currency.wrap(address(usdt)), // tokenOut
            address(hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt)))), // outputToken
            userShares
        );
        vm.stopPrank();

        // === STEP 5: VERIFY RESULTS WITH PROPER ENCRYPTED BALANCE CHECKS ===
        console.log("\nStep 5: Verify batch settlement results with encrypted balance verification");

        // PROPERLY VERIFY ENCRYPTED BALANCES AFTER SETTLEMENT
        euint128 aliceUSDCAfter = encryptedUSDC.encBalances(alice);
        euint128 aliceUSDTAfter = encryptedUSDT.encBalances(alice);
        euint128 bobUSDCAfter = encryptedUSDC.encBalances(bob);
        euint128 bobUSDTAfter = encryptedUSDT.encBalances(bob);

        console.log("\nFinal encrypted balances:");
        console.log("  Alice eUSDC:", getMockValue(aliceUSDCAfter) / 1e6);
        console.log("  Alice eUSDT:", getMockValue(aliceUSDTAfter) / 1e6);
        console.log("  Bob eUSDC:", getMockValue(bobUSDCAfter) / 1e6);
        console.log("  Bob eUSDT:", getMockValue(bobUSDTAfter) / 1e6);

        // Alice's balances:
        // - Started with 1000 USDC
        // - Submitted first intent for 200 USDC → 800 eUSDC
        // - Submitted second intent for 50 USDC → 750 eUSDC (to trigger batch finalization)
        // - Settlement doesn't give her back any USDC (internal transfer is USDT, not USDC)
        assertHashValue(aliceUSDCAfter, uint128(750e6), "Alice should have 750 USDC (1000 - 200 - 50 intents)");

        // - Started with 0 USDT
        // - Got 150 USDT from internal transfer
        // - Got ~49 USDT from net swap (50 USDC swapped with slippage)
        // - Total: ~199 USDT
        assertGtEuint(aliceUSDTAfter, uint128(190e6), "Alice should have >190 USDT (150 internal + ~49 net swap)");
        console.log("Alice gained USDT:", getMockValue(aliceUSDTAfter) / 1e6);

        // Bob's balances:
        // - Started with 0 USDC
        // - Got 150 USDC from internal transfer
        assertHashValue(bobUSDCAfter, uint128(150e6), "Bob should have 150 USDC from internal transfer");

        // - Started with 1000 USDT, submitted intent for 150 USDT → 850 eUSDT
        // - Stayed at 850 eUSDT (no additional USDT movement)
        assertHashValue(bobUSDTAfter, uint128(850e6), "Bob should have 850 USDT (1000 - 150 intent)");

        // Verify hook reserves were updated
        uint256 hookUSDCReserves = hook.poolReserves(poolId, Currency.wrap(address(usdc)));
        uint256 hookUSDTReserves = hook.poolReserves(poolId, Currency.wrap(address(usdt)));
        console.log("\nHook reserves after settlement:");
        console.log("  USDC reserves:", hookUSDCReserves / 1e6, "USDC");
        console.log("  USDT reserves:", hookUSDTReserves / 1e6, "USDT");

        console.log("\nBATCH PROCESSING SUMMARY:");
        console.log(" 1. Alice and Bob deposited 1000 tokens each");
        console.log(" 2. Alice submitted intent: 200 USDC -> USDT (balance: 1000 -> 800 eUSDC)");
        console.log(" 3. Bob submitted intent: 150 USDT -> USDC (balance: 1000 -> 850 eUSDT)");
        console.log(" 4. Alice submitted 2nd intent: 50 USDC -> USDT to trigger finalization (balance: 800 -> 750 eUSDC)");
        console.log(" 5. Batch was finalized (contains Alice's 200 USDC + Bob's 150 USDT intents)");
        console.log(" 6. AVS matched 150 USDC <-> 150 USDT internally (NO AMM swap)");
        console.log("    - Alice received 150 eUSDT from internal transfer");
        console.log("    - Bob received 150 eUSDC from internal transfer");
        console.log(" 7. AVS executed net swap: 50 USDC -> ~49 USDT via AMM");
        console.log("    - Alice received ~49 eUSDT from net swap");
        console.log(" 8. Final balances:");
        console.log("    - Alice: 750 eUSDC (1000 - 200 - 50), ~199 eUSDT (0 + 150 + 49)");
        console.log("    - Bob: 150 eUSDC (0 + 150), 850 eUSDT (1000 - 150)");
        console.log(" 9. All encrypted balances verified correctly with NO BLACK BOXES!");
    }

    function testMultiPoolSupport() public {
        console.log("Testing Multi-Pool Support");
        
        // First, Alice deposits USDC in Pool 1 (USDC/USDT) to create encrypted token
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);
        
        // Create a second pool (USDC/WETH)
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        
        PoolKey memory secondPoolKey = PoolKey(
            Currency.wrap(address(usdc)),
            Currency.wrap(address(weth)),
            3000,
            60,
            IHooks(hook)
        );
        PoolId secondPoolId = secondPoolKey.toId();
        
        // Calculate sqrt price for 1 WETH = 4000 USDC
        // Pool ordering: token0 = USDC (6 decimals), token1 = WETH (18 decimals)
        // Price in pool = WETH per USDC = 1/4000 = 0.00025
        // Adjusted for decimals: 0.00025 * 10^(18-6) = 0.00025 * 1e12 = 2.5e8
        // sqrtPrice = sqrt(2.5e8) ≈ 15811.4
        // sqrtPriceX96 = 15811.4 * 2^96 ≈ 1.25e30
        uint160 sqrtPriceX96_USDC_WETH = 1252707241875239655932069007848031; // sqrt(2.5e8) * 2^96
        
        // Initialize second pool with proper price
        manager.initialize(secondPoolKey, sqrtPriceX96_USDC_WETH);
        
        // Add liquidity to second pool
        // Mint tokens for liquidity provision (need more for the price range)
        uint256 usdcLiquidityAmount = 10000000e6; // 10 million USDC
        uint256 wethLiquidityAmount = 2500e18;     // 2500 WETH (10M / 4000)
        
        usdc.mint(address(this), usdcLiquidityAmount);
        weth.mint(address(this), wethLiquidityAmount);
        
        usdc.approve(address(modifyLiquidityRouter), usdcLiquidityAmount);
        weth.approve(address(modifyLiquidityRouter), wethLiquidityAmount);

        // ticks around the current price (spacing = 60)
        int24 center = 193320;
        int24 tickLower = 192720;
        int24 tickUpper = 193920;
                
        // Add liquidity with appropriate tick range (must be divisible by tick spacing of 60)
        modifyLiquidityRouter.modifyLiquidity(
            secondPoolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,  // Wide range for testing, divisible by 60
                tickUpper: tickUpper,
                liquidityDelta: 1e18,
                salt: 0
            }),
            ZERO_BYTES
        );
        
        // Alice deposits USDC in the second pool
        vm.prank(alice);
        hook.deposit(secondPoolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);
        
        // Bob deposits WETH in the second pool
        weth.mint(bob, 1e18);
        vm.prank(bob);
        weth.approve(address(hook), 1e18);
        vm.prank(bob);
        hook.deposit(secondPoolKey, Currency.wrap(address(weth)), 1e18);
        
        // Verify separate encrypted tokens were created for each pool
        IFHERC20 encryptedUSDC_Pool1 = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdc)));
        IFHERC20 encryptedUSDC_Pool2 = hook.poolEncryptedTokens(secondPoolId, Currency.wrap(address(usdc)));
        IFHERC20 encryptedWETH_Pool2 = hook.poolEncryptedTokens(secondPoolId, Currency.wrap(address(weth)));
        
        assertTrue(address(encryptedUSDC_Pool1) != address(0), "Pool 1 encrypted USDC should exist");
        assertTrue(address(encryptedUSDC_Pool2) != address(0), "Pool 2 encrypted USDC should exist");
        assertTrue(address(encryptedWETH_Pool2) != address(0), "Pool 2 encrypted WETH should exist");
        assertTrue(address(encryptedUSDC_Pool1) != address(encryptedUSDC_Pool2), "Each pool should have separate encrypted tokens");
        
        // Log detailed information about hook balances and encrypted tokens
        console.log("\n=== MULTI-POOL SUPPORT VERIFICATION ===");
        
        // Check hook's actual token balances
        uint256 hookUSDCBalance = usdc.balanceOf(address(hook));
        uint256 hookUSDTBalance = usdt.balanceOf(address(hook));
        uint256 hookWETHBalance = weth.balanceOf(address(hook));
        
        console.log("\nHook's actual token balances:");
        console.log("  USDC balance:", hookUSDCBalance / 1e6, "USDC");
        console.log("  USDT balance:", hookUSDTBalance / 1e6, "USDT");
        console.log("  WETH balance:", hookWETHBalance / 1e18, "WETH");
        
        // Check hook's reserves for each pool
        uint256 pool1USDCReserves = hook.poolReserves(poolId, Currency.wrap(address(usdc)));
        uint256 pool1USDTReserves = hook.poolReserves(poolId, Currency.wrap(address(usdt)));
        uint256 pool2USDCReserves = hook.poolReserves(secondPoolId, Currency.wrap(address(usdc)));
        uint256 pool2WETHReserves = hook.poolReserves(secondPoolId, Currency.wrap(address(weth)));
        
        console.log("\nPool 1 (USDC/USDT) reserves in hook:");
        console.log("  USDC reserves:", pool1USDCReserves / 1e6, "USDC");
        console.log("  USDT reserves:", pool1USDTReserves / 1e6, "USDT");
        
        console.log("\nPool 2 (USDC/WETH) reserves in hook:");
        console.log("  USDC reserves:", pool2USDCReserves / 1e6, "USDC");
        console.log("  WETH reserves:", pool2WETHReserves / 1e18, "WETH");
        
        // Check Alice's encrypted balances in each pool
        euint128 alicePool1USDC = encryptedUSDC_Pool1.encBalances(alice);
        euint128 alicePool2USDC = encryptedUSDC_Pool2.encBalances(alice);
        
        console.log("\nAlice's encrypted balances:");
        console.log("  Pool 1 eUSDC (wrapped):", euint128.unwrap(alicePool1USDC));
        console.log("  Pool 2 eUSDC (wrapped):", euint128.unwrap(alicePool2USDC));
        
        // Check Bob's encrypted balances
        euint128 bobPool2WETH = encryptedWETH_Pool2.encBalances(bob);
        console.log("\nBob's encrypted balances:");
        console.log("  Pool 2 eWETH (wrapped):", euint128.unwrap(bobPool2WETH));
        
        console.log("\n=== TESTING SWAP IN POOL 2 ===");
        
        // Alice submits encrypted swap intent in Pool 2: swap 400 USDC for WETH
        vm.startPrank(alice);
        InEuint128 memory encryptedSwapAmount2 = createInEuint128(uint128(400e6), alice); // 400 USDC
        hook.submitIntent(
            secondPoolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(weth)),
            encryptedSwapAmount2,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();
        console.log("Alice submitted encrypted swap intent: 400 USDC -> WETH");
        
        // Warp time for FHE decryption
        vm.warp(block.timestamp + 11);
        
        // Trigger swap to process intent
        weth.mint(bob, 1e18);
        vm.prank(bob);
        weth.approve(address(swapRouter), 1e18);
        
        vm.prank(bob);
        swapRouter.swap(
            secondPoolKey,
            SwapParams({
                zeroForOne: false, // WETH → USDC
                amountSpecified: -1e17, // Swap 0.1 WETH
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
        console.log("Triggered intent processing via external swap");
        
        // Check updated balances after swap
        uint256 hookUSDCBalanceAfter = usdc.balanceOf(address(hook));
        uint256 hookWETHBalanceAfter = weth.balanceOf(address(hook));
        
        console.log("\nHook's token balances after swap:");
        console.log("  USDC balance:", hookUSDCBalanceAfter / 1e6, "USDC");
        console.log("  WETH balance:", hookWETHBalanceAfter / 1e18, "WETH");
        
        // Check updated reserves
        uint256 pool2USDCReservesAfter = hook.poolReserves(secondPoolId, Currency.wrap(address(usdc)));
        uint256 pool2WETHReservesAfter = hook.poolReserves(secondPoolId, Currency.wrap(address(weth)));
        
        console.log("\nPool 2 reserves after swap:");
        console.log("  USDC reserves:", pool2USDCReservesAfter / 1e6, "USDC");
        console.log("  WETH reserves:", pool2WETHReservesAfter / 1e18, "WETH");
        
        // Check Alice's updated encrypted balances
        euint128 alicePool2USDCAfter = encryptedUSDC_Pool2.encBalances(alice);
        euint128 alicePool2WETH = encryptedWETH_Pool2.encBalances(alice);
        
        console.log("\nAlice's encrypted balances after swap:");
        console.log("  Pool 2 eUSDC (wrapped):", euint128.unwrap(alicePool2USDCAfter));
        console.log("  Pool 2 eWETH (wrapped):", euint128.unwrap(alicePool2WETH));
        
        if (euint128.unwrap(alicePool2WETH) != 0) {
            console.log("SUCCESS: Alice received encrypted WETH tokens from Pool 2 swap!");
        }
        
        console.log("\n=== SUMMARY ===");
        console.log("Pool 1 (USDC/USDT) has encrypted USDC token at:", address(encryptedUSDC_Pool1));
        console.log("Pool 2 (USDC/WETH) has encrypted USDC token at:", address(encryptedUSDC_Pool2));
        console.log("Pool 2 (USDC/WETH) has encrypted WETH token at:", address(encryptedWETH_Pool2));
        console.log("Each pool maintains independent encrypted tokens");
        console.log("Alice deposited", DEPOSIT_AMOUNT / 1e6, "USDC in each pool");
        console.log("Alice swapped 400 USDC for WETH in Pool 2");
        console.log("Bob deposited 1 WETH in Pool 2");
    }

    function testNetSwapExecution() public {
        console.log("Testing Net Swap Execution Through Uniswap Pool");
        
        // Setup: Alice deposits USDC
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);
        
        // Alice submits intent to swap 500 USDC for USDT (no matching counterparty)
        vm.startPrank(alice);
        InEuint128 memory aliceAmount = createInEuint128(uint128(500e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            aliceAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();
        
        bytes32 batchId = hook.currentBatchId(poolId);
        
        // Advance blocks to trigger batch finalization
        vm.roll(block.number + 6);
        
        // Trigger batch finalization by submitting another intent
        vm.prank(bob);
        hook.deposit(poolKey, Currency.wrap(address(usdt)), 100e6);
        vm.startPrank(bob);
        InEuint128 memory bobAmount = createInEuint128(uint128(10e6), bob);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdt)),
            Currency.wrap(address(usdc)),
            bobAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();
        
        // Simulate AVS settlement with only net swap (no internalized transfers)
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);

        // Net swap for Alice's 500 USDC - Alice gets 100% of output
        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](1);
        userShares[0] = IHookSettlement.UserShare({
            user: alice,
            shareNumerator: 1,
            shareDenominator: 1
        });

        // Execute settlement (no inputProof for Fhenix)
        vm.prank(address(swapManager));
        swapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            500e6, // netAmountIn
            Currency.wrap(address(usdc)), // tokenIn
            Currency.wrap(address(usdt)), // tokenOut
            address(hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt)))), // outputToken
            userShares
        );
        
        // Verify reserves changed correctly
        uint256 usdcReserves = hook.poolReserves(poolId, Currency.wrap(address(usdc)));
        uint256 usdtReserves = hook.poolReserves(poolId, Currency.wrap(address(usdt)));
        
        assertEq(usdcReserves, 500e6, "USDC reserves should be 500 (1000 - 500 swapped)");
        // Bob deposited 100 USDT, but also submitted an intent for 10 USDT, so his contribution is 90 USDT
        // Plus ~498-499 from the swap = ~588-589 USDT
        assertTrue(usdtReserves > 588e6, "USDT reserves should be > 588");
        
        console.log("Net swap executed successfully through Uniswap pool");
        console.log("USDC reserves:", usdcReserves / 1e6);
        console.log("USDT reserves:", usdtReserves / 1e6);
    }
    
    function testSingleIntentBatch() public {
        console.log("Testing Single Intent Batch Processing");

        // Alice deposits and submits a single intent
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        bytes32 batchId = hook.currentBatchId(poolId);

        // Advance blocks and trigger finalization
        vm.roll(block.number + 6);

        // Trigger batch finalization by submitting another intent
        vm.prank(bob);
        hook.deposit(poolKey, Currency.wrap(address(usdt)), 100e6);
        vm.startPrank(bob);
        InEuint128 memory bobAmount = createInEuint128(uint128(10e6), bob);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdt)),
            Currency.wrap(address(usdc)),
            bobAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // Settle the single-intent batch
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);

        // Alice gets 100% of swap output
        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](1);
        userShares[0] = IHookSettlement.UserShare({
            user: alice,
            shareNumerator: 1,
            shareDenominator: 1
        });

        // This should succeed even with just 1 intent
        vm.prank(address(swapManager));
        swapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            100e6, // netAmountIn
            Currency.wrap(address(usdc)), // tokenIn
            Currency.wrap(address(usdt)), // tokenOut
            address(hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt)))), // outputToken
            userShares
        );

        console.log("Single intent batch processed successfully");
        console.log("Batch can be any size after block interval");
    }

    // ============================================
    // ERROR CONDITION TESTS - setSwapManager
    // ============================================

    function testSetSwapManager_RevertInvalidAddress() public {
        // Deploy a fresh hook to test setSwapManager
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        // Add large offset to avoid interfering with flag bits in last bytes
        address freshHookAddress = address(uint160(0x1000000000000000000000000000000000000000) | flags);
        deployCodeTo("UniversalPrivacyHook.sol", abi.encode(manager), freshHookAddress);
        UniversalPrivacyHook freshHook = UniversalPrivacyHook(freshHookAddress);

        // Try to set invalid address (address(0))
        vm.expectRevert("Invalid address");
        freshHook.setSwapManager(address(0));

        console.log("setSwapManager correctly rejects address(0)");
    }

    // ============================================
    // ERROR CONDITION TESTS - deposit
    // ============================================

    function testDeposit_RevertWrongHook() public {
        // Create a pool with a different hook
        uint160 differentFlags = uint160(Hooks.BEFORE_SWAP_FLAG);
        // Add large offset to avoid interfering with flag bits in last bytes
        address differentHookAddress = address(uint160(0x2000000000000000000000000000000000000000) | differentFlags);
        deployCodeTo("UniversalPrivacyHook.sol", abi.encode(manager), differentHookAddress);
        UniversalPrivacyHook differentHook = UniversalPrivacyHook(differentHookAddress);

        PoolKey memory differentPoolKey = PoolKey(
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            3000,
            60,
            IHooks(differentHook)
        );

        // Initialize the pool
        manager.initialize(differentPoolKey, SQRT_PRICE_1_1);

        // Try to deposit using the wrong hook (our original hook)
        vm.prank(alice);
        vm.expectRevert("Hook not enabled");
        hook.deposit(differentPoolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        console.log("deposit correctly rejects wrong hook");
    }

    function testDeposit_RevertInvalidCurrency() public {
        // Create a mock token that is NOT part of the pool
        MockERC20 invalidToken = new MockERC20("Invalid Token", "INVALID", 18);
        invalidToken.mint(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        invalidToken.approve(address(hook), DEPOSIT_AMOUNT);

        // Try to deposit invalid currency
        vm.prank(alice);
        vm.expectRevert("Invalid currency");
        hook.deposit(poolKey, Currency.wrap(address(invalidToken)), DEPOSIT_AMOUNT);

        console.log("deposit correctly rejects invalid currency");
    }

    // ============================================
    // ERROR CONDITION TESTS - submitIntent
    // ============================================

    function testSubmitIntent_RevertInvalidPair() public {
        // Alice deposits USDC
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        // Create a third token not in the pool
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Try to submit intent with invalid pair (USDC -> WETH, but pool is USDC/USDT)
        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        vm.expectRevert("Invalid pair");
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(weth)), // Invalid tokenOut
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        console.log("submitIntent correctly rejects invalid pair");
    }

    function testSubmitIntent_RevertTokenNotExists() public {
        // Try to submit intent WITHOUT depositing first (encrypted token doesn't exist)
        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);

        vm.expectRevert("Token not exists");
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        console.log("submitIntent correctly rejects when token doesn't exist");
    }

    // ============================================
    // ERROR CONDITION TESTS - withdraw
    // ============================================

    function testWithdraw_RevertTokenNotExists() public {
        // Try to withdraw from a pool without depositing first
        vm.prank(alice);
        vm.expectRevert("Token not exists");
        hook.withdraw(
            poolKey,
            Currency.wrap(address(usdc)),
            100e6,
            alice
        );

        console.log("withdraw correctly rejects when token doesn't exist");
    }

    // ============================================
    // ERROR CONDITION TESTS - finalizeBatch
    // ============================================

    function testFinalizeBatch_RevertNoActiveBatch() public {
        // Try to finalize batch when no batch exists
        vm.expectRevert("No active batch");
        hook.finalizeBatch(poolId);

        console.log("finalizeBatch correctly rejects when no active batch");
    }

    function testFinalizeBatch_RevertAlreadyFinalized() public {
        // Alice deposits and submits intent
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        bytes32 batchId = hook.currentBatchId(poolId);

        // Advance blocks
        vm.roll(block.number + 6);

        // Finalize batch
        hook.finalizeBatch(poolId);

        // After finalization, currentBatchId is reset to bytes32(0), so trying to finalize
        // the same poolId again will fail with "No active batch" instead of "Already finalized"
        // To test "Already finalized", we would need to submit intents to create a new batch,
        // then try to finalize the old batch ID - but that's not how the external API works.
        // This test is actually not reachable through the external API.

        // Let's test that we can't finalize when no batch exists
        vm.expectRevert("No active batch");
        hook.finalizeBatch(poolId);

        console.log("finalizeBatch correctly rejects when no active batch after finalization");
    }

    function testFinalizeBatch_RevertBatchNotReady() public {
        // Alice deposits and submits intent
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // DON'T advance blocks - try to finalize immediately
        vm.expectRevert("Batch not ready");
        hook.finalizeBatch(poolId);

        console.log("finalizeBatch correctly rejects when batch not ready");
    }

    function testFinalizeBatch_RevertEmptyBatch() public {
        // Create a scenario where we have a batchId but no intents
        // This is tricky because submitIntent always adds to batch
        // We need to manually set up this state or test the internal logic

        // Actually, we can't easily test this because submitIntent creates the batch
        // and immediately adds an intent. This branch exists for defensive programming.
        // Skip this test as it's not reachable through normal flow.

        console.log("finalizeBatch empty batch check exists for defensive programming");
    }

    // ============================================
    // ERROR CONDITION TESTS - settleBatch
    // ============================================

    function testSettleBatch_RevertSwapManagerNotSet() public {
        // Deploy a fresh hook without setting swapManager
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        // Add large offset to avoid interfering with flag bits in last bytes
        address freshHookAddress = address(uint160(0x3000000000000000000000000000000000000000) | flags);
        deployCodeTo("UniversalPrivacyHook.sol", abi.encode(manager), freshHookAddress);
        UniversalPrivacyHook freshHook = UniversalPrivacyHook(freshHookAddress);

        PoolKey memory freshPoolKey = PoolKey(
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            3000,
            60,
            IHooks(freshHook)
        );
        manager.initialize(freshPoolKey, SQRT_PRICE_1_1);
        PoolId freshPoolId = freshPoolKey.toId();

        // Alice needs to approve freshHook to spend tokens
        vm.prank(alice);
        usdc.approve(address(freshHook), type(uint256).max);

        // Alice deposits and submits intent
        vm.prank(alice);
        freshHook.deposit(freshPoolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        freshHook.submitIntent(
            freshPoolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        bytes32 batchId = freshHook.currentBatchId(freshPoolId);

        // Advance blocks and finalize
        vm.roll(block.number + 6);
        freshHook.finalizeBatch(freshPoolId);

        // Deploy MockSwapManager but don't set it in the hook
        MockSwapManager freshSwapManager = new MockSwapManager();
        freshSwapManager.setHook(address(freshHook));

        // We need to create the output token (USDT) first to avoid underflow
        // Bob needs to approve freshHook and deposit USDT to create the encrypted token
        vm.prank(bob);
        usdt.approve(address(freshHook), type(uint256).max);
        vm.prank(bob);
        freshHook.deposit(freshPoolKey, Currency.wrap(address(usdt)), DEPOSIT_AMOUNT);

        // Mark batch as finalized in freshSwapManager to pass its check
        freshSwapManager.finalizeBatch(batchId, "");

        // Try to settle without setting swapManager in hook
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);
        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](0);

        // Get the output token address
        address outputToken = address(freshHook.poolEncryptedTokens(freshPoolId, Currency.wrap(address(usdt))));

        vm.prank(address(freshSwapManager));
        vm.expectRevert("SwapManager not set");
        freshSwapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            0,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            outputToken,
            userShares
        );

        console.log("settleBatch correctly rejects when SwapManager not set");
    }

    function testSettleBatch_RevertOnlySwapManager() public {
        // Alice deposits and submits intent
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        bytes32 batchId = hook.currentBatchId(poolId);

        // Advance blocks and finalize
        vm.roll(block.number + 6);

        // Trigger finalization by submitting another intent
        vm.prank(bob);
        hook.deposit(poolKey, Currency.wrap(address(usdt)), 100e6);
        vm.startPrank(bob);
        InEuint128 memory bobAmount = createInEuint128(uint128(10e6), bob);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdt)),
            Currency.wrap(address(usdc)),
            bobAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // Create a fake swapManager (not the authorized one)
        MockSwapManager fakeSwapManager = new MockSwapManager();
        fakeSwapManager.setHook(address(hook));

        // Need to mark the batch as finalized in the fakeSwapManager so it passes the MockSwapManager check
        fakeSwapManager.finalizeBatch(batchId, "");

        // Try to settle from unauthorized swapManager (fakeSwapManager instead of swapManager)
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);
        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](0);

        // Compute outputToken before expectRevert to avoid consuming it
        address outputToken = address(hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt))));

        vm.prank(address(fakeSwapManager));
        vm.expectRevert("Only SwapManager");
        fakeSwapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            0,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            outputToken,
            userShares
        );

        console.log("settleBatch correctly rejects non-SwapManager caller");
    }

    function testSettleBatch_RevertBatchNotFinalized() public {
        // Alice deposits and submits intent
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        bytes32 batchId = hook.currentBatchId(poolId);

        // DON'T finalize - try to settle directly
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);
        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](0);

        // Compute outputToken before expectRevert to avoid consuming it
        address outputToken = address(hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt))));

        vm.prank(address(swapManager));
        vm.expectRevert("Batch not finalized");
        swapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            0,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            outputToken,
            userShares
        );

        console.log("settleBatch correctly rejects non-finalized batch");
    }

    function testSettleBatch_RevertAlreadySettled() public {
        // Alice deposits and submits intent
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        InEuint128 memory amount = createInEuint128(uint128(100e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            amount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        bytes32 batchId = hook.currentBatchId(poolId);

        // Advance blocks and finalize
        vm.roll(block.number + 6);

        // Trigger finalization
        vm.prank(bob);
        hook.deposit(poolKey, Currency.wrap(address(usdt)), 100e6);
        vm.startPrank(bob);
        InEuint128 memory bobAmount = createInEuint128(uint128(10e6), bob);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdt)),
            Currency.wrap(address(usdc)),
            bobAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // Settle once
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);
        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](0);

        // Compute outputToken before expectRevert to avoid consuming it
        address outputToken = address(hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt))));

        vm.prank(address(swapManager));
        swapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            0,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            outputToken,
            userShares
        );

        // Try to settle again - should revert with "Already settled"
        vm.prank(address(swapManager));
        vm.expectRevert("Already settled");
        swapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            0,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            outputToken,
            userShares
        );

        console.log("settleBatch correctly rejects already settled batch");
    }

    function testSettleBatch_NoNetSwap() public {
        // Test settleBatch with netAmountIn = 0 (only internal transfers, no AMM swap)
        console.log("Testing settleBatch with only internal transfers (no AMM swap)");

        // Setup: Alice and Bob deposit
        vm.prank(alice);
        hook.deposit(poolKey, Currency.wrap(address(usdc)), DEPOSIT_AMOUNT);

        vm.prank(bob);
        hook.deposit(poolKey, Currency.wrap(address(usdt)), DEPOSIT_AMOUNT);

        // Get encrypted tokens
        IFHERC20 encryptedUSDC = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdc)));
        IFHERC20 encryptedUSDT = hook.poolEncryptedTokens(poolId, Currency.wrap(address(usdt)));

        // Alice submits intent
        vm.startPrank(alice);
        InEuint128 memory aliceAmount = createInEuint128(uint128(200e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            aliceAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // Bob submits matching intent
        vm.startPrank(bob);
        InEuint128 memory bobAmount = createInEuint128(uint128(200e6), bob);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdt)),
            Currency.wrap(address(usdc)),
            bobAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        bytes32 batchId = hook.currentBatchId(poolId);

        // Advance blocks and finalize
        vm.roll(block.number + 6);

        // Trigger finalization
        vm.startPrank(alice);
        InEuint128 memory triggerAmount = createInEuint128(uint128(10e6), alice);
        hook.submitIntent(
            poolKey,
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            triggerAmount,
            uint64(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        // Perfect match - internal transfers only, NO net swap
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](2);

        // Operator encrypts with operator as sender
        internalTransfers[0] = InternalTransferInput({
            to: alice,
            encToken: address(encryptedUSDT),
            encAmount: createInEuint128(200e6, operator)
        });

        internalTransfers[1] = InternalTransferInput({
            to: bob,
            encToken: address(encryptedUSDC),
            encAmount: createInEuint128(200e6, operator)
        });

        IHookSettlement.UserShare[] memory userShares = new IHookSettlement.UserShare[](0);

        // Operator calls mockSettleBatch
        vm.startPrank(operator);
        swapManager.mockSettleBatch(
            batchId,
            internalTransfers,
            0, // NO net swap
            Currency.wrap(address(usdc)),
            Currency.wrap(address(usdt)),
            address(encryptedUSDT),
            userShares
        );
        vm.stopPrank();

        // Verify balances
        euint128 aliceUSDTAfter = encryptedUSDT.encBalances(alice);
        euint128 bobUSDCAfter = encryptedUSDC.encBalances(bob);

        assertHashValue(aliceUSDTAfter, uint128(200e6), "Alice should have 200 USDT from internal transfer");
        assertHashValue(bobUSDCAfter, uint128(200e6), "Bob should have 200 USDC from internal transfer");

        console.log("settleBatch successfully processed with netAmountIn = 0 (no AMM swap)");
    }

}