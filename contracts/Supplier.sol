pragma solidity ^0.4.18;

import "./Ledger.sol";
import "./base/Owned.sol";
import "./base/Graceful.sol";
import "./base/Token.sol";
import "./storage/TokenStore.sol";

/**
  * @title The Compound Supplier Account
  * @author Compound
  * @notice A Supplier account allows functions for customer supplies and withdrawals.
  */
contract Supplier is Graceful, Owned, Ledger {
    TokenStore public tokenStore;
    uint16 public supplyRateSlopeBPS = 1000;
    InterestRateStorage public supplyInterestRateStorage;

    /**
      * @notice `setTokenStore` sets the token store contract
      * @dev This is for long-term token storage
      * @param tokenStoreAddress The contract which acts as the long-term token store
      * @return Success of failure of operation
      */
    function setTokenStore(address tokenStoreAddress) public returns (bool) {
        if (!checkOwner()) {
            return false;
        }

        tokenStore = TokenStore(tokenStoreAddress);

        return true;
    }

    /**
      * @notice `checkTokenStore` verifies token store has been set
      * @return True if token store is initialized, false otherwise
      */
    function checkTokenStore() internal returns (bool) {
        if (tokenStore == address(0)) {
            failure("Supplier::TokenStoreUninitialized");
            return false;
        }

        return true;
    }

    /**
      * @notice `setSupplyInterestRateStorage` sets the interest rate storage location for this supply contract
      * @dev This is for long-term data storage
      * @param supplyInterestRateStorage_ The contract which acts as the long-term data store
      * @return Success of failure of operation
      */
    function setSupplyInterestRateStorage(InterestRateStorage supplyInterestRateStorage_) public returns (bool) {
        if (!checkOwner()) {
            return false;
        }

        supplyInterestRateStorage = supplyInterestRateStorage_;

        return true;
    }

    /**
      * @notice `checkSupplierInterestRateStorage` verifies interest rate store has been set
      * @return True if interest rate store is initialized, false otherwise
      */
    function checkSupplierInterestRateStorage() internal returns (bool) {
        if (supplyInterestRateStorage == address(0)) {
            failure("Supplier::InterestRateStorageUnitialized");
            return false;
        }

        return true;
    }

    /**
      * @notice `customerSupply` supplies a given asset in a customer's supplier account.
      * @param asset Asset to supply
      * @param amount The amount of asset to supply
      * @param from The customer's account which is pre-authorized for transfer
      * @return success or failure
      */
    function customerSupply(address asset, uint256 amount, address from) public returns (bool) {
        // TODO: Should we verify that from matches `msg.sender` or `msg.originator`?
        if (!checkTokenStore()) {
            return false;
        }

        if (!checkSupplierInterestRateStorage()) {
            return false;
        }

        if (!accrueSupplyInterest(from, asset)) {
            return false;
        }

        // Transfer `tokenStore` the asset from `from`
        if (!Token(asset).transferFrom(from, address(tokenStore), amount)) {
            failure("Supplier::TokenTransferFromFail", uint256(asset), uint256(amount), uint256(from));
            return false;
        }

        debit(LedgerReason.CustomerSupply, LedgerAccount.Cash, from, asset, amount);
        credit(LedgerReason.CustomerSupply, LedgerAccount.Supply, from, asset, amount);

        return true;
    }

    /**
      * @notice `customerWithdraw` withdraws the given amount from a customer's balance of the specified asset
      * @param asset Asset type to withdraw
      * @param amount amount to withdraw
      * @param to address to withdraw to
      * @return success or failure
      */
    function customerWithdraw(address asset, uint256 amount, address to) public returns (bool) {
        if (!checkTokenStore()) {
            return false;
        }

        if (!checkSupplierInterestRateStorage()) {
            return false;
        }

        // accrue interest, which is likely to increase the balance, before checking balance.
        if (!accrueSupplyInterest(msg.sender, asset)) {
            return false;
        }

        // TODO: Use collateral-adjusted balance.  If a customer has borrows, we shouldn't let them
        // withdraw below their minimum collateral value.
        uint256 balance = getBalance(msg.sender, LedgerAccount.Supply, asset);
        if (amount > balance) {
            failure("Supplier::InsufficientBalance", uint256(asset), uint256(amount), uint256(to), uint256(balance));
            return false;
        }

        debit(LedgerReason.CustomerWithdrawal, LedgerAccount.Supply, msg.sender, asset, amount);
        credit(LedgerReason.CustomerWithdrawal, LedgerAccount.Cash, msg.sender, asset, amount);

        // Transfer asset out to `to` address
        if (!tokenStore.transferAssetOut(asset, to, amount)) {
            // TODO: We've marked the debits and credits, maybe we should reverse those?
            // Can we just do the following?
            // credit(LedgerReason.CustomerWithdrawal, LedgerAccount.Supply, msg.sender, asset, amount);
            // debit(LedgerReason.CustomerWithdrawal, LedgerAccount.Cash, msg.sender, asset, amount);
            // We probably ought to add LedgerReason.CustomerWithdrawalFailed and use that instead of LedgerReason.CustomerWithdrawal.
            // Either way, we'll likely need changes in Farmer and/or Data to process the resulting logs.
            failure("Supplier::TokenTransferToFail", uint256(asset), uint256(amount), uint256(to), uint256(balance));
            return false;
        }

        return true;
    }

    /**
      * @notice `getSupplyBalance` returns the balance (with interest) for
      *         the given account in the given asset (e.g. W-Eth or OMG)
      * @param customer The customer
      * @param asset The asset to check the balance of
      * @return The balance (with interest)
      */
    function getSupplyBalance(address customer, address asset) public view returns (uint256) {
        return supplyInterestRateStorage.getCurrentBalance(
            asset,
            ledgerStorage.getBalanceBlockNumber(customer, uint8(LedgerAccount.Supply), asset),
            ledgerStorage.getBalance(customer, uint8(LedgerAccount.Supply), asset)
        );
    }

    /**
      * @notice `accrueSupplyInterest` accrues any current interest on an
      *         supply account.
      * @param customer The customer
      * @param asset The asset to accrue supply interest on
      * @return success or failure
      */
    function accrueSupplyInterest(address customer, address asset) public returns (bool) {
        if (!checkSupplierInterestRateStorage()) {
            return false;
        }

        uint blockNumber = ledgerStorage.getBalanceBlockNumber(customer, uint8(LedgerAccount.Supply), asset);

        if (blockNumber != block.number) {
            // We need to true up balance

            uint balanceWithInterest = getSupplyBalance(customer, asset);
            uint balanceLessInterest = ledgerStorage.getBalance(customer, uint8(LedgerAccount.Supply), asset);

            if (balanceWithInterest - balanceLessInterest > balanceWithInterest) {
                // Interest should never be negative
                failure("Supplier::InterestUnderflow", uint256(asset), uint256(customer), balanceWithInterest, balanceLessInterest);
                return false;
            }

            uint interest = balanceWithInterest - balanceLessInterest;

            if (interest != 0) {
                debit(LedgerReason.Interest, LedgerAccount.InterestExpense, customer, asset, interest);
                credit(LedgerReason.Interest, LedgerAccount.Supply, customer, asset, interest);
                if (!ledgerStorage.saveCheckpoint(customer, uint8(LedgerAccount.Supply), asset)) {
                    revert();
                }
          }
        }

        return true;
    }

    /**
      * @notice `getScaledSupplyRatePerGroup` returns the current borrow interest rate based on the balance sheet
      * @param asset address of asset
      * @param interestRateScale multiplier used in interest rate storage. We need it here to reduce truncation issues.
      * @param blockUnitsPerYear based on block group size in interest rate storage. We need it here to reduce truncation issues.
      * @return the current supply interest rate (in scale points, aka divide by 10^16 to get real rate)
      */
    function getScaledSupplyRatePerGroup(address asset, uint interestRateScale, uint blockUnitsPerYear) public view returns (uint64) {
        uint256 cash = ledgerStorage.getBalanceSheetBalance(asset, uint8(LedgerAccount.Cash));
        uint256 borrows = ledgerStorage.getBalanceSheetBalance(asset, uint8(LedgerAccount.Borrow));

        // avoid division by 0 without altering calculations in the happy path (at the cost of an extra comparison)
        uint256 denominator = cash + borrows;
        if(denominator == 0) {
            denominator = 1;
        }

        // `supply r` == (1-`reserve ratio`) * 10%
        // note: this is done in one-line since intermediate results would be truncated
        // should scale 10**16 / basisPointMultiplier. Do the division by block units per year in int rate storage
        return uint64( (( basisPointMultiplier  - ( ( basisPointMultiplier * cash ) / ( denominator ) ) ) * supplyRateSlopeBPS / basisPointMultiplier) * (interestRateScale / (blockUnitsPerYear*basisPointMultiplier)));
    }

    /**
      * @notice `snapshotSupplierInterestRate` snapshots the current interest rate for the block unit
      * @param asset address of asset
      * @return true on success, false if failure (e.g. snapshot already taken for this block unit)
      */
    function snapshotSupplierInterestRate(address asset) public returns (bool) {
      uint64 rate = getScaledSupplyRatePerGroup(asset,
          supplyInterestRateStorage.getInterestRateScale(),
          supplyInterestRateStorage.getBlockUnitsPerYear());

      return supplyInterestRateStorage.snapshotCurrentRate(asset, rate);
    }
}