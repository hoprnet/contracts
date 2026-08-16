// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { HoprServiceRegistry, INodeSafeRegistry } from "../../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../../src/interfaces/IServiceRequirement.sol";
import { HoprToken } from "../../../src/static/HoprToken.sol";
import { DenyAllRequirement, MockNodeSafeRegistry, PermissiveRequirement } from "../../mocks/ServiceRegistryMocks.sol";
import { IERC20 } from "openzeppelin-contracts-5.4.0/token/ERC20/IERC20.sol";

/**
 * @dev The action driver of the invariant suite.
 *
 * Every action tests its own preconditions and returns early when a call would fail. A revert
 * from this handler is therefore a real violation, and the suite runs with `fail_on_revert = true`.
 *
 * A hostile action is the one exception. It uses a raw call, so a rejected attempt gives a false
 * boolean instead of a revert, and the handler stays inside the same rule.
 *
 * The universe is bounded on purpose: 4 types, 4 Safes, 6 nodes of which 2 stay unbound, 3
 * requirement values and 2 NodeSafeRegistry instances. A small universe makes collisions frequent,
 * and collisions are where the interesting states are.
 */
contract ServiceRegistryHandler is Test {
    uint256 internal constant TYPE_COUNT = 4;
    uint256 internal constant SAFE_COUNT = 4;
    uint256 internal constant NODE_COUNT = 6;
    uint256 internal constant BOUND_NODE_COUNT = 4;
    uint256 internal constant ACTOR_FUNDING = 100_000 ether;
    uint256 internal constant MAX_AMOUNT = 10 ether;

    HoprServiceRegistry public immutable registry;
    HoprToken public immutable token;
    MockNodeSafeRegistry public immutable bindingsA;
    MockNodeSafeRegistry public immutable bindingsB;

    address public immutable admin;
    address public immutable manager;
    address public immutable stranger;
    address public immutable victim;

    bytes32[TYPE_COUNT] public serviceTypes;
    address[SAFE_COUNT] public safes;
    address[NODE_COUNT] public nodes;
    address[3] public requirementOptions;

    // --- ghost state -----------------------------------------------------------------------

    /// @dev Types that the handler registered. Mirrors what `isServiceType` must report.
    mapping(bytes32 => bool) public ghostRegistered;
    /// @dev The owner that the handler last set. Mirrors what `typeOwner` must report.
    mapping(bytes32 => address) public ghostOwner;
    /// @dev The configuration frozen at the moment of abandonment.
    mapping(bytes32 => bool) public ghostAbandoned;
    mapping(bytes32 => address) public ghostFrozenRequirement;
    mapping(bytes32 => uint256) public ghostFrozenRegistrationBurn;
    mapping(bytes32 => uint256) public ghostFrozenUpdateBurn;

    /// @dev Tokens sent to the registry outside of a fee. Invariant I4 allows exactly this much.
    uint256 public ghostDonated;
    /// @dev The highest `typeCount` ever seen. The count must never fall below it.
    uint256 public ghostMaxTypeCount;
    /// @dev A hostile write that succeeded. This must stay at zero.
    uint256 public ghostUnauthorizedEntryWrites;
    /// @dev A rejected call that still changed an entry. This must stay at zero.
    uint256 public ghostSilentEntryChanges;

    constructor(
        HoprServiceRegistry registry_,
        HoprToken token_,
        MockNodeSafeRegistry bindingsA_,
        address admin_,
        address manager_,
        address stranger_,
        address victim_
    ) {
        registry = registry_;
        token = token_;
        bindingsA = bindingsA_;
        bindingsB = new MockNodeSafeRegistry();
        admin = admin_;
        manager = manager_;
        stranger = stranger_;
        victim = victim_;

        serviceTypes[0] = bytes32("inv:one");
        serviceTypes[1] = bytes32("inv:two");
        serviceTypes[2] = bytes32("inv:three");
        serviceTypes[3] = bytes32("inv:four");

        for (uint256 i = 0; i < SAFE_COUNT; i++) {
            safes[i] = vm.addr(40_000 + i);
        }
        for (uint256 i = 0; i < NODE_COUNT; i++) {
            nodes[i] = vm.addr(41_000 + i);
        }

        requirementOptions[0] = address(0);
        requirementOptions[1] = address(new PermissiveRequirement());
        requirementOptions[2] = address(new DenyAllRequirement());
    }

    /// @dev Called once by the invariant test, which holds the minter role of the token.
    function fundActors() external {
        for (uint256 i = 0; i < SAFE_COUNT; i++) {
            token.mint(safes[i], ACTOR_FUNDING, hex"00", hex"00");
            vm.prank(safes[i]);
            token.approve(address(registry), type(uint256).max);
        }
        // the first four nodes are bound, and the last two stay unbound forever
        for (uint256 i = 0; i < BOUND_NODE_COUNT; i++) {
            _bindBoth(nodes[i], safes[i]);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Type lifecycle
    // ---------------------------------------------------------------------------------------

    function registerServiceType(
        uint256 typeSeed,
        uint256 requirementSeed,
        uint256 burnSeed,
        uint256 safeSeed
    )
        external
    {
        bytes32 serviceType = _pickType(typeSeed);
        if (registry.isServiceType(serviceType)) {
            return;
        }
        address owner = _pickSafe(safeSeed);
        uint256 fee = registry.typeRegistrationFee();
        if (token.balanceOf(owner) < fee) {
            return;
        }

        address requirement = requirementOptions[bound(requirementSeed, 0, 2)];
        uint256 registrationBurn = bound(burnSeed, 0, MAX_AMOUNT);
        uint256 updateBurn = bound(burnSeed >> 8, 0, MAX_AMOUNT);

        vm.prank(owner);
        registry.registerServiceType(serviceType, IServiceRequirement(requirement), registrationBurn, updateBurn);

        ghostRegistered[serviceType] = true;
        ghostOwner[serviceType] = owner;
        if (registry.typeCount() > ghostMaxTypeCount) {
            ghostMaxTypeCount = registry.typeCount();
        }
    }

    function setRequirement(uint256 typeSeed, uint256 requirementSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address owner = ghostOwner[serviceType];
        if (!registry.isServiceType(serviceType) || owner == address(0)) {
            return;
        }

        vm.prank(owner);
        registry.setRequirement(serviceType, IServiceRequirement(requirementOptions[bound(requirementSeed, 0, 2)]));
    }

    function setSelfRegistrationBurn(uint256 typeSeed, uint256 amountSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address owner = ghostOwner[serviceType];
        if (!registry.isServiceType(serviceType) || owner == address(0)) {
            return;
        }

        vm.prank(owner);
        registry.setSelfRegistrationBurn(serviceType, bound(amountSeed, 0, MAX_AMOUNT));
    }

    function setSelfUpdateBurn(uint256 typeSeed, uint256 amountSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address owner = ghostOwner[serviceType];
        if (!registry.isServiceType(serviceType) || owner == address(0)) {
            return;
        }

        vm.prank(owner);
        registry.setSelfUpdateBurn(serviceType, bound(amountSeed, 0, MAX_AMOUNT));
    }

    /// @dev A new owner of zero abandons the type, which freezes its configuration forever.
    function transferTypeOwnership(uint256 typeSeed, uint256 ownerSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address owner = ghostOwner[serviceType];
        if (!registry.isServiceType(serviceType) || owner == address(0)) {
            return;
        }

        uint256 choice = bound(ownerSeed, 0, SAFE_COUNT);
        address newOwner = choice == SAFE_COUNT ? address(0) : safes[choice];

        vm.prank(owner);
        registry.transferTypeOwnership(serviceType, newOwner);

        ghostOwner[serviceType] = newOwner;
        if (newOwner == address(0)) {
            ghostAbandoned[serviceType] = true;
            ghostFrozenRequirement[serviceType] = address(registry.requirements(serviceType));
            ghostFrozenRegistrationBurn[serviceType] = registry.selfRegistrationBurn(serviceType);
            ghostFrozenUpdateBurn[serviceType] = registry.selfUpdateBurn(serviceType);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Self-service entry path
    // ---------------------------------------------------------------------------------------

    function selfRegister(uint256 typeSeed, uint256 nodeSeed, uint256 metadataSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address node = _pickNode(nodeSeed);
        if (!registry.isServiceType(serviceType) || registry.isRegistered(serviceType, node)) {
            return;
        }

        address safe = _boundSafeOf(node);
        if (safe == address(0)) {
            return;
        }
        bytes memory metadata = _metadata(metadataSeed);

        IServiceRequirement requirement = registry.requirements(serviceType);
        if (address(requirement) != address(0)) {
            if (!requirement.canRegister(serviceType, safe, node)) {
                return;
            }
            if (!requirement.validateMetadata(serviceType, node, metadata)) {
                return;
            }
        }
        if (token.balanceOf(safe) < registry.selfRegistrationBurn(serviceType)) {
            return;
        }

        vm.prank(safe);
        registry.selfRegister(serviceType, node, metadata);
    }

    function selfUpdate(uint256 typeSeed, uint256 nodeSeed, uint256 metadataSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address node = _pickNode(nodeSeed);
        if (!registry.isRegistered(serviceType, node)) {
            return;
        }

        address safe = _boundSafeOf(node);
        if (safe == address(0)) {
            return;
        }
        bytes memory metadata = _metadata(metadataSeed);

        IServiceRequirement requirement = registry.requirements(serviceType);
        if (address(requirement) != address(0) && !requirement.validateMetadata(serviceType, node, metadata)) {
            return;
        }
        if (token.balanceOf(safe) < registry.selfUpdateBurn(serviceType)) {
            return;
        }

        vm.prank(safe);
        registry.selfUpdate(serviceType, node, metadata);
    }

    /// @dev Invariant I6. This action needs no policy test and no balance test.
    function selfDeregister(uint256 typeSeed, uint256 nodeSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address node = _pickNode(nodeSeed);
        if (!registry.isRegistered(serviceType, node)) {
            return;
        }

        address safe = _boundSafeOf(node);
        if (safe == address(0)) {
            return;
        }

        vm.prank(safe);
        registry.selfDeregister(serviceType, node);
    }

    // ---------------------------------------------------------------------------------------
    // Hostile actions - invariant I9
    // ---------------------------------------------------------------------------------------

    /**
     * @dev An actor that is not the bound Safe attempts an entry write.
     *
     * The call is raw, so a rejection is a false boolean and never a revert. Two counters record
     * a violation: a write that succeeded for the wrong actor, and an entry that changed even
     * though the call failed.
     */
    function hostileEntryWrite(uint256 actorSeed, uint256 typeSeed, uint256 nodeSeed, uint256 opSeed) external {
        bytes32 serviceType = _pickType(typeSeed);
        address node = _pickNode(nodeSeed);
        address actor = _pickHostileActor(actorSeed);

        address boundSafe = _boundSafeOf(node);
        if (actor == boundSafe) {
            return;
        }

        bytes memory data;
        uint256 op = bound(opSeed, 0, 2);
        if (op == 0) {
            data = abi.encodeWithSelector(HoprServiceRegistry.selfRegister.selector, serviceType, node, hex"ff");
        } else if (op == 1) {
            data = abi.encodeWithSelector(HoprServiceRegistry.selfUpdate.selector, serviceType, node, hex"ff");
        } else {
            data = abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, serviceType, node);
        }

        bytes32 before = _entryHash(serviceType, node);
        vm.prank(actor);
        (bool success,) = address(registry).call(data);

        if (success) {
            ghostUnauthorizedEntryWrites++;
        } else if (_entryHash(serviceType, node) != before) {
            ghostSilentEntryChanges++;
        }
    }

    // ---------------------------------------------------------------------------------------
    // Admin, manager and token movement
    // ---------------------------------------------------------------------------------------

    function setTypeRegistrationFee(uint256 amountSeed) external {
        vm.prank(manager);
        registry.setTypeRegistrationFee(bound(amountSeed, 0, MAX_AMOUNT));
    }

    /// @dev Both instances carry the same bindings, so the probe always passes and entries stay writable.
    function swapNodeSafeRegistry(uint256 seed) external {
        MockNodeSafeRegistry target = bound(seed, 0, 1) == 0
            ? MockNodeSafeRegistry(address(bindingsA))
            : MockNodeSafeRegistry(address(bindingsB));
        address probeNode = nodes[0];
        address expectedSafe = target.nodeToSafe(probeNode);
        if (expectedSafe == address(0)) {
            return;
        }

        vm.prank(admin);
        registry.setNodeSafeRegistry(INodeSafeRegistry(address(target)), probeNode, expectedSafe);
    }

    /// @dev A Safe rotation. Both instances stay in step, so authority never gets stranded.
    function rebindNode(uint256 nodeSeed, uint256 safeSeed) external {
        uint256 index = bound(nodeSeed, 0, BOUND_NODE_COUNT - 1);
        _bindBoth(nodes[index], _pickSafe(safeSeed));
    }

    /// @dev A stray transfer into the registry. Invariant I4 allows exactly the tracked amount.
    function donate(uint256 amountSeed, uint256 safeSeed) external {
        address donor = _pickSafe(safeSeed);
        uint256 amount = bound(amountSeed, 0, MAX_AMOUNT);
        if (token.balanceOf(donor) < amount) {
            return;
        }

        vm.prank(donor);
        bool success = token.transfer(address(registry), amount);
        require(success, "Token transfer failed");
        ghostDonated += amount;
    }

    function recoverTokens(uint256 safeSeed) external {
        vm.prank(admin);
        registry.recoverTokens(IERC20(address(token)), _pickSafe(safeSeed));
        ghostDonated = 0;
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _bindBoth(address node, address safe) internal {
        bindingsA.setBinding(node, safe);
        bindingsB.setBinding(node, safe);
    }

    /// @dev The bound Safe as the registry reads it right now, through the current pointer.
    function _boundSafeOf(address node) internal view returns (address) {
        return registry.nodeSafeRegistry().nodeToSafe(node);
    }

    function _entryHash(bytes32 serviceType, address node) internal view returns (bytes32) {
        HoprServiceRegistry.Entry memory entry = registry.getEntry(serviceType, node);
        return keccak256(abi.encode(entry.metadata, entry.registeredAt, entry.updatedAt));
    }

    function _pickType(uint256 seed) internal view returns (bytes32) {
        return serviceTypes[bound(seed, 0, TYPE_COUNT - 1)];
    }

    function _pickSafe(uint256 seed) internal view returns (address) {
        return safes[bound(seed, 0, SAFE_COUNT - 1)];
    }

    function _pickNode(uint256 seed) internal view returns (address) {
        return nodes[bound(seed, 0, NODE_COUNT - 1)];
    }

    /// @dev Hostile actors include the admin and the manager, so I9 is tested against both roles.
    function _pickHostileActor(uint256 seed) internal view returns (address) {
        uint256 choice = bound(seed, 0, 3 + SAFE_COUNT - 1);
        if (choice == 0) {
            return admin;
        }
        if (choice == 1) {
            return manager;
        }
        if (choice == 2) {
            return stranger;
        }
        return safes[choice - 3];
    }

    function _metadata(uint256 seed) internal pure returns (bytes memory metadata) {
        uint256 length = bound(seed, 0, 64);
        metadata = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            metadata[i] = bytes1(uint8(seed >> (i % 32)));
        }
    }
}
