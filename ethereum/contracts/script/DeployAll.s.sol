// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;
pragma abicoder v2;

import { Script } from "forge-std/Script.sol";

import { ERC1820RegistryFixtureTest } from "../test/utils/ERC1820Registry.sol";
import { SafeSingletonFixtureTest } from "../test/utils/SafeSingleton.sol";
import { PermittableTokenFixtureTest } from "../test/utils/PermittableToken.sol";
import { NetworkConfig } from "./utils/NetworkConfig.s.sol";
import { BoostUtilsLib } from "./utils/BoostUtilsLib.sol";
import { WinProb } from "../src/WinningProbabilityOracle.sol";

/**
 * @title Deploy all the required contracts in development, staging and production environment
 * @notice In local development environment, ERC1820Registry, Safe deployment singleton, Safe suites should be deployed
 * before running this script.
 * @dev It reads the environment, netork and deployer internal key from env variables
 */
contract DeployAllContractsScript is
    Script,
    NetworkConfig,
    ERC1820RegistryFixtureTest,
    SafeSingletonFixtureTest,
    PermittableTokenFixtureTest
{
    using BoostUtilsLib for address;
    // starting key binding fee at deployment time
    uint256 public constant DEV_INIT_KEY_BINDING_FEE = 10_000_000 gwei; // 0.01 HOPR in gwei unit
    uint256 public constant STAGING_INIT_KEY_BINDING_FEE = 1 ether; // 1 HOPR in gwei unit
    uint256 public constant MINTED_TOKEN_AMOUNT = 1000 ether; // 1000 HOPR
    // ticket price oracle
    uint256 public constant LOCAL_TICKET_PRICE = 10_000_000 gwei; // 0.001 HOPR in gwei unit
    uint256 public constant DEV_TICKET_PRICE = 100; // 0.0000000000000001 HOPR in gwei unit
    uint256 public constant STAGING_TICKET_PRICE = 10_000 gwei; // 0.00001 HOPR in gwei unit
    // winnning probability
    uint56 public constant LOCAL_WINNING_PROBABILITY = 72_057_594_037_927_935; // 0.0005 in WinProb unit
    uint56 public constant DEV_WINNING_PROBABILITY = 9_007_199_254_735; // 0.00012500 in WinProb unit
    uint56 public constant STAGING_WINNING_PROBABILITY = 288_230_376_143; // 0.000004 in WinProb unit
    // service registry
    // The delay of DefaultAdminRules guards the admin role transfer only. A units mistake here is
    // near-permanent, because a lower delay must itself wait out the old delay.
    uint48 public constant INIT_ADMIN_DELAY = 2 days;
    uint256 public constant LOCAL_TYPE_REGISTRATION_FEE = 1 ether;
    uint256 public constant DEV_TYPE_REGISTRATION_FEE = 1 ether;
    uint256 public constant STAGING_TYPE_REGISTRATION_FEE = 100 ether;
    // the canonical GnosisVPN exit type, claimed at launch (section 9.4)
    bytes32 public constant GVPN_EXIT_SERVICE_TYPE = bytes32("gvpn:exit");
    uint256 public constant GVPN_EXIT_REGISTRATION_BURN = 1000 ether;
    uint256 public constant GVPN_EXIT_UPDATE_BURN = 100 ether;

    bool internal isHoprChannelsDeployed;
    bool internal isHoprNetworkRegistryDeployed;
    address private owner;

    function setUp() public override(ERC1820RegistryFixtureTest, SafeSingletonFixtureTest) {
        ERC1820RegistryFixtureTest.setUp();
        SafeSingletonFixtureTest.setUp();
    }

    function run() external {
        emit log_named_address("callerAddress", msg.sender);
        // 1. Network check
        // get environment of the script
        getNetwork();
        // read records of deployed files
        readCurrentNetwork();
        // Halt if ERC1820Registry has not been deployed.
        mustHaveErc1820Registry();
        emit log_string(string(abi.encodePacked("Deploying in ", currentNetworkId)));
        // get owner of network registry (and its proxy) depending on the network
        if (keccak256(abi.encodePacked(currentNetworkId)) == keccak256(abi.encodePacked("stake_hub_test"))) {
            owner = PRODUCT_MULTISIG_ADDRESS;
        } else {
            owner = COMM_MULTISIG_ADDRESS;
        }
        // deploy safe suites if needed
        deployEntireSafeSuite();
        // check if deployed contracts need to be written in the filesystem
        bool skipWrite = vm.envBool("UNIT_TEST_SKIP_WRITE");

        // 2. Get deployer internal key.
        // Set to default when it's in development environment (uint for
        // 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        uint256 deployerPrivateKey = currentEnvironmentType == EnvironmentType.LOCAL
            ? 77_814_517_325_470_205_911_140_941_194_401_928_579_557_062_014_761_831_930_645_393_041_380_819_009_408
            : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        emit log_named_address("deployerAddress", deployerAddress);
        vm.startBroadcast(deployerPrivateKey);

        // 3. Deploy
        // 3.1. HoprToken Contract
        // Only deploy Token contract when no deployed one is detected.
        // E.g. always in local environment, or should a new token contract be introduced in
        // development/staging/production.
        _deployHoprTokenAndMintToAddress(deployerAddress, deployerAddress);

        // 3.2. TicketPriceOracle
        _deployHoprTicketPriceOracle(deployerAddress);

        // 3.3. WinningProbabilityOracle
        _deployHoprWinningProbabilityOracle(deployerAddress);

        // 3.4 HoprNodeManagementModule singleton
        _deployHoprNodeManagementModule();

        // 3.5 HoprNodeSafeRegistry
        _deployHoprNodeSafeRegistry();

        // 3.6. HoprChannels Contract
        // Only deploy Channels contract when no deployed one is detected.
        // E.g. always in local environment, or should a new channel contract be introduced in
        // development/staging/production per meta environment.
        _deployHoprChannels();

        // 3.7. Announcements
        _deployHoprAnnouncements(deployerAddress);

        // 3.8 HoprNodeStakeFactory
        _deployHoprNodeStakeFactory(deployerAddress);

        // 3.9. NodeSafeMigration contract
        _deployNodeSafeMigration();

        // 3.10. Deploy a mock xHOPR token contract and mint some tokens to the deployer. This is only for local development environment.
        _deployXHoprTokenAndMintToAddress(deployerAddress);

        // 3.11. HoprServiceRegistry
        // CAUTION: This deployment must stay last. Addresses come from the nonce of the deployer,
        // so a new deployment in an earlier position moves every later anvil-localhost address.
        // Those addresses are mirrored in contracts-addresses.json, in bindings/src/config.rs and
        // in the anvil configuration of blokli-client.
        _deployHoprServiceRegistry(deployerAddress);

        // 4. update indexerStartBlockNumber
        // if both HoprChannels and HoprNetworkRegistry contracts are deployed, update the startup block number for
        // indexer
        if (isHoprChannelsDeployed && isHoprNetworkRegistryDeployed) {
            currentNetworkDetail.indexerStartBlockNumber = block.number;
        }

        // broadcast transaction bundle
        vm.stopBroadcast();

        // write to file
        if (!skipWrite) {
            writeCurrentNetwork();
        }
    }

    /**
     * @dev Deploy node management module
     */
    function _deployHoprNodeManagementModule() internal {
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.moduleImplementationAddress)
        ) {
            // deploy HoprNodeManagementModule contractsd
            currentNetworkDetail.addresses.moduleImplementationAddress =
                deployCode("NodeManagementModule.sol:HoprNodeManagementModule");
        }
    }

    /**
     * @dev deploy node safe factory
     */
    function _deployHoprNodeStakeFactory(address deployerAddress) internal {
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.nodeStakeFactoryAddress)
        ) {
            // deploy HoprNodeStakeFactory contract
            currentNetworkDetail.addresses.nodeStakeFactoryAddress = deployCode(
                "NodeStakeFactory.sol:HoprNodeStakeFactory",
                abi.encode(
                    currentNetworkDetail.addresses.moduleImplementationAddress,
                    currentNetworkDetail.addresses.announcements,
                    deployerAddress
                )
            );
        }
    }

    /**
     * @dev Deploy node safe registry
     */
    function _deployHoprNodeSafeRegistry() internal {
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.nodeSafeRegistryAddress)
        ) {
            // deploy HoprNodeManagementModule contract
            currentNetworkDetail.addresses.nodeSafeRegistryAddress =
                deployCode("NodeSafeRegistry.sol:HoprNodeSafeRegistry");
        }
    }

    /**
     * @dev Deploy hopr token. Set a minter and mint some token to the deployer
     */
    function _deployHoprTokenAndMintToAddress(address deployerAddress, address recipient) internal {
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.tokenContractAddress)
        ) {
            // deploy token contract
            currentNetworkDetail.addresses.tokenContractAddress = deployCode("HoprToken.sol");
            // grant deployer minter role
            (bool successGrantMinterRole,) = currentNetworkDetail.addresses.tokenContractAddress
                .call(abi.encodeWithSignature("grantRole(bytes32,address)", MINTER_ROLE, deployerAddress));
            if (!successGrantMinterRole) {
                emit log_string("Cannot grantMinterRole");
            }
            // mint some tokens to the deployer
            (bool successMintTokens,) = currentNetworkDetail.addresses.tokenContractAddress
                .call(
                    abi.encodeWithSignature(
                        "mint(address,uint256,bytes,bytes)", recipient, MINTED_TOKEN_AMOUNT, hex"00", hex"00"
                    )
                );
            if (!successMintTokens) {
                emit log_string("Cannot mint tokens");
            }
        }
    }

    /**
     * @dev Deploy HoprChannels smart contract and registers NodeSafeRegistry
     */
    function _deployHoprChannels() internal {
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.channelsContractAddress)
        ) {
            // deploy channels contract
            // set closure time to 15 seconds if running in local Anvil, otherwise 5 minutes
            uint256 noticePeriodChannelClosure = currentEnvironmentType == EnvironmentType.LOCAL ? 15 : 5 * 60;
            currentNetworkDetail.addresses.channelsContractAddress = deployCode(
                "Channels.sol:HoprChannels",
                abi.encode(
                    currentNetworkDetail.addresses.tokenContractAddress,
                    noticePeriodChannelClosure,
                    currentNetworkDetail.addresses.nodeSafeRegistryAddress
                )
            );
            isHoprChannelsDeployed = true;
        }
    }

    /**
     * @dev deploy ticket price oracle
     */
    function _deployHoprTicketPriceOracle(address deployerAddress) internal {
        // 0.001 HOPR in local environment; 0.0000000000000001 HOPR in dev; 0.00001 HOPR in staging
        uint256 price;
        if (currentEnvironmentType == EnvironmentType.LOCAL) {
            price = LOCAL_TICKET_PRICE;
        } else if (currentEnvironmentType == EnvironmentType.STAGING) {
            price = STAGING_TICKET_PRICE;
        } else {
            price = DEV_TICKET_PRICE;
        }
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.ticketPriceOracleContractAddress)
        ) {
            // deploy contract
            currentNetworkDetail.addresses.ticketPriceOracleContractAddress =
                deployCode("TicketPriceOracle.sol:HoprTicketPriceOracle", abi.encode(deployerAddress, price));
        }
    }

    /**
     * @dev deploy winning probability oracle
     */
    function _deployHoprWinningProbabilityOracle(address deployerAddress) internal {
        WinProb winProb;
        if (currentEnvironmentType == EnvironmentType.LOCAL) {
            winProb = WinProb.wrap(LOCAL_WINNING_PROBABILITY);
        } else if (currentEnvironmentType == EnvironmentType.STAGING) {
            winProb = WinProb.wrap(STAGING_WINNING_PROBABILITY);
        } else {
            winProb = WinProb.wrap(DEV_WINNING_PROBABILITY);
        }

        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.winningProbabilityContractAddress)
        ) {
            // deploy contract
            currentNetworkDetail.addresses.winningProbabilityContractAddress = deployCode(
                "WinningProbabilityOracle.sol:HoprWinningProbabilityOracle", abi.encode(deployerAddress, winProb)
            );
        }
    }

    /**
     * @dev deploy Announcments smart contract and register NodeSafeRegistry
     */
    function _deployHoprAnnouncements(address deployerAddress) internal {
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.announcements)
        ) {
            uint256 keyBindingFee;
            if (currentEnvironmentType == EnvironmentType.STAGING) {
                keyBindingFee = STAGING_INIT_KEY_BINDING_FEE;
            } else {
                keyBindingFee = DEV_INIT_KEY_BINDING_FEE;
            }
            // deploy HoprAnnouncements contract and register with current NodeSafeRegistry
            address announcementImplementation = deployCode("Announcements.sol:HoprAnnouncements");

            currentNetworkDetail.addresses.announcements = deployCode(
                "Announcements.sol:HoprAnnouncementsProxy",
                abi.encode(
                    announcementImplementation,
                    abi.encodeWithSignature(
                        "initialize(bytes)",
                        abi.encode(
                            currentNetworkDetail.addresses.tokenContractAddress,
                            currentNetworkDetail.addresses.nodeSafeRegistryAddress,
                            keyBindingFee,
                            deployerAddress
                        )
                    )
                )
            );
        }
    }

    /**
     * @dev deploy NodeSafeMigration contract
     */
    function _deployNodeSafeMigration() internal {
        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.nodeSafeMigrationAddress)
        ) {
            // deploy HoprNodeSafeMigration contract
            currentNetworkDetail.addresses.nodeSafeMigrationAddress = deployCode(
                "NodeSafeMigration.sol:HoprNodeSafeMigration",
                abi.encode(
                    currentNetworkDetail.addresses.moduleImplementationAddress,
                    currentNetworkDetail.addresses.nodeStakeFactoryAddress
                )
            );
        }
    }

    /**
     * @dev deploy xHOPR token contract
     * @notice this is only for local development environment, and it will mint some xHOPR tokens to the recipient
     * @param recipient address to receive the minted xHOPR tokens
     */
    function _deployXHoprTokenAndMintToAddress(address recipient) internal {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;

        if (
            currentEnvironmentType == EnvironmentType.LOCAL
                || !isValidAddress(currentNetworkDetail.addresses.xhoprTokenContractAddress)
        ) {
            // deploy contract
            currentNetworkDetail.addresses.xhoprTokenContractAddress = deployCode("ERC677Mock.sol:ERC677Mock");
            // mint some tokens to the recipient
            (bool successMint,) = currentNetworkDetail.addresses.xhoprTokenContractAddress
                .call(abi.encodeWithSignature("batchMintInternal(address[],uint256)", recipients, MINTED_TOKEN_AMOUNT));
            if (!successMint) {
                emit log_string("Cannot mint xHOPR tokens to the recipient");
            }
        }
    }

    /**
     * @dev Deploy the service registry, and claim the canonical `gvpn:exit` type in LOCAL.
     *
     * The admin and the manager are the deployer in LOCAL, and the multisig owner otherwise. The
     * type-registration fee is the only economic barrier against type-table growth, so it is
     * non-zero in every environment. Section 9.3 makes the sizing of that fee a manager duty.
     *
     * Type ids go to the first payer, so a canonical id must be claimed before the address of the
     * registry is announced. This function claims `gvpn:exit` in LOCAL only, where the deployer
     * already holds minted wxHOPR. Every other environment claims it through `SingleAction.s.sol`,
     * as a transaction of the owning Safe.
     *
     * @param deployerAddress the account that broadcasts this batch
     */
    function _deployHoprServiceRegistry(address deployerAddress) internal {
        if (
            currentEnvironmentType != EnvironmentType.LOCAL
                && isValidAddress(currentNetworkDetail.addresses.serviceRegistryAddress)
        ) {
            return;
        }

        uint256 typeRegistrationFee;
        if (currentEnvironmentType == EnvironmentType.LOCAL) {
            typeRegistrationFee = LOCAL_TYPE_REGISTRATION_FEE;
        } else if (currentEnvironmentType == EnvironmentType.STAGING) {
            typeRegistrationFee = STAGING_TYPE_REGISTRATION_FEE;
        } else {
            typeRegistrationFee = DEV_TYPE_REGISTRATION_FEE;
        }

        address initialAdmin = currentEnvironmentType == EnvironmentType.LOCAL ? deployerAddress : owner;

        currentNetworkDetail.addresses.serviceRegistryAddress = deployCode(
            "ServiceRegistry.sol:HoprServiceRegistry",
            abi.encode(
                currentNetworkDetail.addresses.tokenContractAddress,
                currentNetworkDetail.addresses.nodeSafeRegistryAddress,
                INIT_ADMIN_DELAY,
                initialAdmin,
                initialAdmin,
                typeRegistrationFee
            )
        );

        if (currentEnvironmentType == EnvironmentType.LOCAL) {
            _claimGvpnExitServiceType(typeRegistrationFee);
        }
    }

    /**
     * @dev Claim the `gvpn:exit` type with the deployer account. LOCAL only.
     *
     * The approval is exactly the fee. Section 3.6 makes that exact allowance the price protection
     * of the caller: a fee that rises at the same time reverts on the allowance instead of an
     * overpayment.
     *
     * A claim that cannot be made reverts the whole batch. `forge script` simulates before it
     * broadcasts, so a revert here broadcasts nothing and leaves `contracts-addresses.json`
     * untouched. Logging the failure and continuing would instead publish the address of a registry
     * whose canonical id is still free, which is the squatting exposure of section 11.
     *
     * @param typeRegistrationFee the fee that the registry burns for this claim
     */
    function _claimGvpnExitServiceType(uint256 typeRegistrationFee) internal {
        (bool successApprove,) = currentNetworkDetail.addresses.tokenContractAddress
            .call(
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    currentNetworkDetail.addresses.serviceRegistryAddress,
                    typeRegistrationFee
                )
            );
        require(successApprove, "Cannot approve the type registration fee");

        (bool successRegister,) = currentNetworkDetail.addresses.serviceRegistryAddress
            .call(
                abi.encodeWithSignature(
                    "registerServiceType(bytes32,address,uint256,uint256)",
                    GVPN_EXIT_SERVICE_TYPE,
                    address(0),
                    GVPN_EXIT_REGISTRATION_BURN,
                    GVPN_EXIT_UPDATE_BURN
                )
            );
        require(successRegister, "Cannot claim the gvpn:exit service type");
    }

    /**
     * @dev helper function to
     * - grant manager role to manager addresses
     * - grant default admin role to the new owner
     * - renounce default admin role from the current caller
     * @param contractAddress address that has access control
     * @param caller caller address
     * @param newOwner new owner of the contract
     */
    function _helperSwapOwnerGrantManager(address contractAddress, address caller, address newOwner) internal {
        // grant default admin role to the actual owner
        (bool successGrantDefaultAdminRole,) =
            contractAddress.call(abi.encodeWithSignature("grantRole(bytes32,address)", DEFAULT_ADMIN_ROLE, newOwner));
        if (!successGrantDefaultAdminRole) {
            emit log_string("Cannot grant DEFAULT_ADMIN_ROLE role on ");
        }
        // grant manager roles to more accounts
        for (uint256 i = 0; i < PRODUCT_TEAM_MANAGER_ADDRESSES.length; i++) {
            (bool successGrantManagerRole,) = contractAddress.call(
                abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER_ROLE, PRODUCT_TEAM_MANAGER_ADDRESSES[i])
            );
            if (!successGrantManagerRole) {
                emit log_string("Cannot grant MANAGER_ROLE role on ");
            }
        }
        if (!successGrantDefaultAdminRole) {
            emit log_string("Cannot grant MANAGER_ROLE role on ");
        }
        // renounce the default admin role
        (bool successRenounceDefaultAdminRole,) =
            contractAddress.call(abi.encodeWithSignature("renounceRole(bytes32,address)", DEFAULT_ADMIN_ROLE, caller));
        if (!successRenounceDefaultAdminRole) {
            emit log_string("Cannot renounce DEFAULT_ADMIN_ROLE role on ");
        }
    }
}
