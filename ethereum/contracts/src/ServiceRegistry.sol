// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {
    AccessControlDefaultAdminRules
} from "openzeppelin-contracts-5.4.0/access/extensions/AccessControlDefaultAdminRules.sol";
import { ReentrancyGuard } from "openzeppelin-contracts-5.4.0/utils/ReentrancyGuard.sol";
import { IERC20, SafeERC20 } from "openzeppelin-contracts-5.4.0/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "openzeppelin-contracts-5.4.0/utils/structs/EnumerableSet.sol";
import { IServiceRequirement } from "./interfaces/IServiceRequirement.sol";
import { IERC777 } from "./static/openzeppelin-contracts/ERC777.sol";

/**
 * @dev Minimal compile target for HoprNodeSafeRegistry. The registry reads the node-to-Safe
 * binding on every entry write. It never caches the result.
 */
interface INodeSafeRegistry {
    function nodeToSafe(address nodeAddress) external view returns (address);
}

/**
 * @dev Events of HoprServiceRegistry. There is one canonical event for each state mutation.
 *
 * These events live in a separate abstract contract, so that the registry and its tests both
 * inherit them. This follows the convention of this repository.
 *
 * Notes for indexers:
 * - An indexed `bytes32` service type carries the id itself as the topic. A consumer can filter
 *   by exact type without a hash. Right-padded ASCII stays readable in raw logs.
 * - The `safe` field of an entry event is always `msg.sender`. The binding check guarantees that
 *   this address is the bound Safe of the node at write time.
 * - The `burned` field and the `feeBurned` field are zero when the applicable amount is zero.
 *   They make the log stream sufficient for burn accounting. An indexer does not need to join the
 *   logs of the token.
 * - The events embed timestamps, so an indexer rebuilds an entry without a block lookup for each
 *   log. Registration sets `updatedAt` to `registeredAt`, so `Registered` alone initializes an
 *   entry.
 * - The registry emits its events before the logs of the token, inside the same receipt. Effects
 *   come before interactions. The order is: registry events, then any log of the `tokensToSend`
 *   hook of the holder, then the transfer log and the burn log of the token.
 * - These events and the inherited OpenZeppelin role events rebuild the full state and the full
 *   configuration, with zero `eth_call` requests.
 */
abstract contract HoprServiceRegistryEvents {
    /// @dev The constructor emits this event once. It carries every immutable value of the deployment.
    event RegistryInitialized(uint256 version, address admin, address manager, address token, uint48 initialAdminDelay);

    /// @dev The constructor also emits this event, with `oldNodeSafeRegistry` set to `address(0)`.
    event NodeSafeRegistryUpdated(address oldNodeSafeRegistry, address newNodeSafeRegistry);

    /// @dev The constructor also emits this event. It then carries the initial fee.
    event TypeRegistrationFeeUpdated(uint256 amount);

    /// @dev A new service type exists. `feeBurned` is the global type-registration fee.
    event ServiceTypeRegistered(bytes32 indexed serviceType, address indexed owner, uint256 feeBurned);

    /// @dev Registration emits `0 -> owner`. Abandonment emits `owner -> 0`, and it is one-way.
    event TypeOwnershipTransferred(bytes32 indexed serviceType, address oldOwner, address newOwner);

    /// @dev `registerServiceType` also emits this event. A `requirement` of 0 means an open type.
    event RequirementUpdated(bytes32 indexed serviceType, address requirement);

    /// @dev `registerServiceType` also emits this event.
    event SelfRegistrationBurnUpdated(bytes32 indexed serviceType, uint256 amount);

    /// @dev `registerServiceType` also emits this event.
    event SelfUpdateBurnUpdated(bytes32 indexed serviceType, uint256 amount);

    /// @dev A new entry exists. `registeredAt` is also the initial value of `updatedAt`.
    event Registered(
        bytes32 indexed serviceType,
        address indexed node,
        address indexed safe,
        bytes metadata,
        uint48 registeredAt,
        uint256 burned
    );

    /// @dev New metadata replaced the old metadata. `registeredAt` stays, and this event omits it.
    event Updated(
        bytes32 indexed serviceType,
        address indexed node,
        address indexed safe,
        bytes metadata,
        uint48 updatedAt,
        uint256 burned
    );

    /// @dev An entry is gone. This path is always free of policy and of payment.
    event Deregistered(bytes32 indexed serviceType, address indexed node, address indexed safe);

    /// @dev The admin swept out stray ERC-20 tokens.
    event TokensRecovered(address token, address to, uint256 amount);
}

