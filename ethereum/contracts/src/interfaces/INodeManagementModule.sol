// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8;

/**
 * @title HoprNodeManagementModule interface
 */
interface IHoprNodeManagementModule {
    /**
     * @notice Returns a descriptive version of the NodeManagementModule contract.
     * @return The version string.
     */
    // solhint-disable-next-line func-name-mixedcase
    // / forge-lint: disable-next-line(mixed-case-function)
    function VERSION() external view returns (string memory);

    /**
     * @notice Returns if a node is included in the NodeManagementModule contract.
     */
    function isNode(address nodeAddress) external view returns (bool);

    /**
     * @notice Includes nodes in the NodeManagementModule contract.
     * @param nodeAddresses The addresses of the nodes to include.
     */
    function includeNodes(address[] calldata nodeAddresses) external payable;

    /**
     * @notice Allows member nodes to call only their own self-service operations on the registry.
     * @dev Must be executed by the owning Safe when upgrading an existing module deployment.
     */
    function scopeTargetServiceRegistry(address serviceRegistry) external;
}
