pragma solidity ^0.4.18;

import "./Ledger.sol";
import "./base/Owned.sol";
import "./base/Graceful.sol";
import "./base/Token.sol";
import "./storage/PriceOracle.sol";
import "./storage/BorrowStorage.sol";

/**
  * @title The Compound Borrow Account
  * @author Compound
  * @notice A borrow account allows customer's to borrow assets, holding other assets as collateral.
  */
contract Borrower is Graceful, Owned, Ledger {
    PriceOracle public priceOracle;
    BorrowStorage public borrowStorage;
    InterestRateStorage public borrowInterestRateStorage;
    uint16 public borrowRateSlopeBPS = 2000;
    uint16 public minimumBorrowRateBPS = 1000;

    function Borrower () public {}

    /**
      * @notice `setPriceOracle` sets the priceOracle storage location for this contract
      * @dev This is for long-term data storage (TODO: Test)
      * @param priceOracleAddress The contract which acts as the long-term PriceOracle store
      * @return Success of failure of operation
      */
    function setPriceOracle(address priceOracleAddress) public returns (bool) {
        if (!checkOwner()) {
            return false;
        }

        priceOracle = PriceOracle(priceOracleAddress);

        return true;
    }

    /**
      * @notice `setBorrowStorage` sets the borrow storage location for this contract
      * @dev This is for long-term data storage (TODO: Test)
      * @param borrowStorageAddress The contract which acts as the long-term store
      * @return Success of failure of operation
      */
    function setBorrowStorage(address borrowStorageAddress) public returns (bool) {
        if (!checkOwner()) {
            return false;
        }

        borrowStorage = BorrowStorage(borrowStorageAddress);

        return true;
    }

    /**
      * @notice `setBorrowInterestRateStorage` sets the interest rate storage location for this borrow contract
      * @dev This is for long-term data storage (TODO: Test)
      * @param borrowInterestRateStorage_ The contract which acts as the long-term data store
      * @return Success of failure of operation
      */
    function setBorrowInterestRateStorage(InterestRateStorage borrowInterestRateStorage_) public returns (bool) {
        if (!checkOwner()) {
            return false;
        }

        borrowInterestRateStorage = borrowInterestRateStorage_;

        return true;
    }

    /**
      * @notice `checkBorrowInterestRateStorage` verifies interest rate store has been set
      * @return True if interest rate store is initialized, false otherwise
      */
    function checkBorrowInterestRateStorage() internal returns (bool) {
        if (borrowInterestRateStorage == address(0)) {
            failure("Borrower::InterestRateStorageUnitialized");
            return false;
        }

        return true;
    }

    /**
      * @notice `customerBorrow` creates a new borrow and supplies the requested asset into the user's account.
      * @param asset The asset to borrow
      * @param amount The amount to borrow
      * @return success or failure
      */
    function customerBorrow(address asset, uint amount) public returns (bool) {
        if (!borrowStorage.borrowableAsset(asset)) {
            failure("Borrower::AssetNotBorrowable", uint256(asset));
            return false;
        }

        if (!validCollateralRatio(amount, asset)) {
            failure("Borrower::InvalidCollateralRatio", uint256(asset), uint256(amount), getValueEquivalent(msg.sender));
            return false;
        }

        // TODO: If customer already has a borrow of asset, we need to make sure we can handle the change.
        // Before adding the new amount we will need to either calculate interest on existing borrow amount or snapshot
        // the current borrow balance.
        // Alternatively: Block additional borrow for same asset.

        debit(LedgerReason.CustomerBorrow, LedgerAccount.Borrow, msg.sender, asset, amount);
        credit(LedgerReason.CustomerBorrow, LedgerAccount.Supply, msg.sender, asset, amount);

        return true;
    }

    /**
      * @notice `customerPayBorrow` customer makes a borrow payment
      * @param asset The asset to pay down
      * @param amount The amount to pay down
      * @return success or failure
      */
    function customerPayBorrow(address asset, uint amount) public returns (bool) {
        if (!accrueBorrowInterest(msg.sender, asset)) {
            return false;
        }

        credit(LedgerReason.CustomerPayBorrow, LedgerAccount.Borrow, msg.sender, asset, amount);
        debit(LedgerReason.CustomerPayBorrow, LedgerAccount.Supply, msg.sender, asset, amount);

        return true;
    }

    /**
      * @notice `convertCollateral` converts specified amount of collateral asset into borrow asset to improve the borrower's
                collateral ratio for the borrow.
      * @param borrower the borrower who took out the borrow
      * @param paymentAsset asset with which to reduce the borrow balance
      * @param amountInPaymentAsset how much of the paymentAsset to use (in wei-equivalent)
      * @param borrowAsset the asset that was borrowed; must differ from paymentAsset
     **/
    function convertCollateral(address borrower, address paymentAsset, uint256 amountInPaymentAsset, address borrowAsset) public returns (bool) {

        if(borrowAsset == paymentAsset) {
            failure("Borrower::CollateralSameAsBorrow", uint256(borrowAsset));
            return false;
        }

        if(amountInPaymentAsset == 0) {
            failure("Borrower::ZeroCollateralAmount", uint256(borrowAsset));
            return false;
        }

        if(!validPriceOracle()) {
            return false;
        }

        // true up balance first
        if(!accrueBorrowInterest(borrower, borrowAsset)) {
            return false;
        }

        uint borrowBalance = getBalance(borrower, LedgerAccount.Borrow, borrowAsset);
        if(borrowBalance == 0) {
            failure("Borrower::ZeroBorrowBalance", uint256(borrowAsset));
            return false;
        }

        // Only allow conversion if the collateral ratio is NOT valid for the current balance
        if (validCollateralRatioNotSender(borrower, borrowBalance, borrowAsset)) {
            failure("Borrower::ValidCollateralRatio", uint256(borrowAsset), uint256(borrowBalance), getValueEquivalent(borrower));
            return false;
        }

        uint amountInBorrowAsset = priceOracle.getConvertedAssetValue(paymentAsset, amountInPaymentAsset, borrowAsset);

        if(amountInBorrowAsset > borrowBalance) {
            failure("Borrower::TooMuchCollateral", uint256(amountInBorrowAsset), uint256(borrowBalance), amountInPaymentAsset);
            return false;
        }

        // record loss of collateral
        debit(LedgerReason.CollateralPayBorrow, LedgerAccount.Supply, borrower, paymentAsset, amountInPaymentAsset);
        credit(LedgerReason.CollateralPayBorrow, LedgerAccount.Trading, borrower, paymentAsset, amountInPaymentAsset);

        // reduce borrow
        credit(LedgerReason.CollateralPayBorrow, LedgerAccount.Borrow, borrower, borrowAsset, amountInBorrowAsset);
        debit(LedgerReason.CollateralPayBorrow, LedgerAccount.Trading, borrower, borrowAsset, amountInBorrowAsset);

        return true;
    }

    /**
      * @notice `getBorrowBalance` returns the balance (with interest) for
      *         the given customers's borrow of the given asset (e.g. W-Eth or OMG)
      * @param customer The customer
      * @param asset The asset to check the balance of
      * @return The borrow balance of given account
      */
    function getBorrowBalance(address customer, address asset) public view returns (uint256) {
        return borrowInterestRateStorage.getCurrentBalance(
            asset,
            ledgerStorage.getBalanceBlockNumber(customer, uint8(LedgerAccount.Borrow), asset),
            ledgerStorage.getBalance(customer, uint8(LedgerAccount.Borrow), asset)
        );
    }

    /**
      * @notice `accrueBorrowInterest` accrues any current interest on a given borrow.
      * @param customer The customer
      * @param asset The asset to accrue borrow interest on
      * @return success or failure
      */
    function accrueBorrowInterest(address customer, address asset) public returns (bool) {
        if (!checkBorrowInterestRateStorage()) {
            return false;
        }

        uint blockNumber = ledgerStorage.getBalanceBlockNumber(customer, uint8(LedgerAccount.Borrow), asset);

        if (blockNumber != block.number) {
            uint balanceWithInterest = getBorrowBalance(customer, asset);
            uint balanceLessInterest = ledgerStorage.getBalance(customer, uint8(LedgerAccount.Borrow), asset);

            if (balanceWithInterest - balanceLessInterest > balanceWithInterest) {
                // Interest should never be negative
                failure("Borrower::InterestUnderflow", uint256(asset), uint256(customer), balanceWithInterest, balanceLessInterest);
                return false;
            }

            uint interest = balanceWithInterest - balanceLessInterest;

            if (interest != 0) {
                credit(LedgerReason.Interest, LedgerAccount.InterestIncome, customer, asset, interest);
                debit(LedgerReason.Interest, LedgerAccount.Borrow, customer, asset, interest);
                if (!ledgerStorage.saveCheckpoint(customer, uint8(LedgerAccount.Borrow), asset)) {
                    revert();
                }
          }
        }

        return true;
    }

    /**
      * @notice `getMaxBorrowAvailable` gets the maximum borrow available
      * @param account the address of the account
      * @return uint the maximum borrow amount available
      */
    function getMaxBorrowAvailable(address account) view public returns (uint) {
        return getValueEquivalent(account) * borrowStorage.minimumCollateralRatio();
    }

    /**
      * @notice `validCollateralRatio` determines if a the requested amount is valid based on the minimum collateral ratio
      * @param borrowAmount the requested borrow amount
      * @param borrowAsset denomination of borrow
      * @return boolean true if the requested amount is valid and false otherwise
      */
    function validCollateralRatio(uint borrowAmount, address borrowAsset) view internal returns (bool) {
        return validCollateralRatioNotSender(msg.sender, borrowAmount, borrowAsset);
    }

    /**
      * @notice `validCollateralRatioNotSender` determines if a the requested amount is valid for the specified borrower based on the minimum collateral ratio
      * @param borrower the borrower whose collateral should be examined
      * @param borrowAmount the requested (or current) borrow amount
      * @param borrowAsset denomination of borrow
      * @return boolean true if the requested amount is valid and false otherwise
      */
    function validCollateralRatioNotSender(address borrower, uint borrowAmount, address borrowAsset) view internal returns (bool) {
        return (getValueEquivalent(borrower) * borrowStorage.minimumCollateralRatio()) >= priceOracle.getAssetValue(borrowAsset, borrowAmount);
    }

    /**
     * @notice `getValueEquivalent` returns the value of the account based on
     * PriceOracle prices of assets. Note: this includes the Eth value itself.
     * @param acct The account to view value balance
     * @return value The value of the acct in Eth equivalency
     */
    function getValueEquivalent(address acct) public view returns (uint256) {
        uint256 assetCount = priceOracle.getAssetsLength(); // from PriceOracle
        uint256 balance = 0;

        for (uint64 i = 0; i < assetCount; i++) {
          address asset = priceOracle.assets(i);

          balance += priceOracle.getAssetValue(asset, getBalance(acct, LedgerAccount.Supply, asset));
          balance -= priceOracle.getAssetValue(asset, getBalance(acct, LedgerAccount.Borrow, asset));
        }

        return balance;
    }

    /**
      * @notice `validPriceOracle` verifies that the PriceOracle is correct initialized
      * @dev This is just for sanity checking.
      * @return true if successfully initialized, false otherwise
      */
    function validPriceOracle() public returns (bool) {
        bool result = true;

        if (priceOracle == address(0)) {
            failure("Borrower::PriceOracleInitialized");
            result = false;
        }

        if (priceOracle.allowed() != address(this)) {
            failure("Borrower::PriceOracleNotAllowed");
            result = false;
        }

        return result;
    }

    /**
      * @notice `validBorrowStorage` verifies that the BorrowStorage is correctly initialized
      * @dev This is just for sanity checking.
      * @return true if successfully initialized, false otherwise
      */
    function validBorrowStorage() public returns (bool) {
        bool result = true;

        if (borrowStorage == address(0)) {
            failure("Borrower::BorrowStorageInitialized");
            result = false;
        }

        if (borrowStorage.allowed() != address(this)) {
            failure("Borrower::BorrowStorageNotAllowed");
            result = false;
        }

        return result;
    }

    /**
      * @notice `getScaledBorrowRatePerGroup` returns the current borrow interest rate based on the balance sheet
      * @param asset address of asset
      * @param interestRateScale multiplier used in interest rate storage. We need it here to reduce truncation issues.
      * @param blockUnitsPerYear based on block group size in interest rate storage. We need it here to reduce truncation issues.
      * @return the current borrow interest rate (in scale points, aka divide by 10^16 to get real rate)
      */
    function getScaledBorrowRatePerGroup(address asset, uint interestRateScale, uint blockUnitsPerYear) public view returns (uint64) {
        uint256 cash = ledgerStorage.getBalanceSheetBalance(asset, uint8(LedgerAccount.Cash));
        uint256 borrows = ledgerStorage.getBalanceSheetBalance(asset, uint8(LedgerAccount.Borrow));

        // avoid division by 0 without altering calculations in the happy path (at the cost of an extra comparison)
        uint256 denominator = cash + borrows;
        if(denominator == 0) {
            denominator = 1;
        }

        // `borrow r` == 10% + (1-`reserve ratio`) * 20%
        // note: this is done in one-line since intermediate results would be truncated

        return uint64( (minimumBorrowRateBPS + ( basisPointMultiplier  - ( ( basisPointMultiplier * cash ) / ( denominator ) ) ) * borrowRateSlopeBPS / basisPointMultiplier )  * (interestRateScale / (blockUnitsPerYear*basisPointMultiplier)));
    }


    /**
      * @notice `snapshotBorrowInterestRate` snapshots the current interest rate for the block uint
      * @param asset address of asset
      * @return true on success, false if failure (e.g. snapshot already taken for this block uint)
      * TODO: Test
      */
    function snapshotBorrowInterestRate(address asset) public returns (bool) {
      uint64 rate = getScaledBorrowRatePerGroup(asset,
          borrowInterestRateStorage.getInterestRateScale(),
          borrowInterestRateStorage.getBlockUnitsPerYear());

      return borrowInterestRateStorage.snapshotCurrentRate(asset, rate);
    }
}