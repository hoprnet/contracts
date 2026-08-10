// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/**
 * @title Per-type policy contract for HoprServiceRegistry
 * @dev A service type can point to a requirement contract. The registry staticcalls this contract
 * on every `selfRegister` and on every `selfUpdate`.
 *
 * A value of `address(0)` in `requirements[serviceType]` means that the type has no requirement.
 * The type is then open to every bound node. Only the entry burns of the type gate it.
 *
 * The registry is not upgradeable, so both signatures are frozen at deployment. The type owner
 * can still replace the implementation of one type at any time. The parameter lists are wide for
 * this reason. An implementation can ignore each parameter that it does not need.
 *
 * An implementation can read the bound Safe of a node through the public `nodeSafeRegistry()`
 * pointer of the registry.
 *
 * The registry does not wrap these calls in try/catch. A requirement that reverts, or that
 * returns malformed data, reverts the write with the raw error. This is a configuration error of
 * the type owner, and it must be visible.
 */
interface IServiceRequirement {
    /**
     * @dev Reports eligibility for a new registration. The registry makes this call once, at
     * registration, and never again.
     *
     * The registry makes sure that the caller is the bound Safe of the node before this call. An
     * implementation therefore applies its eligibility policy only. Examples are HoprNetworkRegistry
     * admission, stake minimums, allowlists and denylists. An implementation can ignore `caller`.
     *
     * An implementation must not assume that `caller` is a Safe contract. A node can bind itself
     * to an arbitrary EOA in HoprNodeSafeRegistry.
     *
     * A clean `false` makes the registry revert with `RegistrationDenied(serviceType, caller, node)`.
     *
     * @param serviceType the type that receives the new entry
     * @param caller the `msg.sender` of the registry call, which is the bound Safe of the node
     * @param node the native chain address of the node
     * @return true if the registration is permitted
     */
    function canRegister(bytes32 serviceType, address caller, address node) external view returns (bool);

    /**
     * @dev Reports whether the metadata content is acceptable. The registry makes this call on
     * self-registration, and again on every self-update.
     *
     * `canRegister` never sees the metadata, and `validateMetadata` never sees the caller. An
     * eligibility rule that depends on metadata content must live here.
     *
     * The registry applies this call to every update. A policy that becomes stricter therefore
     * freezes metadata that does not comply. It does not remove the entry.
     *
     * A type can use this call to make the global `MAX_METADATA_LENGTH` cap of the registry
     * smaller.
     *
     * A clean `false` makes the registry revert with `MetadataRejected(serviceType, node)`.
     *
     * @param serviceType the type that holds the entry
     * @param node the native chain address of the node
     * @param metadata the opaque metadata of this write
     * @return true if the metadata is accepted
     */
    function validateMetadata(bytes32 serviceType, address node, bytes calldata metadata) external view returns (bool);
}
