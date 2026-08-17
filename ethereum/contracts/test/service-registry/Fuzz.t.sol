// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";

/**
 * @dev Property tests over the boundaries of the registry.
 *
 * The fuzz depth is set for each test through an inline `forge-config` comment. This file
 * therefore never changes `foundry.in.toml`.
 */
contract HoprServiceRegistryFuzzTest is ServiceRegistryFixtureTest {
    uint256 internal constant SPREAD_COUNT = 12;

    address[SPREAD_COUNT] internal spreadNodes;
    address[SPREAD_COUNT] internal spreadSafes;

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i = 0; i < SPREAD_COUNT; i++) {
            spreadNodes[i] = vm.addr(60_000 + i);
            spreadSafes[i] = vm.addr(61_000 + i);
            _bind(spreadNodes[i], spreadSafes[i]);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Metadata length
    // ---------------------------------------------------------------------------------------

    /**
     * @dev The cap is accepted at exactly `MAX_METADATA_LENGTH` and rejected one byte later.
     *
     * The bound reaches well past the cap, so both sides of the boundary get coverage.
     */
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_metadataIsAcceptedExactlyUpToTheCap(uint256 rawLength) public {
        uint256 cap = registry.MAX_METADATA_LENGTH();
        uint256 length = bound(rawLength, 0, 2 * cap);
        bytes memory metadata = _metadataOfLength(length);

        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        if (length <= cap) {
            _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, metadata);
            _assertEntry(SERVICE_TYPE_GVPN, nodeA, metadata, uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
        } else {
            vm.prank(safeA);
            vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.MetadataTooLong.selector, length, cap));
            registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, metadata);
        }
    }

    /// @dev The same cap applies to the update path.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_selfUpdateAppliesTheSameCap(uint256 rawLength) public {
        uint256 cap = registry.MAX_METADATA_LENGTH();
        uint256 length = bound(rawLength, 0, 2 * cap);
        bytes memory metadata = _metadataOfLength(length);

        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, "");

        if (length <= cap) {
            vm.prank(safeA);
            registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, metadata);
            _assertEntry(SERVICE_TYPE_GVPN, nodeA, metadata, uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
        } else {
            vm.prank(safeA);
            vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.MetadataTooLong.selector, length, cap));
            registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, metadata);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Burn exactness - invariant I4
    // ---------------------------------------------------------------------------------------

    /**
     * @dev A paid write moves exactly the configured amount, on all four measures.
     *
     * The supply, the balance of the payer and the allowance of the payer fall by the burn, and
     * the registry keeps nothing.
     */
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_selfRegisterBurnsExactlyTheConfiguredAmount(uint256 rawBurn) public {
        uint256 burn = bound(rawBurn, 0, 1000 ether);
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), burn, 0);

        uint256 supplyBefore = hoprToken.totalSupply();
        uint256 balanceBefore = hoprToken.balanceOf(safeA);
        uint256 allowanceBefore = hoprToken.allowance(safeA, address(registry));

        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        _assertBurned(safeA, supplyBefore, balanceBefore, allowanceBefore, burn);
        _assertVictimUntouched();
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_registerServiceTypeBurnsExactlyTheConfiguredFee(uint256 rawFee) public {
        uint256 fee = bound(rawFee, 0, 1000 ether);
        vm.prank(manager);
        registry.setTypeRegistrationFee(fee);

        uint256 supplyBefore = hoprToken.totalSupply();
        uint256 balanceBefore = hoprToken.balanceOf(typeOwner);
        uint256 allowanceBefore = hoprToken.allowance(typeOwner, address(registry));

        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        _assertBurned(typeOwner, supplyBefore, balanceBefore, allowanceBefore, fee);
        _assertVictimUntouched();
    }

    /// @dev A zero burn leaves the allowance and the supply untouched.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_aZeroBurnTouchesNoToken(bytes calldata metadata) public {
        vm.assume(metadata.length <= 2048);
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        uint256 supplyBefore = hoprToken.totalSupply();
        uint256 allowanceBefore = hoprToken.allowance(safeA, address(registry));

        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, metadata);

        assertEq(hoprToken.totalSupply(), supplyBefore, "a zero burn must not change the supply");
        assertEq(
            hoprToken.allowance(safeA, address(registry)), allowanceBefore, "a zero burn must not change the allowance"
        );
        _assertNoTokensAtRest();
    }

    // ---------------------------------------------------------------------------------------
    // Pagination
    // ---------------------------------------------------------------------------------------

    /**
     * @dev Every page joined together equals `getNodes`, for any page size.
     *
     * The result is compared as a set, because list order is unstable.
     */
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_pagesOfAnySizeCoverTheWholeEntrySet(uint256 rawPageSize) public {
        uint256 pageSize = bound(rawPageSize, 1, SPREAD_COUNT + 3);
        _fillType(SPREAD_COUNT);

        address[] memory collected = new address[](SPREAD_COUNT);
        uint256 seen = 0;
        for (uint256 offset = 0; offset < SPREAD_COUNT; offset += pageSize) {
            (address[] memory page,) = registry.getEntriesPaginated(SERVICE_TYPE_GVPN, offset, pageSize);
            for (uint256 i = 0; i < page.length; i++) {
                collected[seen++] = page[i];
            }
        }

        assertEq(seen, SPREAD_COUNT, "every entry must appear exactly once");
        _assertSameAddressSet(collected, _allNodes(SERVICE_TYPE_GVPN), "the union of pages must equal getNodes");
    }

    /// @dev No offset and no limit can make a paginated view revert.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_paginatedViewsNeverRevert(uint256 offset, uint256 limit) public {
        _fillType(4);

        bytes32[] memory types = registry.getServiceTypesPaginated(offset, limit);
        assertTrue(types.length <= registry.typeCount(), "a type page can never exceed the set");

        (address[] memory nodes, HoprServiceRegistry.Entry[] memory entries) =
            registry.getEntriesPaginated(SERVICE_TYPE_GVPN, offset, limit);
        assertEq(nodes.length, entries.length, "both arrays must stay aligned");
        assertTrue(nodes.length <= registry.nodeCount(SERVICE_TYPE_GVPN), "an entry page can never exceed the set");
    }

    // ---------------------------------------------------------------------------------------
    // The binding check
    // ---------------------------------------------------------------------------------------

    /**
     * @dev Any caller that is not the current bound Safe is rejected, and the error carries the
     * bound Safe that the registry read.
     */
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfRegisterRejectsEveryCallerThatIsNotTheBoundSafe(
        address caller,
        address node,
        address boundSafe
    )
        public
    {
        vm.assume(node != address(0));
        vm.assume(caller != boundSafe);
        assumeNotPrecompile(caller);

        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        _bind(node, boundSafe);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, node, caller, boundSafe));
        registry.selfRegister(SERVICE_TYPE_GVPN, node, hex"01");
    }

    /// @dev An unbound node is rejected whoever calls, because a zero bound Safe matches nobody.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_anUnboundNodeIsAlwaysRejected(address caller, address node) public {
        vm.assume(node != address(0));
        // the precondition is read from state, so it stays correct however many bindings the
        // fixture adds later
        vm.assume(nodeSafeRegistry.nodeToSafe(node) == address(0));
        assumeNotPrecompile(caller);

        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(HoprServiceRegistry.CallerNotNodeSafe.selector, node, caller, address(0))
        );
        registry.selfRegister(SERVICE_TYPE_GVPN, node, hex"01");
    }

    // ---------------------------------------------------------------------------------------
    // Type ids
    // ---------------------------------------------------------------------------------------

    /// @dev Any non-zero id registers, and the zero id never does.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_anyNonZeroServiceTypeCanBeRegistered(bytes32 serviceType) public {
        vm.prank(manager);
        registry.setTypeRegistrationFee(0);

        if (serviceType == bytes32(0)) {
            vm.prank(typeOwner);
            vm.expectRevert(HoprServiceRegistry.ZeroServiceType.selector);
            registry.registerServiceType(serviceType, IServiceRequirement(address(0)), 0, 0);
        } else {
            _registerType(typeOwner, serviceType, IServiceRequirement(address(0)), 0, 0);
            assertTrue(registry.isServiceType(serviceType), "a non-zero id must register");
            assertEq(registry.typeOwner(serviceType), typeOwner, "the registrant owns the type");
        }
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @dev Registers the default type with zero burns and fills it with `count` entries.
    function _fillType(uint256 count) internal {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        for (uint256 i = 0; i < count; i++) {
            vm.prank(spreadSafes[i]);
            registry.selfRegister(SERVICE_TYPE_GVPN, spreadNodes[i], abi.encodePacked(uint8(i + 1)));
        }
    }
}
