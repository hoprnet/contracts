// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Vm } from "forge-std/Vm.sol";
import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry, INodeSafeRegistry, IWxHoprToken } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";
import { MockNodeSafeRegistry } from "../mocks/ServiceRegistryMocks.sol";
import { IAccessControl } from "openzeppelin-contracts-5.4.0/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "openzeppelin-contracts-5.4.0/access/extensions/IAccessControlDefaultAdminRules.sol";
import { IERC20 } from "openzeppelin-contracts-5.4.0/token/ERC20/IERC20.sol";

/**
 * @dev Section 5.3 and section 3.8, the constructor and the two privileged roles.
 *
 * It also covers invariant I9: the bound Safe of a node is the only party that can ever change an
 * entry. An attacker that holds both roles must still fail on every entry function.
 */
contract HoprServiceRegistryAccessTest is ServiceRegistryFixtureTest {
    bytes32 internal constant REGISTRY_INITIALIZED_TOPIC =
        keccak256("RegistryInitialized(uint256,address,address,address,uint48)");
    bytes32 internal constant NODE_SAFE_REGISTRY_UPDATED_TOPIC = keccak256("NodeSafeRegistryUpdated(address,address)");
    bytes32 internal constant TYPE_REGISTRATION_FEE_UPDATED_TOPIC = keccak256("TypeRegistrationFeeUpdated(uint256)");

    /**
     * @dev The two role ids, read once.
     *
     * A getter on the registry is an external call, and `vm.prank` applies to the next external
     * call only. An inline `registry.MANAGER_ROLE()` inside a pranked call therefore consumes the
     * prank, and the call under test runs as the test contract.
     */
    bytes32 internal adminRole;
    bytes32 internal managerRole;

    function setUp() public virtual override {
        super.setUp();
        adminRole = registry.DEFAULT_ADMIN_ROLE();
        managerRole = registry.MANAGER_ROLE();
    }

    // ---------------------------------------------------------------------------------------
    // Constructor - the valid case
    // ---------------------------------------------------------------------------------------

    function test_constructorStoresTheConfiguration() public view {
        assertEq(address(registry.wxHopr()), address(hoprToken), "wxHopr");
        assertEq(address(registry.nodeSafeRegistry()), address(nodeSafeRegistry), "nodeSafeRegistry");
        assertEq(registry.typeRegistrationFee(), TYPE_FEE, "typeRegistrationFee");
        assertEq(registry.VERSION(), 1, "VERSION");
        assertEq(registry.MAX_METADATA_LENGTH(), 2048, "MAX_METADATA_LENGTH");
        assertEq(managerRole, keccak256("MANAGER_ROLE"), "MANAGER_ROLE");
    }

    function test_constructorAssignsBothRoles() public view {
        assertTrue(registry.hasRole(adminRole, admin), "admin must hold the admin role");
        assertTrue(registry.hasRole(managerRole, manager), "manager must hold the manager role");
        assertEq(registry.defaultAdmin(), admin, "defaultAdmin");
        assertEq(registry.defaultAdminDelay(), ADMIN_DELAY, "defaultAdminDelay");
    }

    /// @dev Section 5.3. The three events make the deployment reconstructible from logs alone.
    function test_constructorEmitsThreeEventsInOrder() public {
        MockNodeSafeRegistry freshRegistry = new MockNodeSafeRegistry();

        vm.recordLogs();
        HoprServiceRegistry fresh = new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)),
            INodeSafeRegistry(address(freshRegistry)),
            ADMIN_DELAY,
            admin,
            manager,
            TYPE_FEE
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 initializedAt = _indexOfLog(logs, address(fresh), REGISTRY_INITIALIZED_TOPIC);
        uint256 pointerAt = _indexOfLog(logs, address(fresh), NODE_SAFE_REGISTRY_UPDATED_TOPIC);
        uint256 feeAt = _indexOfLog(logs, address(fresh), TYPE_REGISTRATION_FEE_UPDATED_TOPIC);

        assertTrue(initializedAt < pointerAt, "RegistryInitialized must come first");
        assertTrue(pointerAt < feeAt, "NodeSafeRegistryUpdated must come second");

        (uint256 version, address emittedAdmin, address emittedManager, address emittedToken, uint48 emittedDelay) =
            abi.decode(logs[initializedAt].data, (uint256, address, address, address, uint48));
        assertEq(version, 1, "version in RegistryInitialized");
        assertEq(emittedAdmin, admin, "admin in RegistryInitialized");
        assertEq(emittedManager, manager, "manager in RegistryInitialized");
        assertEq(emittedToken, address(hoprToken), "token in RegistryInitialized");
        assertEq(emittedDelay, ADMIN_DELAY, "delay in RegistryInitialized");

        (address oldPointer, address newPointer) = abi.decode(logs[pointerAt].data, (address, address));
        assertEq(oldPointer, address(0), "the constructor must report a zero old pointer");
        assertEq(newPointer, address(freshRegistry), "the constructor must report the new pointer");

        assertEq(abi.decode(logs[feeAt].data, (uint256)), TYPE_FEE, "fee in TypeRegistrationFeeUpdated");
    }

    function test_constructorAcceptsTheMaximumAdminDelay() public {
        HoprServiceRegistry fresh = new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)),
            INodeSafeRegistry(address(nodeSafeRegistry)),
            MAX_ADMIN_DELAY,
            admin,
            manager,
            0
        );
        assertEq(fresh.defaultAdminDelay(), MAX_ADMIN_DELAY, "30 days must be accepted");
    }

    // ---------------------------------------------------------------------------------------
    // Constructor - the rejection matrix
    // ---------------------------------------------------------------------------------------

    function testRevert_constructorDueToWxHoprTokenNotContractOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.WxHoprTokenNotContract.selector, address(0)));
        new HoprServiceRegistry(
            IWxHoprToken(address(0)),
            INodeSafeRegistry(address(nodeSafeRegistry)),
            ADMIN_DELAY,
            admin,
            manager,
            TYPE_FEE
        );
    }

    function testRevert_constructorDueToWxHoprTokenNotContractOnAnEoa() public {
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.WxHoprTokenNotContract.selector, stranger));
        new HoprServiceRegistry(
            IWxHoprToken(stranger), INodeSafeRegistry(address(nodeSafeRegistry)), ADMIN_DELAY, admin, manager, TYPE_FEE
        );
    }

    function testRevert_constructorDueToNodeSafeRegistryNotContractOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.NodeSafeRegistryNotContract.selector, address(0)));
        new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)), INodeSafeRegistry(address(0)), ADMIN_DELAY, admin, manager, TYPE_FEE
        );
    }

    function testRevert_constructorDueToNodeSafeRegistryNotContractOnAnEoa() public {
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.NodeSafeRegistryNotContract.selector, stranger));
        new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)), INodeSafeRegistry(stranger), ADMIN_DELAY, admin, manager, TYPE_FEE
        );
    }

    function testRevert_constructorDueToZeroManager() public {
        vm.expectRevert(HoprServiceRegistry.ZeroManager.selector);
        new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)),
            INodeSafeRegistry(address(nodeSafeRegistry)),
            ADMIN_DELAY,
            admin,
            address(0),
            TYPE_FEE
        );
    }

    function testRevert_constructorDueToInvalidAdminDelayOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.InvalidAdminDelay.selector, 0, MAX_ADMIN_DELAY));
        new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)), INodeSafeRegistry(address(nodeSafeRegistry)), 0, admin, manager, TYPE_FEE
        );
    }

    /// @dev A units mistake is the reason this bound exists. 30 days in milliseconds is far past it.
    function testRevert_constructorDueToInvalidAdminDelayAboveTheBound() public {
        uint48 tooLong = MAX_ADMIN_DELAY + 1;
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.InvalidAdminDelay.selector, tooLong, MAX_ADMIN_DELAY)
        );
        new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)),
            INodeSafeRegistry(address(nodeSafeRegistry)),
            tooLong,
            admin,
            manager,
            TYPE_FEE
        );
    }

    /// @dev The OpenZeppelin base rejects a zero admin, so the registry declares no error for it.
    function testRevert_constructorDueToZeroAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new HoprServiceRegistry(
            IWxHoprToken(address(hoprToken)),
            INodeSafeRegistry(address(nodeSafeRegistry)),
            ADMIN_DELAY,
            address(0),
            manager,
            TYPE_FEE
        );
    }

    /// @dev The base constructor runs before this body, so its error wins over every local check.
    function test_zeroAdminBeatsEveryConstructorCheckOfTheRegistry() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new HoprServiceRegistry(IWxHoprToken(address(0)), INodeSafeRegistry(address(0)), 0, address(0), address(0), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Section 3.8 - DefaultAdminRules
    // ---------------------------------------------------------------------------------------

    /// @dev OpenZeppelin 5.x excludes the admin role from `grantRole`.
    function testRevert_grantRoleDueToEnforcedDefaultAdminRules() public {
        vm.prank(admin);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        registry.grantRole(adminRole, stranger);
    }

    function testRevert_revokeRoleDueToEnforcedDefaultAdminRules() public {
        vm.prank(admin);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        registry.revokeRole(adminRole, admin);
    }

    /// @dev The admin role moves only through the two-step transfer, and only after the delay.
    function test_defaultAdminTransferIsTwoStepAndDelayed() public {
        vm.prank(admin);
        registry.beginDefaultAdminTransfer(stranger);

        (address pending, uint48 schedule) = registry.pendingDefaultAdmin();
        assertEq(pending, stranger, "pending admin");
        assertEq(schedule, uint48(FIXED_TIMESTAMP) + ADMIN_DELAY, "accept schedule");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        registry.acceptDefaultAdminTransfer();

        // OpenZeppelin treats the schedule as passed only once the timestamp is strictly past it
        vm.warp(schedule + 1);
        vm.prank(stranger);
        registry.acceptDefaultAdminTransfer();

        assertEq(registry.defaultAdmin(), stranger, "the new admin must hold the role");
        assertFalse(registry.hasRole(adminRole, admin), "the old admin must lose the role");
    }

    /// @dev The delay applies to the admin transfer only. Every other change is immediate.
    function test_theAdminDelayDoesNotDelayAnythingElse() public {
        vm.prank(manager);
        registry.setTypeRegistrationFee(1 ether);
        assertEq(registry.typeRegistrationFee(), 1 ether, "a fee change is immediate");
    }

    function test_adminGrantsAndRevokesTheManagerRole() public {
        vm.prank(admin);
        registry.grantRole(managerRole, stranger);
        assertTrue(registry.hasRole(managerRole, stranger), "manager role granted");

        vm.prank(admin);
        registry.revokeRole(managerRole, stranger);
        assertFalse(registry.hasRole(managerRole, stranger), "manager role revoked");
    }

    // ---------------------------------------------------------------------------------------
    // setTypeRegistrationFee
    // ---------------------------------------------------------------------------------------

    function test_setTypeRegistrationFeeStoresAndEmits() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit TypeRegistrationFeeUpdated(123 ether);
        vm.prank(manager);
        registry.setTypeRegistrationFee(123 ether);

        assertEq(registry.typeRegistrationFee(), 123 ether, "fee must be stored");
    }

    function test_setTypeRegistrationFeeAppliesToLaterRegistrationsOnly() public {
        vm.prank(manager);
        registry.setTypeRegistrationFee(0);

        uint256 supplyBefore = hoprToken.totalSupply();
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        assertEq(hoprToken.totalSupply(), supplyBefore, "a zero fee must burn nothing");
    }

    function testRevert_setTypeRegistrationFeeDueToMissingManagerRole() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, managerRole)
        );
        registry.setTypeRegistrationFee(1);
    }

    // ---------------------------------------------------------------------------------------
    // setNodeSafeRegistry
    // ---------------------------------------------------------------------------------------

    function test_setNodeSafeRegistrySwapsThePointerAndEmits() public {
        MockNodeSafeRegistry target = new MockNodeSafeRegistry();
        target.setBinding(nodeA, safeA);

        vm.expectEmit(true, true, true, true, address(registry));
        emit NodeSafeRegistryUpdated(address(nodeSafeRegistry), address(target));
        vm.prank(admin);
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), nodeA, safeA);

        assertEq(address(registry.nodeSafeRegistry()), address(target), "pointer must be swapped");
    }

    /// @dev The swap touches no entry data, and swapping back restores authority.
    function test_setNodeSafeRegistryIsReversibleAndTouchesNoEntry() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        MockNodeSafeRegistry target = new MockNodeSafeRegistry();
        target.setBinding(nodeA, safeB);

        vm.prank(admin);
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), nodeA, safeB);
        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"01", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));

        // authority now follows the new instance
        vm.prank(safeB);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");

        vm.prank(admin);
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(nodeSafeRegistry)), nodeA, safeA);
        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"03");
        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"03", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    function testRevert_setNodeSafeRegistryDueToNotContractOnZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.NodeSafeRegistryNotContract.selector, address(0)));
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(0)), nodeA, safeA);
    }

    function testRevert_setNodeSafeRegistryDueToNotContractOnAnEoa() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.NodeSafeRegistryNotContract.selector, stranger));
        registry.setNodeSafeRegistry(INodeSafeRegistry(stranger), nodeA, safeA);
    }

    /// @dev Probe failure shape 1: the expected Safe is zero and the probe answers zero.
    function testRevert_setNodeSafeRegistryDueToProbeFailedOnZeroExpectedAndZeroActual() public {
        MockNodeSafeRegistry target = new MockNodeSafeRegistry();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                HoprServiceRegistry.NodeSafeRegistryProbeFailed.selector, address(target), nodeA, address(0), address(0)
            )
        );
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), nodeA, address(0));
    }

    /// @dev Probe failure shape 2: the expected Safe is zero while the probe answers a real Safe.
    function testRevert_setNodeSafeRegistryDueToProbeFailedOnZeroExpected() public {
        MockNodeSafeRegistry target = new MockNodeSafeRegistry();
        target.setBinding(nodeA, safeA);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                HoprServiceRegistry.NodeSafeRegistryProbeFailed.selector, address(target), nodeA, address(0), safeA
            )
        );
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), nodeA, address(0));
    }

    /// @dev Probe failure shape 3: the probe node is unbound in the new target.
    function testRevert_setNodeSafeRegistryDueToProbeFailedOnAnUnboundProbeNode() public {
        MockNodeSafeRegistry target = new MockNodeSafeRegistry();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                HoprServiceRegistry.NodeSafeRegistryProbeFailed.selector, address(target), nodeA, safeA, address(0)
            )
        );
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), nodeA, safeA);
    }

    /// @dev Probe failure shape 4: the probe answers a Safe that is not the expected one.
    function testRevert_setNodeSafeRegistryDueToProbeFailedOnAMismatch() public {
        MockNodeSafeRegistry target = new MockNodeSafeRegistry();
        target.setBinding(nodeA, safeB);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                HoprServiceRegistry.NodeSafeRegistryProbeFailed.selector, address(target), nodeA, safeA, safeB
            )
        );
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), nodeA, safeA);
    }

    function testRevert_setNodeSafeRegistryDueToMissingAdminRole() public {
        MockNodeSafeRegistry target = new MockNodeSafeRegistry();
        target.setBinding(nodeA, safeA);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, adminRole)
        );
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), nodeA, safeA);
    }

    // ---------------------------------------------------------------------------------------
    // recoverTokens
    // ---------------------------------------------------------------------------------------

    function test_recoverTokensMovesTheFullBalanceAndEmits() public {
        vm.prank(safeA);
        hoprToken.transfer(address(registry), 5 ether);
        assertEq(hoprToken.balanceOf(address(registry)), 5 ether, "the stray transfer must land");

        vm.expectEmit(true, true, true, true, address(registry));
        emit TokensRecovered(address(hoprToken), stranger, 5 ether);
        vm.prank(admin);
        registry.recoverTokens(IERC20(address(hoprToken)), stranger);

        _assertNoTokensAtRest();
        assertEq(hoprToken.balanceOf(stranger), FUNDING + 5 ether, "the recipient must receive the full balance");
    }

    function test_recoverTokensOnAZeroBalanceIsANoOp() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit TokensRecovered(address(hoprToken), stranger, 0);
        vm.prank(admin);
        registry.recoverTokens(IERC20(address(hoprToken)), stranger);

        assertEq(hoprToken.balanceOf(stranger), FUNDING, "no balance must move");
    }

    function testRevert_recoverTokensDueToZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(HoprServiceRegistry.ZeroRecipient.selector);
        registry.recoverTokens(IERC20(address(hoprToken)), address(0));
    }

    function testRevert_recoverTokensDueToMissingAdminRole() public {
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, adminRole)
        );
        registry.recoverTokens(IERC20(address(hoprToken)), stranger);
    }

    /// @dev Section 5.3. The registry has no receive function, so native xDAI cannot arrive.
    function testRevert_aPlainValueTransferToTheRegistry() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool success,) = address(registry).call{ value: 1 ether }("");
        assertFalse(success, "the registry must reject native value");
    }

    // ---------------------------------------------------------------------------------------
    // Invariant I9 - the negative matrix
    // ---------------------------------------------------------------------------------------

    /**
     * @dev An attacker that holds the admin role and the manager role still cannot touch an entry.
     *
     * The attacker takes the admin role through the two-step transfer, then grants itself the
     * manager role. Every entry function still fails on the binding.
     */
    function test_anAttackerWithBothRolesCannotMutateAnEntry() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        address attacker = vm.addr(98_900);

        vm.prank(admin);
        registry.beginDefaultAdminTransfer(attacker);
        vm.warp(FIXED_TIMESTAMP + ADMIN_DELAY + 1);
        vm.prank(attacker);
        registry.acceptDefaultAdminTransfer();
        vm.prank(attacker);
        registry.grantRole(managerRole, attacker);

        assertTrue(registry.hasRole(adminRole, attacker), "attacker holds the admin role");
        assertTrue(registry.hasRole(managerRole, attacker), "attacker holds the manager role");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, attacker, safeA));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"ff");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, attacker, safeA));
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.AlreadyRegistered.selector, SERVICE_TYPE_GVPN, nodeA)
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"ff");

        // the type is not theirs either
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.NotTypeOwner.selector, SERVICE_TYPE_GVPN, attacker, typeOwner)
        );
        registry.setRequirement(SERVICE_TYPE_GVPN, IServiceRequirement(address(0)));

        // the powers the attacker does hold cannot reach entries
        vm.prank(attacker);
        registry.setTypeRegistrationFee(999 ether);
        vm.prank(attacker);
        registry.recoverTokens(IERC20(address(hoprToken)), attacker);

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"01", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    /**
     * @dev Section 3.4 and section 11. The pointer is the one admin power that reaches entries.
     *
     * This test records that escalation on purpose, so a future change that removes it is visible.
     */
    function test_thePointerIsTheOnlyAdminPowerThatCanReachEntries() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        MockNodeSafeRegistry hostile = new MockNodeSafeRegistry();
        hostile.setBinding(nodeA, stranger);

        vm.prank(admin);
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(hostile)), nodeA, stranger);

        vm.prank(stranger);
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
        _assertNoEntry(SERVICE_TYPE_GVPN, nodeA);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @dev The index of the first log of `emitter` whose first topic is `topic0`.
    function _indexOfLog(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return i;
            }
        }
        revert("expected log not found");
    }
}
