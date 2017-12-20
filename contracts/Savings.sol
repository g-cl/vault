pragma solidity ^0.4.18;

import "./InterestRate.sol";
import "./Ledger.sol";
import "./base/Owned.sol";
import "./base/Graceful.sol";

/**
  * @title The Compound Savings Account
  * @author Compound
  * @notice A Savings account allows functions for customer deposits and withdrawals.
  */
contract Savings is Graceful, Owned, InterestRate, Ledger {

	/**
      * @notice `customerDeposit` deposits a given asset in a customer's savings account.
      * @param asset Asset to deposit
      * @param amount The amount of asset to deposit
      * @param from The customer's account which is pre-authorized for transfer
      * @return success or failure
      */
    function customerDeposit(address asset, uint256 amount, address from) public returns (bool) {
        // TODO: Should we verify that from matches `msg.sender` or `msg.originator`?

        // Transfer ourselves the asset from `from`
        if (!Token(asset).transferFrom(from, address(this), amount)) {
            failure("Savings::TokenTransferFromFail", uint256(asset), uint256(amount), uint256(from));
            return false;
        }

        if (!accrueDepositInterest(from, asset)) {
            return false;
        }

        debit(LedgerReason.CustomerDeposit, LedgerAccount.Cash, from, asset, amount);
        credit(LedgerReason.CustomerDeposit, LedgerAccount.Deposit, from, asset, amount);

        return true;
    }

    /**
      * @notice `customerWithdraw` withdraws a given amount from an customer's balance.
      * @param asset Asset type to withdraw
      * @param amount amount to withdraw
      * @param to address to withdraw to
      * @return success or failure
      */
    function customerWithdraw(address asset, uint256 amount, address to) public returns (bool) {
        if (!accrueDepositInterest(msg.sender, asset)) {
            return false;
        }

        uint256 balance = getBalance(msg.sender, LedgerAccount.Deposit, asset);
        if (amount > balance) {
            failure("Savings::InsufficientBalance", uint256(asset), uint256(amount), uint256(to), uint256(balance));
            return false;
        }

        debit(LedgerReason.CustomerWithdrawal, LedgerAccount.Deposit, msg.sender, asset, amount);
        credit(LedgerReason.CustomerWithdrawal, LedgerAccount.Cash, msg.sender, asset, amount);

        // Transfer asset out to `to` address
        if (!Token(asset).transfer(to, amount)) {
            // TODO: We've marked the debits and credits, maybe we should reverse those?
            failure("Savings::TokenTransferToFail", uint256(asset), uint256(amount), uint256(to), uint256(balance));
            return false;
        }

        return true;
    }

    /**
      * @notice `getDepositBalance` returns the balance (with interest) for
      *         the given account in the given asset (e.g. W-Eth or OMG)
      * @param customer The customer
      * @param asset The asset to check the balance of
      * @return The balance (with interest)
      */
    function getDepositBalance(address customer, address asset) public view returns (uint256) {
        return getDepositBalanceAt(
            customer,
            asset,
            now);
    }

    /**
      * @notice `getDepositBalanceAt` returns the balance (with interest) for
      *         the given customer in the given asset (e.g. W-Eth or OMG)
      * @param customer The customer
      * @param asset The asset to check the balance of
      * @param timestamp The timestamp at which to check the value.
      * @return The balance (with interest)
      */
    function getDepositBalanceAt(address customer, address asset, uint256 timestamp) public view returns (uint256) {
        return balanceWithInterest(
            balanceCheckpoints[customer][uint8(LedgerAccount.Deposit)][asset].balance,
            balanceCheckpoints[customer][uint8(LedgerAccount.Deposit)][asset].timestamp,
            timestamp,
            rates[asset]);
    }

    /**
      * @notice `accrueDepositInterest` accrues any current interest on an
      *         savings account.
      * @param customer The customer
      * @param asset The asset to accrue savings interest on
      * @return success or failure
      */
    function accrueDepositInterest(address customer, address asset) public returns (bool) {
        BalanceCheckpoint storage checkpoint = balanceCheckpoints[customer][uint8(LedgerAccount.Deposit)][asset];

        if(checkpoint.timestamp != 0) {
          uint interest = compoundedInterest(
              checkpoint.balance,
              checkpoint.timestamp,
              now,
              rates[asset]);

          if (interest != 0) {
              debit(LedgerReason.Interest, LedgerAccount.InterestExpense, customer, asset, interest);
              credit(LedgerReason.Interest, LedgerAccount.Deposit, customer, asset, interest);
              saveCheckpoint(customer, LedgerReason.Interest, LedgerAccount.Deposit, asset);
          }
        }

        return true;
    }
}
