// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.0;

import {
    EnumerableSafeModuleSet,
    SafeModuleSet,
    SafeModuleDeployment
} from "../../src/utils/EnumerableSafeModuleSet.sol";

/**
 * @dev Mock contract to test internal library of EnumerableSafeModuleSet
 * Each function from the libarray has a wrapper in the mock contract
 */
contract EnumerableSafeModuleSetMock {
    using EnumerableSafeModuleSet for SafeModuleSet;

    SafeModuleSet internal safeModuleSet;

    function add(SafeModuleDeployment memory safeModuleAddresses) public returns (uint256) {
        return EnumerableSafeModuleSet.add(safeModuleSet, safeModuleAddresses);
    }

    /// forge-lint:disable-next-line(mixed-case-variable)
    function contains(address safeAddress) public view returns (bool) {
        return EnumerableSafeModuleSet.contains(safeModuleSet, safeAddress);
    }

    function length() public view returns (uint256) {
        return EnumerableSafeModuleSet.length(safeModuleSet);
    }

    function at(uint256 index) public view returns (SafeModuleDeployment memory) {
        return EnumerableSafeModuleSet.at(safeModuleSet, index);
    }

    function values() public view returns (SafeModuleDeployment[] memory) {
        return EnumerableSafeModuleSet.values(safeModuleSet);
    }

    /// forge-lint:disable-next-line(mixed-case-variable)
    function tryGet(address safeAddress) public view returns (bool, uint256, SafeModuleDeployment memory) {
        return EnumerableSafeModuleSet.tryGet(safeModuleSet, safeAddress);
    }

    /// forge-lint:disable-next-line(mixed-case-variable)
    function get(address safeAddress) public view returns (SafeModuleDeployment memory) {
        return EnumerableSafeModuleSet.get(safeModuleSet, safeAddress);
    }
}