/**
 *    &&&&
 *    &&&&
 *    &&&&
 *    &&&&  &&&&&&&&&       &&&&&&&&&&&&          &&&&&&&&&&/   &&&&.&&&&&&&&&
 *    &&&&&&&&&   &&&&&   &&&&&&     &&&&&,     &&&&&    &&&&&  &&&&&&&&   &&&&
 *     &&&&&&      &&&&  &&&&#         &&&&   &&&&&       &&&&& &&&&&&     &&&&&
 *     &&&&&       &&&&/ &&&&           &&&& #&&&&        &&&&  &&&&&
 *     &&&&         &&&& &&&&&         &&&&  &&&&        &&&&&  &&&&&
 *     %%%%        /%%%%   %%%%%%   %%%%%%   %%%%  %%%%%%%%%    %%%%%
 *    %%%%%        %%%%      %%%%%%%%%%%    %%%%   %%%%%%       %%%%
 *                                          %%%%
 *                                          %%%%
 *                                          %%%%
 *
 * @title Permissionless on-chain registry of the services that HOPR nodes offer
 *
 * @dev This registry holds the services that HOPR nodes provide and that clients reach over
 * Sessions. The first service type is `gvpn:exit`, for GnosisVPN exit-node discovery. The
 * registry treats type ids and metadata as opaque data. Each type documents its own metadata
 * schema and its own Session-level protocol.
 *
 * The registry is permissionless at two levels:
 * - Anyone can register a service type. The registrant pays the global type-registration fee and
 *   becomes the owner of that type.
 * - Any bound node operator can register entries under any tye. The policy of that type and the
 *   burns of that type apply.
 *
 * Three functions write entries: `selfRegister`, `selfUpdate` and `selfDeregister`. They are the
 * only entry write path, and three gates apply to them. The first gate is authority: the caller
 * must be the Safe that HoprNodeSafeRegistry binds to the node. The second gate is policy: the
 * requirement contract of the type, if the type has one. The third gate is payment: the entry
 * burn of the type. No privileged role can create, modify or remove the entry of another party.
 * This limit applies to the admin, to the manager and to the type owner.
 *
 * The contract is not upgradeable. There is no proxy and no migration path. The error surface,
 * the view surface, and the split between the registration burn and the update burn therefore
 * ship complete at deployment.
 *
 * Reentrancy is a real surface, not defense in depth. wxHOPR is an ERC-777 token. Its
 * `transferFrom` calls the `tokensToSend` hook of the holder before it moves the balance, and
 * before it decrements the allowance. Caller-controlled code therefore runs inside every paid
 * write.
 *
 * Two defenses answer this. One shared `nonReentrant` guard covers `registerServiceType`, the
 * four type owner setters and the three self-service functions. Checks-effects-interactions is
 * also mandatory: the token pull is the last action of every paid path, after all state writes
 * and all registry events. The hook then sees the consistent state that the call already wrote,
 * and it can re-enter nothing. The admin functions and the manager function pull no tokens, and
 * they carry no guard.
 */
