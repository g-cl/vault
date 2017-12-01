pragma solidity ^0.4.18;

import "./InterestRate.sol";
import "./Ledger.sol";
import "./base/Owned.sol";

/**
  * @title The Compound Loan Account
  * @author Compound
  * @notice A loan account allows customer's to borrow assets, holding other assets as collatoral.
  */
contract Loaner is Owned, InterestRate, Ledger {
    // function customerBorrow(address ) {
 	//     if allow(....) {
 	//         debit(LedgerAction.CustomerLoan, LedgerAccount.Loan, from, asset, amount);
 	//         credit(LedgerAction.CustomerLoan, LedgerAccount.Deposit, from, asset, amount);
 	//     }
 	// }

    /**
      * @notice `getLoanBalance` returns the balance (with interest) for
      *         the given customers's loan of the given asset (e.g. W-Eth or OMG)
      * @param customer The customer
      * @param asset The asset to check the balance of
      */
    function getLoanBalance(address customer, address asset) public view returns (uint256) {
        return getLoanBalanceAt(
            customer,
            asset,
            now);
    }

    /**
      * @notice `getLoanBalanceAt` returns the balance (with interest) for
      *         the given account's loan of the given asset (e.g. W-Eth or OMG)
      * @param customer The customer
      * @param asset The asset to check the balance of
      * @param timestamp The timestamp at which to check the value.
      */
    function getLoanBalanceAt(address customer, address asset, uint256 timestamp) public view returns (uint256) {
        return balanceWithInterest(
            balanceCheckpoints[customer][uint8(LedgerAccount.Loan)][asset].balance,
            balanceCheckpoints[customer][uint8(LedgerAccount.Loan)][asset].timestamp,
            timestamp,
            rates[asset]);
    }

    /**
      * @notice `accrueLoanInterest` accrues any current interest on a given loan.
      * @param customer The customer
      * @param asset The asset to accrue loan interest on
      */
    function accrueLoanInterest(address customer, address asset) public returns (uint256) {
        uint balance;
        BalanceCheckpoint storage checkpoint = balanceCheckpoints[customer][uint8(LedgerAccount.Loan)][asset];

        uint interest = compoundedInterest(
            checkpoint.balance,
            checkpoint.timestamp,
            now,
            rates[asset]);

        if (interest == 0) {
            balance = checkpoint.balance;
        } else {
          credit(LedgerReason.Interest, LedgerAccount.InterestIncome, customer, asset, interest);

          balance = debit(LedgerReason.Interest, LedgerAccount.Loan, customer, asset, interest);
        }

        saveCheckpoint(customer, LedgerReason.Interest, LedgerAccount.Loan, asset);

        return balance;
    }
}
