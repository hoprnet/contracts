// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";
import {
    ConfigurableRequirement,
    DenyRegisterRequirement,
    PermissiveRequirement
} from "../mocks/ServiceRegistryMocks.sol";

/**
 * @dev Section 5.1, the type lifecycle. It also covers invariant I2, that types are permanent, and
 * invariant I10, that only the current owner governs a type.
 */
contract HoprServiceRegistryTypeLifecycleTest is ServiceRegistryFixtureTest {
    PermissiveRequirement internal permissive;
    DenyRegisterRequirement internal denyRegister;

    function setUp() public virtual override {
        super.setUp();
        permissive = new PermissiveRequirement();
        denyRegister = new DenyRegisterRequirement();
    }

    // ---------------------------------------------------------------------------------------
    // registerServiceType
    // ---------------------------------------------------------------------------------------

    function test_registerServiceTypeStoresTheFullConfiguration() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, permissive, REGISTRATION_BURN, UPDATE_BURN);

        assertTrue(registry.isServiceType(SERVICE_TYPE_GVPN), "type must exist");
        assertEq(registry.typeOwner(SERVICE_TYPE_GVPN), typeOwner, "registrant must own the type");
        assertEq(address(registry.requirements(SERVICE_TYPE_GVPN)), address(permissive), "requirement must be stored");
        assertEq(registry.selfRegistrationBurn(SERVICE_TYPE_GVPN), REGISTRATION_BURN, "registration burn");
        assertEq(registry.selfUpdateBurn(SERVICE_TYPE_GVPN), UPDATE_BURN, "update burn");
        assertEq(registry.typeCount(), 1, "type count");
        assertEq(registry.typeAt(0), SERVICE_TYPE_GVPN, "type enumeration");
    }

    /// @dev Section 5.1 step 4 fixes the order of these five events. Indexers replay them by position.
    function test_registerServiceTypeEmitsFiveEventsInOrder() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit ServiceTypeRegistered(SERVICE_TYPE_GVPN, typeOwner, TYPE_FEE);
        vm.expectEmit(true, true, true, true, address(registry));
        emit TypeOwnershipTransferred(SERVICE_TYPE_GVPN, address(0), typeOwner);
        vm.expectEmit(true, true, true, true, address(registry));
        emit RequirementUpdated(SERVICE_TYPE_GVPN, address(permissive));
        vm.expectEmit(true, true, true, true, address(registry));
        emit SelfRegistrationBurnUpdated(SERVICE_TYPE_GVPN, REGISTRATION_BURN);
        vm.expectEmit(true, true, true, true, address(registry));
        emit SelfUpdateBurnUpdated(SERVICE_TYPE_GVPN, UPDATE_BURN);

        vm.prank(typeOwner);
        registry.registerServiceType(SERVICE_TYPE_GVPN, permissive, REGISTRATION_BURN, UPDATE_BURN);
    }

    function test_registerServiceTypeBurnsTheGlobalFee() public {
        uint256 supplyBefore = hoprToken.totalSupply();
        uint256 balanceBefore = hoprToken.balanceOf(typeOwner);

        _registerType(typeOwner, SERVICE_TYPE_GVPN, permissive, REGISTRATION_BURN, UPDATE_BURN);

        _assertBurned(typeOwner, supplyBefore, balanceBefore, type(uint256).max, TYPE_FEE);
        _assertVictimUntouched();
    }

    function test_registerServiceTypeAcceptsAZeroRequirement() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        assertEq(address(registry.requirements(SERVICE_TYPE_GVPN)), address(0), "zero requirement means an open type");
        assertTrue(registry.isServiceType(SERVICE_TYPE_GVPN), "an open type is still a registered type");
    }

    /// @dev Anyone can register a type. No role gates this path.
    function test_registerServiceTypeIsPermissionless() public {
        _registerType(stranger, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        assertEq(registry.typeOwner(SERVICE_TYPE_GVPN), stranger, "a stranger can own a type");
    }

    /// @dev Invariant I2. The type count never decreases, because no function removes a type.
    function test_typesArePermanent() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        assertEq(registry.typeCount(), 1, "one type");

        _registerType(stranger, SERVICE_TYPE_ALT, IServiceRequirement(address(0)), 0, 0);
        assertEq(registry.typeCount(), 2, "two types");

        // abandonment does not remove the type
        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, address(0));
        assertEq(registry.typeCount(), 2, "abandonment must not remove a type");
        assertTrue(registry.isServiceType(SERVICE_TYPE_GVPN), "an abandoned type still exists");
    }

    function testRevert_registerServiceTypeDueToZeroServiceType() public {
        vm.prank(typeOwner);
        vm.expectRevert(HoprServiceRegistry.ZeroServiceType.selector);
        registry.registerServiceType(bytes32(0), IServiceRequirement(address(0)), 0, 0);
    }

    function testRevert_registerServiceTypeDueToServiceTypeExists() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.ServiceTypeExists.selector, SERVICE_TYPE_GVPN));
        registry.registerServiceType(SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
    }

    function testRevert_registerServiceTypeDueToRequirementNotContract() public {
        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.RequirementNotContract.selector, stranger));
        registry.registerServiceType(SERVICE_TYPE_GVPN, IServiceRequirement(stranger), 0, 0);
    }

    /**
     * @dev Precedence, section 5.1 step 1 before step 3.
     *
     * Note: the pair of `ZeroServiceType` and `ServiceTypeExists` cannot be constructed. A zero id
     * is rejected at step 1, so a zero id can never reach the type set and can never exist.
     */
    function test_zeroServiceTypeBeatsRequirementNotContract() public {
        vm.prank(typeOwner);
        vm.expectRevert(HoprServiceRegistry.ZeroServiceType.selector);
        registry.registerServiceType(bytes32(0), IServiceRequirement(stranger), 0, 0);
    }

    /// @dev Precedence, section 5.1 step 2 before step 3.
    function test_serviceTypeExistsBeatsRequirementNotContract() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.ServiceTypeExists.selector, SERVICE_TYPE_GVPN));
        registry.registerServiceType(SERVICE_TYPE_GVPN, IServiceRequirement(stranger), 0, 0);
    }

    // ---------------------------------------------------------------------------------------
    // Type owner functions - the shared prefix
    // ---------------------------------------------------------------------------------------

    function testRevert_setRequirementDueToUnknownServiceType() public {
        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.UnknownServiceType.selector, SERVICE_TYPE_GVPN));
        registry.setRequirement(SERVICE_TYPE_GVPN, permissive);
    }

    function testRevert_setSelfRegistrationBurnDueToUnknownServiceType() public {
        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.UnknownServiceType.selector, SERVICE_TYPE_GVPN));
        registry.setSelfRegistrationBurn(SERVICE_TYPE_GVPN, 1);
    }

    function testRevert_setSelfUpdateBurnDueToUnknownServiceType() public {
        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.UnknownServiceType.selector, SERVICE_TYPE_GVPN));
        registry.setSelfUpdateBurn(SERVICE_TYPE_GVPN, 1);
    }

    function testRevert_transferTypeOwnershipDueToUnknownServiceType() public {
        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.UnknownServiceType.selector, SERVICE_TYPE_GVPN));
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, stranger);
    }

    /// @dev `NotTypeOwner` carries the type, the caller and the current owner.
    function testRevert_setRequirementDueToNotTypeOwner() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.NotTypeOwner.selector, SERVICE_TYPE_GVPN, stranger, typeOwner)
        );
        registry.setRequirement(SERVICE_TYPE_GVPN, permissive);
    }

    /// @dev Precedence: the type existence test runs before the ownership test.
    function test_unknownServiceTypeBeatsNotTypeOwner() public {
        // `stranger` is not the owner of `SERVICE_TYPE_ALT`, and that type does not exist either.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.UnknownServiceType.selector, SERVICE_TYPE_ALT));
        registry.setRequirement(SERVICE_TYPE_ALT, permissive);
    }

    // ---------------------------------------------------------------------------------------
    // Type owner functions - the individual bodies
    // ---------------------------------------------------------------------------------------

    function test_setRequirementStoresAndEmits() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.expectEmit(true, true, true, true, address(registry));
        emit RequirementUpdated(SERVICE_TYPE_GVPN, address(permissive));
        vm.prank(typeOwner);
        registry.setRequirement(SERVICE_TYPE_GVPN, permissive);

        assertEq(address(registry.requirements(SERVICE_TYPE_GVPN)), address(permissive), "requirement must be stored");
    }

    function test_setRequirementAcceptsZeroToReopenAType() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, permissive, 0, 0);

        vm.prank(typeOwner);
        registry.setRequirement(SERVICE_TYPE_GVPN, IServiceRequirement(address(0)));

        assertEq(address(registry.requirements(SERVICE_TYPE_GVPN)), address(0), "requirement must be cleared");
    }

    function testRevert_setRequirementDueToRequirementNotContract() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.RequirementNotContract.selector, stranger));
        registry.setRequirement(SERVICE_TYPE_GVPN, IServiceRequirement(stranger));
    }

    function test_setSelfRegistrationBurnStoresAndEmits() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.expectEmit(true, true, true, true, address(registry));
        emit SelfRegistrationBurnUpdated(SERVICE_TYPE_GVPN, 7 ether);
        vm.prank(typeOwner);
        registry.setSelfRegistrationBurn(SERVICE_TYPE_GVPN, 7 ether);

        assertEq(registry.selfRegistrationBurn(SERVICE_TYPE_GVPN), 7 ether, "registration burn must be stored");
    }

    function test_setSelfUpdateBurnStoresAndEmits() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.expectEmit(true, true, true, true, address(registry));
        emit SelfUpdateBurnUpdated(SERVICE_TYPE_GVPN, 3 ether);
        vm.prank(typeOwner);
        registry.setSelfUpdateBurn(SERVICE_TYPE_GVPN, 3 ether);

        assertEq(registry.selfUpdateBurn(SERVICE_TYPE_GVPN), 3 ether, "update burn must be stored");
    }

    function test_transferTypeOwnershipStoresAndEmits() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.expectEmit(true, true, true, true, address(registry));
        emit TypeOwnershipTransferred(SERVICE_TYPE_GVPN, typeOwner, stranger);
        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, stranger);

        assertEq(registry.typeOwner(SERVICE_TYPE_GVPN), stranger, "new owner must be stored");
    }

    /// @dev Invariant I10. The old owner loses every power at the moment of the transfer.
    function test_transferTypeOwnershipKillsTheOldOwner() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, stranger);

        vm.prank(typeOwner);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.NotTypeOwner.selector, SERVICE_TYPE_GVPN, typeOwner, stranger)
        );
        registry.setSelfUpdateBurn(SERVICE_TYPE_GVPN, 1);
    }

    // ---------------------------------------------------------------------------------------
    // Abandonment - invariants I2 and I10
    // ---------------------------------------------------------------------------------------

    function test_transferTypeOwnershipToZeroAbandonsTheType() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, permissive, REGISTRATION_BURN, UPDATE_BURN);

        vm.expectEmit(true, true, true, true, address(registry));
        emit TypeOwnershipTransferred(SERVICE_TYPE_GVPN, typeOwner, address(0));
        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, address(0));

        assertEq(registry.typeOwner(SERVICE_TYPE_GVPN), address(0), "abandoned type has no owner");
    }

    /// @dev Abandonment is one-way. All four owner functions are permanently dead afterwards.
    function test_abandonmentKillsAllFourOwnerFunctions() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, permissive, REGISTRATION_BURN, UPDATE_BURN);
        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, address(0));

        address[3] memory callers = [typeOwner, stranger, admin];
        for (uint256 i = 0; i < callers.length; i++) {
            address caller = callers[i];
            bytes memory expected = abi.encodeWithSelector(
                HoprServiceRegistry.NotTypeOwner.selector, SERVICE_TYPE_GVPN, caller, address(0)
            );

            vm.prank(caller);
            vm.expectRevert(expected);
            registry.setRequirement(SERVICE_TYPE_GVPN, IServiceRequirement(address(0)));

            vm.prank(caller);
            vm.expectRevert(expected);
            registry.setSelfRegistrationBurn(SERVICE_TYPE_GVPN, 1);

            vm.prank(caller);
            vm.expectRevert(expected);
            registry.setSelfUpdateBurn(SERVICE_TYPE_GVPN, 1);

            // there is no re-claim path: even a transfer back to a live address is dead
            vm.prank(caller);
            vm.expectRevert(expected);
            registry.transferTypeOwnership(SERVICE_TYPE_GVPN, caller);
        }
    }

    /// @dev The configuration of an abandoned type is frozen, and its entries stay writable.
    function test_abandonedTypeFreezesConfigButKeepsEntriesWritable() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), REGISTRATION_BURN, UPDATE_BURN);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, address(0));

        // the frozen configuration keeps its values
        assertEq(registry.selfRegistrationBurn(SERVICE_TYPE_GVPN), REGISTRATION_BURN, "registration burn is frozen");
        assertEq(registry.selfUpdateBurn(SERVICE_TYPE_GVPN), UPDATE_BURN, "update burn is frozen");
        assertEq(address(registry.requirements(SERVICE_TYPE_GVPN)), address(0), "requirement is frozen");

        // a new entry still registers under the frozen rules
        _registerEntry(safeB, SERVICE_TYPE_GVPN, nodeB, hex"02");
        _assertEntry(SERVICE_TYPE_GVPN, nodeB, hex"02", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));

        // an existing entry still updates and still deregisters
        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"03");
        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"03", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));

        vm.prank(safeA);
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
        _assertNoEntry(SERVICE_TYPE_GVPN, nodeA);
    }

    /// @dev Invariant I3. A zero owner and a zero requirement never mean "unregistered".
    function test_abandonedOpenTypeIsStillAServiceType() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, address(0));

        assertEq(registry.typeOwner(SERVICE_TYPE_GVPN), address(0), "owner is zero");
        assertEq(address(registry.requirements(SERVICE_TYPE_GVPN)), address(0), "requirement is zero");
        assertTrue(registry.isServiceType(SERVICE_TYPE_GVPN), "I3: the type still exists");
    }

    // ---------------------------------------------------------------------------------------
    // Section 3.5 - eligibility is never re-checked
    // ---------------------------------------------------------------------------------------

    /**
     * @dev A stricter policy freezes metadata that does not comply. It does not evict an entry.
     *
     * `denyRegister` answers `false` to `canRegister` and `true` to `validateMetadata`.
     */
    function test_canRegisterIsNeverRecheckedAfterRegistration() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, permissive, 0, 0);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.prank(typeOwner);
        registry.setRequirement(SERVICE_TYPE_GVPN, denyRegister);

        // the existing entry still updates
        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"02");
        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"02", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));

        // a new entry is blocked
        vm.prank(safeB);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.RegistrationDenied.selector, SERVICE_TYPE_GVPN, safeB, nodeB)
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeB, hex"03");
    }

    /// @dev R3. A type owner has no power over an entry of its own type.
    function test_typeOwnerHasNoPowerOverEntries() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, typeOwner, safeA));
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);

        vm.prank(typeOwner);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, nodeA, typeOwner, safeA));
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, hex"99");

        _assertEntry(SERVICE_TYPE_GVPN, nodeA, hex"01", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }
}
