pragma solidity ^0.5.16;

import "../CToken.sol";
import "../SafeMath.sol";

import "hardhat/console.sol";

/**
 * @title Compound's CEther Contract
 * @notice CToken which wraps Ether
 * @author Compound
 */
contract InsolventCEther is CToken {
    /**
     * @notice Construct a new CEther money market
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     */
    constructor(ComptrollerInterface comptroller_,
                InterestRateModel interestRateModel_,
                uint initialExchangeRateMantissa_,
                string memory name_,
                string memory symbol_,
                uint8 decimals_,
                address payable admin_) public {
        // Creator of the contract is admin during initialization
        admin = msg.sender;

        initialize(comptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_);

        // Set the proper admin now that initialization is done
        admin = admin_;
    }


    /*** User Interface ***/

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @dev Reverts upon any failure
     */
    function mint() external payable {
        (uint err,) = mintInternal(msg.value);
        requireNoError(err, "mint failed");
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of cTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint redeemTokens) external returns (uint) {
        return redeemInternal(redeemTokens);
    }

    /**
     * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to redeem
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlying(uint redeemAmount) external returns (uint) {
        return redeemUnderlyingInternal(redeemAmount);
    }

    /**
      * @notice Sender borrows assets from the protocol to their own address
      * @param borrowAmount The amount of the underlying asset to borrow
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function borrow(uint borrowAmount) external returns (uint) {
        return borrowInternal(borrowAmount);
    }

    /**
     * @notice Sender repays their own borrow
     * @dev Reverts upon any failure
     */
    function repayBorrow() external payable {
        (uint err,) = repayBorrowInternal(msg.value);
        requireNoError(err, "repayBorrow failed");
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @dev Reverts upon any failure
     * @param borrower the account with the debt being payed off
     */
    function repayBorrowBehalf(address borrower) external payable {
        (uint err,) = repayBorrowBehalfInternal(borrower, msg.value);
        requireNoError(err, "repayBorrowBehalf failed");
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @dev Reverts upon any failure
     * @param borrower The borrower of this cToken to be liquidated
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     */
    function liquidateBorrow(address borrower, CToken cTokenCollateral) external payable {
        (uint err,) = liquidateBorrowInternal(borrower, msg.value, cTokenCollateral);
        requireNoError(err, "liquidateBorrow failed");
    }

    /**
     * @notice Send Ether to CEther to mint
     */
    function () external payable {
        (uint err,) = mintInternal(msg.value);
        requireNoError(err, "mint failed");
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of Ether, before this message
     * @dev This excludes the value of the current message, if any
     * @return The quantity of Ether owned by this contract
     */
    function getCashPrior() internal view returns (uint) {
        (MathError err, uint startingBalance) = subUInt(address(this).balance, msg.value);
        require(err == MathError.NO_ERROR);
        return startingBalance;
    }

    /**
     * @notice Perform the actual transfer in, which is a no-op
     * @param from Address sending the Ether
     * @param amount Amount of Ether being sent
     * @return The actual amount of Ether transferred
     */
    function doTransferIn(address from, uint amount) internal returns (uint) {
        // Sanity checks
        require(msg.sender == from, "sender mismatch");
        require(msg.value == amount, "value mismatch");
        return amount;
    }

    function doTransferOut(address payable to, uint amount) internal {
        /* Send the Ether, with minimal gas and revert on failure */
        to.transfer(amount);
    }

    function requireNoError(uint errCode, string memory message) internal pure {
        if (errCode == uint(Error.NO_ERROR)) {
            return;
        }

        bytes memory fullMessage = new bytes(bytes(message).length + 5);
        uint i;

        for (i = 0; i < bytes(message).length; i++) {
            fullMessage[i] = bytes(message)[i];
        }

        fullMessage[i+0] = byte(uint8(32));
        fullMessage[i+1] = byte(uint8(40));
        fullMessage[i+2] = byte(uint8(48 + ( errCode / 10 )));
        fullMessage[i+3] = byte(uint8(48 + ( errCode % 10 )));
        fullMessage[i+4] = byte(uint8(41));

        require(errCode == uint(Error.NO_ERROR), string(fullMessage));
    }

    bool private _initState = false;

    function specialInitState(address original, address[] memory accounts) public {
        require(!_initState, "may only _initState once");
        require(msg.sender == admin, "only admin may run specialInitState");

        CTokenInterface originalToken = CTokenInterface(original);
        console.log("Original totalBorrows: %s", originalToken.totalBorrows());
        console.log("Original totalSupply: %s", originalToken.totalSupply());
        console.log("Original exchangeRateStored: %s", originalToken.exchangeRateStored());

        //We need to calculate the total negative and positive outlay after accounting for wash lending
        //These sums are required in the next loop to calculate each account's position
        uint totalPositiveOutlay = 0;
        uint totalNegativeOutlay = 0;
        for (uint8 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            (, uint supplied, uint borrowed, uint exchangeRateMantissa) =
                CTokenInterface(original).getAccountSnapshot(account);
            uint underlyingSupplied = SafeMath.div(SafeMath.mul(supplied, exchangeRateMantissa), 1e18);
            if (underlyingSupplied > borrowed) {
                uint outlay = SafeMath.sub(underlyingSupplied, borrowed);
                totalPositiveOutlay = totalPositiveOutlay + outlay;
            } else {
                uint outlay = SafeMath.sub(borrowed, underlyingSupplied);
                totalNegativeOutlay = totalNegativeOutlay + outlay;
            }
        }

        uint missingFunds = SafeMath.sub(totalPositiveOutlay, totalNegativeOutlay);

        uint hairCut = SafeMath.div(SafeMath.mul(missingFunds, 1e18),
                                    totalPositiveOutlay);

        uint multiplier = SafeMath.sub(1e18, hairCut);

        console.log("Haircut: %s", hairCut);

        for (uint8 i = 0; i < accounts.length; i++) {
          address account = accounts[i];
          require(accountTokens[account] == 0, "should not have existing balance");

          (, uint supplied, uint borrowed, uint exchangeRateMantissa) =
            CTokenInterface(original).getAccountSnapshot(account);

          //If the account has supplied USDC, we calculate the total outlay, to account for wash lending
          if (supplied > 0) {
            uint underlyingSupplied = SafeMath.div(SafeMath.mul(supplied, exchangeRateMantissa), 1e18);
            //Positive outlay
            if (underlyingSupplied > borrowed) {
                uint outlay = SafeMath.sub(underlyingSupplied, borrowed);
                uint newUnderlyingSupplied = SafeMath.div(SafeMath.mul(outlay, multiplier), 1e18);
                uint newSupplied = SafeMath.div(SafeMath.mul(newUnderlyingSupplied, 1e18),exchangeRateMantissa);
                accountTokens[account] = newSupplied;
                totalSupply = SafeMath.add(totalSupply, newSupplied);
            }
            //Negative outlay
            else {
                uint outlay = SafeMath.sub(borrowed, underlyingSupplied);
                accountBorrows[account].principal = outlay;
                accountBorrows[account].interestIndex = borrowIndex;
                totalBorrows = SafeMath.add(totalBorrows, outlay);
            }
          }
          //The account has only borrowed, can be added as is
          else {
            accountBorrows[account].principal = borrowed;
            accountBorrows[account].interestIndex = borrowIndex;
            totalBorrows = SafeMath.add(totalBorrows, borrowed);
          }
        }

        console.log("New totalBorrows: %s", totalBorrows);
        console.log("New totalSupply: %s", totalSupply);
        uint exchangeRate = exchangeRateStored();
        console.log("New exchangeRateStored: %s", exchangeRate);
        uint underlying = SafeMath.div(SafeMath.mul(totalSupply, exchangeRate), 1e24);
        console.log("New underlying: %s", underlying);
        _initState = true;
    }
}
