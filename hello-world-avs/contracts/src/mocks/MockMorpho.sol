// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockMorpho
 * @notice Mock Morpho protocol for testing
 * @dev Supports PT-USR as collateral with higher APY but higher borrow rates
 */
contract MockMorpho {
    // User collateral balances: user => token => amount
    mapping(address => mapping(address => uint256)) public collateralBalances;

    // User debt balances: user => (loanToken => (collateralToken => amount))
    mapping(address => mapping(address => mapping(address => uint256))) public debtBalances;

    // Borrow rates per collateral type in basis points per year
    mapping(address => uint256) public borrowRates; // Higher rate for PT-USR

    event Supply(address indexed user, address indexed collateralToken, uint256 amount, address indexed onBehalf);
    event Withdraw(address indexed user, address indexed asset, uint256 amount, address indexed onBehalf, address receiver);
    event Borrow(
        address indexed user,
        address indexed loanToken,
        address indexed collateralToken,
        uint256 lltv,
        uint256 assets,
        address onBehalf,
        address receiver
    );
    event Repay(
        address indexed user, address indexed loanToken, address indexed collateralToken, uint256 assets, address onBehalf
    );

    /**
     * @notice Set borrow rate for borrowing against a collateral type
     */
    function setBorrowRate(address collateralToken, uint256 rateBps) external {
        borrowRates[collateralToken] = rateBps;
    }

    /**
     * @notice Supply collateral (PT tokens)
     * @param collateralToken PT token address (e.g., PT-USR)
     * @param collateralTokenAmount Amount to supply
     * @param onBehalf Address to supply for
     */
    function supply(address collateralToken, uint256 collateralTokenAmount, address onBehalf) external {
        // Pull tokens from sender
        IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralTokenAmount);

        // Credit collateral balance
        collateralBalances[onBehalf][collateralToken] += collateralTokenAmount;

        emit Supply(msg.sender, collateralToken, collateralTokenAmount, onBehalf);
    }

    /**
     * @notice Withdraw collateral
     * @param asset Collateral token address
     * @param amount Amount to withdraw
     * @param onBehalf Address to withdraw from
     * @param receiver Address to receive tokens
     */
    function withdraw(address asset, uint256 amount, address onBehalf, address receiver) external {
        require(msg.sender == onBehalf || msg.sender == address(this), "Unauthorized");

        uint256 userBalance = collateralBalances[onBehalf][asset];
        require(amount <= userBalance, "Insufficient collateral");

        // Debit collateral balance
        collateralBalances[onBehalf][asset] -= amount;

        // Transfer tokens
        IERC20(asset).transfer(receiver, amount);

        emit Withdraw(msg.sender, asset, amount, onBehalf, receiver);
    }

    /**
     * @notice Borrow assets against collateral
     * @param loanToken Token to borrow (USDC/USDT)
     * @param collateralToken Collateral token (PT-USR)
     * @param lltv Loan-to-value ratio (unused in mock, but kept for interface)
     * @param assets Amount to borrow
     * @param onBehalf Address to borrow for
     * @param receiver Address to receive borrowed tokens
     */
    function borrow(
        address loanToken,
        address collateralToken,
        uint256 lltv,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        // Simple mock: allow borrowing without strict collateral checks
        // In production, would verify collateral value >= assets * lltv

        // Credit debt balance
        debtBalances[onBehalf][loanToken][collateralToken] += assets;

        // Transfer borrowed tokens
        IERC20(loanToken).transfer(receiver, assets);

        emit Borrow(msg.sender, loanToken, collateralToken, lltv, assets, onBehalf, receiver);
    }

    /**
     * @notice Repay borrowed assets
     * @param loanToken Token to repay (USDC/USDT)
     * @param collateralToken Collateral token used
     * @param assets Amount to repay
     * @param onBehalf Address to repay for
     */
    function repay(address loanToken, address collateralToken, uint256 assets, address onBehalf) external {
        uint256 userDebt = debtBalances[onBehalf][loanToken][collateralToken];
        require(assets <= userDebt, "Repay amount exceeds debt");

        // Pull repayment tokens
        IERC20(loanToken).transferFrom(msg.sender, address(this), assets);

        // Debit debt balance
        debtBalances[onBehalf][loanToken][collateralToken] -= assets;

        emit Repay(msg.sender, loanToken, collateralToken, assets, onBehalf);
    }

    /**
     * @notice Get user collateral balance
     */
    function getCollateralBalance(address user, address collateralToken) external view returns (uint256) {
        return collateralBalances[user][collateralToken];
    }

    /**
     * @notice Get user debt balance
     */
    function getDebtBalance(address user, address loanToken, address collateralToken) external view returns (uint256) {
        return debtBalances[user][loanToken][collateralToken];
    }

    /**
     * @notice Fund contract with tokens (for testing)
     */
    function fundContract(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}
