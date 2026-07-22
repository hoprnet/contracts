# hopr-bindings

[![docs.rs](https://docs.rs/hopr-bindings/badge.svg)](https://docs.rs/hopr-bindings)
[![crates.io](https://img.shields.io/crates/v/hopr-bindings.svg)](https://crates.io/crates/hopr-bindings)

Rust bindings for the [HOPR protocol](https://hoprnet.org/) smart contracts, generated with
[`alloy`](https://github.com/alloy-rs/alloy)'s `sol!`/`abigen!` macros from the Solidity sources and ABIs in
[`ethereum/contracts`](https://github.com/hoprnet/contracts).

This crate only exists to automate that export: it re-generates the bindings whenever the contracts change and
bundles the addresses they are deployed at, so downstream HOPR Rust code (the node, indexers, tooling) never has to
hand-write contract call boilerplate.

Full API documentation is available on [docs.rs](https://docs.rs/hopr-bindings).

## Installation

```sh
cargo add hopr-bindings
```

or add it directly to `Cargo.toml`:

```toml
[dependencies]
hopr-bindings = "4"
```

Full API documentation is available on [docs.rs](https://docs.rs/hopr-bindings).

## Installation

```sh
cargo add hopr-bindings
```

or add it directly to `Cargo.toml`:

```toml
[dependencies]
hopr-bindings = "4"
```

## What's in here

- `codegen` — the generated bindings themselves, one module per contract (e.g. [`crate::hopr_channels`],
  [`crate::hopr_token`], [`crate::hopr_node_safe_registry`]). These are auto-generated and re-exported at the crate
  root, so e.g. `hopr_bindings::hopr_channels::HoprChannels` works directly.
- [`config`] — [`ContractAddresses`](crate::config::ContractAddresses) (where each contract lives on a given
  network), [`ContractInstances`](crate::config::ContractInstances) (live handles to those contracts through an
  `alloy` provider), and helpers to deploy a full local HOPR + Safe + Multicall3 stack against
  [Anvil](https://book.getfoundry.sh/anvil/) for testing.
- [`constants`] — well-known addresses and deployment bytecode for infrastructure the HOPR contracts depend on
  (ERC-1820 registry, [Safe](https://safe.global/) suite, Multicall3).
- [`error`] — the [`Error`](crate::error::Error) type returned by this crate's helpers.
- the `hopr-contract-addresses` binary — dumps the bundled `contracts-addresses.json` (see below) to stdout.

## Getting started

Look up the addresses of an already-deployed network:

```rust
use hopr_bindings::config::NetworksWithContractAddresses;

let networks = NetworksWithContractAddresses::default();
let localhost = &networks.networks["anvil-localhost"];
println!("HOPR token deployed at {}", localhost.addresses.token);
```

Or spin up a fresh local deployment (e.g. for integration tests) and call a contract:

```no_run
use hopr_bindings::config::{ContractInstances, create_anvil, create_provider};

# async fn run() -> anyhow::Result<()> {
let anvil = create_anvil(None, false, true);
let hopr_deployer_key = anvil.keys()[0].to_bytes();
let common_deployer_key = anvil.keys()[1].to_bytes();
let hopr_deployer_address = anvil.addresses()[0];
let common_deployer_address = anvil.addresses()[1];

let provider = create_provider(&anvil, &hopr_deployer_key, &common_deployer_key)?;
let contracts =
    ContractInstances::deploy_for_testing(provider, hopr_deployer_address, common_deployer_address).await?;

let balance = contracts.token.balanceOf(hopr_deployer_address).call().await?;
println!("deployer HOPR balance: {balance}");
# Ok(())
# }
```

## The `contracts-addresses.json` file

`ethereum/bindings/contracts-addresses.json` is the single source of truth for where the HOPR contracts are deployed
on every network (local, staging, production). It is embedded into the crate at build time
([`config::CONTRACTS_ADDRESSES_FILE_CONTENT`]) and parsed into [`config::NetworksWithContractAddresses`]. It is kept
up to date automatically as part of the deployment pipeline in this repository — see
[`ethereum/README.md`](https://github.com/hoprnet/contracts/blob/main/ethereum/README.md) for how deployments work.

## Regenerating the bindings

The generated contract bindings (re-exported at the crate root, e.g. [`crate::hopr_channels`]) are produced from the
compiled contracts in
[`ethereum/contracts`](https://github.com/hoprnet/contracts/tree/main/ethereum/contracts) and must not be edited by
hand — they are overwritten by the codegen tooling whenever the contracts are rebuilt.
