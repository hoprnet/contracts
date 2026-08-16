// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";
import {
    ConfigurableRequirement,
    DenyAllRequirement,
    DenyMetadataRequirement,
    DenyRegisterRequirement,
    MalformedNodeSafeRegistry,
    PermissiveRequirement,
    RevertingNodeSafeRegistry
} from "../mocks/ServiceRegistryMocks.sol";

/**
 * @dev Section 5.2, the self-service entry path. This is the only entry write path.
 *
 * It also covers invariant I6, that a bound node can always delist itself, and the rule of section
 * 5 that an external staticcall has no try/catch.
 */
contract HoprServiceRegistrySelfServiceTest is ServiceRegistryFixtureTest {
    ConfigurableRequirement internal requirement;

    function setUp() public virtual override {
        super.setUp();
        requirement = new ConfigurableRequirement(true, true);
    }

    // ---------------------------------------------------------------------------------------
    // selfRegister - the success path
    // ---------------------------------------------------------------------------------------

    function test_selfRegisterStoresTheEntry() public {
        _registerDefaultType();

        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"c0ffee");

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"c0ffee", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
        assertEq(registry.nodeCount(SERVICE_TYPE_GVPN), 1, "node count");
        assertEq(registry.nodeAt(SERVICE_TYPE_GVPN, 0), nodeA, "node enumeration");
    }

    /// @dev Section 3.2. Registration sets `updatedAt` to `registeredAt`.
    function test_selfRegisterSetsUpdatedAtToRegisteredAt() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        HoprServiceRegistry.Entry memory entry = registry.getEntry(SERVICE_TYPE_GVPN, nodeA);
        assertEq(entry.registeredAt, entry.updatedAt, "registration must set updatedAt to registeredAt");
    }

    function test_selfRegisterEmitsRegistered() public {
        _registerDefaultType();

        vm.expectEmit(true, true, true, true, address(registry));
        emit Registered(SERVICE_TYPE_GVPN, nodeA, safeA, hex"01", uint48(FIXED_TIMESTAMP), REGISTRATION_BURN);
        vm.prank(safeA);
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function test_selfRegisterAcceptsEmptyMetadata() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, "");

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, "", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    function test_selfRegisterAcceptsMetadataAtTheExactCap() public {
        _registerDefaultType();
        bytes memory metadata = _metadataOfLength(registry.MAX_METADATA_LENGTH());
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, metadata);

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, metadata, uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    /// @dev One node can hold an entry under several types.
    function test_selfRegisterAllowsOneNodeUnderSeveralTypes() public {
        _registerDefaultType();
        _registerType(typeOwner, SERVICE_TYPE_ALT, IServiceRequirement(address(0)), 0, 0);

        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");
        _registerEntry(safeA, SERVICE_TYPE_ALT, nodeA, hex"02");

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"01", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
        _assertEntry(SERVICE_TYPE_ALT, nodeA, hex"02", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    // ---------------------------------------------------------------------------------------
    // selfRegister - the check order of section 5.2
    // ---------------------------------------------------------------------------------------

    function testRevert_selfRegisterDueToUnknownServiceType() public {
        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.UnknownServiceType.selector, SERVICE_TYPE_GVPN));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfRegisterDueToAlreadyRegistered() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.AlreadyRegistered.selector, SERVICE_TYPE_GVPN, nodeA)
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"02");
    }

    function testRevert_selfRegisterDueToCallerNotNodeSafe() public {
        _registerDefaultType();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, stranger, safeA));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    /// @dev An unbound node has a bound Safe of zero. The check has no escape hatch for zero.
    function testRevert_selfRegisterDueToCallerNotNodeSafeForAnUnboundNode() public {
        _registerDefaultType();

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, unboundNode, safeA, address(0))
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, unboundNode, hex"01");
    }

    /// @dev A zero node address needs no separate test, because zero can never be bound.
    function testRevert_selfRegisterDueToCallerNotNodeSafeForAZeroNode() public {
        _registerDefaultType();

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, address(0), safeA, address(0))
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, address(0), hex"01");
    }

    function testRevert_selfRegisterDueToMetadataTooLong() public {
        _registerDefaultType();
        uint256 cap = registry.MAX_METADATA_LENGTH();
        bytes memory metadata = _metadataOfLength(cap + 1);

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.MetadataTooLong.selector, cap + 1, cap));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, metadata);
    }

    function testRevert_selfRegisterDueToRegistrationDenied() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, new DenyRegisterRequirement(), 0, 0);

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.RegistrationDenied.selector, SERVICE_TYPE_GVPN, safeA, nodeA)
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfRegisterDueToMetadataRejected() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, new DenyMetadataRequirement(), 0, 0);

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.MetadataRejected.selector, SERVICE_TYPE_GVPN, nodeA));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    // ---------------------------------------------------------------------------------------
    // selfRegister - error precedence
    // ---------------------------------------------------------------------------------------

    /**
     * @dev `requireNodeSafe` is a modifier, so it runs before the function body reaches step 1.
     * A caller that is not the bound Safe never learns whether the type exists.
     */
    function test_callerNotNodeSafeBeatsUnknownServiceType() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, stranger, safeA));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    /**
     * @dev `requireNodeSafe` is a modifier, so it runs before the function body reaches step 2.
     * An existing entry never surfaces as `AlreadyRegistered` to a caller that is not the bound
     * Safe; that caller sees `CallerNotNodeSafe` instead.
     */
    function test_callerNotNodeSafeBeatsAlreadyRegistered() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, stranger, safeA));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"02");
    }

    /// @dev Step 3 beats step 4.
    function test_callerNotNodeSafeBeatsMetadataTooLong() public {
        _registerDefaultType();
        bytes memory metadata = _metadataOfLength(registry.MAX_METADATA_LENGTH() + 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, stranger, safeA));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, metadata);
    }

    /// @dev Step 4 beats step 5a. The length cap runs before the policy.
    function test_metadataTooLongBeatsRegistrationDenied() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, new DenyAllRequirement(), 0, 0);
        uint256 cap = registry.MAX_METADATA_LENGTH();
        bytes memory metadata = _metadataOfLength(cap + 1);

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.MetadataTooLong.selector, cap + 1, cap));
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, metadata);
    }

    /// @dev Step 5a beats step 5b. Eligibility runs before the metadata policy.
    function test_registrationDeniedBeatsMetadataRejected() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, new DenyAllRequirement(), 0, 0);

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.RegistrationDenied.selector, SERVICE_TYPE_GVPN, safeA, nodeA)
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    // ---------------------------------------------------------------------------------------
    // selfUpdate
    // ---------------------------------------------------------------------------------------

    function test_selfUpdateReplacesMetadataAndKeepsRegisteredAt() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.warp(FIXED_TIMESTAMP + 1000);
        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"0203");

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"0203", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP + 1000));
    }

    function test_selfUpdateEmitsUpdated() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.expectEmit(true, true, true, true, address(registry));
        emit Updated(SERVICE_TYPE_GVPN, nodeA, safeA, hex"02", uint48(FIXED_TIMESTAMP), UPDATE_BURN);
        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");
    }

    /**
     * @dev An unknown type gives `NotRegistered`, and never `UnknownServiceType`.
     *
     * Section 5.2 step 1 tests the entry, not the type. Invariant I1 makes this sufficient: an
     * entry can only exist under a registered type.
     */
    function testRevert_selfUpdateDueToNotRegisteredOnAnUnknownType() public {
        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.NotRegistered.selector, SERVICE_TYPE_GVPN, nodeA));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfUpdateDueToNotRegisteredOnAKnownType() public {
        _registerDefaultType();

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.NotRegistered.selector, SERVICE_TYPE_GVPN, nodeA));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfUpdateDueToCallerNotNodeSafe() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, stranger, safeA));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");
    }

    function testRevert_selfUpdateDueToMetadataTooLong() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");
        uint256 cap = registry.MAX_METADATA_LENGTH();

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.MetadataTooLong.selector, cap + 1, cap));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, _metadataOfLength(cap + 1));
    }

    function testRevert_selfUpdateDueToMetadataRejected() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");
        requirement.setValidateMetadataResult(false);

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.MetadataRejected.selector, SERVICE_TYPE_GVPN, nodeA));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");
    }

    /// @dev Section 5.2 step 4. `selfUpdate` never calls `canRegister`.
    function test_selfUpdateNeverCallsCanRegister() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        // a mode that reverts would surface if `canRegister` were called
        requirement.setCanRegisterMode(ConfigurableRequirement.Mode.Revert);

        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"02", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    // ---------------------------------------------------------------------------------------
    // selfDeregister
    // ---------------------------------------------------------------------------------------

    function test_selfDeregisterRemovesTheEntry() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.expectEmit(true, true, true, true, address(registry));
        emit Deregistered(SERVICE_TYPE_GVPN, nodeA, safeA);
        vm.prank(safeA);
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);

        _assertNoEntry(SERVICE_TYPE_GVPN, nodeA);
        assertEq(registry.nodeCount(SERVICE_TYPE_GVPN), 0, "node count must fall to zero");
    }

    function testRevert_selfDeregisterDueToNotRegistered() public {
        _registerDefaultType();

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.NotRegistered.selector, SERVICE_TYPE_GVPN, nodeA));
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
    }

    function testRevert_selfDeregisterDueToCallerNotNodeSafe() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, stranger, safeA));
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
    }

    /**
     * @dev Precedence: `requireNodeSafe` is a modifier, so the binding test runs before the
     * function body ever reaches the entry test.
     */
    function test_callerNotNodeSafeBeatsNotRegisteredOnDeregister() public {
        _registerDefaultType();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, stranger, safeA));
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
    }

    /**
     * @dev Invariant I6. A bound node can always delist itself.
     *
     * `poorSafe` holds no wxHOPR and gives the registry no allowance. The type carries a deny-all
     * requirement and a non-zero update burn. The deregistration must still succeed.
     */
    function test_selfDeregisterWorksUnderADenyAllRequirementWithNoTokens() public {
        address poorSafe = vm.addr(98_800);
        address poorNode = vm.addr(98_801);
        _bind(poorNode, poorSafe);

        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        _registerEntry(poorSafe, SERVICE_TYPE_GVPN, poorNode, hex"01");

        vm.startPrank(typeOwner);
        registry.setRequirement(SERVICE_TYPE_GVPN, new DenyAllRequirement());
        registry.setSelfUpdateBurn(SERVICE_TYPE_GVPN, 1000 ether);
        registry.setSelfRegistrationBurn(SERVICE_TYPE_GVPN, 1000 ether);
        vm.stopPrank();

        assertEq(hoprToken.balanceOf(poorSafe), 0, "the safe must hold no tokens");
        assertEq(hoprToken.allowance(poorSafe, address(registry)), 0, "the safe must give no allowance");

        vm.prank(poorSafe);
        registry.selfDeregister(SERVICE_TYPE_GVPN, poorNode);

        _assertNoEntry(SERVICE_TYPE_GVPN, poorNode);
    }

    // ---------------------------------------------------------------------------------------
    // Entry lifetime
    // ---------------------------------------------------------------------------------------

    /// @dev A re-registration after a deregistration starts a fresh lifetime.
    function test_reRegistrationAfterDeregistrationGetsAFreshRegisteredAt() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.warp(FIXED_TIMESTAMP + 500);
        vm.prank(safeA);
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);

        vm.warp(FIXED_TIMESTAMP + 900);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"02");

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"02", uint48(FIXED_TIMESTAMP + 900), uint48(FIXED_TIMESTAMP + 900));
    }

    /**
     * @dev Section 3.3. A Safe rotation carries the registry authority with it.
     *
     * The registry reads the binding on every call, so no rotation ceremony exists.
     */
    function test_safeRotationCarriesAuthority() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        _bind(nodeA, safeB);

        // the old Safe lost authority at once
        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, safeA, safeB));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");

        // the new Safe holds it
        vm.prank(safeB);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"03");
        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"03", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    /**
     * @dev Section 3.3. A lost binding does not invalidate an entry, and it makes the entry
     * permanent. This is invariant I9 from the side of the operator.
     */
    function test_aLostBindingLeavesTheEntryInPlaceAndPermanent() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        _bind(nodeA, address(0));

        assertTrue(registry.isRegistered(SERVICE_TYPE_GVPN, nodeA), "the entry stays discoverable");

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, safeA, address(0))
        );
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
    }

    // ---------------------------------------------------------------------------------------
    // Argument forwarding to the requirement
    // ---------------------------------------------------------------------------------------

    function test_selfRegisterForwardsExactArgumentsToTheRequirement() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        bytes memory metadata = hex"aabbcc";

        vm.expectCall(
            address(requirement), abi.encodeCall(IServiceRequirement.canRegister, (SERVICE_TYPE_GVPN, safeA, nodeA))
        );
        vm.expectCall(
            address(requirement),
            abi.encodeCall(IServiceRequirement.validateMetadata, (SERVICE_TYPE_GVPN, nodeA, metadata))
        );

        vm.prank(safeA);
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, metadata);
    }

    function test_selfUpdateForwardsExactArgumentsToTheRequirement() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");
        bytes memory metadata = hex"ddeeff";

        vm.expectCall(
            address(requirement),
            abi.encodeCall(IServiceRequirement.validateMetadata, (SERVICE_TYPE_GVPN, nodeA, metadata))
        );

        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, metadata);
    }

    /// @dev The echo mode returns the arguments through the revert data of the requirement.
    function test_canRegisterReceivesTheCallerAndTheNode() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        requirement.setCanRegisterMode(ConfigurableRequirement.Mode.EchoArgs);

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(ConfigurableRequirement.CanRegisterArgs.selector, SERVICE_TYPE_GVPN, safeA, nodeA)
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    /// @dev `validateMetadata` never sees the caller, so its echo carries the node and the metadata.
    function test_validateMetadataReceivesTheNodeAndTheMetadata() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        requirement.setValidateMetadataMode(ConfigurableRequirement.Mode.EchoArgs);

        vm.prank(safeA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigurableRequirement.ValidateMetadataArgs.selector, SERVICE_TYPE_GVPN, nodeA, hex"beef"
            )
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"beef");
    }

    // ---------------------------------------------------------------------------------------
    // Raw error propagation - section 5 forbids try/catch
    // ---------------------------------------------------------------------------------------

    function testRevert_selfRegisterDueToARevertingRequirement() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        requirement.setCanRegisterMode(ConfigurableRequirement.Mode.Revert);

        vm.prank(safeA);
        vm.expectRevert(ConfigurableRequirement.RequirementIsDown.selector);
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfUpdateDueToARevertingRequirement() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");
        requirement.setValidateMetadataMode(ConfigurableRequirement.Mode.Revert);

        vm.prank(safeA);
        vm.expectRevert(ConfigurableRequirement.RequirementIsDown.selector);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");
    }

    /// @dev A requirement that answers with 4 bytes fails the ABI decoder of the registry.
    function testRevert_selfRegisterDueToAMalformedRequirement() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, requirement, 0, 0);
        requirement.setCanRegisterMode(ConfigurableRequirement.Mode.ReturnMalformed);

        vm.prank(safeA);
        vm.expectRevert();
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfRegisterDueToARevertingNodeSafeRegistry() public {
        _registerDefaultType();
        vm.etch(address(nodeSafeRegistry), address(new RevertingNodeSafeRegistry()).code);

        vm.prank(safeA);
        vm.expectRevert(RevertingNodeSafeRegistry.NodeSafeRegistryIsDown.selector);
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfRegisterDueToAMalformedNodeSafeRegistry() public {
        _registerDefaultType();
        vm.etch(address(nodeSafeRegistry), address(new MalformedNodeSafeRegistry()).code);

        vm.prank(safeA);
        vm.expectRevert();
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, hex"01");
    }

    function testRevert_selfDeregisterDueToARevertingNodeSafeRegistry() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");
        vm.etch(address(nodeSafeRegistry), address(new RevertingNodeSafeRegistry()).code);

        vm.prank(safeA);
        vm.expectRevert(RevertingNodeSafeRegistry.NodeSafeRegistryIsDown.selector);
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
    }
}
