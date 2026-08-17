// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { IERC1820Registry } from "openzeppelin-contracts-5.4.0/interfaces/IERC1820Registry.sol";
import { IERC20 } from "openzeppelin-contracts-5.4.0/token/ERC20/IERC20.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";

/**
 * @dev A wxHOPR holder that re-enters the registry from its own ERC-777 send hook.
 *
 * wxHOPR calls `tokensToSend` of the holder before it moves the balance and before it decrements
 * the allowance. This contract is therefore caller-controlled code that runs in the middle of
 * every paid write of the registry.
 *
 * The constructor registers this contract as its own `ERC777TokensSender`. The ERC-1820 registry
 * skips the `canImplementInterfaceForAddress` magic value when the implementer is the caller, and
 * an address is its own manager by default. No further setup is needed.
 *
 * A test arms one inner call, then makes an outer call through `callRegistry`. The hook snapshots
 * the state of the registry, then makes the armed call. With `swallow` set, the hook keeps the
 * failure of the inner call in storage and lets the outer call finish. Without it, the hook
 * bubbles the failure and the whole transaction reverts.
 */
contract ReentrantTokenHolder {
    IERC1820Registry internal constant ERC1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 internal constant TOKENS_SENDER_INTERFACE_HASH = keccak256("ERC777TokensSender");

    /// @dev Marks the exact point of the token pull inside the receipt.
    event HookFired();

    HoprServiceRegistry public immutable registry;
    IERC20 public immutable token;

    /// @dev The entry that the hook inspects while the outer call is still in flight.
    bytes32 public watchedType;
    address public watchedNode;

    bool public armed;
    bool public swallow;
    bytes public innerCalldata;

    bool public hookFired;
    bool public lastInnerSuccess;
    bytes public lastRevertData;

    /// @dev State of the registry as seen from inside the token pull.
    bool public seenIsRegistered;
    uint48 public seenRegisteredAt;
    uint256 public seenNodeCount;
    uint256 public seenRegistryBalance;
    uint256 public seenTypeCount;

    constructor(HoprServiceRegistry registry_, IERC20 token_) {
        registry = registry_;
        token = token_;
        ERC1820.setInterfaceImplementer(address(this), TOKENS_SENDER_INTERFACE_HASH, address(this));
    }

    /// @dev Gives the registry an allowance on the wxHOPR of this contract.
    function approveRegistry(uint256 amount) external {
        token.approve(address(registry), amount);
    }

    /// @dev Names the entry that the hook reads while the outer call runs.
    function watch(bytes32 serviceType, address node) external {
        watchedType = serviceType;
        watchedNode = node;
    }

    /**
     * @dev Arms one inner call for the next hook.
     *
     * @param innerCalldata_ the call that the hook makes back into the registry
     * @param swallow_ true keeps a failure in storage, false bubbles it and reverts everything
     */
    function arm(bytes calldata innerCalldata_, bool swallow_) external {
        armed = true;
        swallow = swallow_;
        innerCalldata = innerCalldata_;
        hookFired = false;
        lastInnerSuccess = false;
        lastRevertData = "";
    }

    /// @dev Makes an outer call into the registry as this contract.
    function callRegistry(bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory returnData) = address(registry).call(data);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }

    /**
     * @dev The ERC-777 send hook. wxHOPR calls it before the balance moves.
     *
     * The hook disarms itself first, so a nested pull cannot start an endless recursion.
     */
    function tokensToSend(address, address, address, uint256, bytes calldata, bytes calldata) external {
        if (!armed) {
            return;
        }
        armed = false;
        hookFired = true;
        emit HookFired();

        seenIsRegistered = registry.isRegistered(watchedType, watchedNode);
        seenRegisteredAt = registry.getEntry(watchedType, watchedNode).registeredAt;
        seenNodeCount = registry.nodeCount(watchedType);
        seenTypeCount = registry.typeCount();
        seenRegistryBalance = token.balanceOf(address(registry));

        (bool success, bytes memory returnData) = address(registry).call(innerCalldata);
        lastInnerSuccess = success;
        lastRevertData = returnData;

        if (!success && !swallow) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
