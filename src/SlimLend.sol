// SPDX-License-Identifier: BSL-3.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {console} from "forge-std/Test.sol";

contract SlimLend is ERC20("LPSlimShares", "LPS") {
    using SafeERC20 for IERC20;

    uint256 totalDepositedTokens;
    uint256 totalBorrowedTokens;
    uint256 lpSharePrice = 1e18;
    uint256 borrowerSharePrice = 1e18;
    uint256 lastUpdateTime = block.timestamp;
    IERC20 immutable assetToken;
    IERC20 immutable collateralToken;
    IPriceFeed immutable priceFeed;

    uint256 constant MIN_COLLATERALIZATION_RATIO = 1.5e18;
    uint256 constant LIQUIDATION_THRESHOLD = 1.1e18;
    uint256 constant OPTIMAL_UTILIZATION = 0.95e18;
    uint256 constant KINK_INTEREST_PER_SECOND = 1585489599; // see test for derivation
    uint256 constant MAX_INTEREST_PER_SECOND = 15854895991; // see test for derivation

    error Slippage();
    error InsufficientLiquidity();
    error MinCollateralization();
    error HealthyAccount();
    error InsufficientCollateral();

    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPRedeem(address indexed user, uint256 shares, uint256 amount);
    event DepositCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 amount
    );
    event WithdrawCollateral(address indexed user, uint256 amount);

    struct BorrowerInfo {
        uint256 borrowerShares;
        uint256 collateralTokenAmount;
    }

    mapping(address => BorrowerInfo) public borrowerInfo;

    constructor(
        IERC20 _assetToken,
        IERC20 _collateralToken,
        IPriceFeed _priceFeed
    ) {
        assetToken = _assetToken;
        collateralToken = _collateralToken;
        priceFeed = _priceFeed;
    }

    /**
     * @notice Calculate the current utilization of the pool
     * @dev For simplicity, utilization does NOT include interest accrued, only the raw amount of deposit/borrow
     * @return The utilization ratio (total borrowed / total deposited) with 18 decimals
     */
    function utilization() public view returns (uint256) {
        if (totalDepositedTokens == 0) {
            return 0;
        }
        return Math.mulDiv(totalBorrowedTokens, 1e18, totalDepositedTokens);
    }

    /*
     * @notice Calculate the current interest rates based on utilization
     * @param _utilization The current utilization ratio with 18 decimals
     * @return borrowerRate The interest rate paid by borrowers with 18 decimals
     * @return lenderRate The interest rate earned by lenders with 18 decimals
     */
    function interestRate(
        uint256 _utilization
    ) public pure returns (uint256 borrowerRate, uint256 lenderRate) {
        /*
        Sketch
        if(_utilization <= OPTIMAL_UTILIZATION) {
            return 
        } else {

        }*/
        if (_utilization <= OPTIMAL_UTILIZATION) {
            // linear: at the kink point (OPTIMAL)
            borrowerRate = Math.mulDiv(
                _utilization,
                KINK_INTEREST_PER_SECOND,
                OPTIMAL_UTILIZATION
            );
        } else {
            uint256 denom = 1e18 - OPTIMAL_UTILIZATION;
            uint256 numerator = MAX_INTEREST_PER_SECOND -
                KINK_INTEREST_PER_SECOND;
            borrowerRate =
                Math.mulDiv(
                    _utilization - OPTIMAL_UTILIZATION,
                    numerator,
                    denom
                ) +
                KINK_INTEREST_PER_SECOND;
        }
        lenderRate = Math.mulDiv(borrowerRate, _utilization, 1e18);
    }

    function _updateSharePrices() internal {
        uint256 timePassed = _subFloorZero(block.timestamp, lastUpdateTime);
        if (timePassed == 0) {
            return;
        }

        (uint256 borrowerRate, uint256 lenderRate) = interestRate(
            utilization()
        );
        if (borrowerRate == 0 && lenderRate == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }

        // Lender side: lpSharePrice *= (1 + lenderRate * dt)
        {
            uint256 lenderAccum = lenderRate * timePassed; // still 1e18-scaled
            uint256 lpDelta = Math.mulDiv(lpSharePrice, lenderAccum, 1e18);
            lpSharePrice += lpDelta;
        }

        // Borrower side: borrowerSharePrice *= (1 + borrowerRate * dt)
        {
            uint256 borrowerAccum = borrowerRate * timePassed;
            uint256 borrowerDelta = Math.mulDiv(
                borrowerSharePrice,
                borrowerAccum,
                1e18
            );
            borrowerSharePrice += borrowerDelta;
        }

        lastUpdateTime = block.timestamp;
    }

    // function _updateSharePrices() internal {
    //     (uint256 borrowerRate, uint256 lenderRate) = interestRate(
    //         utilization()
    //     );
    //     uint256 timePassed = _subFloorZero(block.timestamp, lastUpdateTime);
    //     // uint256 effectiveLenderRate = Math.modExp(
    //     //     1e18 + lenderRate,
    //     //     timePassed,
    //     //     type(uint256).max
    //     // );
    //     // uint256 effectiveBorrowerRate = Math.modExp(
    //     //     1e18 + lenderRate,
    //     //     timePassed,
    //     //     type(uint256).max
    //     // );

    //     // lpSharePrice = Math.mulDiv(effectiveLenderRate, lpSharePrice, 1e18);
    //     // borrowerSharePrice = Math.mulDiv(
    //     //     effectiveBorrowerRate,
    //     //     borrowerSharePrice,
    //     //     1e18
    //     // );
    //     lastUpdateTime = block.timestamp;
    // }

    /*
     * @notice Deposit asset token to earn interest and receive LP shares
     * @param amount The amount of asset token to deposit
     * @param minSharesOut The minimum amount of LP shares to receive (slippage protection)
     */
    function lpDepositAsset(uint256 amount, uint256 minSharesOut) public {
        _updateSharePrices();

        // uint256 totalShares = totalSupply();
        uint256 sharesOut = Math.mulDiv(amount, 1e18, lpSharePrice);
        // if ((totalShares != 0) && (totalDepositedTokens != 0)) {
        //     // sharesOut = Math.mulDiv(amount, totalShares, totalDepositedTokens);
        // }
        require(sharesOut >= minSharesOut, Slippage());
        assetToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, sharesOut);
        totalDepositedTokens += amount;
        emit LPDeposit(msg.sender, amount, sharesOut);
    }

    /*
     * @notice Redeem asset token by burning LP shares
     * @param amountShares The amount of LP shares to burn
     * @param minAmountAssetOut The minimum amount of asset token to receive (slippage protection)
     */
    function lpRedeemShares(
        uint256 amountShares,
        uint256 minAmountAssetOut
    ) public {
        _updateSharePrices();

        uint256 assetsOut = Math.mulDiv(amountShares, lpSharePrice, 1e18);
        require(assetsOut >= minAmountAssetOut, Slippage());
        require(
            totalDepositedTokens - totalBorrowedTokens >= assetsOut,
            InsufficientLiquidity()
        );
        _burn(msg.sender, amountShares);
        assetToken.safeTransfer(msg.sender, assetsOut);
        totalDepositedTokens -= assetsOut;
        emit LPRedeem(msg.sender, amountShares, assetsOut);
    }

    /*
     * @notice Deposit collateral token
     * @param amount The amount of collateral token to deposit
     */
    function borrowerDepositCollateral(uint256 amount) public {
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        BorrowerInfo storage c = borrowerInfo[msg.sender];
        c.collateralTokenAmount += amount;
        console.log(
            "borrower shares:",
            borrowerInfo[msg.sender].borrowerShares
        );
        console.log(
            "borrower collateral:",
            borrowerInfo[msg.sender].collateralTokenAmount
        );
        emit DepositCollateral(msg.sender, amount);
    }

    /*
     * @notice Withdraw collateral token. Cannot withdraw if it would cause the borrower's
     *         collateralization ratio to fall below the minimum.
     * @param amount The amount of collateral token to withdraw
     */
    function borrowerWithdrawCollateral(uint256 amount) public {
        _updateSharePrices();

        BorrowerInfo storage b = borrowerInfo[msg.sender];
        // uint256 sharesValue = Math.mulDiv(amount, borrowerSharePrice, 1e18);
        // console.log("Collateral:", collateralValue(msg.sender));
        // console.log("debt shares:", sharesValue);
        // console.log("min ratio:", MIN_COLLATERALIZATION_RATIO);
        // console.log("amount:", amount);
        // console.log(
        //     "collateral - shares - amount:",
        //     collateralValue(msg.sender) - sharesValue - amount
        // );
        require(b.collateralTokenAmount >= amount, InsufficientCollateral());
        b.collateralTokenAmount -= amount;
        collateralToken.safeTransfer(msg.sender, amount);

        require(
            collateralization_ratio(msg.sender) >= MIN_COLLATERALIZATION_RATIO,
            MinCollateralization()
        );

        // collateralization_ratio(borrower)

        // require(
        //     collateralValue(msg.sender) - sharesValue - amount >
        //         Math.mulDiv(MIN_COLLATERALIZATION_RATIO, lpSharePrice, 1e18),
        //     MinCollateralization()
        // );

        emit WithdrawCollateral(msg.sender, amount);
    }

    /*
     * @notice Borrow asset token. Assumes collateral has already been deposited
     * @param amount The amount of asset token to borrow
     */
    function borrow(uint256 amount) public {
        _updateSharePrices();

        if (amount == 0) {
            return;
        }

        require(
            amount <= assetToken.balanceOf(address(this)),
            InsufficientLiquidity()
        );
        BorrowerInfo storage b = borrowerInfo[msg.sender];
        b.borrowerShares += Math.mulDiv(amount, 1e18, borrowerSharePrice);
        require(b.borrowerShares > 0);
        assetToken.safeTransfer(msg.sender, amount);
        require(
            collateralization_ratio(msg.sender) >= MIN_COLLATERALIZATION_RATIO,
            MinCollateralization()
        );
        console.log("amount:", amount);
        console.log("ratio: ", collateralization_ratio(msg.sender));
        console.log("min: ", MIN_COLLATERALIZATION_RATIO);
        totalBorrowedTokens += amount;
        emit Borrow(msg.sender, amount);
    }

    /*
     * @notice Calculate the value of a borrower's collateral in asset token
     * @param borrower The address of the borrower to check
     * @return The dollar value of the borrower's collateral in asset token with 18 decimals
     */
    function collateralValue(address borrower) public view returns (uint256) {
        (, int256 collateralPriceInt, , , ) = priceFeed.latestRoundData();
        return
            Math.mulDiv(
                borrowerInfo[borrower].collateralTokenAmount,
                uint256(collateralPriceInt),
                1e8
            );
    }

    /*
     * @notice Calculate the collateralization ratio of a borrower
     * @param borrower The address of the borrower to check
     * @return The collateralization ratio (collateral value / debt value) with 18 decimals
     *         If the borrower has no debt, returns type(uint256).max
     */
    function collateralization_ratio(
        address borrower
    ) public view returns (uint256) {
        BorrowerInfo memory b = borrowerInfo[borrower];
        if (b.borrowerShares == 0) {
            return type(uint256).max;
        }
        uint256 sharesValue = Math.mulDiv(
            b.borrowerShares,
            borrowerSharePrice,
            1e18
        );

        console.log("collateral: ", b.collateralTokenAmount);
        console.log("collateral value:", collateralValue(borrower));
        console.log("borrower shares:", b.borrowerShares);
        console.log("borrower share price:", borrowerSharePrice);
        console.log("shares value:", sharesValue);
        return Math.mulDiv(collateralValue(borrower), 1e18, sharesValue);
    }

    /*
     * @notice Repay borrowed asset token to reduce debt
     * @param amountAsset The amount of asset token to repay
     * @param minBorrowSharesBurned The minimum amount of borrower shares to burn (slippage protection)
     */
    function repay(uint256 amountAsset, uint256 minBorrowSharesBurned) public {
        _updateSharePrices();

        BorrowerInfo storage b = borrowerInfo[msg.sender];
        // (, int256 price, , , ) = priceFeed.latestRoundData();
        // uint256 amountAssetValue = Math.mulDiv(
        //     amountAsset,
        //     uint256(price),
        //     1e8
        // );
        uint256 sharesToBurn = Math.mulDiv(
            amountAsset,
            1e18,
            borrowerSharePrice
        );
        // console.log("price:", price);
        console.log("amountAsset:", amountAsset);
        // console.log("amountAssetValue:", amountAssetValue);
        console.log("borrowerSharePrice:", borrowerSharePrice);
        console.log("sharesToBurn: ", sharesToBurn);
        require(sharesToBurn >= minBorrowSharesBurned, Slippage());

        // _burn(msg.sender, sharesToBurn);
        assetToken.safeTransferFrom(msg.sender, address(this), amountAsset);
        uint256 borrowerShares = b.borrowerShares;
        b.borrowerShares = _subFloorZero(borrowerShares, sharesToBurn);
        totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, sharesToBurn);

        emit Repay(msg.sender, sharesToBurn);
    }

    // if x < y return 0, else x - y
    function _subFloorZero(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return x < y ? 0 : x - y;
    }

    /*
     * @notice Check if a borrower can be liquidated
     * @param borrower The address of the borrower to check
     * @return True if the borrower can be liquidated, false otherwise
     */
    function canLiquidate(address borrower) public view returns (bool) {
        return collateralization_ratio(borrower) < LIQUIDATION_THRESHOLD;
    }

    /*
     * @notice Liquidate a borrower if their collateralization ratio is below the liquidation threshold.
     *         Seize all of the borrower's collateral in exchange for repaying all of their debt.
     *         This liquidation strategy is unsafe because if the debt goes underwater, nobody has an incentive
     *         to liquidate. This is acceptable for a demo / educational project but not for production.
     * @dev The liquidator must approve the contract to spend the borrower's debt amount in asset token
     * @param borrower The address of the borrower to liquidate
     */
    function liquidate(address borrower) public {
        console.log("collateral_ratio:", collateralization_ratio(borrower));
        _updateSharePrices(); // TODO: Wasn't checked in the tests (add a counter-test)
        if (canLiquidate(borrower)) {
            BorrowerInfo storage b = borrowerInfo[borrower];
            uint256 amountNeeded = Math.mulDiv(
                b.borrowerShares,
                borrowerSharePrice,
                1e18
            );
            assetToken.safeTransferFrom(
                msg.sender,
                address(this),
                amountNeeded
            );
            uint256 collateralAmount = b.collateralTokenAmount;
            collateralToken.safeTransfer(msg.sender, collateralAmount);
            totalBorrowedTokens = _subFloorZero(
                totalBorrowedTokens,
                amountNeeded
            );
            b.borrowerShares = 0;
            b.collateralTokenAmount = 0;

            // or delete b
            emit Liquidate(msg.sender, borrower, collateralAmount);
            return;
        }
        revert HealthyAccount();
    }
}
