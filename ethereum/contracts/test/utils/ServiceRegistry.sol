// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { HoprTokenFixtureTest } from "./Tokens.sol";
import { HoprServiceRegistry, HoprServiceRegistryEvents, INodeSafeRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";
import { MockNodeSafeRegistry } from "../mocks/ServiceRegistryMocks.sol";

/**
 * @dev The shared fixture of every HoprServiceRegistry test.
 *
 * It extends `HoprTokenFixtureTest`, which already chains `ERC1820RegistryFixtureTest` and
 * `AccountsFixtureTest`. The 1820 registry is therefore in place, which ERC-777 needs, and a real
 * `HoprToken` is deployed. This fixture reuses that stack instead of a new one.
 *
 * `setUp` calls no function that mutates registry state. Every test starts from a deployed but
 * empty registry and creates the state that it needs.
 *
 * The `victim` account holds an unlimited approval to the registry and never calls the registry.
 * It is the standing witness of invariant I5: a stale unlimited approval is not drainable by a
 * third party.
 */
abstract contract ServiceRegistryFixtureTest is HoprTokenFixtureTest, HoprServiceRegistryEvents {
    bytes32 internal constant SERVICE_TYPE_GVPN = bytes32("gvpn:exit");
    bytes32 internal constant SERVICE_TYPE_ALT = bytes32("gvpn:exit2");

    uint48 internal constant ADMIN_DELAY = 2 days;
    uint48 internal constant MAX_ADMIN_DELAY = 30 days;

    uint256 internal constant TYPE_FEE = 50 ether;
    uint256 internal constant REGISTRATION_BURN = 10 ether;
    uint256 internal constant UPDATE_BURN = 1 ether;

    /// @dev A fixed timestamp makes every `registeredAt` assertion deterministic.
    uint256 internal constant FIXED_TIMESTAMP = 1_800_000_000;

    uint256 internal constant FUNDING = 1_000_000 ether;

    HoprServiceRegistry internal registry;
    MockNodeSafeRegistry internal nodeSafeRegistry;

    address internal admin;
    address internal manager;
    address internal stranger;
    address internal typeOwner;
    address internal safeA;
    address internal safeB;
    address internal nodeA;
    address internal nodeB;
    address internal unboundNode;
    address internal victim;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(FIXED_TIMESTAMP);

        admin = vm.addr(98_765);
        manager = vm.addr(98_766);
        stranger = vm.addr(98_767);
        typeOwner = vm.addr(98_768);
        safeA = vm.addr(98_769);
        safeB = vm.addr(98_770);
        nodeA = vm.addr(98_771);
        nodeB = vm.addr(98_772);
        unboundNode = vm.addr(98_773);
        victim = vm.addr(98_774);

        vm.label(admin, "admin");
        vm.label(manager, "manager");
        vm.label(stranger, "stranger");
        vm.label(typeOwner, "typeOwner");
        vm.label(safeA, "safeA");
        vm.label(safeB, "safeB");
        vm.label(nodeA, "nodeA");
        vm.label(nodeB, "nodeB");
        vm.label(unboundNode, "unboundNode");
        vm.label(victim, "victim");

        nodeSafeRegistry = new MockNodeSafeRegistry();
        registry = new HoprServiceRegistry(
            address(hoprToken), INodeSafeRegistry(address(nodeSafeRegistry)), ADMIN_DELAY, admin, manager, TYPE_FEE
        );
        vm.label(address(registry), "registry");
        vm.label(address(nodeSafeRegistry), "nodeSafeRegistry");

        _mintAndApprove(typeOwner, FUNDING);
        _mintAndApprove(stranger, FUNDING);
        _mintAndApprove(safeA, FUNDING);
        _mintAndApprove(safeB, FUNDING);
        _mintAndApprove(victim, FUNDING);

        nodeSafeRegistry.setBinding(nodeA, safeA);
        nodeSafeRegistry.setBinding(nodeB, safeB);
    }

    // ---------------------------------------------------------------------------------------
    // State helpers
    // ---------------------------------------------------------------------------------------

    /// @dev Binds a node to a Safe in the mock NodeSafeRegistry.
    function _bind(address node, address safe) internal {
        nodeSafeRegistry.setBinding(node, safe);
    }

    /// @dev Mints wxHOPR to an account and gives the registry an unlimited allowance on it.
    function _mintAndApprove(address account, uint256 amount) internal {
        hoprToken.mint(account, amount, hex"00", hex"00");
        vm.prank(account);
        hoprToken.approve(address(registry), type(uint256).max);
    }

    /// @dev Registers a service type as `owner`.
    function _registerType(
        address owner,
        bytes32 serviceType,
        IServiceRequirement requirement,
        uint256 registrationBurn,
        uint256 updateBurn
    )
        internal
    {
        vm.prank(owner);
        registry.registerServiceType(serviceType, requirement, registrationBurn, updateBurn);
    }

    /// @dev Registers the default `gvpn:exit` type with no requirement and the default burns.
    function _registerDefaultType() internal {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), REGISTRATION_BURN, UPDATE_BURN);
    }

    /// @dev Registers one entry as `safe`.
    function _registerEntry(address safe, bytes32 serviceType, address node, bytes memory metadata) internal {
        vm.prank(safe);
        registry.selfRegister(serviceType, node, metadata);
    }

    /// @dev Builds metadata of an exact byte length, filled with a non-zero pattern.
    function _metadataOfLength(uint256 length) internal pure returns (bytes memory metadata) {
        metadata = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            metadata[i] = 0xab;
        }
    }

    // ---------------------------------------------------------------------------------------
    // Assertion helpers
    // ---------------------------------------------------------------------------------------

    /// @dev Asserts every field of one entry.
    function _assertEntry(
        bytes32 serviceType,
        address node,
        bytes memory metadata,
        uint48 registeredAt,
        uint48 updatedAt
    )
        internal
        view
    {
        HoprServiceRegistry.Entry memory entry = registry.getEntry(serviceType, node);
        assertEq(entry.metadata, metadata, "entry metadata");
        assertEq(entry.registeredAt, registeredAt, "entry registeredAt");
        assertEq(entry.updatedAt, updatedAt, "entry updatedAt");
        assertTrue(registry.isRegistered(serviceType, node), "entry must be registered");
    }

    /// @dev Asserts that the entry is absent and that `getEntry` returns a zeroed record.
    function _assertNoEntry(bytes32 serviceType, address node) internal view {
        HoprServiceRegistry.Entry memory entry = registry.getEntry(serviceType, node);
        assertEq(entry.metadata.length, 0, "absent entry must carry no metadata");
        assertEq(entry.registeredAt, 0, "absent entry must have registeredAt 0");
        assertEq(entry.updatedAt, 0, "absent entry must have updatedAt 0");
        assertFalse(registry.isRegistered(serviceType, node), "entry must be absent");
    }

    /// @dev Invariant I4. The token balance of the registry is zero at rest.
    function _assertNoTokensAtRest() internal view {
        assertEq(hoprToken.balanceOf(address(registry)), 0, "I4: registry must hold no tokens at rest");
    }

    /// @dev Invariant I5. The unlimited approval of `victim` is never spent by a third party.
    function _assertVictimUntouched() internal view {
        assertEq(hoprToken.balanceOf(victim), FUNDING, "I5: victim balance must not move");
        assertEq(
            hoprToken.allowance(victim, address(registry)), type(uint256).max, "I5: victim allowance must not move"
        );
    }

    /**
     * @dev Asserts that a paid call burned exactly `amount`.
     *
     * The total supply, the balance of the payer and the allowance of the payer must all move by
     * the same amount. The registry must keep nothing.
     *
     * The vendored ERC-777 base of wxHOPR has no exemption for an unlimited approval. It
     * decrements every allowance, so even `type(uint256).max` falls by the burn.
     */
    function _assertBurned(
        address payer,
        uint256 supplyBefore,
        uint256 payerBalanceBefore,
        uint256 payerAllowanceBefore,
        uint256 amount
    )
        internal
        view
    {
        assertEq(hoprToken.totalSupply(), supplyBefore - amount, "total supply must fall by the burn");
        assertEq(hoprToken.balanceOf(payer), payerBalanceBefore - amount, "payer balance must fall by the burn");
        assertEq(
            hoprToken.allowance(payer, address(registry)),
            payerAllowanceBefore - amount,
            "payer allowance must fall by the burn"
        );
        _assertNoTokensAtRest();
    }

    /// @dev Every registered type, read through the only enumeration that exists.
    function _allTypes() internal view returns (bytes32[] memory) {
        return registry.getServiceTypesPaginated(0, registry.typeCount());
    }

    /// @dev Every node of a type.
    function _allNodes(bytes32 serviceType) internal view returns (address[] memory) {
        return registry.getNodes(serviceType);
    }

    /// @dev Set comparison for addresses. List order is unstable, so a test must never use order.
    function _assertSameAddressSet(
        address[] memory actual,
        address[] memory expected,
        string memory reason
    )
        internal
        pure
    {
        assertEq(actual.length, expected.length, reason);
        for (uint256 i = 0; i < expected.length; i++) {
            assertTrue(_containsAddress(actual, expected[i]), reason);
        }
    }

    function _containsAddress(address[] memory haystack, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) {
                return true;
            }
        }
        return false;
    }

    function _containsBytes32(bytes32[] memory haystack, bytes32 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) {
                return true;
            }
        }
        return false;
    }
}
