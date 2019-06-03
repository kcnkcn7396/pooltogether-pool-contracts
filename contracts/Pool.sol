pragma solidity ^0.5.0;

import "openzeppelin-eth/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "./compound/ICErc20.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "kleros/contracts/data-structures/SortitionSumTreeFactory.sol";
import "./UniformRandomNumber.sol";
import "fixidity/contracts/FixidityLib.sol";

/**
 * @title The Pool contract for PoolTogether
 * @author Brendan Asselstine
 * @notice This contract implements a "lossless pool".  The pool exists in three states: open, locked, and complete.
 * The pool begins in the open state during which users can buy any number of tickets.  The more tickets they purchase, the greater their chances of winning.
 * After the lockStartBlock the owner may lock the pool.  The pool transfers the pool of ticket money into the Compound Finance money market and no more tickets are sold.
 * After the lockEndBlock the owner may unlock the pool.  The pool will withdraw the ticket money from the money market, plus earned interest, back into the contract.  The fee will be sent to
 * the owner, and users will be able to withdraw their ticket money and winnings, if any.
 * @dev All monetary values are stored internally as fixed point 24.
 */
contract Pool is Ownable {
  using SafeMath for uint256;

  event BoughtTickets(address indexed sender, int256 count, uint256 totalPrice);
  event Withdrawn(address indexed sender, int256 amount);
  event OwnerWithdrawn(address indexed sender, int256 amount);
  event PoolLocked();
  event PoolUnlocked();

  enum State {
    OPEN,
    LOCKED,
    COMPLETE
  }

  struct Entry {
    address addr;
    int256 amount;
    uint256 ticketCount;
  }

  bytes32 public constant SUM_TREE_KEY = "PoolPool";

  int256 private totalAmount; // fixed point 24
  uint256 private lockStartBlock;
  uint256 private lockEndBlock;
  bytes32 private secretHash;
  bytes32 private secret;
  State public state;
  int256 private finalAmount; //fixed point 24
  mapping (address => Entry) private entries;
  uint256 public entryCount;
  ICErc20 public moneyMarket;
  IERC20 public token;
  int256 private ticketPrice; //fixed point 24
  int256 private feeFraction; //fixed point 24
  bool private ownerHasWithdrawn;
  bool public allowLockAnytime;

  using SortitionSumTreeFactory for SortitionSumTreeFactory.SortitionSumTrees;
  SortitionSumTreeFactory.SortitionSumTrees internal sortitionSumTrees;

  /**
   * @notice Creates a new Pool.
   * @param _moneyMarket The Compound money market to supply tokens to.
   * @param _token The ERC20 token to be used.
   * @param _lockStartBlock The block number on or after which the deposit can be made to Compound
   * @param _lockEndBlock The block number on or after which the Compound supply can be withdrawn
   * @param _ticketPrice The price of each ticket (fixed point 18)
   * @param _feeFractionFixedPoint18 The fraction of the winnings going to the owner (fixed point 18)
   */
  constructor (
    ICErc20 _moneyMarket,
    IERC20 _token,
    uint256 _lockStartBlock,
    uint256 _lockEndBlock,
    int256 _ticketPrice,
    int256 _feeFractionFixedPoint18,
    bool _allowLockAnytime
  ) public {
    require(_lockEndBlock > _lockStartBlock, "lock end block is not after start block");
    require(address(_moneyMarket) != address(0), "money market address cannot be zero");
    require(address(_token) != address(0), "token address cannot be zero");
    require(_ticketPrice > 0, "ticket price must be greater than zero");
    require(_feeFractionFixedPoint18 >= 0, "fee must be zero or greater");
    require(_feeFractionFixedPoint18 <= 1000000000000000000, "fee fraction must be less than 1");
    feeFraction = FixidityLib.newFixed(_feeFractionFixedPoint18, uint8(18));
    ticketPrice = FixidityLib.newFixed(_ticketPrice);
    sortitionSumTrees.createTree(SUM_TREE_KEY, 4);

    moneyMarket = _moneyMarket;
    token = _token;
    lockStartBlock = _lockStartBlock;
    lockEndBlock = _lockEndBlock;
    allowLockAnytime = _allowLockAnytime;
  }

  /**
   * @notice Buys a pool ticket.  Only possible while the Pool is in the "open" state.  The
   * user can buy any number of tickets.  Each ticket is a chance at winning.
   */
  function buyTickets (int256 _count) public requireOpen {
    require(_count > 0, "number of tickets is less than or equal to zero");
    int256 countFixed = FixidityLib.newFixed(_count);
    int256 totalDeposit = FixidityLib.multiply(ticketPrice, countFixed);
    uint256 totalDepositNonFixed = uint256(FixidityLib.fromFixed(totalDeposit));
    require(token.transferFrom(msg.sender, address(this), totalDepositNonFixed), "token transfer failed");

    if (_hasEntry(msg.sender)) {
      entries[msg.sender].amount = FixidityLib.add(entries[msg.sender].amount, totalDeposit);
      entries[msg.sender].ticketCount = entries[msg.sender].ticketCount.add(uint256(_count));
    } else {
      entries[msg.sender] = Entry(
        msg.sender,
        totalDeposit,
        uint256(_count)
      );
      entryCount = entryCount.add(1);
    }

    sortitionSumTrees.set(SUM_TREE_KEY, totalDepositNonFixed, bytes32(uint256(msg.sender)));

    totalAmount = FixidityLib.add(totalAmount, totalDeposit);

    // the total amount cannot exceed the max pool size
    require(totalAmount < maxPoolSizeFixedPoint24(FixidityLib.maxFixedDiv()), "pool size exceeds maximum");

    emit BoughtTickets(msg.sender, _count, totalDepositNonFixed);
  }

  /**
   * @notice Pools the deposits and supplies them to Compound.
   * Can only be called by the owner when the pool is open.
   * Fires the PoolLocked event.
   */
  function lock(bytes32 _secretHash) external requireOpen onlyOwner {
    if (allowLockAnytime) {
      lockStartBlock = block.number;
    } else {
      require(block.number >= lockStartBlock, "pool can only be locked on or after lock start block");
    }
    require(_secretHash != 0, "secret hash must be defined");
    secretHash = _secretHash;
    state = State.LOCKED;

    if (totalAmount > 0) {
      uint256 totalAmountNonFixed = uint256(FixidityLib.fromFixed(totalAmount));
      require(token.approve(address(moneyMarket), totalAmountNonFixed), "could not approve money market spend");
      require(moneyMarket.mint(totalAmountNonFixed) == 0, "could not supply money market");
    }

    emit PoolLocked();
  }

  /**
   * @notice Withdraws the deposit from Compound and selects a winner.
   * Can only be called by the owner after the lock end block.
   * Fires the PoolUnlocked event.
   */
  function unlock(bytes32 _secret) public requireLocked onlyOwner {
    if (allowLockAnytime) {
      lockEndBlock = block.number;
    } else {
      require(lockEndBlock < block.number, "pool cannot be unlocked yet");
    }
    require(keccak256(abi.encodePacked(_secret)) == secretHash, "secret does not match");

    secret = _secret;

    state = State.COMPLETE;

    uint256 balance = moneyMarket.balanceOfUnderlying(address(this));

    if (balance > 0) {
      require(moneyMarket.redeemUnderlying(balance) == 0, "could not redeem from compound");
      finalAmount = FixidityLib.newFixed(int256(balance));
    }

    state = State.COMPLETE;

    uint256 fee = feeAmount();
    if (fee > 0) {
      require(token.transfer(owner(), fee), "could not transfer winnings");
    }

    emit PoolUnlocked();
  }

  /**
   * @notice Transfers a users deposit, and potential winnings, back to them.
   * The Pool must be unlocked.
   * The user must have deposited funds.  Fires the Withdrawn event.
   */
  function withdraw() public requireComplete {
    require(_hasEntry(msg.sender), "entrant exists");
    Entry storage entry = entries[msg.sender];
    require(entry.amount > 0, "entrant has already withdrawn");
    int256 winningTotal = winnings(msg.sender);
    delete entry.amount;

    emit Withdrawn(msg.sender, winningTotal);

    require(token.transfer(msg.sender, uint256(winningTotal)), "could not transfer winnings");
  }

  /**
   * @notice Calculates a user's winnings.  This is their deposit plus their winnings, if any.
   * @param _addr The address of the user
   */
  function winnings(address _addr) public view returns (int256) {
    Entry storage entry = entries[_addr];
    if (entry.addr == address(0)) { //if does not have an entry
      return 0;
    }
    if (entry.amount == 0) { // if entry has already withdrawn
      return 0;
    }
    int256 winningTotal = entry.amount;
    if (state == State.COMPLETE && _addr == winnerAddress()) {
      winningTotal = FixidityLib.add(winningTotal, netWinningsFixedPoint24());
    }
    return FixidityLib.fromFixed(winningTotal);
  }

  /**
   * @notice Selects and returns the winner's address
   * @return The winner's address
   */
  function winnerAddress() public view returns (address) {
    if (totalAmount > 0) {
      return address(uint256(sortitionSumTrees.draw(SUM_TREE_KEY, randomToken())));
    } else {
      return address(0);
    }
  }

  function netWinningsFixedPoint24() internal view returns (int256) {
    return grossWinningsFixedPoint24() - feeAmountFixedPoint24();
  }

  function grossWinningsFixedPoint24() internal view returns (int256) {
    if (state == State.COMPLETE) {
      return FixidityLib.subtract(finalAmount, totalAmount);
    } else {
      return 0;
    }
  }

  /**
   * @notice Calculates the size of the fee based on the gross winnings
   * @return The fee for the pool to be transferred to the owner
   */
  function feeAmount() public view returns (uint256) {
    return uint256(FixidityLib.fromFixed(feeAmountFixedPoint24()));
  }

  function feeAmountFixedPoint24() internal view returns (int256) {
    return FixidityLib.multiply(grossWinningsFixedPoint24(), feeFraction);
  }

  function randomToken() public view returns (uint256) {
    if (block.number <= lockEndBlock) {
      return 0;
    } else {
      return _selectRandom(uint256(FixidityLib.fromFixed(totalAmount)));
    }
  }

  function _selectRandom(uint256 total) internal view returns (uint256) {
    return UniformRandomNumber.uniform(_entropy(), total);
  }

  function _entropy() internal view returns (uint256) {
    return uint256(blockhash(lockEndBlock) ^ secret);
  }

  /**
   * @notice Retrieves information about the pool.
   * @return A tuple containing:
   *    entryTotal (the total of all deposits)
   *    startBlock (the block after which the pool can be locked)
   *    endBlock (the block after which the pool can be unlocked)
   *    poolState (either OPEN, LOCKED, COMPLETE)
   *    winner (the address of the winner)
   *    supplyBalanceTotal (the total deposits plus any interest from Compound)
   *    ticketCost (the cost of each ticket in DAI)
   *    participantCount (the number of unique purchasers of tickets)
   *    maxPoolSize (the maximum theoretical size of the pool to prevent overflow)
   *    estimatedInterestFixedPoint18 (the estimated total interest percent for this pool)
   *    hashOfSecret (the hash of the secret the owner submitted upon locking)
   */
  function getInfo() public view returns (
    int256 entryTotal,
    uint256 startBlock,
    uint256 endBlock,
    State poolState,
    address winner,
    int256 supplyBalanceTotal,
    int256 ticketCost,
    uint256 participantCount,
    int256 maxPoolSize,
    int256 estimatedInterestFixedPoint18,
    bytes32 hashOfSecret
  ) {
    address winAddr = address(0);
    if (state == State.COMPLETE) {
      winAddr = winnerAddress();
    }
    return (
      FixidityLib.fromFixed(totalAmount),
      lockStartBlock,
      lockEndBlock,
      state,
      winAddr,
      FixidityLib.fromFixed(finalAmount),
      FixidityLib.fromFixed(ticketPrice),
      entryCount,
      FixidityLib.fromFixed(maxPoolSizeFixedPoint24(FixidityLib.maxFixedDiv())),
      FixidityLib.fromFixed(currentInterestFractionFixedPoint24(), uint8(18)),
      secretHash
    );
  }

  /**
   * @notice Retrieves information about a user's entry in the Pool.
   * @return Returns a tuple containing:
   *    addr (the address of the user)
   *    amount (the amount they deposited)
   *    ticketCount (the number of tickets they have bought)
   */
  function getEntry(address _addr) public view returns (
    address addr,
    int256 amount,
    uint256 ticketCount
  ) {
    Entry storage entry = entries[_addr];
    return (
      entry.addr,
      FixidityLib.fromFixed(entry.amount),
      entry.ticketCount
    );
  }

  /**
   * @notice Calculates the maximum pool size so that it doesn't overflow after earning interest
   * @dev poolSize = totalDeposits + totalDeposits * interest => totalDeposits = poolSize / (1 + interest)
   * @return The maximum size of the pool to be deposited into the money market
   */
  function maxPoolSizeFixedPoint24(int256 _maxValueFixedPoint24) public view returns (int256) {
    /// Double the interest rate in case it increases over the lock period.  Somewhat arbitrarily.
    int256 interestFraction = FixidityLib.multiply(currentInterestFractionFixedPoint24(), FixidityLib.newFixed(2));
    return FixidityLib.divide(_maxValueFixedPoint24, FixidityLib.add(interestFraction, FixidityLib.newFixed(1)));
  }

  /**
   * @notice Estimates the current effective interest rate using the money market's current supplyRateMantissa and the lock duration in blocks.
   * @return The current estimated effective interest rate
   */
  function currentInterestFractionFixedPoint24() public view returns (int256) {
    int256 blockDuration = int256(lockEndBlock - lockStartBlock);
    int256 supplyRateMantissaFixedPoint24 = FixidityLib.newFixed(int256(supplyRateMantissa()), uint8(18));
    return FixidityLib.multiply(supplyRateMantissaFixedPoint24, FixidityLib.newFixed(blockDuration));
  }

  /**
   * @notice Extracts the supplyRateMantissa value from the money market contract
   * @return The money market supply rate per block
   */
  function supplyRateMantissa() public view returns (uint256) {
    return moneyMarket.supplyRatePerBlock();
  }

  function _hasEntry(address _addr) internal view returns (bool) {
    return entries[_addr].addr == _addr;
  }

  modifier requireOpen() {
    require(state == State.OPEN, "state is not open");
    _;
  }

  modifier requireLocked() {
    require(state == State.LOCKED, "state is not locked");
    _;
  }

  modifier requireComplete() {
    require(state == State.COMPLETE, "pool is not complete");
    require(block.number > lockEndBlock, "block is before lock end period");
    _;
  }
}
