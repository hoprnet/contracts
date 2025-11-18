// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { IERC1820Registry } from "openzeppelin-contracts-5.4.0/interfaces/IERC1820Registry.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts-upgradeable-5.4.0/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable-5.4.0/access/OwnableUpgradeable.sol";
import { ERC1967Proxy } from "openzeppelin-contracts-5.4.0/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC777 } from "./static/openzeppelin-contracts/ERC777.sol";
import { HoprMultiSig } from "./MultiSig.sol";
import { HoprLedger } from "./Ledger.sol";
import { HoprNodeSafeRegistry } from "./node-stake/NodeSafeRegistry.sol";
import { INDEX_SNAPSHOT_INTERVAL } from "./Channels.sol";
import {
    MAX_KEY_ID,
    KeyId,
    EnumerableKeyBindingSet,
    KeyBindingSet,
    KeyBindingWithSignature,
    KeyBindingWithSignatureTimestamp
} from "./utils/EnumerableKeyBindingSet.sol";

/// forge-lint:disable-next-item(mixed-case-variable)
abstract contract HoprAnnouncementsEvents {
    /**
     * @dev Emitted when a new key binding is created
     * Note that the key id uses uint256 format for gas saving reason.
     * The key id range is controlled to be within uint32 range in the KeyBindingSet library.
     */
    event KeyBinding(
        bytes32 ed25519_sig_0, bytes32 ed25519_sig_1, bytes32 ed25519_pub_key, address chain_key, uint256 key_id
    );

    /**
     * A node is announce with a multiaddress base which a peer can use to
     * construct a full p2p multiaddress.
     * Examples:
     *   /dns4/ams-2.bootstrap.libp2p.io/tcp/443/wss
     *   /ip6/2604:1380:2000:7a00::1/tcp/4001
     *   /ip4/147.75.83.83/tcp/4001
     *   /ip6/2604:1380:2000:7a00::1/udp/4001/quic
     *   /ip4/147.75.83.83/udp/4001/quic
     *   /dns6/ams-2.bootstrap.libp2p.io/tcp/443/wss
     */
    event AddressAnnouncement(address node, string baseMultiaddr);

    event RevokeAnnouncement(address node);

    event KeyBindingFeeUpdate(uint256 newFee, uint256 oldFee);
}

contract HoprAnnouncementsProxy is ERC1967Proxy {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _implementation, bytes memory data) ERC1967Proxy(_implementation, data) { }

    function implementation() public view returns (address) {
        return _implementation();
    }
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
 * Publishes transport-layer information in the hopr network.
 * The contract is UUPS upgradable and Ownable.
 *
 * Relay nodes MUST bind their off-chain keys to their on-chain identity
 * and announce a base multiaddress to be publicly reachable.
 * Edge nodes MUST bind their off-chain keys to their on-chain identity.
 * and they MAY announce a base multiaddress to be publicly reachable.
 *
 * A key id is a 4 byte unsigned integer, which is incremented on each new key binding.
 * The key id is used to retrieve the off-chain keys and the chain-key.
 * A unique key id is bound to a set of off-chain key and a chain-key (Ethereum address)
 * A node MAY bind multiple off-chain keys to the same chain-key.
 * A node MUST NOT bind the same off-chain keys to multiple chain-keys.
 * Key ids cannot be re-used or overwritten.
 * The range of valid key ids is [0, 2^32 - 1].
 *
 * When a node binds its off-chain keys, it MUST pay a fee in wxHOPR tokens.
 * The fee is burned by the contract.
 * The fee amount is set by the contract owner and can be updated.
 * The fee MAY be zero, if the contract owner decides so.
 *
 * The key binding process and announcement process are idempotent.
 *
 * The chain-key is used to retrieve the multiaddress base of a node.
 * By knowing the key id of a peer, a node can retrieve the off-chain keys and then the multiaddress base.
 *
 * Key-binding MUST be done before announcement.
 */
