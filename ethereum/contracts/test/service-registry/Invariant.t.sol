// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { ServiceRegistryHandler } from "./handlers/ServiceRegistryHandler.sol";

/**
 * @dev The invariant suite. The handler drives every action, and it never reverts on a rejected
 * call, so this suite runs with `fail_on_revert = true`.
 *
 * Three invariants of section 8 are covered elsewhere, because an invariant run cannot observe
 * them. I7 is a static property of one deployment, and Payment.t.sol tests it. I8 is a
 * reconstruction from logs, and EventReplay.t.sol tests it. The full matrix of I6 is small and
 * enumerable, and SelfService.t.sol tests it.
 */
contract HoprServiceRegistryInvariantTest is ServiceRegistryFixtureTest {
    ServiceRegistryHandler internal handler;

    function setUp() public virtual override {
        super.setUp();

        handler = new ServiceRegistryHandler(registry, hoprToken, nodeSafeRegistry, admin, manager, stranger, victim);
        hoprToken.grantRole(MINTER_ROLE, address(handler));
        handler.fundActors();

        targetContract(address(handler));
    }

    /**
     * @dev Invariant I4. The registry holds no tokens at rest, except the tracked donations.
     *
     * Fee collection moves exactly the configured amount and burns exactly that amount. It never
     * burns `balanceOf`, so a donation can neither distort a burn event nor be burned.
     */
    function invariant_I4_theRegistryHoldsOnlyTrackedDonations() public view {
        assertEq(
            hoprToken.balanceOf(address(registry)),
            handler.ghostDonated(),
            "I4: the registry must hold nothing beyond the tracked donations"
        );
    }

    /// @dev Invariant I5. A stale unlimited approval is not drainable by a third party.
    function invariant_I5_theVictimApprovalIsNeverSpent() public view {
        _assertVictimUntouched();
    }

    /// @dev Invariant I1. An entry can only exist under a registered type.
    function invariant_I1_everyEntryLivesUnderARegisteredType() public view {
        for (uint256 t = 0; t < 4; t++) {
            bytes32 serviceType = handler.serviceTypes(t);
            uint256 count = registry.nodeCount(serviceType);
            if (count > 0) {
                assertTrue(registry.isServiceType(serviceType), "I1: entries require a registered type");
            }
            for (uint256 n = 0; n < 6; n++) {
                if (registry.isRegistered(serviceType, handler.nodes(n))) {
                    assertTrue(registry.isServiceType(serviceType), "I1: an entry implies a registered type");
                }
            }
        }
    }

    /// @dev Invariant I2. The type count never decreases, because no function removes a type.
    function invariant_I2_theTypeCountNeverDecreases() public view {
        assertGe(registry.typeCount(), handler.ghostMaxTypeCount(), "I2: types are permanent");
    }

    /// @dev Invariant I2. Abandonment freezes the requirement and both burns forever.
    function invariant_I2_anAbandonedTypeKeepsItsFrozenConfiguration() public view {
        for (uint256 t = 0; t < 4; t++) {
            bytes32 serviceType = handler.serviceTypes(t);
            if (!handler.ghostAbandoned(serviceType)) {
                continue;
            }
            assertEq(
                address(registry.requirements(serviceType)),
                handler.ghostFrozenRequirement(serviceType),
                "I2: the requirement of an abandoned type is frozen"
            );
            assertEq(
                registry.selfRegistrationBurn(serviceType),
                handler.ghostFrozenRegistrationBurn(serviceType),
                "I2: the registration burn of an abandoned type is frozen"
            );
            assertEq(
                registry.selfUpdateBurn(serviceType),
                handler.ghostFrozenUpdateBurn(serviceType),
                "I2: the update burn of an abandoned type is frozen"
            );
        }
    }

    /**
     * @dev Invariant I3. `isServiceType` is the authoritative existence test.
     *
     * A zero owner and a zero requirement are both legal states of a registered type, so neither
     * value may change what `isServiceType` reports.
     */
    function invariant_I3_isServiceTypeIsAuthoritative() public view {
        for (uint256 t = 0; t < 4; t++) {
            bytes32 serviceType = handler.serviceTypes(t);
            assertEq(
                registry.isServiceType(serviceType),
                handler.ghostRegistered(serviceType),
                "I3: existence must follow registration only"
            );
        }
    }

    /// @dev Invariant I9. No party other than the bound Safe ever writes an entry.
    function invariant_I9_noUnauthorizedEntryWriteEverSucceeds() public view {
        assertEq(handler.ghostUnauthorizedEntryWrites(), 0, "I9: a hostile entry write succeeded");
        assertEq(handler.ghostSilentEntryChanges(), 0, "I9: a rejected call still changed an entry");
    }

    /// @dev Invariant I10. Only the current owner governs a type, and abandonment is one-way.
    function invariant_I10_theOwnerOfEachTypeFollowsTheGhost() public view {
        for (uint256 t = 0; t < 4; t++) {
            bytes32 serviceType = handler.serviceTypes(t);
            assertEq(
                registry.typeOwner(serviceType), handler.ghostOwner(serviceType), "I10: only the owner moves ownership"
            );
            if (handler.ghostAbandoned(serviceType)) {
                assertEq(registry.typeOwner(serviceType), address(0), "I10: abandonment is one-way");
            }
        }
    }

    /// @dev The two enumerations must always agree with the membership tests.
    function invariant_enumerationAgreesWithMembership() public view {
        uint256 typeCount = registry.typeCount();
        bytes32[] memory allTypes = registry.getServiceTypesPaginated(0, typeCount);
        assertEq(allTypes.length, typeCount, "the type page must cover the whole set");

        for (uint256 i = 0; i < allTypes.length; i++) {
            assertTrue(registry.isServiceType(allTypes[i]), "an enumerated type must exist");

            address[] memory typeNodes = registry.getNodes(allTypes[i]);
            assertEq(typeNodes.length, registry.nodeCount(allTypes[i]), "getNodes must match nodeCount");
            for (uint256 j = 0; j < typeNodes.length; j++) {
                assertTrue(registry.isRegistered(allTypes[i], typeNodes[j]), "an enumerated node must be registered");
                assertTrue(
                    registry.getEntry(allTypes[i], typeNodes[j]).registeredAt != 0,
                    "a registered entry must carry a non-zero registeredAt"
                );
            }
        }
    }
}
