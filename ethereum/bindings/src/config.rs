use std::{collections::BTreeMap, str::FromStr};

use alloy::{
    contract::Result as ContractResult,
    network::{EthereumWallet, TransactionBuilder},
    node_bindings::{Anvil, AnvilInstance},
    primitives::{Address, Bytes, U256},
    providers::{MULTICALL3_ADDRESS, ProviderBuilder},
    rpc::types::TransactionRequest,
    signers::local::PrivateKeySigner,
    sol_types::{SolCall, SolValue},
};
use serde::{Deserialize, Serialize};
use serde_with::{DisplayFromStr, serde_as};
use tracing::debug;

use crate::{
    constants::*,
    erc677_mock::ERC677Mock::{self, ERC677MockInstance},
    hopr_announcements::HoprAnnouncements::{self, HoprAnnouncementsInstance},
    hopr_announcements_proxy::HoprAnnouncementsProxy,
    hopr_channels::HoprChannels::{self, HoprChannelsInstance},
    hopr_node_management_module::HoprNodeManagementModule::{self, HoprNodeManagementModuleInstance},
    hopr_node_safe_migration::HoprNodeSafeMigration::{self, HoprNodeSafeMigrationInstance},
    hopr_node_safe_registry::HoprNodeSafeRegistry::{self, HoprNodeSafeRegistryInstance},
    hopr_node_stake_factory::HoprNodeStakeFactory::{self, HoprNodeStakeFactoryInstance},
    hopr_ticket_price_oracle::HoprTicketPriceOracle::{self, HoprTicketPriceOracleInstance},
    hopr_token::HoprToken::{self, HoprTokenInstance},
    hopr_winning_probability_oracle::HoprWinningProbabilityOracle::{self, HoprWinningProbabilityOracleInstance},
};
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
    /// XHOPR token contract
    #[serde_as(as = "DisplayFromStr")]
    pub xhopr_token: Address,
}

impl IntoIterator for &ContractAddresses {
    type IntoIter = std::vec::IntoIter<Address>;
    type Item = Address;

