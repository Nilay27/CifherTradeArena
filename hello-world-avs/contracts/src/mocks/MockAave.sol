// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockAave
 * @notice Mock Aave V3 Pool for testing
 * @dev Supports PT-eUSDE and PT-sUSDE as collateral, USDC/USDT borrowing
 */
contract MockAave {
    // User collateral balances: user => token => amount
    mapping(address => mapping(address => uint256)) public collateralBalances;

    // User debt balances: user => token => amount
    mapping(address => mapping(address => uint256)) public debtBalances;

    // Supported collateral tokens (PT tokens)
    mapping(address => bool) public supportedCollateral;

    // Borrow rates in basis points per year (e.g., 500 = 5% APY)
    mapping(address => uint256) public borrowRates;

    event Deposit(address indexed user, address indexed asset, uint256 amount, address indexed onBehalfOf);
    event Withdraw(address indexed user, address indexed asset, uint256 amount, address indexed to);
    event Borrow(
        address indexed user, address indexed asset, uint256 amount, uint256 interestRateMode, address indexed onBehalfOf
    );
    event Repay(address indexed user, address indexed asset, uint256 amount, address indexed onBehalfOf);

    /**
     * @notice Set supported collateral token
     */
    function setSupportedCollateral(address token, bool supported) external {
        supportedCollateral[token] = supported;
    }

    /**
     * @notice Set borrow rate for a token
     */
    function setBorrowRate(address token, uint256 rateBps) external {
        borrowRates[token] = rateBps;
    }

    /**
     * @notice Deposit collateral (PT tokens)
     * @param asset PT token address
     * @param amount Amount to deposit
     * @param onBehalfOf Address to deposit for
     * @param referralCode Referral code (unused)
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        require(supportedCollateral[asset], "Collateral not supported");

        // Pull tokens from sender
        IERC20(asset).transferFrom(msg.sender, address(this), amount);

        // Credit collateral balance
        collateralBalances[onBehalfOf][asset] += amount;

        emit Deposit(msg.sender, asset, amount, onBehalfOf);
    }

    /**
     * @notice Withdraw collateral
     * @param asset PT token address
     * @param amount Amount to withdraw (type(uint256).max for all)
     * @param to Address to send tokens to
     * @return Actual amount withdrawn
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 userBalance = collateralBalances[msg.sender][asset];
        uint256 amountToWithdraw = amount == type(uint256).max ? userBalance : amount;

        require(amountToWithdraw <= userBalance, "Insufficient collateral");

        // Debit collateral balance
        collateralBalances[msg.sender][asset] -= amountToWithdraw;

        // Transfer tokens
        IERC20(asset).transfer(to, amountToWithdraw);

        emit Withdraw(msg.sender, asset, amountToWithdraw, to);
        return amountToWithdraw;
    }

    /**
     * @notice Borrow assets (USDC/USDT)
     * @param asset Borrow token address
     * @param amount Amount to borrow
     * @param interestRateMode Interest rate mode (1=stable, 2=variable, unused in mock)
     * @param referralCode Referral code (unused)
     * @param onBehalfOf Address to borrow for
     */
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external
    {
        // Simple mock: allow borrowing without collateral checks
        // In production, would check collateral value vs borrow amount

        // Credit debt balance
        debtBalances[onBehalfOf][asset] += amount;

        // Transfer borrowed tokens
        IERC20(asset).transfer(msg.sender, amount);

        emit Borrow(msg.sender, asset, amount, interestRateMode, onBehalfOf);
    }

    /**
     * @notice Repay borrowed assets
     * @param asset Borrow token address
     * @param amount Amount to repay (type(uint256).max for all)
     * @param interestRateMode Interest rate mode (unused)
     * @param onBehalfOf Address to repay for
     * @return Actual amount repaid
     */
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256)
    {
        uint256 userDebt = debtBalances[onBehalfOf][asset];
        uint256 amountToRepay = amount == type(uint256).max ? userDebt : amount;

        require(amountToRepay <= userDebt, "Repay amount exceeds debt");

        // Pull repayment tokens
        IERC20(asset).transferFrom(msg.sender, address(this), amountToRepay);

        // Debit debt balance
        debtBalances[onBehalfOf][asset] -= amountToRepay;

        emit Repay(msg.sender, asset, amountToRepay, onBehalfOf);
        return amountToRepay;
    }

    /**
     * @notice Get user collateral balance
     */
    function getCollateralBalance(address user, address asset) external view returns (uint256) {
        return collateralBalances[user][asset];
    }

    /**
     * @notice Get user debt balance
     */
    function getDebtBalance(address user, address asset) external view returns (uint256) {
        return debtBalances[user][asset];
    }

    /**
     * @notice Fund contract with tokens (for testing)
     */
    function fundContract(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}