contract HoprServiceRegistry is AccessControlDefaultAdminRules, ReentrancyGuard, HoprServiceRegistryEvents {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    struct Entry {
        uint48 registeredAt; // block timestamp of the registration \ these two pack
        uint48 updatedAt; // block timestamp of the last update      / into one slot
        bytes metadata; // opaque data, with a schema that belongs to the service type
    } // registration sets updatedAt to registeredAt

    /// @dev The service type id must not be zero.
    error ZeroServiceType();
    /// @dev The service type is not registered. `isServiceType` is the authoritative existence test.
    error UnknownServiceType(bytes32 serviceType);
    /// @dev The service type is already registered. Type ids go to the first payer.
    error ServiceTypeExists(bytes32 serviceType);
    /// @dev The caller does not own the type. An abandoned type has an owner of 0, which nobody matches.
    error NotTypeOwner(bytes32 serviceType, address caller, address owner);
    /// @dev The recipient of `recoverTokens` must not be zero.
    error ZeroRecipient();
    /// @dev A non-zero requirement must have code, because the registry staticcalls it.
    error RequirementNotContract(address requirement);
    /// @dev The NodeSafeRegistry target must have code. This error also covers the zero address.
    error NodeSafeRegistryNotContract(address nodeSafeRegistry);
    /// @dev The probe on a new NodeSafeRegistry target did not return the expected non-zero Safe.
    error NodeSafeRegistryProbeFailed(
        address nodeSafeRegistry, address probeNode, address expectedSafe, address actualSafe
    );
    /// @dev An entry for this type and node already exists. The registry tests this before the binding.
    error AlreadyRegistered(bytes32 serviceType, address node);
    /// @dev No entry exists for this type and node.
    error NotRegistered(bytes32 serviceType, address node);
    /// @dev The caller is not the bound Safe of the node. A `boundSafe` of 0 means an unbound node.
    error CallerNotNodeSafe(address node, address caller, address boundSafe);
    /// @dev The metadata is longer than the permanent `MAX_METADATA_LENGTH` cap.
    error MetadataTooLong(uint256 length, uint256 max);
    /// @dev The requirement of the type returned a clean `false` from `canRegister`.
    error RegistrationDenied(bytes32 serviceType, address caller, address node);
    /// @dev The requirement of the type returned a clean `false` from `validateMetadata`.
    error MetadataRejected(bytes32 serviceType, address node);
    /// @dev The wxHOPR token must have code. This error also covers the zero address.
    error WxHoprTokenNotContract(address token);
    /// @dev `initialManager` must not be zero. The OpenZeppelin base rejects a zero admin separately.
    error ZeroManager();
    /// @dev The initial admin delay must be non-zero and at most 30 days. A units mistake is near-permanent.
    error InvalidAdminDelay(uint48 delay, uint48 maxDelay);

    /// @dev `RegistryInitialized` carries this value.
    uint256 public constant VERSION = 1;

    /// @dev This role has one power only: `setTypeRegistrationFee`.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /**
     * @dev Hard cap on the metadata bytes of an entry. Every write path applies it.
     *
     * The burn prices one write, not the size of that write. Without a cap, repeated writes can
     * grow the entries of a type until a list view exceeds the `eth_call` gas limit of an RPC
     * node. This cap is permanent, and nobody can raise it. A type can make it smaller through
     * `validateMetadata`.
     */
    uint256 public constant MAX_METADATA_LENGTH = 2048;

    /**
     * @dev Upper bound on the admin delay of the constructor. This constant is private, so that
     * the external surface stays exactly what the specification freezes. `InvalidAdminDelay`
     * carries the value.
     */
    uint48 private constant _MAX_ADMIN_DELAY = 30 days;

    /**
     * @dev The payment token. Every fee is wxHOPR, pulled by allowance and then burned.
     */
    address public immutable WXHOPR_TOKEN;

    /**
     * @dev The authority root of every entry write. This pointer is mutable on purpose, because
     * HoprNodeSafeRegistry versions do migrate. An immutable pointer would permanently disable
     * every entry write path for a node that is bound in a successor instance.
     *
     * The admin can swap this pointer. The setter applies a code check and a probe, and it emits
     * an event. This is the largest trusted-admin power of the registry.
     */
    INodeSafeRegistry public nodeSafeRegistry;

    /// @dev The global fee that `registerServiceType` burns. The manager sets it.
    uint256 public typeRegistrationFee;

    /// @dev Per-type governance. A value of `address(0)` means abandoned, and abandonment is one-way.
    mapping(bytes32 => address) public typeOwner;

    /// @dev Per-type policy. A value of `address(0)` means no requirement, that is, an open type.
    mapping(bytes32 => IServiceRequirement) public requirements;

    /// @dev Per-type burn of `selfRegister`, in 18-decimal wxHOPR units. The type owner sets it.
    mapping(bytes32 => uint256) public selfRegistrationBurn;

    /// @dev Per-type burn of `selfUpdate`, in 18-decimal wxHOPR units. The type owner sets it.
    mapping(bytes32 => uint256) public selfUpdateBurn;

    /// @dev The type set. It is unbounded and an attacker can grow it, so enumeration is paginated.
    EnumerableSet.Bytes32Set private _types;

    /// @dev Per-type node set. This is the authoritative entry existence test. Its order is unstable.
    mapping(bytes32 => EnumerableSet.AddressSet) private _nodes;

    /// @dev Per-type entry records.
    mapping(bytes32 => mapping(address => Entry)) private _entries;

    // ---------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------

    /**
     * @dev The live authority test behind every entry write.
     *
     * The registry reads the binding on every call and never caches it. A Safe rotation in
     * HoprNodeSafeRegistry therefore carries the registry authority with it.
     *
     * This staticcall has no try/catch. A target that reverts, or that returns malformed data,
     * surfaces raw.
     */
    modifier requireNodeSafe(address node) {
        address boundSafe = nodeSafeRegistry.nodeToSafe(node);
        if (boundSafe == address(0) || msg.sender != boundSafe) {
            revert CallerNotNodeSafe(node, msg.sender, boundSafe);
        }
        _;
    }

    /// @dev A non-zero requirement must have code, because the registry staticcalls it.
    modifier requireRequirementIsContract(address requirement) {
        if (requirement != address(0) && requirement.code.length == 0) {
            revert RequirementNotContract(requirement);
        }
        _;
    }

    /// @dev The permanent metadata cap. Every write path applies it.
    modifier requireMetadataFits(bytes calldata metadata) {
        if (metadata.length > MAX_METADATA_LENGTH) {
            revert MetadataTooLong(metadata.length, MAX_METADATA_LENGTH);
        }
        _;
    }

    /**
     * @dev The shared prefix of all four type owner functions.
     *
     * An abandoned type has an owner of 0. No caller can ever match that value, so every owner
     * function is permanently dead for such a type.
     */
    modifier requireTypeOwner(bytes32 serviceType) {
        if (!_types.contains(serviceType)) {
            revert UnknownServiceType(serviceType);
        }
        address owner = typeOwner[serviceType];
        if (msg.sender != owner) {
            revert NotTypeOwner(serviceType, msg.sender, owner);
        }
        _;
    }

    // ---------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------
    /**
     * @dev Validates the immutable configuration. Emits the three events that rebuild the
     * deployment from logs alone.
     *
     * The constructor applies no probe to `nodeSafeRegistry_`. A deployment is rehearsed and
     * reviewed, and a later pointer swap is not.
     *
     * The OpenZeppelin base rejects a zero `initialAdmin` with `AccessControlInvalidDefaultAdmin`
     * before this body runs.
     *
     * @param wxHopr_ the payment token, which must have code
     * @param nodeSafeRegistry_ the initial authority root, which must have code
     * @param initialAdminDelay_ the DefaultAdminRules delay, non-zero and at most 30 days
     * @param initialAdmin the holder of `DEFAULT_ADMIN_ROLE`, which must be non-zero
     * @param initialManager the holder of `MANAGER_ROLE`, which must be non-zero
     * @param initialTypeRegistrationFee the type-registration fee at launch, best kept non-zero
     */
    constructor(
        address wxHopr_,
        INodeSafeRegistry nodeSafeRegistry_,
        uint48 initialAdminDelay_,
        address initialAdmin,
        address initialManager,
        uint256 initialTypeRegistrationFee
    )
        AccessControlDefaultAdminRules(initialAdminDelay_, initialAdmin)
    {
        if (address(wxHopr_).code.length == 0) {
            revert WxHoprTokenNotContract(address(wxHopr_));
        }
        if (address(nodeSafeRegistry_).code.length == 0) {
            revert NodeSafeRegistryNotContract(address(nodeSafeRegistry_));
        }
        if (initialManager == address(0)) {
            revert ZeroManager();
        }
        if (initialAdminDelay_ == 0 || initialAdminDelay_ > _MAX_ADMIN_DELAY) {
            revert InvalidAdminDelay(initialAdminDelay_, _MAX_ADMIN_DELAY);
        }

        WXHOPR_TOKEN = wxHopr_;
        nodeSafeRegistry = nodeSafeRegistry_;
        typeRegistrationFee = initialTypeRegistrationFee;
        _grantRole(MANAGER_ROLE, initialManager);

        emit RegistryInitialized(VERSION, initialAdmin, initialManager, address(wxHopr_), initialAdminDelay_);
        emit NodeSafeRegistryUpdated(address(0), address(nodeSafeRegistry_));
        emit TypeRegistrationFeeUpdated(initialTypeRegistrationFee);
    }

    // ---------------------------------------------------------------------------------------
    // Type lifecycle (section 5.1)
    // ---------------------------------------------------------------------------------------

    /**
     * @dev Registers a new service type. Anyone can call it. The caller becomes the type owner and
     * pays the global type-registration fee.
     *
     * The check order is normative:
     * 1. `ZeroServiceType`, if the id is zero.
     * 2. `ServiceTypeExists`, if the type is already registered.
     * 3. `RequirementNotContract`, unless `requirement` is `address(0)` or has code.
     * 4. Effects, then the five registration events.
     * 5. Fee collection, last. The ERC-777 hook of the payer then sees a complete type.
     *
     * Type ids go to the first payer. The deployment batch must therefore claim every canonical id
     * before anyone announces the address of the registry.
     *
     * @param serviceType the `bytes32` id, by convention right-padded ASCII, and never zero
     * @param requirement the policy contract of the type, or `address(0)` for an open type
     * @param registrationBurn the `selfRegister` burn of the type
     * @param updateBurn the `selfUpdate` burn of the type
     */
    function registerServiceType(
        bytes32 serviceType,
        IServiceRequirement requirement,
        uint256 registrationBurn,
        uint256 updateBurn
    )
        external
        nonReentrant
        requireRequirementIsContract(address(requirement))
    {
        if (serviceType == bytes32(0)) {
            revert ZeroServiceType();
        }
        if (_types.contains(serviceType)) {
            revert ServiceTypeExists(serviceType);
        }

        uint256 fee = typeRegistrationFee;

        _types.add(serviceType);
        typeOwner[serviceType] = msg.sender;
        requirements[serviceType] = requirement;
        selfRegistrationBurn[serviceType] = registrationBurn;
        selfUpdateBurn[serviceType] = updateBurn;

        emit ServiceTypeRegistered(serviceType, msg.sender, fee);
        emit TypeOwnershipTransferred(serviceType, address(0), msg.sender);
        emit RequirementUpdated(serviceType, address(requirement));
        emit SelfRegistrationBurnUpdated(serviceType, registrationBurn);
        emit SelfUpdateBurnUpdated(serviceType, updateBurn);

        _collectFee(fee);
    }

    /**
     * @dev Replaces the policy contract of a type. Only the type owner can call it.
     *
     * A value of `address(0)` opens the type. A deny-all requirement is the emergency stop of one
     * type.
     *
     * The check order is `UnknownServiceType`, then `NotTypeOwner`, then `RequirementNotContract`.
     *
     * @param serviceType the type to reconfigure
     * @param requirement the new policy contract, or `address(0)` for none
     */
    function setRequirement(
        bytes32 serviceType,
        IServiceRequirement requirement
    )
        external
        nonReentrant
        requireRequirementIsContract(address(requirement))
        requireTypeOwner(serviceType)
    {
        requirements[serviceType] = requirement;
        emit RequirementUpdated(serviceType, address(requirement));
    }

    /**
     * @dev Sets the `selfRegister` burn of a type. Only the type owner can call it.
     * @param serviceType the type to reconfigure
     * @param amount the new burn in 18-decimal wxHOPR units, which can be zero
     */
    function setSelfRegistrationBurn(
        bytes32 serviceType,
        uint256 amount
    )
        external
        nonReentrant
        requireTypeOwner(serviceType)
    {
        selfRegistrationBurn[serviceType] = amount;
        emit SelfRegistrationBurnUpdated(serviceType, amount);
    }

    /**
     * @dev Sets the `selfUpdate` burn of a type. Only the type owner can call it.
     *
     * A cheaper update burn than the registration burn is correct, because the registration burn
     * already prices the worst-case footprint. A free update is dangerous: it lets one paid entry
     * produce unlimited metadata rewrites and unlimited event spam.
     *
     * @param serviceType the type to reconfigure
     * @param amount the new burn in 18-decimal wxHOPR units, which can be zero
     */
    function setSelfUpdateBurn(bytes32 serviceType, uint256 amount)
        external
        nonReentrant
        requireTypeOwner(serviceType)
    {
        selfUpdateBurn[serviceType] = amount;
        emit SelfUpdateBurnUpdated(serviceType, amount);
    }

    /**
     * @dev Transfers the governance of a type. The transfer is single-step. The owner is expected
     * to be a Safe that executes reviewed transactions, and a mistyped target is unrecoverable.
     *
     * A `newOwner` of `address(0)` abandons the type. Abandonment is one-way and has no re-claim
     * path. Every owner function then reverts with `NotTypeOwner` forever, which freezes the
     * requirement and the burns of the type. Entries continue to register, to update and to
     * deregister under the frozen rules.
     *
     * @param serviceType the type to transfer
     * @param newOwner the new owner, or `address(0)` to abandon the type
     */
    function transferTypeOwnership(
        bytes32 serviceType,
        address newOwner
    )
        external
        nonReentrant
        requireTypeOwner(serviceType)
    {
        address oldOwner = typeOwner[serviceType];
        typeOwner[serviceType] = newOwner;
        emit TypeOwnershipTransferred(serviceType, oldOwner, newOwner);
    }

    // ---------------------------------------------------------------------------------------
    // Self-service entry path (section 5.2) - the only entry write path
    // ---------------------------------------------------------------------------------------

    /**
     * @dev Creates an entry for `node` under `serviceType`. The caller must be the Safe that
     * HoprNodeSafeRegistry binds to `node` at this moment.
     *
     * The check order is normative:
     * 1. `UnknownServiceType`, if the type is not registered.
     * 2. `AlreadyRegistered`, for any existing entry. This test comes before the binding test, so
     *    an existing entry surfaces as `AlreadyRegistered` and not as `CallerNotNodeSafe`.
     * 3. `CallerNotNodeSafe`, unless the caller is the non-zero bound Safe of the node. A
     *    `boundSafe` of zero means an unbound node. This case also covers a `node` of
     *    `address(0)`, because zero can never be bound. The path therefore carries no separate
     *    zero-node test.
     * 4. `MetadataTooLong`.
     * 5. If the type has a requirement: `canRegister`, then `validateMetadata`.
     * 6. Effects, then `Registered`.
     * 7. Fee collection, last.
     *
     * @param serviceType the type that receives the entry
     * @param node the native chain address of the node
     * @param metadata opaque metadata of at most `MAX_METADATA_LENGTH` bytes
     */
    function selfRegister(
        bytes32 serviceType,
        address node,
        bytes calldata metadata
    )
        external
        nonReentrant
        requireNodeSafe(node)
        requireMetadataFits(metadata)
    {
        if (!_types.contains(serviceType)) {
            revert UnknownServiceType(serviceType);
        }
        if (_nodes[serviceType].contains(node)) {
            revert AlreadyRegistered(serviceType, node);
        }

        IServiceRequirement requirement = requirements[serviceType];
        if (address(requirement) != address(0)) {
            if (!requirement.canRegister(serviceType, msg.sender, node)) {
                revert RegistrationDenied(serviceType, msg.sender, node);
            }
            if (!requirement.validateMetadata(serviceType, node, metadata)) {
                revert MetadataRejected(serviceType, node);
            }
        }

        uint48 nowTs = uint48(block.timestamp);
        uint256 burn = selfRegistrationBurn[serviceType];

        _nodes[serviceType].add(node);
        _entries[serviceType][node] = Entry({ metadata: metadata, registeredAt: nowTs, updatedAt: nowTs });

        emit Registered(serviceType, node, msg.sender, metadata, nowTs, burn);

        _collectFee(burn);
    }

    /**
     * @dev Replaces the metadata of an entry. `registeredAt` stays, and `updatedAt` moves to now.
     *
     * The check order is normative:
     * 1. `NotRegistered`, if the entry is absent. This test also covers type existence, because an
     *    entry can only exist under a registered type. An unknown type therefore gives
     *    `NotRegistered`, and not `UnknownServiceType`.
     * 2. Binding.
     * 3. `MetadataTooLong`.
     * 4. If the type has a requirement: `validateMetadata` only. The registry never repeats the
     *    eligibility test, so a stricter policy freezes metadata that does not comply instead of
     *    removal of the entry.
     * 5. Effects, then `Updated`.
     * 6. Fee collection, last.
     *
     * @param serviceType the type that holds the entry
     * @param node the native chain address of the node
     * @param metadata the replacement metadata, of at most `MAX_METADATA_LENGTH` bytes
     */
    function selfUpdate(
        bytes32 serviceType,
        address node,
        bytes calldata metadata
    )
        external
        nonReentrant
        requireNodeSafe(node)
        requireMetadataFits(metadata)
    {
        if (!_nodes[serviceType].contains(node)) {
            revert NotRegistered(serviceType, node);
        }

        IServiceRequirement requirement = requirements[serviceType];
        if (address(requirement) != address(0)) {
            if (!requirement.validateMetadata(serviceType, node, metadata)) {
                revert MetadataRejected(serviceType, node);
            }
        }

        uint48 nowTs = uint48(block.timestamp);
        uint256 burn = selfUpdateBurn[serviceType];

        Entry storage entry = _entries[serviceType][node];
        entry.metadata = metadata;
        entry.updatedAt = nowTs;

        emit Updated(serviceType, node, msg.sender, metadata, nowTs, burn);

        _collectFee(burn);
    }

    /**
     * @dev Removes an entry. The binding is the only gate. Policy and payment never apply here.
     *
     * A bound node can always delist itself. This holds under a deny-all requirement, and with a
     * zero token balance and a zero allowance.
     *
     * The check order is normative: `NotRegistered`, then the binding, then the effects and
     * `Deregistered`.
     *
     * Deregistration removes state, but not history. The metadata stays visible in the event log
     * forever.
     *
     * @param serviceType the type that holds the entry
     * @param node the native chain address of the node
     */
    function selfDeregister(bytes32 serviceType, address node) external nonReentrant requireNodeSafe(node) {
        if (!_nodes[serviceType].contains(node)) {
            revert NotRegistered(serviceType, node);
        }

        _nodes[serviceType].remove(node);
        delete _entries[serviceType][node];

        emit Deregistered(serviceType, node, msg.sender);
    }

    // ---------------------------------------------------------------------------------------
    // Admin and manager (section 5.3)
    // ---------------------------------------------------------------------------------------

    /**
     * @dev Points the registry at a new authority root. Only the admin can call it, and there is
     * no timelock. The DefaultAdminRules delay protects the admin role itself, and nothing else.
     *
     * This power is an escalation. No other admin power touches entries, but a malicious target
     * can re-map the authority of any node. The code check and the probe stop honest mistakes, not
     * an attacker. The swap emits an event, so operators can monitor it.
     *
     * The probe must return exactly `expectedSafe`, and `expectedSafe` must itself be non-zero.
     * This proves that the target answers the expected ABI with reviewed data.
     *
     * @param nodeSafeRegistry_ the new target, which must have code
     * @param probeNode a node that is verified to be bound in the new target
     * @param expectedSafe the Safe that `probeNode` must resolve to, which must be non-zero
     */
    function setNodeSafeRegistry(
        INodeSafeRegistry nodeSafeRegistry_,
        address probeNode,
        address expectedSafe
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(nodeSafeRegistry_).code.length == 0) {
            revert NodeSafeRegistryNotContract(address(nodeSafeRegistry_));
        }

        address actualSafe = nodeSafeRegistry_.nodeToSafe(probeNode);
        if (expectedSafe == address(0) || actualSafe != expectedSafe) {
            revert NodeSafeRegistryProbeFailed(address(nodeSafeRegistry_), probeNode, expectedSafe, actualSafe);
        }

        address oldNodeSafeRegistry = address(nodeSafeRegistry);
        nodeSafeRegistry = nodeSafeRegistry_;
        emit NodeSafeRegistryUpdated(oldNodeSafeRegistry, address(nodeSafeRegistry_));
    }

    /**
     * @dev Sweeps out stray ERC-20 transfers. Only the admin can call it.
     *
     * The token balance of the registry is zero at rest, so any balance is stray.
     *
     * Native xDAI is not recoverable. The registry has no receive function, and a force-sent
     * balance stays stuck.
     *
     * @param token the token to sweep out
     * @param to the recipient, which must be non-zero
     */
    function recoverTokens(IERC20 token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) {
            revert ZeroRecipient();
        }

        uint256 amount = token.balanceOf(address(this));
        emit TokensRecovered(address(token), to, amount);

        token.safeTransfer(to, amount);
    }

    /**
     * @dev Sets the global type-registration fee. Only the manager can call it, and this is the
     * one power of the manager.
     *
     * The new fee applies to later `registerServiceType` calls only. A caller protects itself by
     * an approval of exactly the fee that it read at review time. A fee that rises at the same
     * time then reverts on the allowance instead of an overpayment.
     *
     * @param amount the new fee in 18-decimal wxHOPR units, which can be zero
     */
    function setTypeRegistrationFee(uint256 amount) external onlyRole(MANAGER_ROLE) {
        typeRegistrationFee = amount;
        emit TypeRegistrationFeeUpdated(amount);
    }

    // ---------------------------------------------------------------------------------------
    // Views (section 5.4) - these ship complete, because nobody can add one later
    // ---------------------------------------------------------------------------------------

    /**
     * @dev The only existence test for a service type.
     *
     * A `typeOwner[t]` of 0 also encodes a registered but abandoned type. A `requirements[t]` of 0
     * also encodes a registered but open type. Neither value means that the type is unregistered.
     */
    function isServiceType(bytes32 serviceType) external view returns (bool) {
        return _types.contains(serviceType);
    }

    /// @dev The number of registered types. This value never decreases, because types are permanent.
    function typeCount() external view returns (uint256) {
        return _types.length();
    }

    /**
     * @dev The type at `index`. The order is unstable across writes.
     *
     * This function reverts with the standard array out-of-bounds panic (0x32) when `index` is not
     * less than `typeCount()`.
     */
    function typeAt(uint256 index) external view returns (bytes32) {
        return _types.at(index);
    }

    /**
     * @dev Paginated type enumeration, and the only type enumeration that exists. The type set is
     * unbounded and an attacker can grow it, so there is no unpaginated variant.
     *
     * There is also no reverse lookup from a node over all types. That job belongs to an indexer
     * that reads the `Registered` stream and the `Deregistered` stream.
     *
     * An `offset` at or past the end returns an empty array. The last page truncates to
     * `min(limit, count - offset)`. A `limit` of 0 returns an empty array.
     *
     * The order is unstable, so a consumer must pin all pages of one scan to a single block tag.
     */
    function getServiceTypesPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        uint256 size = _pageSize(_types.length(), offset, limit);
        bytes32[] memory page = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            page[i] = _types.at(offset + i);
        }
        return page;
    }

    /**
     * @dev Every node that is registered under a type. This is a convenience for small types, and
     * `getEntriesPaginated` is the canonical read path.
     *
     * Deregistration swaps the last element into the hole, so the order is unstable. A consumer
     * must compare the result as a set, and never by position.
     */
    function getNodes(bytes32 serviceType) external view returns (address[] memory) {
        return _nodes[serviceType].values();
    }

    /// @dev Returns a zeroed `Entry` when the entry is absent. A `registeredAt` of 0 means absent.
    function getEntry(bytes32 serviceType, address node) external view returns (Entry memory) {
        return _entries[serviceType][node];
    }

    /// @dev Reports whether an entry exists for this type and node.
    function isRegistered(bytes32 serviceType, address node) external view returns (bool) {
        return _nodes[serviceType].contains(node);
    }

    /**
     * @dev Paginated entry enumeration, and the canonical read path. The two returned arrays share
     * one index: `nodes[i]` owns `entries[i]`.
     *
     * The bounds behave as in `getServiceTypesPaginated`.
     *
     * CAUTION: Keep `limit` small. Each entry carries up to `MAX_METADATA_LENGTH` bytes, so a
     * large page can exceed the `eth_call` response size limit of a public RPC node. A limit of 50
     * is a reasonable maximum for a type with large metadata.
     */
    function getEntriesPaginated(
        bytes32 serviceType,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory, Entry[] memory)
    {
        EnumerableSet.AddressSet storage nodeSet = _nodes[serviceType];
        uint256 size = _pageSize(nodeSet.length(), offset, limit);

        address[] memory nodes = new address[](size);
        Entry[] memory entries = new Entry[](size);
        for (uint256 i = 0; i < size; i++) {
            address node = nodeSet.at(offset + i);
            nodes[i] = node;
            entries[i] = _entries[serviceType][node];
        }
        return (nodes, entries);
    }

    /// @dev The number of entries under a type.
    function nodeCount(bytes32 serviceType) external view returns (uint256) {
        return _nodes[serviceType].length();
    }

    /**
     * @dev The node at `index` inside a type. The order is unstable across writes.
     *
     * This function reverts with the standard array out-of-bounds panic (0x32) when `index` is not
     * less than `nodeCount(serviceType)`.
     */
    function nodeAt(bytes32 serviceType, uint256 index) external view returns (address) {
        return _nodes[serviceType].at(index);
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /**
     * @dev Fee collection. Every paid path shares it, and it is always the last step.
     *
     * This function pulls exactly `amount` from `msg.sender`. It then burns exactly that amount
     * from the balance of the registry, and never `balanceOf`. A donation or a stray transfer
     * therefore cannot distort a burn event, and cannot be burned. `recoverTokens` reaches strays
     * only.
     *
     * The registry moves tokens from `msg.sender` only, and inside that same call only. A stale
     * unlimited approval to the registry is therefore not drainable by a third party.
     *
     * A zero amount skips all token interaction. This is what makes `selfDeregister` free, and
     * what makes a zero-burn type free.
     *
     * CAUTION: The `tokensToSend` hook of the payer runs on the line below. Every caller of this
     * function must complete its state writes and emit its event before it arrives here.
     */
    function _collectFee(uint256 amount) private {
        if (amount == 0) {
            return;
        }
        IERC20(address(WXHOPR_TOKEN)).safeTransferFrom(msg.sender, address(this), amount);
        IERC777(address(WXHOPR_TOKEN)).burn(amount, "");
    }

    /**
     * @dev The page size of both paginated views.
     *
     * The bounds test runs first, so `count - offset` cannot underflow. An `offset` of
     * `type(uint256).max` therefore gives an empty page.
     */
    function _pageSize(uint256 count, uint256 offset, uint256 limit) private pure returns (uint256) {
        if (offset >= count) {
            return 0;
        }
        uint256 available = count - offset;
        return limit < available ? limit : available;
    }
}
