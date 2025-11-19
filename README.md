# SlimLend - DeFi Lending Protocol based on RareSkills exercise

A minimal, gas-efficient DeFi lending protocol built with Solidity that enables users to earn yield by providing liquidity and borrow assets against collateral.

## Overview

SlimLend is a two-sided lending market where:
- **Lenders** deposit assets to earn interest proportional to the utilization rate
- **Borrowers** deposit collateral to borrow assets, paying interest based on demand

The protocol uses a dynamic interest rate model that increases with utilization, with a kink mechanism that significantly raises rates near full capacity to protect liquidity providers.

## Key Features

### For Lenders (Liquidity Providers)
- **Deposit Assets**: Provide liquidity to earn yield
- **Receive LP Shares**: ERC20 tokens representing pool ownership
- **Redeem Shares**: Withdraw assets plus accrued interest at any time
- **Dynamic Yield**: Interest rates increase with pool utilization

### For Borrowers
- **Collateralized Borrowing**: Deposit collateral tokens to borrow asset tokens
- **Flexible Repayment**: Repay debt at any time to reduce or eliminate positions
- **Withdraw Collateral**: Remove collateral when debt is repaid or reduced
- **Oracle-Based Pricing**: Chainlink price feeds determine collateral value

## Technical Specifications

### Collateralization Requirements
- **Minimum Collateralization Ratio**: 150% (1.5x)
- **Liquidation Threshold**: 110% (1.1x)
- Positions below 110% can be liquidated by anyone

### Interest Rate Model
The protocol uses a two-tier interest rate model based on utilization:

- **Below Optimal Utilization (95%)**: Interest scales linearly from 0 to kink rate
- **Above Optimal Utilization**: Interest increases exponentially to maximum rate
- **Kink Rate**: ~5% APR at 95% utilization
- **Maximum Rate**: ~50% APR at 100% utilization

Interest accrues per second and compounds continuously through share price appreciation.

### Share Mechanism
The protocol uses two share systems:
1. **LP Shares**: ERC20 tokens for lenders, appreciate with earned interest
2. **Borrower Shares**: Internal accounting for borrowers, depreciate with accrued interest

## Core Functions

### Liquidity Provider Functions
- `lpDepositAsset(uint256 amount, uint256 minShares)` - Deposit assets, receive LP shares
- `lpRedeemShares(uint256 shares, uint256 minAmount)` - Redeem LP shares for assets

### Borrower Functions
- `borrowerDepositCollateral(uint256 amount)` - Deposit collateral tokens
- `borrow(uint256 amount)` - Borrow assets against collateral
- `repay(uint256 amount)` - Repay borrowed assets
- `borrowerWithdrawCollateral(uint256 amount)` - Withdraw collateral

### Liquidation
- `liquidate(address borrower, uint256 amount)` - Liquidate undercollateralized positions

### View Functions
- `collateralValue(address user)` - Get USD value of user's collateral
- `debtValue(address user)` - Get USD value of user's debt
- `collateralizationRatio(address user)` - Get current collateralization ratio
- `utilization()` - Get current pool utilization percentage

## Smart Contract Architecture

### Core Contract: `SlimLend.sol`
- Inherits from OpenZeppelin's ERC20 for LP share tokens
- Uses SafeERC20 for secure token transfers
- Integrates with Chainlink price feeds via `IPriceFeed` interface
- Implements fixed-point arithmetic with 18 decimal precision

### Dependencies
- OpenZeppelin Contracts (ERC20, SafeERC20)
- Chainlink Price Feeds
- Foundry for testing and deployment

## Security Features

- **Slippage Protection**: Min/max parameters on deposit/redeem functions
- **Collateralization Checks**: All borrowing/withdrawal operations verify ratio requirements
- **Oracle Integration**: External price feeds prevent price manipulation
- **Liquidation Mechanism**: Incentivizes maintenance of healthy positions
- **Integer Math Safety**: Uses OpenZeppelin's Math library for safe operations

## Testing

The protocol includes comprehensive test coverage:
- Unit tests for all core functions
- Integration tests simulating full user flows
- Edge case testing for collateralization scenarios
- Interest accrual verification over time
- Liquidation mechanism validation

### Run Tests
```shell
forge test
```

### Run Specific Test File
```shell
forge test --match-path test/SlimLend.borrow.t.sol
```

### Gas Snapshots
```shell
forge snapshot
```

## Build & Deploy

### Build
```shell
forge build
```

### Deploy
```shell
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --private-key <PRIVATE_KEY>
```

## License

BSL-3.0 (Business Source License 3.0)

## Disclaimer

This protocol is for educational purposes. It has not been audited. Do not use in production with real funds.
