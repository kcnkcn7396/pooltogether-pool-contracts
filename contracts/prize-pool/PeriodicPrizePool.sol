pragma solidity ^0.6.4;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@opengsn/gsn/contracts/BaseRelayRecipient.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";
import "@nomiclabs/buidler/console.sol";

import "../base/ModuleManager.sol";
import "../token/ControlledTokenFactory.sol";
import "../yield-service/YieldServiceInterface.sol";
import "../yield-service/YieldServiceConstants.sol";
import "../token/TokenControllerInterface.sol";
import "../token/Sponsorship.sol";
import "../token/Loyalty.sol";
import "./PrizePoolInterface.sol";
import "../prize-strategy/PrizeStrategyInterface.sol";
import "../rng/RNGInterface.sol";
import "../util/ERC1820Constants.sol";
import "../token/ControlledTokenFactory.sol";

/* solium-disable security/no-block-members */
contract PeriodicPrizePool is ReentrancyGuardUpgradeSafe, BaseRelayRecipient, PrizePoolInterface, IERC777Recipient, ModuleManager {
  using SafeMath for uint256;

  event TicketsRedeemedInstantly(address indexed to, uint256 amount, uint256 fee);
  event TicketsRedeemedWithTimelock(address indexed to, uint256 amount, uint256 unlockTimestamp);

  Ticket public override ticket;
  Sponsorship public override sponsorship;
  PrizeStrategyInterface public override prizeStrategy;
  
  RNGInterface public rng;
  uint256 public currentPrizeStartedAt;
  uint256 prizePeriodSeconds;
  uint256 public previousPrize;
  uint256 public feeScaleMantissa;
  uint256 public rngRequestId;

  function construct () public initializer {
    __Ownable_init();
    __ReentrancyGuard_init();
  }

  function initialize (
    address _trustedForwarder,
    Sponsorship _sponsorship,
    Ticket _ticket,
    PrizeStrategyInterface _prizeStrategy,
    RNGInterface _rng,
    uint256 _prizePeriodSeconds
  ) public onlyOwner {
    require(address(_sponsorship) != address(0), "sponsorship must not be zero");
    require(address(_sponsorship.controller()) == address(this), "sponsorship controller does not match");
    require(address(_ticket) != address(0), "ticket is not zero");
    require(address(_ticket.prizePool()) == address(this), "ticket is not for this prize pool");
    require(address(_prizeStrategy) != address(0), "prize strategy must not be zero");
    require(_prizePeriodSeconds > 0, "prize period must be greater than zero");
    require(address(_rng) != address(0), "rng cannot be zero");
    ticket = _ticket;
    prizeStrategy = _prizeStrategy;
    sponsorship = _sponsorship;
    trustedForwarder = _trustedForwarder;
    rng = _rng;
    prizePeriodSeconds = _prizePeriodSeconds;
    currentPrizeStartedAt = block.timestamp;
    ERC1820Constants.REGISTRY.setInterfaceImplementer(address(this), ERC1820Constants.TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
  }

  function currentPrize() public override returns (uint256) {
    uint256 yieldBalance = yieldService().balanceOf(address(this));
    uint256 supply = sponsorship.totalSupply();
    uint256 prize;
    if (yieldBalance > supply) {
      prize = yieldBalance.sub(supply);
    }
    return prize;
  }

  function mintSponsorship(uint256 amount) external override nonReentrant {
    _mintSponsorship(_msgSender(), amount);
  }

  function mintSponsorshipTo(address to, uint256 amount) external override nonReentrant {
    _mintSponsorship(to, amount);
  }

  function _mintSponsorship(address to, uint256 amount) internal {
    // Transfer deposit
    IERC20 token = yieldService().token();
    require(token.allowance(_msgSender(), address(this)) >= amount, "insuff");
    token.transferFrom(_msgSender(), address(this), amount);

    // create the sponsorship
    sponsorship.mint(to, amount);

    // Deposit into pool
    token.approve(address(yieldService()), amount);
    yieldService().supply(amount);
  }

  function redeemSponsorship(uint256 amount) external override nonReentrant {
    uint256 bal = sponsorship.balanceOf(_msgSender());

    // burn the sponsorship
    sponsorship.burn(_msgSender(), amount);

    // redeem the collateral
    yieldService().redeem(amount);

    // transfer back to user
    IERC20(yieldService().token()).transfer(_msgSender(), amount);
  }

  function calculateRemainingPreviousPrize() public view override returns (uint256) {
    return multiplyByRemainingTimeFraction(previousPrize);
  }

  function multiplyByRemainingTimeFraction(uint256 value) public view returns (uint256) {
    return FixedPoint.multiplyUintByMantissa(
      value,
      FixedPoint.calculateMantissa(remainingSecondsToPrize(), prizePeriodSeconds)
    );
  }

  function calculateUnlockTimestamp(address, uint256) public view override returns (uint256) {
    return prizePeriodEndAt();
  }

  function estimatePrize(uint256 secondsPerBlockFixedPoint18) external returns (uint256) {
    return currentPrize().add(estimateRemainingPrizeWithBlockTime(secondsPerBlockFixedPoint18));
  }

  function estimateRemainingPrize() public view returns (uint256) {
    return estimateRemainingPrizeWithBlockTime(13 ether);
  }

  function estimateRemainingPrizeWithBlockTime(uint256 secondsPerBlockFixedPoint18) public view returns (uint256) {
    return yieldService().estimateAccruedInterestOverBlocks(
      sponsorship.totalSupply(),
      estimateRemainingBlocksToPrize(secondsPerBlockFixedPoint18)
    );
  }

  function estimateRemainingBlocksToPrize(uint256 secondsPerBlockFixedPoint18) public view returns (uint256) {
    return FixedPoint.divideUintByMantissa(
      remainingSecondsToPrize(),
      secondsPerBlockFixedPoint18
    );
  }

  function remainingSecondsToPrize() public view returns (uint256) {
    uint256 endAt = prizePeriodEndAt();
    if (block.timestamp > endAt) {
      return 0;
    } else {
      return endAt - block.timestamp;
    }
  }

  function isPrizePeriodOver() public view returns (bool) {
    return block.timestamp > prizePeriodEndAt();
  }

  function isRngRequested() public view returns (bool) {
    return rngRequestId != 0;
  }

  function isRngCompleted() public view returns (bool) {
    return rng.isRequestComplete(rngRequestId);
  }

  function canStartAward() public view override returns (bool) {
    return isPrizePeriodOver() && !isRngRequested();
  }

  function canCompleteAward() public view override returns (bool) {
    return isRngRequested() && isRngCompleted();
  }

  function startAward() external override requireCanStartAward nonReentrant {
    rngRequestId = rng.requestRandomNumber(address(0),0);
  }

  function completeAward() external override requireCanCompleteAward nonReentrant {

    uint256 prize = currentPrize();
    if (prize > 0) {

      sponsorship.mint(address(this), prize);

      sponsorship.approve(address(prizeStrategy), prize);
    }

    sponsorship.rewardLoyalty(prize);

    currentPrizeStartedAt = block.timestamp;
    prizeStrategy.award(uint256(rng.randomNumber(rngRequestId)), prize);

    previousPrize = prize;
    rngRequestId = 0;
  }

  function token() external override view returns (IERC20) {
    return yieldService().token();
  }

  function prizePeriodEndAt() public view returns (uint256) {
    // current prize started at is non-inclusive, so add one
    return currentPrizeStartedAt + prizePeriodSeconds;
  }

  function tokensReceived(
    address operator,
    address from,
    address to,
    uint256 amount,
    bytes calldata userData,
    bytes calldata operatorData
  ) external override {
  }

  function _msgSender() internal override(BaseRelayRecipient, ContextUpgradeSafe) virtual view returns (address payable) {
    return BaseRelayRecipient._msgSender();
  }

  function yieldService() public view override returns (YieldServiceInterface) {
    return YieldServiceInterface(getModuleByHashName(ERC1820Constants.YIELD_SERVICE_INTERFACE_HASH));
  }

  modifier requireCanStartAward() {
    require(isPrizePeriodOver(), "prize period not over");
    require(!isRngRequested(), "rng has already been requested");
    _;
  }

  modifier requireCanCompleteAward() {
    require(isRngRequested(), "no rng request has been made");
    require(isRngCompleted(), "rng request has not completed");
    _;
  }

  modifier notRequestingRN() {
    require(rngRequestId == 0, "rng request is in flight");
    _;
  }
}