    fn into_iter(self) -> Self::IntoIter {
        vec![
            self.token,
            self.channels,
            self.announcements,
            self.node_safe_registry,
            self.node_safe_migration,
            self.ticket_price_oracle,
            self.winning_probability_oracle,
            self.node_stake_factory,
            self.module_implementation,
            self.xhopr_token,
        ]
        .into_iter()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SingleNetworkContractAddresses {
    pub chain_id: u64,
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

/// Holds instances to contracts.
#[derive(Debug, Clone)]
pub struct ContractInstances<P> {
    pub token: HoprTokenInstance<P>,
    pub channels: HoprChannelsInstance<P>,
    pub announcements: HoprAnnouncementsInstance<P>,
    pub safe_registry: HoprNodeSafeRegistryInstance<P>,
    pub price_oracle: HoprTicketPriceOracleInstance<P>,
    pub win_prob_oracle: HoprWinningProbabilityOracleInstance<P>,
    pub stake_factory: HoprNodeStakeFactoryInstance<P>,
    pub module_implementation: HoprNodeManagementModuleInstance<P>,
    pub node_safe_migration: HoprNodeSafeMigrationInstance<P>,
    pub xhopr_token: ERC677MockInstance<P>,
}

impl<P> ContractInstances<P>
where
    P: alloy::providers::Provider + Clone,
{
    pub fn new(contract_addresses: &ContractAddresses, provider: P) -> Self {
        Self {
            token: HoprTokenInstance::new(contract_addresses.token, provider.clone()),
            channels: HoprChannelsInstance::new(contract_addresses.channels, provider.clone()),
            announcements: HoprAnnouncementsInstance::new(contract_addresses.announcements, provider.clone()),
            safe_registry: HoprNodeSafeRegistryInstance::new(contract_addresses.node_safe_registry, provider.clone()),
            price_oracle: HoprTicketPriceOracleInstance::new(contract_addresses.ticket_price_oracle, provider.clone()),
            win_prob_oracle: HoprWinningProbabilityOracleInstance::new(
                contract_addresses.winning_probability_oracle,
                provider.clone(),
            ),
            stake_factory: HoprNodeStakeFactoryInstance::new(contract_addresses.node_stake_factory, provider.clone()),
            module_implementation: HoprNodeManagementModuleInstance::new(
                contract_addresses.module_implementation,
                provider.clone(),
            ),
            node_safe_migration: HoprNodeSafeMigrationInstance::new(
                contract_addresses.node_safe_migration,
                provider.clone(),
            ),
            xhopr_token: ERC677MockInstance::new(contract_addresses.xhopr_token, provider.clone()).into(),
        }
    }

    pub async fn deploy_erc1820_registry(provider: P, common_deployer_address: Address) -> ContractResult<()> {
        debug!("deploying ERC1820 registry...");
        // Fund 1820 deployer and deploy ERC1820Registry
        let tx = TransactionRequest::default()
            .with_to(ERC_1820_DEPLOYER)
            .with_from(common_deployer_address)
            .with_value(ETH_VALUE_FOR_ERC1820_DEPLOYER);

        // Sequentially executing the following transactions:
        // 1. Fund the deployer wallet
        provider.send_transaction(tx.clone()).await?.watch().await?;
        // 2. Use the funded deployer wallet to deploy ERC1820Registry with a signed txn
        provider
            .send_raw_transaction(&ERC_1820_REGISTRY_DEPLOY_CODE)
            .await?
            .watch()
            .await?;

        Ok(())
    }

    pub async fn deploy_multicall3(provider: P, common_deployer_address: Address) -> ContractResult<()> {
        debug!("deploying Multicall3...");
        // Fund Multicall3 deployer and deploy Multicall3
        let multicall3_code = provider.get_code_at(MULTICALL3_ADDRESS).await?;
        if multicall3_code.is_empty() {
            // Fund Multicall3 deployer and deploy Multicall3
            let tx = TransactionRequest::default()
                .with_to(crate::constants::MULTICALL3_DEPLOYER)
                .with_from(common_deployer_address)
                .with_value(crate::constants::ETH_VALUE_FOR_MULTICALL3_DEPLOYER);
            // Sequentially executing the following transactions:
            // 1. Fund the deployer wallet
            provider.send_transaction(tx.clone()).await?.watch().await?;
            // 2. Use the funded deployer wallet to deploy Multicall3 with a signed txn
            provider
                .send_raw_transaction(MULTICALL3_DEPLOY_CODE)
                .await?
                .watch()
                .await?;
        }
        Ok(())
    }

    pub async fn deploy_safe_suites(provider: P, common_deployer_address: Address) -> ContractResult<()> {
        debug!("deploying Safe contracts...");

        // Check if safe suite has been deployed. If so, skip this step
        let code = provider.get_code_at(SAFE_SINGLETON_ADDRESS).await?;

        // only deploy contracts when needed
        if code.is_empty() {
            // Deploy Safe diamond deployment proxy singleton
            let safe_diamond_proxy_address = {
                // Fund the Safe deployer with 0.01 anvil-eth and deploy the Safe diamond deployment proxy singleton
                let tx = TransactionRequest::default()
                    .with_to(SAFE_DEPLOYER_ADDRESS)
                    .with_from(common_deployer_address)
                    .with_value(SAFE_DEPLOYER_BALANCE);

                provider.send_transaction(tx).await?.watch().await?;

                let tx = provider
                    .send_raw_transaction(&SAFE_DIAMOND_PROXY_SINGLETON_DEPLOY_CODE)
                    .await?
                    .get_receipt()
                    .await?;

                tx.contract_address.unwrap()
            };
            debug!("Safe diamond proxy singleton {:?}", safe_diamond_proxy_address);

            // Deploy minimum Safe suite
            // 1. Safe proxy factory deploySafeProxyFactory();
            let _tx_safe_proxy_factory = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_from(common_deployer_address)
                .with_input(SAFE_PROXY_FACTORY_DEPLOY_CODE);
            // 2. Handler: only CompatibilityFallbackHandler and omit TokenCallbackHandler as it's not used now
            // 2. Handler: deploy Safe ExtensibleFallbackHandler, v1.5.0
            let _tx_safe_compatibility_fallback_handler = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_from(common_deployer_address)
                .with_input(SAFE_COMPATIBILITY_FALLBACK_HANDLER_DEPLOY_CODE_V150);
            // 3. Library: only MultiSendCallOnly and omit MultiSendCall
            let _tx_safe_multisend_call_only = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_from(common_deployer_address)
                .with_input(SAFE_MULTISEND_CALL_ONLY_DEPLOY_CODE);
            // 4. Safe singleton v1.4.1 deploySafe();
            let _tx_safe_singleton_v141 = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_from(common_deployer_address)
                .with_input(SAFE_SINGLETON_DEPLOY_CODE_V141);
            // 5. Safe L2 singleton v1.4.1 deploySafe();
            let _tx_safe_l2_singleton_v141 = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_from(common_deployer_address)
                .with_input(SAFE_SINGLETON_L2_DEPLOY_CODE_V141);
            // 6. Safe multisend:
            let _tx_safe_multisend = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_from(common_deployer_address)
                .with_input(SAFE_MULTISEND_DEPLOY_CODE);
            // 7. Safe L2 singleton v1.5.0 deploySafe();
            let _tx_safe_l2_singleton_v150 = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_from(common_deployer_address)
                .with_input(SAFE_SINGLETON_L2_DEPLOY_CODE_V150);
            // other omitted libs: SimulateTxAccessor, CreateCall, and SignMessageLib
            // broadcast those transactions
            provider.send_transaction(_tx_safe_proxy_factory).await?.watch().await?;
            provider
                .send_transaction(_tx_safe_compatibility_fallback_handler)
                .await?
                .watch()
                .await?;
            provider
                .send_transaction(_tx_safe_multisend_call_only)
                .await?
                .watch()
                .await?;
            provider
                .send_transaction(_tx_safe_singleton_v141)
                .await?
                .watch()
                .await?;
            provider
                .send_transaction(_tx_safe_l2_singleton_v141)
                .await?
                .watch()
                .await?;
            provider.send_transaction(_tx_safe_multisend).await?.watch().await?;
            provider
                .send_transaction(_tx_safe_l2_singleton_v150)
                .await?
                .watch()
                .await?;
        }

        let code_safe_singleton_v141 = provider.get_code_at(SAFE_SINGLETON_L2_ADDRESS_V141).await?;
        let code_safe_singleton_v150 = provider.get_code_at(SAFE_SINGLETON_L2_ADDRESS_V150).await?;
        let code_compatibility_handler_v150 = provider
            .get_code_at(SAFE_COMPATIBILITY_FALLBACK_HANDLER_ADRESS_V150)
            .await?;
        assert!(
            !code_safe_singleton_v141.is_empty(),
            "Safe singleton v1.4.1 not deployed"
        );
        assert!(
            !code_safe_singleton_v150.is_empty(),
            "Safe singleton v1.5.0 not deployed"
        );
        assert!(
            !code_compatibility_handler_v150.is_empty(),
            "Safe compatibility handler v1.5.0 not deployed"
        );
        Ok(())
    }

    async fn inner_deploy_common_contracts_for_testing(
        provider: P,
        common_deployer_address: Address,
    ) -> ContractResult<()> {
        // Pre-deploy common contracts
        debug!(
            "Common deployer nonce before: {}",
            provider.get_transaction_count(common_deployer_address).latest().await?
        );
        debug!(
            "Common deployer balance before: {}",
            provider.get_balance(common_deployer_address).await?
        );
        Self::deploy_erc1820_registry(provider.clone(), common_deployer_address).await?;
        Self::deploy_multicall3(provider.clone(), common_deployer_address).await?;
        Self::deploy_safe_suites(provider.clone(), common_deployer_address).await?;
        debug!(
            "Common deployer nonce after: {}",
            provider.get_transaction_count(common_deployer_address).latest().await?
        );
        debug!(
            "Common deployer balance after: {}",
            provider.get_balance(common_deployer_address).await?
        );
        Ok(())
    }

    /// Deploys testing environment (with dummy network registry proxy) via the given provider.
    async fn inner_deploy_hopr_contracts_for_testing(
        provider: P,
        hopr_deployer_address: Address,
    ) -> ContractResult<Self> {
        debug!("deploying contracts...");
        debug!(
            "Hopr deployer nonce before: {}",
            provider.get_transaction_count(hopr_deployer_address).latest().await?
        );
        // HoprToken contract
        let token = HoprToken::deploy(provider.clone()).await?;
        // - grant deployer minter role in the token contract, so that the deployer can mint tokens for testing
        token
            .grantRole(HOPR_TOKEN_MINTER_ROLE, hopr_deployer_address)
            .send()
            .await?
            .watch()
            .await?;
        // - mint some tokens to the deployer for testing
        token
            .mint(
                hopr_deployer_address,
                MINTED_TOKEN_AMOUNT,
                Bytes::default(),
                Bytes::default(),
            ) // mint 1000 tokens to the deployer
            .send()
            .await?
            .watch()
            .await?;

        // HoprTicketPriceOracle contract
        let price_oracle = HoprTicketPriceOracle::deploy(
            provider.clone(),
            hopr_deployer_address,
            U256::from(100000000000000000_u128), // U256::from(100000000000000000_u128),
        )
        .await?;

        // HoprWinningProbabilityOracle contract
        let win_prob_oracle = HoprWinningProbabilityOracle::deploy(
            provider.clone(),
            hopr_deployer_address,
            alloy::primitives::aliases::U56::from(0xFFFFFFFFFFFFFF_u64), /* 0xFFFFFFFFFFFFFF in hex or
                                                                          * 72057594037927935 in
                                                                          * decimal values */
        )
        .await?;

        // HoprNodeManagementModule contract
        let module_implementation = HoprNodeManagementModule::deploy(provider.clone()).await?;

        // HoprNodeSafeRegistry contract
        let safe_registry = HoprNodeSafeRegistry::deploy(provider.clone()).await?;

        // HoprChannels contract
        let channels = HoprChannels::deploy(
            provider.clone(),
            Address::from(token.address().as_ref()),
            1_u32,
            Address::from(safe_registry.address().as_ref()),
        )
        .await?;

        // HoprAnnouncements contract and proxy
        let announcements_implementation = HoprAnnouncements::deploy(provider.clone()).await?;
        let announcement_initialize_parameters = (
            *token.address(),
            *safe_registry.address(),
            INIT_KEY_BINDING_FEE,
            hopr_deployer_address,
        )
            .abi_encode();
        let encode_initialization = HoprAnnouncements::initializeCall {
            initParams: announcement_initialize_parameters.into(),
        }
        .abi_encode();
        let announcements_proxy = HoprAnnouncementsProxy::deploy(
            provider.clone(),
            Address::from(announcements_implementation.address().as_ref()),
            encode_initialization.into(),
        )
        .await?;

        // HoprNodeStakeFactory contract
        let stake_factory = HoprNodeStakeFactory::deploy(
            provider.clone(),
            Address::from(module_implementation.address().as_ref()),
            Address::from(announcements_proxy.address().as_ref()),
            hopr_deployer_address,
        )
        .await?;

        // HoprNodeSafeMigration contract
        let node_safe_migration = HoprNodeSafeMigration::deploy(
            provider.clone(),
            Address::from(module_implementation.address().as_ref()),
            Address::from(stake_factory.address().as_ref()),
        )
        .await?;

        // Mock xHOPR token contract
        let mock_xhopr_token = ERC677Mock::deploy(provider.clone()).await?;
        // - mint some tokens to the deployer for testing
        mock_xhopr_token
            .batchMintInternal(vec![hopr_deployer_address], MINTED_TOKEN_AMOUNT) // mint 1000 tokens to the deployer
            .send()
            .await?
            .watch()
            .await?;

        // get the defaultHoprNetwork from the stake factory
        let default_hopr_network = stake_factory.defaultHoprNetwork().call().await?;
        let new_default_hopr_network = HoprNodeStakeFactory::HoprNetwork {
            tokenAddress: *token.address(),
            defaultTokenAllowance: default_hopr_network.defaultTokenAllowance,
            defaultAnnouncementTarget: default_hopr_network.defaultAnnouncementTarget,
        };
        // Update the `defaultHoprNetwork` in the factory contract, to update the token address
        stake_factory
            .updateHoprNetwork(new_default_hopr_network)
            .send()
            .await?
            .watch()
            .await?;

        Ok(Self {
            token,
            channels,
            announcements: HoprAnnouncementsInstance::new(*announcements_proxy.address(), provider.clone()),
            safe_registry,
            price_oracle,
            win_prob_oracle,
            stake_factory,
            module_implementation,
            node_safe_migration,
            xhopr_token: mock_xhopr_token.into(),
        })
    }

    /// Deploys testing environment, including both pre-deploying common contracts and deploying Hopr contracts, via the
    /// given provider.
    pub async fn deploy_for_testing(
        provider: P,
        hopr_deployer_address: Address,
        common_deployer_address: Address,
    ) -> ContractResult<Self> {
        // use the common deployer wallet to pre-deploy common contracts
        Self::inner_deploy_common_contracts_for_testing(provider.clone(), common_deployer_address).await?;
        // use the hopr deployer wallet to deploy Hopr contracts
        let instances = Self::inner_deploy_hopr_contracts_for_testing(provider.clone(), hopr_deployer_address).await?;

        Ok(Self { ..instances })
    }

    pub fn get_contract_addresses(&self) -> ContractAddresses {
        ContractAddresses {
            token: *self.token.address(),
            channels: *self.channels.address(),
            announcements: *self.announcements.address(),
            node_safe_registry: *self.safe_registry.address(),
            ticket_price_oracle: *self.price_oracle.address(),
            winning_probability_oracle: *self.win_prob_oracle.address(),
            node_stake_factory: *self.stake_factory.address(),
            module_implementation: *self.module_implementation.address(),
            node_safe_migration: *self.node_safe_migration.address(),
            xhopr_token: *self.xhopr_token.address(),
        }
    }
}

impl<P> From<&ContractInstances<P>> for ContractAddresses
where
    P: alloy::providers::Provider + Clone,
{
    fn from(instances: &ContractInstances<P>) -> Self {
        Self {
            token: *instances.token.address(),
            channels: *instances.channels.address(),
            announcements: *instances.announcements.address(),
            node_safe_registry: *instances.safe_registry.address(),
            ticket_price_oracle: *instances.price_oracle.address(),
            winning_probability_oracle: *instances.win_prob_oracle.address(),
            node_safe_migration: *instances.node_safe_migration.address(),
            node_stake_factory: *instances.stake_factory.address(),
            module_implementation: *instances.module_implementation.address(),
            xhopr_token: *instances.xhopr_token.address(),
        }
    }
}

/// Creates and spawns an Anvil instance.
/// If `at_default_port` is true, the Anvil instance will be spawned at the default port 8545.
/// Otherwise, it will be spawned at a random available port.
pub fn create_anvil(mnemonic: Option<&str>, at_default_port: bool, use_default_chain_id: bool) -> AnvilInstance {
    let mut anvil = Anvil::new();

    if let Some(mnemonic) = mnemonic {
        anvil = anvil.mnemonic(mnemonic);
    }

    let random_port = {
        let listener =
            std::net::TcpListener::bind("127.0.0.1:0").unwrap_or_else(|_| panic!("Failed to bind localhost"));
        listener
            .local_addr()
            .unwrap_or_else(|_| panic!("Failed to get local address"))
            .port()
    };

    if at_default_port {
        anvil = anvil.port(8545u16);
    } else {
        anvil = anvil.port(random_port);
    }

    if !use_default_chain_id {
        anvil = anvil.chain_id(random_port.into());
    }

    anvil.spawn()
}

pub fn create_provider(
    anvil: &AnvilInstance,
    hopr_deployer_signing_key: &[u8],
    common_deployer_signing_key: &[u8],
) -> Result<
    impl alloy::providers::Provider + Clone + alloy::providers::WalletProvider<Wallet = EthereumWallet>,
    crate::error::Error,
> {
    let common_deployer_signer = PrivateKeySigner::from_slice(common_deployer_signing_key)?;
    let hopr_deployer_signer = PrivateKeySigner::from_slice(hopr_deployer_signing_key)?;

    let mut wallet = EthereumWallet::from(common_deployer_signer);
    wallet.register_default_signer(hopr_deployer_signer);

    Ok(ProviderBuilder::new().wallet(wallet).connect_http(anvil.endpoint_url()))
}

#[cfg(test)]
mod tests {
    use tracing::{debug, info};

    use super::{ContractInstances, NetworksWithContractAddresses};
    use crate::config::{create_anvil, create_provider};

    #[test]
    fn networks_with_contract_addresses_are_default_constructible() {
        let contract_addresses: NetworksWithContractAddresses = Default::default();

        assert!(!contract_addresses.networks.is_empty());
    }

    #[tokio::test]
    async fn deploy_for_testing_deploys_all_contracts() -> anyhow::Result<()> {
        let anvil = create_anvil(None, false, true);
        let hopr_deployer_private_key = anvil.keys()[0].to_bytes();
        let common_deployer_private_key = anvil.keys()[1].to_bytes();
        let hopr_deployer_address = anvil.addresses()[0];
        let common_deployer_address = anvil.addresses()[1];

        let provider = create_provider(
            &anvil,
            hopr_deployer_private_key.as_ref(),
            common_deployer_private_key.as_ref(),
        )?;

        debug!("Anvil rpc url: {}", anvil.endpoint_url());
        debug!("Deployer addresses:");
        debug!("  hopr_deployer_address:      {}", hopr_deployer_address);
        debug!("  common_deployer_address:    {}", common_deployer_address);

        let instances = ContractInstances::deploy_for_testing(provider, hopr_deployer_address, common_deployer_address)
            .await
            .expect("deployment should succeed");

        let addresses = instances.get_contract_addresses();

        info!("Deployed contract addresses:");
        info!("  token:                      {}", addresses.token);
        info!("  channels:                   {}", addresses.channels);
        info!("  announcements:              {}", addresses.announcements);
        info!("  node_safe_registry:         {}", addresses.node_safe_registry);
        info!("  ticket_price_oracle:        {}", addresses.ticket_price_oracle);
        info!("  winning_probability_oracle: {}", addresses.winning_probability_oracle);
        info!("  node_stake_factory:         {}", addresses.node_stake_factory);
        info!("  module_implementation:      {}", addresses.module_implementation);
        info!("  node_safe_migration:        {}", addresses.node_safe_migration);
        info!("  xhopr_token:                {}", addresses.xhopr_token);

        // Check that the addresses are the same as the ones in the contracts-addresses.json file
        let expected_addresses = NetworksWithContractAddresses::default().networks["anvil-localhost"].addresses;
        assert_eq!(
            addresses, expected_addresses,
            "contract addresses should match the ones in contracts-addresses.json"
        );

        // Check the token balance of the hopr_deployer_address
        let wxhopr_token_balance = instances.token.balanceOf(hopr_deployer_address).call().await?;
        assert_eq!(
            wxhopr_token_balance,
            crate::constants::MINTED_TOKEN_AMOUNT,
            "hopr_deployer_address should have the expected wxHOPRtoken balance"
        );
        let xhopr_token_balance = instances.xhopr_token.balanceOf(hopr_deployer_address).call().await?;
        assert_eq!(
            xhopr_token_balance,
            crate::constants::MINTED_TOKEN_AMOUNT,
            "hopr_deployer_address should have the expected xHOPR token balance"
        );

        Ok(())
    }
}
