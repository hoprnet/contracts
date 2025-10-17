//! HOPR Smart Contracts Addresses dumper.
//!
//! This executable dumps the content of the build state of the contracts-addresses.json file.
//!
//! ## Help
//! ```shell
//! ➜   hopr-contract-addresses
//! {
//!   "networks": {
//!     "rotsee": {
//!      "addresses": {
//!        "announcements": "0x0347A131861881604EA841b678210ba60b8E6D82",
//!        "channels": "0x2CCd294e00593CE482216b88F3B481dF5EEFf357",
//!        "module_implementation": "0x79C3bF06E96A9373765284aFb0a35e9529E2B3F2",
//!        "node_safe_migration": "0xe9670B5D87c87111C9050D915971B73b9f5021a9",
//!        "node_safe_registry": "0xaFa257f2799835D2E29e7eC7ee448530F9d8Cb20",
//!        "node_stake_factory": "0xcB0841cc3DBDE97aC52B945F02Ee4F3D8707d977",
//!        "ticket_price_oracle": "0xFA251d4C367683d6181531afd5964E660aCf43A0",
//!        "token": "0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1",
//!        "winning_probability_oracle": "0xa641822a52AcbDc0c0123337f715C1d9756c21bD"
//!      },
//!      "environment_type": "staging",
//!      "indexer_start_block_number": 42671336
//!    },
//!     "debug-staging": {
//!       "indexer_start_block_number": 29690235,
//!       "addresses": {
//!         "announcements": "0xD78BCa8452B8Ea281a659f380E0eF710C64EB85b",
//!         "channels": "0xc060582564b12335cD804339842F5509dbF6F74d",
//!         "network_registry": "0xf08E27C3A09627D605bFd164459f7caF18D1d25f",
//!         "network_registry_proxy": "0x0D1a8f1b13FD1d64696c5E03dd45Cd139e40dE0c",
//!         "token": "0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1",
//!         "node_stake_v2_factory": "0x5F5b459db681996292Ad58cc10e88027033149B8",
//!         "node_safe_registry": "0x0bf6bd25ac47FE9D41A99B135Cb439B89138F05a",
//!         "module_implementation": "0xe8d914Ef66b4FF086C6fbCb1E0ea97c0A9D2f3de",
//!         "ticket_price_oracle": "0x281a91FeA199a3bAB5D7d5f05833B257E2fd7741",
//!         "winning_probability_oracle": "0x02e1009fd222917Ee7bdfdBF8AE1e56c4ae3F6f3"
//!       }
//!     }
//!   }
//! }
//! ```

fn main() -> anyhow::Result<()> {
    println!("{}", hopr_bindings::CONTRACTS_ADDRESSES_FILE_CONTENT);

    Ok(())
}
