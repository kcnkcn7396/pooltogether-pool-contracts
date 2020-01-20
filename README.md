# PoolTogether Contracts

[![CircleCI](https://circleci.com/gh/pooltogether/pooltogether-contracts.svg?style=svg)](https://circleci.com/gh/pooltogether/pooltogether-contracts)

[Code Coverage](https://v2.coverage.pooltogether.us/)

PoolTogether is a prize-linked savings account built on Ethereum. This project contains the Ethereum smart contracts that power the protocol.  The protocol is described in detail in the article [Inside PoolTogether v2.0](https://medium.com/pooltogether/inside-pooltogether-v2-0-e7d0e1b90a08).

**If you want to run PoolTogether locally in an isolated test environment check out the [PoolTogether Mock](https://github.com/pooltogether/pooltogether-contracts-mock) project**

# Ethereum Networks

## Mainnet

| Contract                | Address |
| -------                 | -------- |
| Pool Sai                | [0xb7896fce748396EcFC240F5a0d3Cc92ca42D7d84](https://etherscan.io/address/0xb7896fce748396EcFC240F5a0d3Cc92ca42D7d84) |
| Pool Sai Token (plSai)  | [0xfE6892654CBB05eB73d28DCc1Ff938f59666Fe9f](https://etherscan.io/address/0xfE6892654CBB05eB73d28DCc1Ff938f59666Fe9f) |
| Pool Dai                | [0x29fe7D60DdF151E5b52e5FAB4f1325da6b2bD958](https://etherscan.io/address/0x29fe7D60DdF151E5b52e5FAB4f1325da6b2bD958) |
| Pool Dai Token (plDai)  | [0x49d716DFe60b37379010A75329ae09428f17118d](https://etherscan.io/address/0x49d716DFe60b37379010A75329ae09428f17118d) |

## Kovan

| Contract      | Address  |
| -------       | -------- |
| PoolSai       | [0xF6e245adb2d4758fC180dAB8B212316C8fBA3c02](https://kovan.etherscan.io/address/0xF6e245adb2d4758fC180dAB8B212316C8fBA3c02) |
| PoolSaiToken  | [0xb7896fce748396EcFC240F5a0d3Cc92ca42D7d84](https://kovan.etherscan.io/address/0xb7896fce748396EcFC240F5a0d3Cc92ca42D7d84) |
| PoolDai       | [0x8Db43b4A833815cF535b89d366B5d84D88e43944](https://kovan.etherscan.io/address/0x8Db43b4A833815cF535b89d366B5d84D88e43944) |
| PoolDaiToken  | [0xaf4D6cD3409272ac73593E27A4E6298a649baECf](https://kovan.etherscan.io/address/0xaf4D6cD3409272ac73593E27A4E6298a649baECf) |
| PoolUsdc      | [0x30EE6b6be3C91D8b5D5a04c46b6076a427256436](https://kovan.etherscan.io/address/0x30EE6b6be3C91D8b5D5a04c46b6076a427256436) |
| PoolUsdcToken | [0x9d3D7471a6DC4D6F19e073788d9a57c492f11Bc1](https://kovan.etherscan.io/address/0x9d3D7471a6DC4D6F19e073788d9a57c492f11Bc1) |

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

When a Pool administrator opens a new draw, they commit a hash of a secret and salt.  When the Pool administrator rewards a draw, they reveal the secret and salt.  The secret is then hashed and used to randomly select a winner.

Decentralizing this portion of the protocol is very high on our to-do list.

# Testing Upgrades

The project includes a CLI tool to make working with forks much easier.  To see what commands the tool offers, enter:

```sh
$ yarn fork -h
```

The fork command will allow you to spin up a fork of mainnet and run transactions using unlocked accounts.  The first 10 largest accounts from the subgraph are automatically unlocked.

## Upgrading All Proxies

To upgrade all proxies in the fork by doing a simple implementation address change (i.e. using `upgrade` vs `upgradeAndCall`) you can use the `yarn fork upgrade` command.  Just make sure to `yarn fork push` the new contracts first.

For example:

```sh
# starts the fork
$ yarn fork start
```

```sh
# Ensures the necessary accounts have Eth and tokens
$ yarn fork pay
```

```sh
# Pushes the latest contract implementations to the fork
$ yarn fork push
```

```sh
# Upgrades the deployed proxies to their latest implementations
$ yarn fork upgrade
```

## Fork Actions

There are a few pre-baked actions that can be performed to test the fork.

```sh
# For the top ten users, withdraw and then deposit back into the pool.
$ yarn fork withdraw-deposit
```

```sh
# Rewards the pool
$ yarn fork reward
```
