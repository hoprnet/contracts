// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Test } from "forge-std/Test.sol";

import { DeployAllContractsScript } from "../../script/DeployAll.s.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";
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

        (DeployAllContractsScript.Addresses memory networkAddress,,,) = deployScriptContract.currentNetworkDetail();

        emit log_string("Deployed contracts:");
        emit log_named_address("tokenContractAddress", networkAddress.tokenContractAddress);
        emit log_named_address("ticketPriceOracleContractAddress", networkAddress.ticketPriceOracleContractAddress);
        emit log_named_address("winningProbabilityContractAddress", networkAddress.winningProbabilityContractAddress);
        emit log_named_address("moduleImplementationAddress", networkAddress.moduleImplementationAddress);
        emit log_named_address("nodeSafeRegistryAddress", networkAddress.nodeSafeRegistryAddress);
        emit log_named_address("channelsContractAddress", networkAddress.channelsContractAddress);
        emit log_named_address("announcements", networkAddress.announcements);
        emit log_named_address("nodeStakeFactoryAddress", networkAddress.nodeStakeFactoryAddress);
        emit log_named_address("nodeSafeMigrationAddress", networkAddress.nodeSafeMigrationAddress);
        emit log_named_address("xHOPR token contract address", networkAddress.xhoprTokenContractAddress);
        emit log_named_address("serviceRegistryAddress", networkAddress.serviceRegistryAddress);

        assertTrue(deployScriptContract.isValidAddress(networkAddress.serviceRegistryAddress), "registry deployed");
        _assertServiceRegistryIsConfigured(networkAddress);
    }

    /**
     * @dev The registry must be live and must already own the canonical `gvpn:exit` type.
     *
     * Type ids go to the first payer, so the deployment batch claims the canonical id in LOCAL.
     * Section 9.4 covers the same claim for every other environment.
     */
    function _assertServiceRegistryIsConfigured(DeployAllContractsScript.Addresses memory networkAddress)
        internal
        view
    {
        HoprServiceRegistry registry = HoprServiceRegistry(networkAddress.serviceRegistryAddress);
        bytes32 gvpnExit = bytes32("gvpn:exit");

        assertEq(address(registry.WXHOPR_TOKEN()), networkAddress.tokenContractAddress, "registry token");
        assertEq(
            address(registry.nodeSafeRegistry()), networkAddress.nodeSafeRegistryAddress, "registry node safe registry"
        );
        assertEq(registry.typeRegistrationFee(), 1 ether, "local type registration fee");
        assertEq(registry.defaultAdminDelay(), 2 days, "admin delay");

        assertTrue(registry.isServiceType(gvpnExit), "the gvpn:exit type must be claimed at deployment");
        assertEq(registry.selfRegistrationBurn(gvpnExit), 1000 ether, "gvpn:exit registration burn");
        assertEq(registry.selfUpdateBurn(gvpnExit), 100 ether, "gvpn:exit update burn");
        assertEq(address(registry.requirements(gvpnExit)), address(0), "gvpn:exit starts open");
    }
}

/**
 * @dev Points the internal claim at the given token and registry, without running the deployment.
 *
 * `_claimGvpnExitServiceType` reads exactly these two addresses plus three constants, so the claim
 * can be exercised against mocks. Mocking during a full `run()` is not an option, because in LOCAL
 * both contracts are created inside `run()` itself.
 */
contract GvpnExitClaimHarness is DeployAllContractsScript {
    function claimGvpnExitServiceType(address token, address registry, uint256 typeRegistrationFee) external {
        currentNetworkDetail.addresses.tokenContractAddress = token;
        currentNetworkDetail.addresses.serviceRegistryAddress = registry;
        _claimGvpnExitServiceType(typeRegistrationFee, 1000 ether, 100 ether);
    }
}

contract ApprovingTokenMock {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract RevertingTokenMock {
    function approve(address, uint256) external pure returns (bool) {
        revert("token transfers are paused");
    }
}

contract RevertingRegistryMock {
    error ServiceTypeExists(bytes32 serviceType);

    function registerServiceType(bytes32 serviceType, address, uint256, uint256) external pure {
        revert ServiceTypeExists(serviceType);
    }
}

/**
 * @dev A claim that cannot be made must stop the deployment.
 *
 * Type ids go to the first payer, so a batch that logs the failure and continues reaches
 * `writeCurrentNetwork()` and publishes a registry address whose canonical id is still free. That
 * is the squatting exposure of section 11.
 */
contract DeployAllGvpnExitClaimTest is Test {
    GvpnExitClaimHarness internal harness;

    function setUp() public {
        harness = new GvpnExitClaimHarness();
    }

    function testRevert_claimGvpnExitServiceTypeDueToFailedApproval() public {
        address token = address(new RevertingTokenMock());
        address registry = address(new RevertingRegistryMock());

        vm.expectRevert("Cannot approve the type registration fee");
        harness.claimGvpnExitServiceType(token, registry, 1 ether);
    }

    function testRevert_claimGvpnExitServiceTypeDueToFailedRegistration() public {
        address token = address(new ApprovingTokenMock());
        address registry = address(new RevertingRegistryMock());

        vm.expectRevert("Cannot claim the gvpn:exit service type");
        harness.claimGvpnExitServiceType(token, registry, 1 ether);
    }
}
