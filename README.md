# PoolTogether Contracts

[![CircleCI](https://circleci.com/gh/pooltogether/pooltogether-contracts.svg?style=svg)](https://circleci.com/gh/pooltogether/pooltogether-contracts)

[Code Coverage](https://v2.coverage.pooltogether.us/)

PoolTogether is a prize-linked savings account built on Ethereum. This project contains the Ethereum smart contracts that power the protocol.  The protocol is described in detail in the article [Inside PoolTogether v2.0](https://medium.com/pooltogether/inside-pooltogether-v2-0-e7d0e1b90a08).

**If you want to run PoolTogether locally in an isolated test environment check out the [PoolTogether Mock](https://github.com/pooltogether/pooltogether-contracts-mock) project**

# Ethereum Networks

| Network | Contract | Address |
| ------- | -------- | ------- |
| mainnet | Pool (abi on Etherscan)    | [0xb7896fce748396EcFC240F5a0d3Cc92ca42D7d84](https://etherscan.io/address/0xb7896fce748396EcFC240F5a0d3Cc92ca42D7d84) |
| rinkeby | Pool ([abi](https://abis.v2.pooltogether.us/Pool.json)) | [0xf6535134C89D5e32ccE2C88E7847e207164E754F](https://rinkeby.etherscan.io/address/0xf6535134C89D5e32ccE2C88E7847e207164E754F) |

# Setup

Clone the repo and then install deps:

```
$ yarn
```

# Testing

To run the entire test suite and see the gas usage:

```
$ yarn test
```

Ignore the warnings.

# Coverage

To run the coverage checks:

```
$ yarn coverage
```

# Deploying to Rinkeby

Copy over .envrc and allow direnv:

```
$ cp .envrc.example .envrc
$ direnv allow
```

If you change `HDWALLET_MNEMONIC` then you'll need to update `ADMIN_ADDRESS` as well.  I like to use the second address generated by the `HDWALLET_MNEMONIC`.

To deploy the project to Rinkeby:

```
yarn session-rinkeby
yarn push
yarn migrate-rinkeby
```

# How it Works

A prize-linked savings account is one in which interest payments are distributed as prizes.  PoolTogether uses [Compound](https://compound.finance) to generate interest on pooled deposits and distributes the interest in prize draws.

## User Flow

1. An administrator opens a new draw by committing the hash of a secret and salt.
2. A user deposits tokens into the Pool.  The Pool transfers the tokens to the Compound CToken contract and adds the deposit to the currently open draw.
3. Time passes.  Interest accrues.
4. An administrator executes the "reward" function, which:
  - If there is a committed draw it is "rewarded": the admin reveals the previously committed secret and uses it to select a winner for the currently accrued interest on the pool deposits.  The interest is added to the open draw to increase the user's eligibility.
  - The open draw is "committed", meaning it will no longer receive deposits.
  - A new draw is opened to receive deposits.  The admin commits a hash of a secret and salt.
5. A user withdraws.  The Pool will withdraw from the Compound CToken all of the user's deposits and winnings.  Any amounts across open, committed, or rewarded draws will be withdrawn.

As you can see, prizes are awarded in rolling draws.  In this way, we can ensure users will contribute fairly to a prize.  The open period allows users to queue up their deposits for the committed period, then once the committed period is over the interest accrued is awarded to one of the participants.

You can visualize the rolling draws like so:

| Step  | Draw 1    | Draw 2    | Draw 3    | Draw 4    |  Draw ... |
| ----- | ------    | ------    | ------    | ------    | --------- |
| 1     | Open      |           |           |           |           |
| 2     | Committed | Open      |           |           |           |
| 3     | Rewarded  | Committed | Open      |           |           |
| 4     |           | Rewarded  | Committed | Open      |           |
| 5     |           |           | Rewarded  | Committed |           |
| ...   |           |           |           | Rewarded  |           |

## Winner Selection

When a Pool administrator opens a new draw, they commit a hash of a secret and salt.  When the Pool administrator rewards a draw, they reveal the secret and salt.  The secret is combined with the hash of the gross winnings to serve as the entropy used to randomly select a winner.

Decentralizing this portion of the protocol is very high on our to-do list.

# Testing Upgrades

The project includes a CLI tool to make working with forks much easier.  To see what commands the tool offers, enter:

```sh
$ yarn fork -h
```

The only drawback to this tool is that it **changes the .openzeppelin/mainnet.json config**.  Make sure to `git checkout .openzeppelin/mainnet.json` so that you don't commit the forked changes.  This is a limitation of OpenZeppelin for the moment.

To test the upgrade to v2.x follow these steps:

**1. Fix .envrc**

Set the environment variables SECRET_SEED, SALT_SEED, LOCALHOST_URL, GANACHE_FORK_URL and then run `direnv allow`

**2. Start a fork of mainnet**

`yarn fork start`

**3. Give some eth to the deployment admin**

`yarn fork pay`

**4. Push the latest contract to the fork**

`yarn fork push`

**5. Upgrade the contracts to v2.x**

`yarn fork upgrade-v2x`

**6. Test withdrawals and deposits**

`yarn fork withdraw-deposit`

**7. Trigger the reward function**

`yarn fork reward`
