use std::{collections::BTreeMap, str::FromStr};

use alloy::primitives::Address;
use serde::{Deserialize, Serialize};
use serde_with::{DisplayFromStr, serde_as};

pub const CONTRACTS_ADDRESSES_FILE_CONTENT: &str = include_str!(concat!(env!("OUT_DIR"), "/contracts-addresses.json"));

/// Holds addresses of all smart contracts.
#[serde_as]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ContractAddresses {
    /// Announcements contract
    #[serde_as(as = "DisplayFromStr")]
    pub announcements: Address,
    /// Channels contract
    #[serde_as(as = "DisplayFromStr")]
    pub channels: Address,
    /// Node management module contract (can be zero if safe is not used)
    #[serde_as(as = "DisplayFromStr")]
    pub module_implementation: Address,
    /// Migration helper for node safes and modules
    #[serde_as(as = "DisplayFromStr")]
    pub node_safe_migration: Address,
    /// Safe registry contract
    #[serde_as(as = "DisplayFromStr")]
    pub node_safe_registry: Address,
    /// Stake factory contract
    #[serde_as(as = "DisplayFromStr")]
    pub node_stake_factory: Address,
    /// Price oracle contract
    #[serde_as(as = "DisplayFromStr")]
    pub ticket_price_oracle: Address,
    /// Token contract
    #[serde_as(as = "DisplayFromStr")]
    pub token: Address,
    /// Minimum ticket winning probability contract
    #[serde_as(as = "DisplayFromStr")]
    pub winning_probability_oracle: Address,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SingleNetworkContractAddresses {
    pub indexer_start_block_number: u32,
    pub addresses: ContractAddresses,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworksWithContractAddresses {
    pub networks: BTreeMap<String, SingleNetworkContractAddresses>,
}

impl Default for NetworksWithContractAddresses {
    fn default() -> Self {
        Self::from_str(CONTRACTS_ADDRESSES_FILE_CONTENT)
            .expect("bundled public contracts addresses should be always convertible")
    }
}

impl FromStr for NetworksWithContractAddresses {
    type Err = serde_json::Error;

    fn from_str(data: &str) -> std::result::Result<Self, Self::Err> {
        serde_json::from_str::<NetworksWithContractAddresses>(data)
    }
}

#[cfg(test)]
mod tests {
    use super::NetworksWithContractAddresses;

    #[test]
    fn networks_with_contract_addresses_are_default_constructible() {
        let contract_addresses: NetworksWithContractAddresses = Default::default();

        assert!(!contract_addresses.networks.is_empty());
    }
}
