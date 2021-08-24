const ethers = require('ethers')
const { Assertion } = require('chai')

Assertion.addMethod('equalish', function (value, difference = 10) {
  var obj = this._obj;

  let delta
  if (obj.lt(value)) {
    delta = value.sub(obj)
  } else {
    delta = obj.sub(value)
  }

  this.assert(
      delta.lte(difference)
    , `expected ${obj.toString()} to be within ${difference} of #{exp} but got #{act}`
    , `expected ${obj.toString()} to not be within #{act}`
    , value.toString()        // expected
    , obj.toString()   // actual
  );
});