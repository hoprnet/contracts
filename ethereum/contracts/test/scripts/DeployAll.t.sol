// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Test } from "forge-std/Test.sol";

import { DeployAllContractsScript } from "../../script/DeployAll.s.sol";
import { ERC1820RegistryFixtureTest } from "../utils/ERC1820Registry.sol";
import { SafeSingletonFixtureTest } from "../utils/SafeSingleton.sol";

contract DeployAllTest is Test, ERC1820RegistryFixtureTest, SafeSingletonFixtureTest {
    DeployAllContractsScript public deployScriptContract;

    function setUp() public override(ERC1820RegistryFixtureTest, SafeSingletonFixtureTest) {
        // invoke super.setup() for ERC1820RegistryFixtureTest, SafeSingletonFixtureTest separately
        ERC1820RegistryFixtureTest.setUp();
        SafeSingletonFixtureTest.setUp();
    }

    function test_Run() public {
        deployScriptContract = new DeployAllContractsScript();
        vm.setEnv("FOUNDRY_PROFILE", "local");
        vm.setEnv("NETWORK", "anvil-localhost");
        vm.setEnv("UNIT_TEST_SKIP_WRITE", "true");
        deployScriptContract.run();

        (DeployAllContractsScript.Addresses memory networkAddress, , ,) = deployScriptContract.currentNetworkDetail();

        emit log_string(string("Deployed contracts:"));
        emit log_named_address("tokenContractAddress", networkAddress.tokenContractAddress);
        emit log_named_address("ticketPriceOracleContractAddress", networkAddress.ticketPriceOracleContractAddress);
        emit log_named_address("winningProbabilityContractAddress", networkAddress.winningProbabilityContractAddress);
        emit log_named_address("moduleImplementationAddress", networkAddress.moduleImplementationAddress);
        emit log_named_address("nodeSafeRegistryAddress", networkAddress.nodeSafeRegistryAddress);
        emit log_named_address("channelsContractAddress", networkAddress.channelsContractAddress);
        emit log_named_address("Announcements", networkAddress.announcements);
        emit log_named_address("nodeStakeFactoryAddress", networkAddress.nodeStakeFactoryAddress);
        emit log_named_address("nodeSafeMigrationAddress", networkAddress.nodeSafeMigrationAddress);
        emit log_named_address("xHOPR token contract address", networkAddress.xhoprTokenContractAddress);
    }

}
