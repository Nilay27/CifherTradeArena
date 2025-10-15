// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";
import {FHE, euint128, euint32, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title CoFheUtils
 * @notice Comprehensive testing utilities for FHE encrypted values using CoFHE mock contracts
 * @dev This library provides helpers to properly verify encrypted values in tests instead of treating them as black boxes.
 *      Since CoFHE mock contracts store plaintext values in the TaskManager, we can extract and compare them.
 */
abstract contract CoFheUtils is Test, CoFheTest {

    // ============================================
    // MOCK STORAGE HELPERS
    // ============================================

    /**
     * @notice Helper to retrieve plaintext value from mock storage for euint128
     * @param value The encrypted euint128 value
     * @return The plaintext uint128 value stored in mock storage
     */
    function getMockValue(euint128 value) internal view returns (uint128) {
        return uint128(mockStorage(euint128.unwrap(value)));
    }

    /**
     * @notice Helper to retrieve plaintext value from mock storage for euint32
     * @param value The encrypted euint32 value
     * @return The plaintext uint32 value stored in mock storage
     */
    function getMockValue(euint32 value) internal view returns (uint32) {
        return uint32(mockStorage(euint32.unwrap(value)));
    }

    /**
     * @notice Helper to retrieve plaintext value from mock storage for ebool
     * @param value The encrypted ebool value
     * @return The plaintext bool value stored in mock storage
     */
    function getMockValue(ebool value) internal view returns (bool) {
        return mockStorage(ebool.unwrap(value)) == 1;
    }

    // ============================================
    // EQUALITY ASSERTIONS - euint128
    // ============================================

    /**
     * @notice Assert two encrypted euint128 values are equal
     * @param a First encrypted value
     * @param b Second encrypted value
     */
    function assertEqEuint(euint128 a, euint128 b) internal view {
        assertEq(getMockValue(a), getMockValue(b), "euint128 values not equal");
    }

    /**
     * @notice Assert two encrypted euint128 values are equal with custom error message
     */
    function assertEqEuint(euint128 a, euint128 b, string memory message) internal view {
        assertEq(getMockValue(a), getMockValue(b), message);
    }

    /**
     * @notice Assert encrypted euint128 equals plaintext value
     * @param a Encrypted value
     * @param b Plaintext value
     */
    function assertEqEuint(euint128 a, uint128 b) internal view {
        assertHashValue(a, b);
    }

    /**
     * @notice Assert plaintext equals encrypted euint128
     */
    function assertEqEuint(uint128 a, euint128 b) internal view {
        assertHashValue(b, a);
    }

    /**
     * @notice Assert encrypted euint128 with offset equals another encrypted value
     * @param a First encrypted value
     * @param aOffset Offset to apply to first value (can be positive or negative)
     * @param b Second encrypted value
     */
    function assertEqEuint(euint128 a, int128 aOffset, euint128 b) internal view {
        int128 aAfterOffset = int128(getMockValue(a)) + aOffset;
        require(aAfterOffset >= 0, "Offset caused underflow");
        assertEq(uint128(aAfterOffset), getMockValue(b), "euint128 values with offset not equal");
    }

    /**
     * @notice Assert encrypted euint128 equals another with offset applied
     * @param a First encrypted value
     * @param b Second encrypted value
     * @param bOffset Offset to apply to second value
     */
    function assertEqEuint(euint128 a, euint128 b, int128 bOffset) internal view {
        int128 bAfterOffset = int128(getMockValue(b)) + bOffset;
        require(bAfterOffset >= 0, "Offset caused underflow");
        assertEq(getMockValue(a), uint128(bAfterOffset), "euint128 values with offset not equal");
    }

    // ============================================
    // COMPARISON ASSERTIONS - euint128
    // ============================================

    /**
     * @notice Assert first encrypted value is less than second
     * @param a First encrypted value
     * @param b Second encrypted value
     */
    function assertLtEuint(euint128 a, euint128 b) internal view {
        assertTrue(getMockValue(a) < getMockValue(b), "a should be < b");
    }

    /**
     * @notice Assert first encrypted value is less than second with message
     */
    function assertLtEuint(euint128 a, euint128 b, string memory message) internal view {
        assertTrue(getMockValue(a) < getMockValue(b), message);
    }

    /**
     * @notice Assert encrypted value is less than plaintext value
     */
    function assertLtEuint(euint128 a, uint128 b) internal view {
        assertTrue(getMockValue(a) < b, "encrypted value should be < plaintext");
    }

    /**
     * @notice Assert first encrypted value is less than or equal to second
     */
    function assertLteEuint(euint128 a, euint128 b) internal view {
        assertTrue(getMockValue(a) <= getMockValue(b), "a should be <= b");
    }

    /**
     * @notice Assert first encrypted value is less than or equal to second with message
     */
    function assertLteEuint(euint128 a, euint128 b, string memory message) internal view {
        assertTrue(getMockValue(a) <= getMockValue(b), message);
    }

    /**
     * @notice Assert first encrypted value is greater than second
     */
    function assertGtEuint(euint128 a, euint128 b) internal view {
        assertTrue(getMockValue(a) > getMockValue(b), "a should be > b");
    }

    /**
     * @notice Assert first encrypted value is greater than second with message
     */
    function assertGtEuint(euint128 a, euint128 b, string memory message) internal view {
        assertTrue(getMockValue(a) > getMockValue(b), message);
    }

    /**
     * @notice Assert encrypted value is greater than plaintext value
     */
    function assertGtEuint(euint128 a, uint128 b) internal view {
        assertTrue(getMockValue(a) > b, "encrypted value should be > plaintext");
    }

    /**
     * @notice Assert encrypted value is greater than plaintext value with message
     */
    function assertGtEuint(euint128 a, uint128 b, string memory message) internal view {
        assertTrue(getMockValue(a) > b, message);
    }

    /**
     * @notice Assert first encrypted value is greater than or equal to second
     */
    function assertGteEuint(euint128 a, euint128 b) internal view {
        assertTrue(getMockValue(a) >= getMockValue(b), "a should be >= b");
    }

    /**
     * @notice Assert first encrypted value is greater than or equal to second with message
     */
    function assertGteEuint(euint128 a, euint128 b, string memory message) internal view {
        assertTrue(getMockValue(a) >= getMockValue(b), message);
    }

    // ============================================
    // NORMALIZED COMPARISON - euint128
    // ============================================

    /**
     * @notice Assert two encrypted values are equal after normalizing first value
     * @dev Useful for comparing values that may have rounding due to operations
     * @param a First encrypted value (to be normalized)
     * @param aAmount Normalization amount (e.g., for precision handling)
     * @param b Second encrypted value
     */
    function assertEqEuintNormalise(euint128 a, uint128 aAmount, euint128 b) internal view {
        uint128 aNormalized = (getMockValue(a) / aAmount) * aAmount;
        assertEq(aNormalized, getMockValue(b), "Normalized euint128 values not equal");
    }

    /**
     * @notice Assert two encrypted values are equal after normalizing second value
     */
    function assertEqEuintNormalise(euint128 a, euint128 b, uint128 bAmount) internal view {
        uint128 bNormalized = (getMockValue(b) / bAmount) * bAmount;
        assertEq(getMockValue(a), bNormalized, "Normalized euint128 values not equal");
    }

    /**
     * @notice Assert encrypted values are equal after normalizing first and offsetting second
     */
    function assertEqEuintNormalise(euint128 a, uint128 aAmount, euint128 b, int128 bOffset) internal view {
        uint128 aNormalized = (getMockValue(a) / aAmount) * aAmount;
        int128 bAfterOffset = int128(getMockValue(b)) + bOffset;
        require(bAfterOffset >= 0, "Offset caused underflow");
        assertEq(aNormalized, uint128(bAfterOffset), "Normalized/offset euint128 values not equal");
    }

    /**
     * @notice Assert encrypted values are equal after offsetting first and normalizing second
     */
    function assertEqEuintNormalise(euint128 a, int128 aOffset, euint128 b, uint128 bAmount) internal view {
        int128 aAfterOffset = int128(getMockValue(a)) + aOffset;
        require(aAfterOffset >= 0, "Offset caused underflow");
        uint128 bNormalized = (getMockValue(b) / bAmount) * bAmount;
        assertEq(uint128(aAfterOffset), bNormalized, "Offset/normalized euint128 values not equal");
    }

    // ============================================
    // DIFFERENCE ASSERTIONS - euint128
    // ============================================

    /**
     * @notice Assert the difference between two encrypted values equals expected amount
     * @param a First encrypted value (larger)
     * @param b Second encrypted value (smaller)
     * @param expectedDiff Expected difference (a - b)
     */
    function assertDiffEuint(euint128 a, euint128 b, uint128 expectedDiff) internal view {
        uint128 actualDiff = getMockValue(a) - getMockValue(b);
        assertEq(actualDiff, expectedDiff, "Difference between encrypted values incorrect");
    }

    /**
     * @notice Assert encrypted value increased by expected amount
     * @param beforeVal Encrypted value before operation
     * @param afterVal Encrypted value after operation
     * @param expectedIncrease Expected increase amount
     */
    function assertIncreasedBy(euint128 beforeVal, euint128 afterVal, uint128 expectedIncrease) internal view {
        uint128 actualIncrease = getMockValue(afterVal) - getMockValue(beforeVal);
        assertEq(actualIncrease, expectedIncrease, "Value did not increase by expected amount");
    }

    /**
     * @notice Assert encrypted value decreased by expected amount
     */
    function assertDecreasedBy(euint128 beforeVal, euint128 afterVal, uint128 expectedDecrease) internal view {
        uint128 actualDecrease = getMockValue(beforeVal) - getMockValue(afterVal);
        assertEq(actualDecrease, expectedDecrease, "Value did not decrease by expected amount");
    }

    // ============================================
    // BOOLEAN ASSERTIONS - ebool
    // ============================================

    /**
     * @notice Assert encrypted boolean is true
     */
    function assertTrueEbool(ebool value) internal view {
        assertTrue(getMockValue(value), "ebool should be true");
    }

    /**
     * @notice Assert encrypted boolean is true with message
     */
    function assertTrueEbool(ebool value, string memory message) internal view {
        assertTrue(getMockValue(value), message);
    }

    /**
     * @notice Assert encrypted boolean is false
     */
    function assertFalseEbool(ebool value) internal view {
        assertFalse(getMockValue(value), "ebool should be false");
    }

    /**
     * @notice Assert encrypted boolean is false with message
     */
    function assertFalseEbool(ebool value, string memory message) internal view {
        assertFalse(getMockValue(value), message);
    }

    /**
     * @notice Assert two encrypted booleans are equal
     */
    function assertEqEbool(ebool a, ebool b) internal view {
        assertEq(getMockValue(a), getMockValue(b), "ebool values not equal");
    }

    /**
     * @notice Assert encrypted boolean equals plaintext boolean
     */
    function assertEqEbool(ebool a, bool b) internal view {
        assertHashValue(a, b);
    }

    // ============================================
    // EQUALITY ASSERTIONS - euint32
    // ============================================

    /**
     * @notice Assert two encrypted euint32 values are equal
     */
    function assertEqEuint32(euint32 a, euint32 b) internal view {
        assertEq(getMockValue(a), getMockValue(b), "euint32 values not equal");
    }

    /**
     * @notice Assert encrypted euint32 equals plaintext value
     */
    function assertEqEuint32(euint32 a, uint32 b) internal view {
        assertHashValue(a, b);
    }

    // ============================================
    // RANGE ASSERTIONS - euint128
    // ============================================

    /**
     * @notice Assert encrypted value is within range [min, max] inclusive
     */
    function assertInRange(euint128 value, uint128 min, uint128 max) internal view {
        uint128 actual = getMockValue(value);
        assertTrue(actual >= min && actual <= max, "Value not in expected range");
    }

    /**
     * @notice Assert encrypted value is within range with message
     */
    function assertInRange(euint128 value, uint128 min, uint128 max, string memory message) internal view {
        uint128 actual = getMockValue(value);
        assertTrue(actual >= min && actual <= max, message);
    }

    /**
     * @notice Assert encrypted value is not zero
     */
    function assertNotZeroEuint(euint128 value) internal view {
        assertTrue(getMockValue(value) != 0, "euint128 should not be zero");
    }

    /**
     * @notice Assert encrypted value is zero
     */
    function assertZeroEuint(euint128 value) internal view {
        assertEq(getMockValue(value), 0, "euint128 should be zero");
    }

    // ============================================
    // BATCH BALANCE CHECKING
    // ============================================

    /**
     * @notice Snapshot of encrypted balance for before/after comparisons
     */
    struct BalanceSnapshot {
        uint128 value;
    }

    /**
     * @notice Create a balance snapshot from encrypted value
     */
    function snapshot(euint128 balance) internal view returns (BalanceSnapshot memory) {
        return BalanceSnapshot({value: getMockValue(balance)});
    }

    /**
     * @notice Assert balance increased from snapshot by expected amount
     */
    function assertIncreasedBy(
        BalanceSnapshot memory beforeSnap,
        euint128 afterVal,
        uint128 expectedIncrease
    ) internal view {
        uint128 actualIncrease = getMockValue(afterVal) - beforeSnap.value;
        assertEq(actualIncrease, expectedIncrease, "Balance did not increase by expected amount");
    }

    /**
     * @notice Assert balance decreased from snapshot by expected amount
     */
    function assertDecreasedBy(
        BalanceSnapshot memory beforeSnap,
        euint128 afterVal,
        uint128 expectedDecrease
    ) internal view {
        uint128 actualDecrease = beforeSnap.value - getMockValue(afterVal);
        assertEq(actualDecrease, expectedDecrease, "Balance did not decrease by expected amount");
    }

    /**
     * @notice Assert balance unchanged from snapshot
     */
    function assertUnchanged(BalanceSnapshot memory beforeSnap, euint128 afterVal) internal view {
        assertEq(beforeSnap.value, getMockValue(afterVal), "Balance should not have changed");
    }

    // ============================================
    // DEBUGGING HELPERS
    // ============================================

    /**
     * @notice Log encrypted euint128 value for debugging
     */
    function logEuint128(string memory label, euint128 value) internal {
        emit log_named_uint(label, getMockValue(value));
    }

    /**
     * @notice Log encrypted ebool value for debugging
     */
    function logEbool(string memory label, ebool value) internal {
        emit log_named_string(label, getMockValue(value) ? "true" : "false");
    }

    /**
     * @notice Log two encrypted values side by side for comparison
     */
    function logComparison(string memory label, euint128 a, euint128 b) internal {
        emit log_named_uint(string(abi.encodePacked(label, " (a)")), getMockValue(a));
        emit log_named_uint(string(abi.encodePacked(label, " (b)")), getMockValue(b));
    }
}
