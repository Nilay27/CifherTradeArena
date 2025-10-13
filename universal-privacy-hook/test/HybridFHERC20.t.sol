// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheUtils} from "./utils/CoFheUtils.sol";

/**
 * @title HybridFHERC20Test
 * @notice Comprehensive test suite for HybridFHERC20 token
 * @dev Tests all functionality including mint, burn, transfer, wrap/unwrap with proper FHE verification
 */
contract HybridFHERC20Test is Test, CoFheUtils {
    HybridFHERC20 token;

    address alice = address(0xABCD);
    address bob = address(0x1234);

    uint128 constant MINT_AMOUNT = 1000e6;
    uint128 constant TRANSFER_AMOUNT = 200e6;

    function setUp() public {
        // Deploy token with 6 decimals (like USDC)
        token = new HybridFHERC20("Test Token", "TEST", 6);
    }

    // ============================================
    // METADATA TESTS
    // ============================================

    function testMetadata() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 6);
    }

    // ============================================
    // PUBLIC MINT TESTS
    // ============================================

    function testMintPublic() public {
        token.mint(alice, MINT_AMOUNT);

        assertEq(token.balanceOf(alice), MINT_AMOUNT);
        assertEq(token.totalSupply(), MINT_AMOUNT);
    }

    function testMintPublicMultipleUsers() public {
        token.mint(alice, MINT_AMOUNT);
        token.mint(bob, MINT_AMOUNT * 2);

        assertEq(token.balanceOf(alice), MINT_AMOUNT);
        assertEq(token.balanceOf(bob), MINT_AMOUNT * 2);
        assertEq(token.totalSupply(), MINT_AMOUNT * 3);
    }

    // ============================================
    // PUBLIC BURN TESTS
    // ============================================

    function testBurnPublic() public {
        token.mint(alice, MINT_AMOUNT);

        token.burn(alice, TRANSFER_AMOUNT);

        assertEq(token.balanceOf(alice), MINT_AMOUNT - TRANSFER_AMOUNT);
        assertEq(token.totalSupply(), MINT_AMOUNT - TRANSFER_AMOUNT);
    }

    // ============================================
    // ENCRYPTED MINT TESTS
    // ============================================

    function testMintEncryptedWithInEuint128() public {
        InEuint128 memory encAmount = createInEuint128(MINT_AMOUNT, address(this));

        token.mintEncrypted(alice, encAmount);

        euint128 aliceBalance = token.encBalances(alice);
        assertHashValue(aliceBalance, MINT_AMOUNT, "Alice should have MINT_AMOUNT encrypted");

        euint128 totalEncSupply = token.totalEncryptedSupply();
        assertHashValue(totalEncSupply, MINT_AMOUNT, "Total encrypted supply should be MINT_AMOUNT");
    }

    function testMintEncryptedWithEuint128() public {
        euint128 encAmount = FHE.asEuint128(MINT_AMOUNT);
        FHE.allowThis(encAmount);
        FHE.allow(encAmount, address(token));

        token.mintEncrypted(alice, encAmount);

        euint128 aliceBalance = token.encBalances(alice);
        assertHashValue(aliceBalance, MINT_AMOUNT, "Alice should have MINT_AMOUNT encrypted");
    }

    function testMintEncryptedMultipleUsers() public {
        InEuint128 memory aliceAmount = createInEuint128(MINT_AMOUNT, address(this));
        InEuint128 memory bobAmount = createInEuint128(MINT_AMOUNT * 2, address(this));

        token.mintEncrypted(alice, aliceAmount);
        token.mintEncrypted(bob, bobAmount);

        euint128 aliceBalance = token.encBalances(alice);
        euint128 bobBalance = token.encBalances(bob);

        assertHashValue(aliceBalance, MINT_AMOUNT);
        assertHashValue(bobBalance, MINT_AMOUNT * 2);

        euint128 totalEncSupply = token.totalEncryptedSupply();
        assertHashValue(totalEncSupply, MINT_AMOUNT * 3);
    }

    function testMintEncryptedMultipleTimes() public {
        InEuint128 memory amount1 = createInEuint128(MINT_AMOUNT, address(this));
        InEuint128 memory amount2 = createInEuint128(TRANSFER_AMOUNT, address(this));

        token.mintEncrypted(alice, amount1);
        token.mintEncrypted(alice, amount2);

        euint128 aliceBalance = token.encBalances(alice);
        assertHashValue(aliceBalance, MINT_AMOUNT + TRANSFER_AMOUNT);
    }

    // ============================================
    // ENCRYPTED BURN TESTS
    // ============================================

    function testBurnEncryptedWithInEuint128() public {
        // First mint
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Then burn
        InEuint128 memory burnAmount = createInEuint128(TRANSFER_AMOUNT, address(this));
        token.burnEncrypted(alice, burnAmount);

        euint128 aliceBalance = token.encBalances(alice);
        assertHashValue(aliceBalance, MINT_AMOUNT - TRANSFER_AMOUNT);

        euint128 totalEncSupply = token.totalEncryptedSupply();
        assertHashValue(totalEncSupply, MINT_AMOUNT - TRANSFER_AMOUNT);
    }

    function testBurnEncryptedWithEuint128() public {
        // First mint
        euint128 mintAmount = FHE.asEuint128(MINT_AMOUNT);
        FHE.allowThis(mintAmount);
        FHE.allow(mintAmount, address(token));
        token.mintEncrypted(alice, mintAmount);

        // Then burn
        euint128 burnAmount = FHE.asEuint128(TRANSFER_AMOUNT);
        FHE.allowThis(burnAmount);
        FHE.allow(burnAmount, address(token));
        token.burnEncrypted(alice, burnAmount);

        euint128 aliceBalance = token.encBalances(alice);
        assertHashValue(aliceBalance, MINT_AMOUNT - TRANSFER_AMOUNT);
    }

    function testBurnEncryptedMoreThanBalance() public {
        // Mint some amount
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Try to burn more than balance - should burn 0 (safe burn)
        InEuint128 memory burnAmount = createInEuint128(MINT_AMOUNT * 2, address(this));
        token.burnEncrypted(alice, burnAmount);

        // Balance should be unchanged because burn amount > balance
        // The _calculateBurnAmount returns ZERO when amount > balance
        euint128 aliceBalance = token.encBalances(alice);
        assertHashValue(aliceBalance, MINT_AMOUNT, "Balance should be unchanged when burning more than balance");
    }

    // ============================================
    // ENCRYPTED TRANSFER TESTS
    // ============================================

    function testTransferEncryptedWithInEuint128() public {
        // Mint to alice
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Alice transfers to bob
        vm.startPrank(alice);
        InEuint128 memory transferAmount = createInEuint128(TRANSFER_AMOUNT, alice);
        token.transferEncrypted(bob, transferAmount);
        vm.stopPrank();

        euint128 aliceBalance = token.encBalances(alice);
        euint128 bobBalance = token.encBalances(bob);

        assertHashValue(aliceBalance, MINT_AMOUNT - TRANSFER_AMOUNT);
        assertHashValue(bobBalance, TRANSFER_AMOUNT);
    }

    function testTransferEncryptedWithEuint128() public {
        // Mint to alice
        euint128 mintAmount = FHE.asEuint128(MINT_AMOUNT);
        FHE.allowThis(mintAmount);
        FHE.allow(mintAmount, address(token));
        token.mintEncrypted(alice, mintAmount);

        // Alice transfers to bob
        vm.startPrank(alice);
        euint128 transferAmount = FHE.asEuint128(TRANSFER_AMOUNT);
        FHE.allowThis(transferAmount);
        FHE.allow(transferAmount, address(token));
        token.transferEncrypted(bob, transferAmount);
        vm.stopPrank();

        euint128 aliceBalance = token.encBalances(alice);
        euint128 bobBalance = token.encBalances(bob);

        assertHashValue(aliceBalance, MINT_AMOUNT - TRANSFER_AMOUNT);
        assertHashValue(bobBalance, TRANSFER_AMOUNT);
    }

    function testTransferFromEncryptedWithInEuint128() public {
        // Mint to alice
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Transfer from alice to bob (called by anyone)
        InEuint128 memory transferAmount = createInEuint128(TRANSFER_AMOUNT, address(this));
        token.transferFromEncrypted(alice, bob, transferAmount);

        euint128 aliceBalance = token.encBalances(alice);
        euint128 bobBalance = token.encBalances(bob);

        assertHashValue(aliceBalance, MINT_AMOUNT - TRANSFER_AMOUNT);
        assertHashValue(bobBalance, TRANSFER_AMOUNT);
    }

    function testTransferFromEncryptedWithEuint128() public {
        // Mint to alice
        euint128 mintAmount = FHE.asEuint128(MINT_AMOUNT);
        FHE.allowThis(mintAmount);
        FHE.allow(mintAmount, address(token));
        token.mintEncrypted(alice, mintAmount);

        // Transfer from alice to bob
        euint128 transferAmount = FHE.asEuint128(TRANSFER_AMOUNT);
        FHE.allowThis(transferAmount);
        FHE.allow(transferAmount, address(token));
        token.transferFromEncrypted(alice, bob, transferAmount);

        euint128 aliceBalance = token.encBalances(alice);
        euint128 bobBalance = token.encBalances(bob);

        assertHashValue(aliceBalance, MINT_AMOUNT - TRANSFER_AMOUNT);
        assertHashValue(bobBalance, TRANSFER_AMOUNT);
    }

    function testTransferEncryptedMoreThanBalance() public {
        // Mint to alice
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Try to transfer more than balance - should transfer 0
        vm.startPrank(alice);
        InEuint128 memory transferAmount = createInEuint128(MINT_AMOUNT * 2, alice);
        token.transferEncrypted(bob, transferAmount);
        vm.stopPrank();

        // Alice should still have full balance, bob should have 0
        euint128 aliceBalance = token.encBalances(alice);
        euint128 bobBalance = token.encBalances(bob);

        assertHashValue(aliceBalance, MINT_AMOUNT);
        assertHashValue(bobBalance, 0);
    }

    // ============================================
    // ERROR CONDITION TESTS
    // ============================================

    function testTransferEncryptedFromZeroAddress() public {
        InEuint128 memory amount = createInEuint128(TRANSFER_AMOUNT, address(this));

        vm.expectRevert(HybridFHERC20.HybridFHERC20__InvalidSender.selector);
        token.transferFromEncrypted(address(0), bob, amount);
    }

    function testTransferEncryptedToZeroAddress() public {
        // Mint to alice first
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Try to transfer to zero address
        vm.startPrank(alice);
        InEuint128 memory transferAmount = createInEuint128(TRANSFER_AMOUNT, alice);
        vm.expectRevert(HybridFHERC20.HybridFHERC20__InvalidReceiver.selector);
        token.transferEncrypted(address(0), transferAmount);
        vm.stopPrank();
    }

    // ============================================
    // WRAP TESTS
    // ============================================

    function testWrap() public {
        // First mint public tokens to alice
        token.mint(alice, MINT_AMOUNT);
        assertEq(token.balanceOf(alice), MINT_AMOUNT);

        // Wrap public to encrypted
        token.wrap(alice, MINT_AMOUNT);

        // Public balance should be 0
        assertEq(token.balanceOf(alice), 0);

        // Encrypted balance should be MINT_AMOUNT
        euint128 aliceEncBalance = token.encBalances(alice);
        assertHashValue(aliceEncBalance, MINT_AMOUNT);
    }

    function testWrapPartial() public {
        // Mint public tokens
        token.mint(alice, MINT_AMOUNT);

        // Wrap only half
        uint128 wrapAmount = MINT_AMOUNT / 2;
        token.wrap(alice, wrapAmount);

        // Public balance should be half
        assertEq(token.balanceOf(alice), MINT_AMOUNT - wrapAmount);

        // Encrypted balance should be half
        euint128 aliceEncBalance = token.encBalances(alice);
        assertHashValue(aliceEncBalance, wrapAmount);
    }

    // ============================================
    // UNWRAP TESTS
    // ============================================

    function testRequestUnwrapWithInEuint128() public {
        // First mint encrypted tokens
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Request unwrap
        InEuint128 memory unwrapAmount = createInEuint128(TRANSFER_AMOUNT, address(this));
        euint128 burnAmount = token.requestUnwrap(alice, unwrapAmount);

        // Verify burn amount was calculated correctly
        assertHashValue(burnAmount, TRANSFER_AMOUNT);
    }

    function testRequestUnwrapWithEuint128() public {
        // First mint encrypted tokens
        euint128 mintAmount = FHE.asEuint128(MINT_AMOUNT);
        FHE.allowThis(mintAmount);
        FHE.allow(mintAmount, address(token));
        token.mintEncrypted(alice, mintAmount);

        // Request unwrap
        euint128 unwrapAmount = FHE.asEuint128(TRANSFER_AMOUNT);
        FHE.allowThis(unwrapAmount);
        FHE.allow(unwrapAmount, address(token));
        euint128 burnAmount = token.requestUnwrap(alice, unwrapAmount);

        // Verify burn amount was calculated correctly
        assertHashValue(burnAmount, TRANSFER_AMOUNT);
    }

    function testGetUnwrapResult() public {
        // Mint encrypted tokens
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Request unwrap
        InEuint128 memory unwrapAmount = createInEuint128(TRANSFER_AMOUNT, address(this));
        euint128 burnAmount = token.requestUnwrap(alice, unwrapAmount);

        // Wait for decryption to complete
        vm.warp(block.timestamp + 11);

        // Get unwrap result
        uint128 unwrappedAmount = token.getUnwrapResult(alice, burnAmount);

        assertEq(unwrappedAmount, TRANSFER_AMOUNT);

        // Public balance should now have unwrapped amount
        assertEq(token.balanceOf(alice), TRANSFER_AMOUNT);

        // Encrypted balance should be reduced
        euint128 aliceEncBalance = token.encBalances(alice);
        assertHashValue(aliceEncBalance, MINT_AMOUNT - TRANSFER_AMOUNT);
    }

    function testGetUnwrapResultSafe() public {
        // Mint encrypted tokens
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Request unwrap
        InEuint128 memory unwrapAmount = createInEuint128(TRANSFER_AMOUNT, address(this));
        euint128 burnAmount = token.requestUnwrap(alice, unwrapAmount);

        // Wait for decryption to complete
        vm.warp(block.timestamp + 11);

        // Get unwrap result safely
        (uint128 unwrappedAmount, bool decrypted) = token.getUnwrapResultSafe(alice, burnAmount);

        assertTrue(decrypted, "Should be decrypted");
        assertEq(unwrappedAmount, TRANSFER_AMOUNT);

        // Public balance should now have unwrapped amount
        assertEq(token.balanceOf(alice), TRANSFER_AMOUNT);

        // Encrypted balance should be reduced
        euint128 aliceEncBalance = token.encBalances(alice);
        assertHashValue(aliceEncBalance, MINT_AMOUNT - TRANSFER_AMOUNT);
    }

    // ============================================
    // DECRYPT BALANCE TESTS
    // ============================================

    function testDecryptBalance() public {
        // Mint encrypted tokens
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Request decryption
        token.decryptBalance(alice);

        // Wait for decryption to complete
        vm.warp(block.timestamp + 11);

        // Get decrypt result
        uint128 decryptedBalance = token.getDecryptBalanceResult(alice);
        assertEq(decryptedBalance, MINT_AMOUNT);
    }

    function testGetDecryptBalanceResultSafe() public {
        // Mint encrypted tokens
        InEuint128 memory mintAmount = createInEuint128(MINT_AMOUNT, address(this));
        token.mintEncrypted(alice, mintAmount);

        // Request decryption
        token.decryptBalance(alice);

        // Wait for decryption to complete
        vm.warp(block.timestamp + 11);

        // Get decrypt result safely
        (uint128 decryptedBalance, bool decrypted) = token.getDecryptBalanceResultSafe(alice);

        assertTrue(decrypted);
        assertEq(decryptedBalance, MINT_AMOUNT);
    }
}
