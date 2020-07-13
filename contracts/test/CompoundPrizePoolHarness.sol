pragma solidity ^0.6.4;

import "../prize-pool/compound/CompoundPrizePool.sol";

/* solium-disable security/no-block-members */
contract CompoundPrizePoolHarness is CompoundPrizePool {

  uint256 internal time;

  function initialize(CTokenInterface _cToken) public {
    cToken = _cToken;
  }

  function supply(uint256 mintAmount) external {
    _supply(mintAmount);
  }

  function redeem(uint256 redeemAmount) external {
    _redeem(redeemAmount);
  }

  function setCurrentTime(uint256 _time) external {
    time = _time;
  }

  function _currentTime() internal override view returns (uint256) {
    if (time == 0) {
      return block.timestamp;
    }
    return time;
  }

}