/// forge-lint:disable-next-item(mixed-case-variable)
contract HoprAnnouncements is
    UUPSUpgradeable,
    OwnableUpgradeable,
    HoprMultiSig,
    HoprAnnouncementsEvents,
    HoprLedger(INDEX_SNAPSHOT_INTERVAL)
{
    using EnumerableKeyBindingSet for KeyBindingSet;

    error ZeroAddress(string reason);
    error EmptyMultiaddr();
    error WrongToken();
    error InvalidTokenRecipient();
    error InvalidTokenSender();
    error InvalidTokensReceivedUsage();
    error InvalidKeyBindingFeeAmount();
    error NoNeedToProvideKeyBindingFee();

    // required by ERC1820 spec. ERC1820 registry address
    IERC1820Registry internal constant _ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    // required by ERC777 spec
    bytes32 public constant TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");
    // pre-computed size of the encoded payload for tokensReceived hook with empty multiaddr
    uint256 public immutable ERC777_HOOK_BIND_KEY_MAYBE_ANNOUNCE_SIZE =
        abi.encode(address(0), bytes32(0), bytes32(0), bytes32(0), "").length;

    // key bindings
    KeyBindingSet internal _keyBindings;
    // key binding fee in TOKEN. This can be updated by the owner.
    uint256 public keyBindingFee = 10_000_000 gwei; // 0.01 wxHOPR tokens per key binding
    // accepted token for key binding fees
    /// forge-lint:disable-next-line(mixed-case-variable)
    IERC777 public TOKEN;
    // chain-key (node address) to multiaddress base
    mapping(address => string) public multiaddrOf;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Sets token address and NodeSafeRegistry address
     *
     * @param initParams abi encoded parameters:
     *  - _token address of the ERC777 token used for key binding fees
     *  - _safeRegistry address of the HoprNodeSafeRegistry contract
     *  - _keyBindingFee fee amount in token's smallest unit for key binding
     */
    function initialize(bytes memory initParams) public initializer {
        _initializeLedger(INDEX_SNAPSHOT_INTERVAL);
        (address _token, address _safeRegistry, uint256 _keyBindingFee, address _owner) =
            abi.decode(initParams, (address, address, uint256, address));

        if (_token == address(0)) {
            revert ZeroAddress({ reason: "_token must not be empty" });
        }
        if (_safeRegistry == address(0)) {
            revert ZeroAddress({ reason: "_safeRegistry must not be empty" });
        }
        if (_owner == address(0)) {
            revert ZeroAddress({ reason: "_owner must not be empty" });
        }
        TOKEN = IERC777(_token);
        setNodeSafeRegistry(HoprNodeSafeRegistry(_safeRegistry));

        _ERC1820_REGISTRY.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
        _updateKeyBindingFeeInternal(_keyBindingFee);
        __Ownable_init_unchained(_owner);
    }

    /**
     * @dev ERC777 tokensReceived hook
     * It is called when tokens are sent to this contract. Only accept wxHOPR tokens.
     * The implementation should only accept tokens sent to this contract.
     * Tokens are accepted as payment for key binding fees.
     * If invalid tokens are sent, the transaction is reverted.
     * If invalid keybinding payload is sent, the transaction is reverted.
     * The userData MUST contain the key binding parameters as in `bindKeysMaybeAnnounceSafe` function,
     * where the following parameters are encoded:
     *   - address nodeAddress. The node's on-chain identity (chain-key)
     *   - bytes32 ed25519_sig_0. The first part of the EdDSA signature
     *   - bytes32 ed25519_sig_1. The second part of the EdDSA signature
     *   - bytes32 ed25519_pub_key. The EdDSA public key of the node
     *   - string baseMultiaddr. The base multiaddress of the node. This value is optional.
     *            If an empty string is provided, no announcement is made. Only key binding is performed.
     * @param from The address sending the tokens. Node or Safe contract could be the sender.
     * If the sender is the Safe contract, it must be the one associated with the node.
     * @param to The address receiving the tokens. Must be this contract's address.
     * @param amount The amount of tokens sent. Must be equal to the key binding fee.
     * @param userData The data sent along with the tokens. It must contain the key binding parameters.
     *
     */
    function tokensReceived(
        address, // operator not needed
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata // operatorData not needed
    )
        external
    {
        // don't accept any other tokens ;-)
        if (msg.sender != address(TOKEN)) {
            revert WrongToken();
        }
        // only accept tokens sent to this contract
        if (to != address(this)) {
            revert InvalidTokenRecipient();
        }
        // userData should contain at least 32 * 4 + 32 * 2 (for baseMultiaddr string) = 192 bytes:
        if (userData.length < ERC777_HOOK_BIND_KEY_MAYBE_ANNOUNCE_SIZE) {
            revert InvalidTokensReceivedUsage();
        }
        // decode userData to extract key binding parameters
        (
            address nodeAddress,
            bytes32 ed25519_sig_0,
            bytes32 ed25519_sig_1,
            bytes32 ed25519_pub_key,
            string memory baseMultiaddr
        ) = abi.decode(userData, (address, bytes32, bytes32, bytes32, string));

        // check the `from` address is the node or the Safe contract associated with the node
        // accepted scenarios:
        // 1) node without Safe pays for key binding: from == nodeAddress and expectedSafe == address(0)
        // 2) node with Safe pays for key binding: from == expectedSafe && expectedSafe != address(0)
        address expectedSafe = registry.nodeToSafe(nodeAddress);
        if ((expectedSafe == address(0) && from != nodeAddress) || (expectedSafe != address(0) && from != expectedSafe))
        {
            revert InvalidTokenSender();
        }

        // firstly, perform idempotent key binding
        (bool isNewInsertion,) = _bindKeysInternal(nodeAddress, ed25519_sig_0, ed25519_sig_1, ed25519_pub_key);

        if (isNewInsertion) {
            // check that the sent amount is equal to the key binding fee
            if (amount != keyBindingFee) revert InvalidKeyBindingFeeAmount();
        } else if (amount != 0) {
            // When it's an existing key binding,
            // no need to pay again for existing key binding
            revert NoNeedToProvideKeyBindingFee();
        }

        // secondly, perform optional announcement
        if (bytes(baseMultiaddr).length != 0) {
            _announceInternal(nodeAddress, baseMultiaddr);
        }
        // burn the received tokens
        if (amount > 0) {
            TOKEN.burn(amount, "");
        }
    }

    /**
     * @dev Only owner can update the key binding fee.
     */
    function updateKeyBindingFee(uint256 newFee) external onlyOwner {
        _updateKeyBindingFeeInternal(newFee);
    }

    /**
     * @dev Announces a new multiaddress for the sender.
     *     MUST be called by the Safe contract associated with the node in the NodeSafeRegistry
     */
    function announceSafe(address selfAddress, string calldata baseMultiaddr)
        external
        HoprMultiSig.onlySafe(selfAddress)
    {
        _announceInternal(selfAddress, baseMultiaddr);
    }

    /**
     * @dev Announces a new multiaddress for the sender.
     *      MUST be called by the node itself, if the node is not associated with any Safe
     */
    function announce(string calldata baseMultiaddr) external HoprMultiSig.noSafeSet {
        _announceInternal(msg.sender, baseMultiaddr);
    }

    /**
     * @dev Opts out from acting as a public relay node (PRN)
     *      MUST be called by the Safe contract associated with the node in the NodeSafeRegistry
     *      This only removes the multiaddress announcement, but keeps the key-binding
     */
    function revokeSafe(address selfAddress) external HoprMultiSig.onlySafe(selfAddress) {
        _revokeInternal(selfAddress);
    }

    /**
     * @dev Opts out from acting as a public relay node (PRN)
     *      MUST be called by the node itself, if the node is not associated with any Safe
     *      This only removes the multiaddress announcement, but keeps the key-binding
     */
    function revoke() external HoprMultiSig.noSafeSet {
        _revokeInternal(msg.sender);
    }

    // View functions for key bindings
    // // --- The following mappings are for easier lookups ---
    // // keybindings: key-id => { offchain keys + chain-key }
    // mapping(KeyId => KeyBinding) keyBindingOf; // This is similar to _values
    // // reverse lookup: pubkey => key-id
    // mapping(bytes32 => KeyId) keyIdOf;

    /**
     * @dev Returns the range of valid key ids.
     */
    function getKeyIdRange() external pure returns (uint32 minKeyId, uint32 maxKeyId) {
        return (0, MAX_KEY_ID);
    }

    /**
     * @dev Returns the number of key bindings.
     */
    function getKeyBindingCount() external view returns (uint256) {
        return _keyBindings.length();
    }

    /**
     * @dev Returns the list of all key bindings.
     *      The key id can be derived from the index in the array (starting from 0, capped at MAX_KEY_ID).
     * Note: this function is gas expensive.
     */
    function getAllKeyBindings() external view returns (KeyBindingWithSignatureTimestamp[] memory) {
        return _keyBindings.values();
    }

    function isOffchainKeyBound(bytes32 ed25519_pub_key) external view returns (bool) {
        return _keyBindings.contains(ed25519_pub_key);
    }

    /**
     * @dev Returns the key binding associated with the off-chain public key.
     *      Returns (false, 0, empty) if the off-chain public key does not exist in the list.
     */
    function tryGetKeyBinding(bytes32 ed25519_pub_key)
        external
        view
        returns (bool, KeyId, KeyBindingWithSignatureTimestamp memory)
    {
        (bool success, uint256 possibleKeyId, KeyBindingWithSignatureTimestamp memory keyBinding) =
            _keyBindings.tryGet(ed25519_pub_key);
        return (success, KeyId.wrap(uint32(possibleKeyId)), keyBinding);
    }

    /**
     * @dev Returns the key binding at a specific key id.
     */
    function getKeyBindingWithKeyId(KeyId keyId) external view returns (KeyBindingWithSignatureTimestamp memory) {
        uint256 index = uint256(uint32(KeyId.unwrap(keyId)));
        return _keyBindings.at(index);
    }

    /**
     * @dev Returns the off-chain public key associated with the key id.
     */
    function getOffchainKeyWithKeyId(KeyId keyId) external view returns (bytes32 ed25519_pub_key) {
        uint256 index = uint256(uint32(KeyId.unwrap(keyId)));
        return _keyBindings.at(index).ed25519_pub_key;
    }

    /**
     * @dev Returns the key id associated with the off-chain public key.
     *      Returns (false, 0) if the off-chain public key does not exist in the list.
     */
    function getKeyIdWithOffchainKey(bytes32 ed25519_pub_key) external view returns (bool, KeyId) {
        (bool success, uint256 possibleKeyId,) = _keyBindings.tryGet(ed25519_pub_key);
        return (success, KeyId.wrap(uint32(possibleKeyId)));
    }

    /**
     * [mandatory] Registers a node within the Hopr network and cross-signs on-chain and off-chain keys.
     *
     * Creates a link between an Ethereum, the corresponding secp256k1 public key,
     * a ed25519 EdDSA public key. By submitting the transaction, the caller provides
     * a secp256k1 signature of the ed25519 public key. Conversely, the EdDSA signature
     * signs the secp256k1 public key.
     *
     * The key-id of key binding is allocated automatically and returned by the function.
     * The key id is calculated as the current number of key bindings + 1.
     *
     * The Key-Binding process is idempotent, i.e., re-binding the same off-chain key to the same
     * on-chain identity MUST NOT fail, but return the existing key id.
     *
     * @dev The verification of the ed25519 EdDSA signature happens off-chain.
     *
     * @param ed25519_sig_0 first component of the EdDSA signature
     * @param ed25519_sig_1 second component of the EdDSA signature
     * @param ed25519_pub_key EdDSA public key
     */
    function _bindKeysInternal(
        address selfAddress,
        bytes32 ed25519_sig_0,
        bytes32 ed25519_sig_1,
        bytes32 ed25519_pub_key
    )
        internal
        returns (bool isNewInsertion, uint256 keyIdIndex)
    {
        (bool containsKey, uint256 position,) = _keyBindings.tryGet(ed25519_pub_key);
        if (containsKey) {
            // key already bound, return existing key id
            return (false, position);
        }

        // Otherwise, add new key binding
        keyIdIndex =
            _keyBindings.add(KeyBindingWithSignature(ed25519_sig_0, ed25519_sig_1, ed25519_pub_key, selfAddress));
        indexEvent(
            abi.encodePacked(
                KeyBinding.selector, ed25519_sig_0, ed25519_sig_1, ed25519_pub_key, selfAddress, keyIdIndex
            )
        );
        emit KeyBinding(ed25519_sig_0, ed25519_sig_1, ed25519_pub_key, selfAddress, keyIdIndex);
        return (true, keyIdIndex);
    }

    /**
     * [optional] Announces a base mutliaddress for a node
     *
     * @dev Turns a node into a public relay node (PRN)
     *
     * @param baseMultiaddr base multiaddress of the node
     */
    function _announceInternal(address selfAddress, string memory baseMultiaddr) internal {
        if (bytes(baseMultiaddr).length == 0) {
            revert EmptyMultiaddr();
        }
        if (
            bytes(multiaddrOf[selfAddress]).length != 0
                && keccak256(bytes(multiaddrOf[selfAddress])) == keccak256(bytes(baseMultiaddr))
        ) {
            // no-op if the same multiaddr is announced again
            return;
        }
        multiaddrOf[selfAddress] = baseMultiaddr;
        indexEvent(abi.encodePacked(AddressAnnouncement.selector, selfAddress, baseMultiaddr));
        emit AddressAnnouncement(selfAddress, baseMultiaddr);
    }

    /**
     * Opts out from acting as a public relay node (PRN)
     */
    function _revokeInternal(address selfAddress) internal {
        delete multiaddrOf[selfAddress];
        indexEvent(abi.encodePacked(RevokeAnnouncement.selector, selfAddress));
        emit RevokeAnnouncement(selfAddress);
    }

    /**
     * @dev Updates the key binding fee.
     * The new fee is applied to subsequent key bindings.
     * The fee MAY be zero.
     * @param newFee new fee amount in token's smallest unit
     */
    function _updateKeyBindingFeeInternal(uint256 newFee) internal {
        uint256 oldFee = keyBindingFee;
        keyBindingFee = newFee;
        indexEvent(abi.encodePacked(KeyBindingFeeUpdate.selector, newFee, oldFee));
        emit KeyBindingFeeUpdate(newFee, oldFee);
    }

    /**
     * @dev Override {_authorizeUpgrade} to only allow owner to upgrade the contract
     */
    function _authorizeUpgrade(address) internal override(UUPSUpgradeable) onlyOwner { }
}
