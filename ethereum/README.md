# HOPR Ethereum Package

This directory contains the Ethereum smart contracts and Rust bindings for the [HOPR protocol](https://github.com/hoprnet/hoprnet), which powers HOPR's privacy-preserving incentive framework.

## Contract overview

```
├── Announcements.sol            # Node announcement mechanism (independent of staking)
├── Channels.sol                 # Uni-directional payment channel contract
├── Crypto.sol                   # Cryptographic utility functions and primitives
├── MultiSig.sol                 # Multisig modifiers to enforce Safe-based node operations
├── Ledger.sol                   # Snapshot-based index for HOPR Channels
├── TicketPriceOracle.sol        # Oracle for updating the HOPR ticket price network-wide
├── WinningProbabilityOracle.sol # Oracle for updating the minimum winning probability network-wide
├── ServiceRegistry.sol          # Permissionless registry of services that HOPR nodes offer
├── interfaces/                  # Solidity interfaces for contract interoperability
│   ├── IAvatar.sol
│   ├── INetworkRegistryRequirement.sol
│   ├── INodeManagementModule.sol
│   └── IServiceRequirement.sol

├── node-stake/                          # Node staking system built on Safe's account-abstraction design
│   ├── NodeSafeRegistry.sol             # Registry mapping nodes to their Safe wallets
│   ├── NodeStakeFactory.sol             # Factory contract to deploy and initialize node Safes
│   ├── migration/                       # Contracts for upgrading Safes and/or modules
│   │   └── NodeSafeMigration.sol        # Upgrades Safe to v1.5.0 and the module to the current version
│   └── permissioned-module/             # Modules for Safe-based node management
│       ├── CapabilityPermissions.sol    # Defines capability-based permission rules
│       ├── NodeManagementModule.sol     # Main module for managing nodes via a Safe
│       └── SimplifiedModule.sol        # Lightweight version of the Node Management Module

├── utils/                               # Shared utility libraries
│   ├── EnumerableKeyBindingSet.sol      # Enumerable set for KeyBinding structs
│   ├── EnumerableSafeModuleSet.sol      # Enumerable set for SafeModule structs
│   ├── EnumerableStringSet.sol          # Enumerable set for strings
│   ├── EnumerableTargetSet.sol          # Enumerable set for targets (addresses with metadata)
│   ├── SafeSuiteLibV141.sol             # Helper for deploying Safe v1.4.1 suite contracts
│   ├── SafeSuiteLibV150.sol             # Helper for deploying Safe v1.5.0 suite contracts
│   └── TargetUtils.sol                  # Helper functions for managing targets

└── static/                           # Legacy contracts (archived, not actively maintained)
    ├── HoprDistributor.sol           # Token distribution
    ├── HoprForwarder.sol             # Minimal forwarder for meta-transactions
    ├── HoprToken.sol                 # ERC20 token implementation for HOPR
    ├── HoprWrapper.sol               # Legacy wrapper contract
    ├── HoprWrapperProxy.sol          # Proxy for interacting with HoprWrapper
    ├── NetworkRegistry.sol           # Legacy Network Registry
    ├── ERC777/
    │   └── ERC777Snapshot.sol
    ├── openzeppelin-contracts/
    │   └── ERC777.sol
    ├── proxy/                        # Adapters between NetworkRegistry and staking modules
    │   ├── DummyProxyForNetworkRegistry.sol
    │   ├── SafeProxyForNetworkRegistry.sol
    │   └── StakingProxyForNetworkRegistry.sol
    └── stake/                        # Legacy staking contracts by season
        ├── HoprBoost.sol
        ├── HoprStake.sol
        ├── HoprStake2.sol
        ├── HoprStakeBase.sol
        ├── HoprStakeSeason3.sol
        ├── HoprStakeSeason4.sol
        ├── HoprStakeSeason5.sol
        ├── HoprStakeSeason6.sol
        ├── HoprStakeSeason7.sol
        ├── HoprStakeSeason8.sol
        ├── HoprWhitehat.sol
        └── IHoprBoost.sol
```

## Installation

Use the [Nix environment](../README.md#develop), or install the following tools manually:

1. `rustup`
2. `foundryup`
3. `brew install lcov` (required for viewing coverage reports)

Without Nix, create a `foundry.toml` from `foundry.in.toml` and set the `solc` version under `[profile.default]`.

Set up environment variables:

```sh
cd contracts
cp ./contracts/.env.example ./contracts/.env
```

Then fill in the required values.

## Testing

### Unit tests

```sh
cd contracts && make sc-test
```

### Coverage

```sh
cd contracts && make sc-coverage
```

## Deployment

### Local (Anvil)

```sh
# Start Anvil, wait until its RPC is ready, then deploy all contracts
anvil &
until cast chain-id >/dev/null 2>&1; do sleep 0.2; done
make anvil-deploy-all
```

```sh
# Stop the Anvil daemon
lsof -i :8545 -s TCP:LISTEN -t | xargs -I {} -n 1 kill {}
```

### Remote networks (development, staging, production)

Before deploying to a new network, update `contracts-addresses.json`:

1. Add a new entry with the network name.
2. Set all addresses to `0x0000000000000000000000000000000000000000`, except for `token` and `xhopr_token`.
3. Set `environment_type` to `development`, `staging`, or `production`. This affects the default winning probability, ticket price, and key-binding fees.
4. Set `indexer_start_block_number` to `0`. The deployment script will update it to the first deployment block automatically.

A sample entry:

```json
"piz-palu-dev": {
  "addresses": {
    "announcements": "0x0000000000000000000000000000000000000000",
    "channels": "0x0000000000000000000000000000000000000000",
    "module_implementation": "0x0000000000000000000000000000000000000000",
    "node_safe_migration": "0x0000000000000000000000000000000000000000",
    "node_safe_registry": "0x0000000000000000000000000000000000000000",
    "node_stake_factory": "0x0000000000000000000000000000000000000000",
    "ticket_price_oracle": "0x0000000000000000000000000000000000000000",
    "token": "0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1",
    "winning_probability_oracle": "0x0000000000000000000000000000000000000000",
    "xhopr_token": "0xD057604A14982FE8D88c5fC25Aac3267eA142a08"
  },
  "chain_id": 100,
  "environment_type": "development",
  "indexer_start_block_number": 0
}
```

Staging and production both target Gnosis chain. Load environment variables, then run the appropriate script:

```sh
source .env
```

```sh
# Deploy to staging and verify on Sourcify
FOUNDRY_PROFILE=staging NETWORK=debug-staging forge script --broadcast --verify --verifier sourcify script/DeployAll.s.sol:DeployAllContractsScript

# Deploy to development and verify on Gnosisscan
FOUNDRY_PROFILE=development NETWORK=jura-dev forge script --broadcast --slow \
   --verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=100" \
   --delay 30 --chain 100 --etherscan-api-key "${ETHERSCAN_API_KEY}" \
   --priority-gas-price 0.001gwei --with-gas-price 0.002gwei \
   script/DeployAll.s.sol:DeployAllContractsScript
```

### Manual contract verification

If a contract is not automatically verified, use `forge verify-contract` directly:

```sh
export ETHERSCAN_API_KEY=<gnosisscan_api_key>
forge verify-contract \
   --verifier etherscan \
   --verifier-url "https://api.gnosisscan.io/api" \
   --chain gnosis \
   --constructor-args $(cast abi-encode "constructor(address,address,uint256)" \
      0xA02Af160a280957A8881879Ee9239A614Ab47F0D \
      0x4fF4e61052a4DFb1bE72866aB711AE08DD861976 \
      1000000000000000000000) \
   0xcA9B1bC189F977B2A9217598D0300d956b6a719f \
   src/proxy/HoprStakingProxyForNetworkRegistry.sol:HoprStakingProxyForNetworkRegistry
```

Check the verification status with:

```sh
forge verify-check --chain-id <number> <GUID>
```

### Contract addresses

`contracts-addresses.json` is the authoritative reference for deployed contract addresses across all networks (local, staging, production). For each network it records contract addresses, chain ID, environment type, and the indexer start block. It is updated automatically on each deployment.

### Legacy contract deployment order

The diagram below shows the deployment dependencies for contracts in `static/`. Contracts at the bottom depend on those above them. `HoprDistributor` and `HoprWrapper` are skipped in local deployments.

```
              +-----------------+
              | ERC1820Registry |
              +--------^--------+
                       |
                +------+------+       +------------+        +-----------+
                |  HoprToken  |       | xHoprToken |        | HoprBoost |
                +^---^--^---^-+       +-^----^-----+        +-----^-----+
                 |   |  |   |           |    |                    |
+----------------++  |  | +-+-----------+-+  |                    |
| HoprDistributor |  |  | |  HoprWrapper  |  |                    |
+-----------------+  |  | +---------------+  |                    |
                     |  |                    |                    |
                     |  +-----------------+  |   +----------------+
                     |                    |  |   |
                     |                 +--+--+---+-+
                     |                 | HoprStake |
                     |                 +-----^-----+
                     |                       |
             +-------+------+    +-----------+----------+
             | HoprChannels |    | NetworkRegistryProxy |
             +--------------+    +-----------^----------+
                                             |
                                  +----------+----------+
                                  | HoprNetworkRegistry |
                                  +---------------------+
```

## Notes

### Compiler versions

Some contracts use updated Solidity compiler versions compared to their original on-chain deployments. This is a workaround for Foundry's lack of multi-version compiler support.

| Version | Usage                                                                                                                                                                                         |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| v0.4    | `PermittableToken` — base implementation of the deployed xHOPR token. Source was extracted from the deployed contract; only the `pragma solidity` directive was relaxed to allow compilation. |
| v0.6    | Deployed `HoprToken`.                                                                                                                                                                         |
| v0.8    | All current contracts.                                                                                                                                                                        |

### Pinned library dependencies

Dependencies are locked to audited commits:

- **Safe contracts** — commit [`eb93dbb`](https://github.com/safe-global/safe-contracts/blob/main/docs/audit_1_4_0.md)
- **Zodiac Modifier Roles v1** — commit [`454be9d`](https://github.com/gnosis/zodiac-modifier-roles-v1/tree/main). After importing, adjust the `pragma` for two contracts and manually add their Gnosis Safe imports (e.g. `Enum.sol`).
- **Zodiac Base** — commit [`8a77e7b`](https://github.com/gnosis/zodiac/tree/8a77e7b224af8004bd9f2ff4e2919642e93ffd85)

To install:

```sh
forge install safe-global/safe-contracts@eb93dbb0f62e2dc1b308ac4c110038062df0a8c9 \
   gnosis/zodiac-modifier-roles-v1@454be9d3c26f90221ca717518df002d1eca1845f \
   gnosis/zodiac@8a77e7b224af8004bd9f2ff4e2919642e93ffd85 \
   OpenZeppelin/openzeppelin-contracts-upgradeable \
   --no-git --no-commit
```

### Safe suite deployment

`SafeSuiteSetupScript` deploys Safe suite contracts deterministically using the `main-suite` tag:

|                              | l2  | l2-suite | main-suite | accessors | factory | handlers | libraries | singleton |
| ---------------------------- | --- | -------- | ---------- | --------- | ------- | -------- | --------- | --------- |
| SimulateTxAccessor           |     | x        | x          | x         |         |          |           |           |
| SafeProxyFactory             |     | x        | x          |           | x       |          |           |           |
| TokenCallbackHandler         |     | x        | x          |           |         | x        |           |           |
| CompatibilityFallbackHandler |     | x        | x          |           |         | x        |           |           |
| CreateCall                   |     | x        | x          |           |         |          | x         |           |
| MultiSend                    |     | x        | x          |           |         |          | x         |           |
| MultiSendCallOnly            |     | x        | x          |           |         |          | x         |           |
| SignMessageLib               |     | x        | x          |           |         |          | x         |           |
| SafeL2                       | x   | x        |            |           |         |          |           |           |
| Safe                         |     |          | x          |           |         |          |           | x         |

Deployment begins with a singleton contract whose details are stored in the [safe-singleton-factory artifacts](https://github.com/safe-global/safe-singleton-factory/tree/main/artifacts). The `anvil-deploy-safe-singleton` target follows the [chain 31337 deployment spec](https://github.com/safe-global/safe-singleton-factory/blob/6700a7c90ececc8cb9e1a4d97fd70fea1ee4670d/artifacts/31337/deployment.json). Running `make run-anvil` also deploys the SafeSingleton, which acts as the factory for deterministic deployments.

### Dufour network migration

In the Dufour network, node-staking Safes use `Safe.sol` v1.3 and node-staking modules use an undeclared version of `NodeManagementModule.sol`. Because module proxies were created with a minimal proxy (implementation address fixed at deployment) and the module does not allow delegatecalls, existing `NodeManagementModule` instances cannot be upgraded in place.

Instead, module owners (i.e. the Safe attached to the module) may call `migrate` to point to a new implementation. `NodeSafeMigration` supports this process by:

- Deploying a new `NodeManagementModule` proxy using `NodeManagementModule.sol` v2.0.0.
- Initialising basic targets on the new module (Channels, Token, Announcements, Send — all must already be deployed and supplied to `NodeSafeMigration`).
- Registering node(s) with the new module.
- Returning ownership to the caller.

Optionally, `NodeSafeMigration` can also upgrade the Safe implementation itself.

Before migrating, node runners must redeem all tickets, close all channels, and shut down the node. The migration is then executed as a multicall:

1. Migrate the module.
2. (Optional) Remove the old module from the Safe.
3. (Optional) Upgrade the Safe implementation.
