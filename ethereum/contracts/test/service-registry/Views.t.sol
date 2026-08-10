// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { stdError } from "forge-std/Test.sol";
import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";

/**
 * @dev Section 5.4, the view surface. These views ship complete, because nobody can add one later.
 *
 * It also covers invariant I3, that `isServiceType` is the only existence test, and the rule that
 * list order is unstable.
 */
contract HoprServiceRegistryViewsTest is ServiceRegistryFixtureTest {
    uint256 internal constant ENTRY_COUNT = 5;

    address[ENTRY_COUNT] internal nodes;
    address[ENTRY_COUNT] internal safes;

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i = 0; i < ENTRY_COUNT; i++) {
            nodes[i] = vm.addr(70_000 + i);
            safes[i] = vm.addr(80_000 + i);
            _bind(nodes[i], safes[i]);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Existence tests
    // ---------------------------------------------------------------------------------------

    function test_isServiceTypeIsFalseBeforeRegistration() public view {
        assertFalse(registry.isServiceType(SERVICE_TYPE_GVPN), "an unregistered type must not exist");
        assertEq(registry.typeCount(), 0, "type count starts at zero");
    }

    /**
     * @dev Invariant I3. A zero owner and a zero requirement are both legal states of a registered
     * type. Neither means that the type is unregistered.
     */
    function test_isServiceTypeIsTrueForAnAbandonedOpenType() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        vm.prank(typeOwner);
        registry.transferTypeOwnership(SERVICE_TYPE_GVPN, address(0));

        assertEq(registry.typeOwner(SERVICE_TYPE_GVPN), address(0), "owner is zero");
        assertEq(address(registry.requirements(SERVICE_TYPE_GVPN)), address(0), "requirement is zero");
        assertTrue(registry.isServiceType(SERVICE_TYPE_GVPN), "I3: the type still exists");
    }

    function test_getEntryIsZeroedWhenAbsent() public {
        _registerDefaultType();
        _assertNoEntry(SERVICE_TYPE_GVPN, nodeA);
    }

    /// @dev A view on an unknown type answers empty, and never reverts.
    function test_viewsOnAnUnknownTypeAnswerEmpty() public view {
        assertEq(registry.nodeCount(SERVICE_TYPE_GVPN), 0, "nodeCount");
        assertEq(registry.getNodes(SERVICE_TYPE_GVPN).length, 0, "getNodes");
        assertFalse(registry.isRegistered(SERVICE_TYPE_GVPN, nodeA), "isRegistered");

        (address[] memory pageNodes, HoprServiceRegistry.Entry[] memory pageEntries) =
            registry.getEntriesPaginated(SERVICE_TYPE_GVPN, 0, 10);
        assertEq(pageNodes.length, 0, "paginated nodes");
        assertEq(pageEntries.length, 0, "paginated entries");
    }

    // ---------------------------------------------------------------------------------------
    // Pagination bounds - both tables share one helper, so both are tested
    // ---------------------------------------------------------------------------------------

    function test_getServiceTypesPaginatedReturnsTheWholeSet() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        _registerType(typeOwner, SERVICE_TYPE_ALT, IServiceRequirement(address(0)), 0, 0);

        bytes32[] memory page = registry.getServiceTypesPaginated(0, 10);
        assertEq(page.length, 2, "both types must appear");
        assertTrue(_containsBytes32(page, SERVICE_TYPE_GVPN), "gvpn type");
        assertTrue(_containsBytes32(page, SERVICE_TYPE_ALT), "alt type");
    }

    function test_getServiceTypesPaginatedTruncatesTheTailPage() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        _registerType(typeOwner, SERVICE_TYPE_ALT, IServiceRequirement(address(0)), 0, 0);

        // one type remains from offset 1, so a limit of 10 truncates to 1
        assertEq(registry.getServiceTypesPaginated(1, 10).length, 1, "tail page must truncate");
    }

    function test_getServiceTypesPaginatedReturnsEmptyAtOrPastTheEnd() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        assertEq(registry.getServiceTypesPaginated(1, 10).length, 0, "offset at the end");
        assertEq(registry.getServiceTypesPaginated(2, 10).length, 0, "offset past the end");
    }

    function test_getServiceTypesPaginatedReturnsEmptyForAZeroLimit() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        assertEq(registry.getServiceTypesPaginated(0, 0).length, 0, "a zero limit must return empty");
    }

    /// @dev The bounds test runs before the subtraction, so the maximum offset cannot underflow.
    function test_getServiceTypesPaginatedDoesNotOverflowAtTheMaximumOffset() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        assertEq(registry.getServiceTypesPaginated(type(uint256).max, 10).length, 0, "max offset must be empty");
        assertEq(
            registry.getServiceTypesPaginated(type(uint256).max, type(uint256).max).length,
            0,
            "max offset and max limit must be empty"
        );
    }

    function test_getEntriesPaginatedTruncatesTheTailPage() public {
        _registerDefaultTypeWithEntries();

        (address[] memory pageNodes,) = registry.getEntriesPaginated(SERVICE_TYPE_GVPN, 3, 10);
        assertEq(pageNodes.length, ENTRY_COUNT - 3, "tail page must truncate to the remainder");
    }

    function test_getEntriesPaginatedReturnsEmptyAtOrPastTheEnd() public {
        _registerDefaultTypeWithEntries();

        (address[] memory atEnd,) = registry.getEntriesPaginated(SERVICE_TYPE_GVPN, ENTRY_COUNT, 10);
        assertEq(atEnd.length, 0, "offset at the end");

        (address[] memory pastEnd,) = registry.getEntriesPaginated(SERVICE_TYPE_GVPN, ENTRY_COUNT + 7, 10);
        assertEq(pastEnd.length, 0, "offset past the end");
    }

    function test_getEntriesPaginatedReturnsEmptyForAZeroLimit() public {
        _registerDefaultTypeWithEntries();

        (address[] memory pageNodes, HoprServiceRegistry.Entry[] memory pageEntries) =
            registry.getEntriesPaginated(SERVICE_TYPE_GVPN, 0, 0);
        assertEq(pageNodes.length, 0, "a zero limit must return no nodes");
        assertEq(pageEntries.length, 0, "a zero limit must return no entries");
    }

    function test_getEntriesPaginatedDoesNotOverflowAtTheMaximumOffset() public {
        _registerDefaultTypeWithEntries();

        (address[] memory pageNodes,) = registry.getEntriesPaginated(SERVICE_TYPE_GVPN, type(uint256).max, 10);
        assertEq(pageNodes.length, 0, "max offset must be empty");
    }

    // ---------------------------------------------------------------------------------------
    // Pagination content
    // ---------------------------------------------------------------------------------------

    /// @dev The two arrays share one index. `nodes[i]` must own `entries[i]`.
    function test_getEntriesPaginatedKeepsTheTwoArraysAligned() public {
        _registerDefaultTypeWithEntries();

        (address[] memory pageNodes, HoprServiceRegistry.Entry[] memory pageEntries) =
            registry.getEntriesPaginated(SERVICE_TYPE_GVPN, 0, ENTRY_COUNT);
        assertEq(pageNodes.length, pageEntries.length, "both arrays must have the same length");

        for (uint256 i = 0; i < pageNodes.length; i++) {
            HoprServiceRegistry.Entry memory direct = registry.getEntry(SERVICE_TYPE_GVPN, pageNodes[i]);
            assertEq(pageEntries[i].metadata, direct.metadata, "metadata must match the direct read");
            assertEq(pageEntries[i].registeredAt, direct.registeredAt, "registeredAt must match");
            assertEq(pageEntries[i].updatedAt, direct.updatedAt, "updatedAt must match");
        }
    }

    /// @dev Every page joined together must equal the full set, with no gap and no repeat.
    function test_pagesOfSizeOneCoverTheWholeSetExactlyOnce() public {
        _registerDefaultTypeWithEntries();

        address[] memory collected = new address[](ENTRY_COUNT);
        for (uint256 i = 0; i < ENTRY_COUNT; i++) {
            (address[] memory page,) = registry.getEntriesPaginated(SERVICE_TYPE_GVPN, i, 1);
            assertEq(page.length, 1, "each single-item page must hold one node");
            collected[i] = page[0];
        }

        _assertSameAddressSet(collected, _allNodes(SERVICE_TYPE_GVPN), "the union of pages must equal getNodes");
    }

    // ---------------------------------------------------------------------------------------
    // Order instability
    // ---------------------------------------------------------------------------------------

    /**
     * @dev A deregistration swaps the last node into the hole of the removed one.
     *
     * The remaining set is correct, and the order changed. A consumer must therefore compare as a
     * set. This test asserts the set, and separately records that the position moved.
     */
    function test_deregistrationSwapsAndPopsSoOrderIsUnstable() public {
        _registerDefaultTypeWithEntries();

        address lastBefore = registry.nodeAt(SERVICE_TYPE_GVPN, ENTRY_COUNT - 1);
        assertEq(registry.nodeAt(SERVICE_TYPE_GVPN, 0), nodes[0], "the first node starts at index 0");

        vm.prank(safes[0]);
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodes[0]);

        assertEq(registry.nodeCount(SERVICE_TYPE_GVPN), ENTRY_COUNT - 1, "one node must be gone");
        assertEq(registry.nodeAt(SERVICE_TYPE_GVPN, 0), lastBefore, "the last node moved into the hole");

        address[] memory expected = new address[](ENTRY_COUNT - 1);
        for (uint256 i = 1; i < ENTRY_COUNT; i++) {
            expected[i - 1] = nodes[i];
        }
        _assertSameAddressSet(_allNodes(SERVICE_TYPE_GVPN), expected, "the remaining set must be correct");
    }

    // ---------------------------------------------------------------------------------------
    // Index access
    // ---------------------------------------------------------------------------------------

    /// @dev Section 5.4. An index past the end gives the standard array panic, and no custom error.
    function testRevert_typeAtDueToAnIndexPastTheEnd() public {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.expectRevert(stdError.indexOOBError);
        registry.typeAt(1);
    }

    function testRevert_typeAtDueToAnEmptySet() public {
        vm.expectRevert(stdError.indexOOBError);
        registry.typeAt(0);
    }

    function testRevert_nodeAtDueToAnIndexPastTheEnd() public {
        _registerDefaultTypeWithEntries();

        vm.expectRevert(stdError.indexOOBError);
        registry.nodeAt(SERVICE_TYPE_GVPN, ENTRY_COUNT);
    }

    function testRevert_nodeAtDueToAnUnknownType() public {
        vm.expectRevert(stdError.indexOOBError);
        registry.nodeAt(SERVICE_TYPE_GVPN, 0);
    }

    // ---------------------------------------------------------------------------------------
    // getNodes
    // ---------------------------------------------------------------------------------------

    function test_getNodesReturnsEveryNodeOfTheType() public {
        _registerDefaultTypeWithEntries();

        address[] memory expected = new address[](ENTRY_COUNT);
        for (uint256 i = 0; i < ENTRY_COUNT; i++) {
            expected[i] = nodes[i];
        }
        _assertSameAddressSet(_allNodes(SERVICE_TYPE_GVPN), expected, "getNodes must hold every node");
    }

    /// @dev Entry sets are per type, so one type never leaks into another.
    function test_entrySetsAreIsolatedPerType() public {
        _registerDefaultTypeWithEntries();
        _registerType(typeOwner, SERVICE_TYPE_ALT, IServiceRequirement(address(0)), 0, 0);

        assertEq(registry.nodeCount(SERVICE_TYPE_ALT), 0, "a new type starts empty");

        vm.prank(safes[0]);
        registry.selfRegister(SERVICE_TYPE_ALT, nodes[0], hex"aa");

        assertEq(registry.nodeCount(SERVICE_TYPE_ALT), 1, "the new type holds one node");
        assertEq(registry.nodeCount(SERVICE_TYPE_GVPN), ENTRY_COUNT, "the old type is unchanged");
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @dev Registers the default type with a zero burn, then one entry for each prepared node.
    function _registerDefaultTypeWithEntries() internal {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        for (uint256 i = 0; i < ENTRY_COUNT; i++) {
            vm.prank(safes[i]);
            registry.selfRegister(SERVICE_TYPE_GVPN, nodes[i], abi.encodePacked(uint8(i + 1)));
        }
    }
}
