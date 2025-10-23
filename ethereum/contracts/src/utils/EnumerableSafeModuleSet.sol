// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

struct SafeModuleDeployment {
    address safeProxyInstance;
    address moduleProxyInstance;
}

struct SafeModuleSet {
    // Storage of SafeModuleDeployment values
    SafeModuleDeployment[] _values;
    // Position is the index of the value in the `values` array plus 1.
    // Position 0 is used to mean a value is not in the set.
    // The key is the safeProxyInstance of the SafeModuleDeployment.
    // Each safeProxyInstance can only be associated with maximum one moduleProxyInstance.
    mapping(address => uint256) _positions;
}

/**
 * @dev Library for storing deployed safe and module sets from the factory contracts
 * Adapted from OpenZeppelin's EnumerableSet
 * library, for SafeModuleDeployment type.
 */
library EnumerableSafeModuleSet {
    // when the address is not stared as a target address
    error NonExistentKey();
    // when the safeProxyInstance is already in the set
    error ExistingSafeModule();

    /**
     * @dev Add a value to a set. O(1).
     */
    function add(SafeModuleSet storage set, SafeModuleDeployment memory value) internal returns (uint256) {
        // Check if the safeProxyInstance is already in the set
        if (contains(set, value.safeProxyInstance)) {
            revert ExistingSafeModule();
        }

        // add value to the set
        set._values.push(value);
        // The value is stored at length-1, but we add 1 to all indexes
        // and use 0 as a sentinel value
        set._positions[value.safeProxyInstance] = set._values.length;

        return set._values.length - 1;
    }

    /**
     * @dev Returns true if the safeProxyInstance is in the set. O(1).
     *      This function is used to check if a safe module pair exists
     */
    /// forge-lint:disable-next-line(mixed-case-variable)
    function contains(SafeModuleSet storage set, address safeProxyInstance) internal view returns (bool) {
        return set._positions[safeProxyInstance] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function length(SafeModuleSet storage set) internal view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(SafeModuleSet storage set, uint256 index) internal view returns (SafeModuleDeployment memory) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(SafeModuleSet storage set) internal view returns (SafeModuleDeployment[] memory) {
        return set._values;
    }

    /**
     * @dev Tries to returns the value associated with the safe proxy address. O(1).
     *      Does not revert if `safeProxyInstance` is not in the map.
     * @return (bool, uint256, SafeModuleDeployment memory)
     *          Returns (true, position, SafeModuleDeployment) if the safeProxyInstance is in the set,
     *          Returns (false, 0, empty SafeModuleDeployment) if the safeProxyInstance is not in the set.
     */
    /// forge-lint:disable-next-line(mixed-case-variable)
    function tryGet(SafeModuleSet storage set, address safeProxyInstance)
        internal
        view
        returns (bool, uint256, SafeModuleDeployment memory)
    {
        uint256 index = set._positions[safeProxyInstance];
        if (index == 0) {
            return (false, 0, SafeModuleDeployment(address(0), address(0)));
        } else {
            return (true, index - 1, set._values[index - 1]);
        }
    }

    /**
     * @dev Returns the value associated with `safeProxyInstance` key. O(1).
     *
     * Requirements:
     *
     * - `safeProxyInstance` key must be in the map.
     */
    /// forge-lint:disable-next-line(mixed-case-variable)
    function get(SafeModuleSet storage set, address safeProxyInstance)
        internal
        view
        returns (SafeModuleDeployment memory)
    {
        uint256 index = set._positions[safeProxyInstance];
        if (index == 0) {
            revert NonExistentKey();
        }
        return set._values[index - 1];
    }
}
