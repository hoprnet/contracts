// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Test, stdStorage, StdStorage } from "forge-std/Test.sol";
import {
    SafeModuleDeployment,
    EnumerableSafeModuleSet,
    EnumerableSafeModuleSetMock
} from "../mocks/EnumerableSafeModuleSetMock.sol";

contract EnumerableSafeModuleSetTest is Test {
    using stdStorage for StdStorage;
    using EnumerableSafeModuleSet for SafeModuleDeployment;

    EnumerableSafeModuleSetMock public enumerableSafeModuleSetMock;

    /**
     * @dev create mock for test
     */
    function setUp() public {
        enumerableSafeModuleSetMock = new EnumerableSafeModuleSetMock();
    }

    /**
     * @dev modifier to create a new instance of the mock contract before each test
     */
    modifier beforeEach() {
        enumerableSafeModuleSetMock = new EnumerableSafeModuleSetMock();
        _;
    }

    /**
     * @dev limit the size of the targetVals array for gas report generation
     */
    modifier limitSize(address[] memory addresses) {
        vm.assume(addresses.length <= 256);
        _;
    }

    /**
     * @dev modifier to ensure all addresses in the array are unique
     */
    modifier uniqueValues(address[] memory addresses) {
        for (uint256 i = 0; i < addresses.length; i++) {
            vm.assume(addresses[i] != address(0));
            for (uint256 j = 0; j < i; j++) {
                vm.assume(addresses[i] != addresses[j]);
            }
        }
        _;
    }

    /**
     * @dev fuzz test on add, length and contains
     */
    function testFuzz_AddLengthContains(address safe1, address safe2)
        public
        beforeEach
    {
        vm.assume(safe1 != safe2);
        assumeUnusedAddress(safe1);
        assumeUnusedAddress(safe2);

        SafeModuleDeployment memory safeModuleAddresses1 =
            SafeModuleDeployment(safe1, safe1);
        SafeModuleDeployment memory safeModuleAddresses2 =
            SafeModuleDeployment(safe2, safe2);

        // Include the first item
        assertEq(enumerableSafeModuleSetMock.add(safeModuleAddresses1), 0);
        // check safeModuleAddresses is indeed added
        SafeModuleDeployment[] memory firstValues = enumerableSafeModuleSetMock.values();
        assertEq(firstValues.length, 1);
        assertEq(enumerableSafeModuleSetMock.length(), 1);
        assertTrue(_compareSafeModule(firstValues[0], safeModuleAddresses1));

        // check adding another safeModuleAddresses
        assertEq(enumerableSafeModuleSetMock.add(safeModuleAddresses2), 1);
        SafeModuleDeployment[] memory secondValues = enumerableSafeModuleSetMock.values();
        assertEq(secondValues.length, 2);
        assertEq(enumerableSafeModuleSetMock.length(), 2);
        assertTrue(_compareSafeModule(secondValues[1], safeModuleAddresses2));
        // check set indeed contains the targetAddress
        assertTrue(enumerableSafeModuleSetMock.contains(safe1));
        assertTrue(enumerableSafeModuleSetMock.contains(safe2));
    }

    function testRevert_AddExistingSafeModule(address safe) public beforeEach {
        assumeUnusedAddress(safe);
        SafeModuleDeployment memory safeModuleAddresses =
            SafeModuleDeployment(safe, safe);
        assertEq(enumerableSafeModuleSetMock.add(safeModuleAddresses), 0);
        // check adding the same safeModuleAddresses again reverts
        vm.expectRevert(EnumerableSafeModuleSet.ExistingSafeModule.selector);
        enumerableSafeModuleSetMock.add(safeModuleAddresses);
    }

    /**
     * @dev test values
     */
    function test_Values() public beforeEach {
        // check default values
        SafeModuleDeployment[] memory values = enumerableSafeModuleSetMock.values();
        assertEq(values.length, 0);
    }

    /**
     * @dev fuzz test at
     */
    function testFuzz_At(address[] memory safes)
        public
        beforeEach
        limitSize(safes)
    {
        // add unique values to target
        uint256 addedCount = _helperCreateSafeModuleSet(safes);
        SafeModuleDeployment[] memory values = enumerableSafeModuleSetMock.values();
        assertEq(addedCount, enumerableSafeModuleSetMock.length());

        for (uint256 i = 0; i < values.length; i++) {
            // compare each value from at() with values()
            assertTrue(_compareSafeModule(values[i], enumerableSafeModuleSetMock.at(i)));
        }
    }

    /**
     * @dev fuzz test get and tryGet methods
     */
    function testFuzz_GetAndTryGetWithInArray(address[] memory safes)
        public
        beforeEach
        uniqueValues(safes)
        limitSize(safes)
    {
        // at least one item can be found from the array
        vm.assume(safes.length > 0);

        // add values to target
        _helperCreateSafeModuleSet(safes);

        for (uint256 i = 0; i < safes.length; i++) {
            (bool tryResult, uint256 index, SafeModuleDeployment memory tryDeployment) =
                enumerableSafeModuleSetMock.tryGet(safes[i]);
            assertEq(index, i);
            assertTrue(_compareSafeModule(tryDeployment, enumerableSafeModuleSetMock.at(i)));
            assertTrue(tryResult);
        }
    }

    /**
     * @dev test revert condition of get, namely when the address does not exist
     */
    function testRevert_Get(address[] memory safes)
        public
        beforeEach
        uniqueValues(safes)
        limitSize(safes)
    {
        // add values to target
        _helperCreateSafeModuleSet(safes);

        // address(0) is not going to be added to the set
        address nonExistentKey = address(0);

        (bool tryResult, uint256 index, SafeModuleDeployment memory tryDeployment) =
            enumerableSafeModuleSetMock.tryGet(nonExistentKey);
        vm.expectRevert(EnumerableSafeModuleSet.NonExistentKey.selector);
        enumerableSafeModuleSetMock.get(nonExistentKey);

        assertFalse(tryResult);
        assertEq(index, 0);
        assertTrue(
            _compareSafeModule(tryDeployment, SafeModuleDeployment(address(0), address(0)))
        );
    }

    /**
     * @dev test positive condition of get
     */
    function testFuzz_Get(address[] memory safes)
        public
        beforeEach
        uniqueValues(safes)
        limitSize(safes)
    {
        // add values to target
        _helperCreateSafeModuleSet(safes);

        if (safes.length == 0) {
            return;
        } else {
            (bool tryResult, uint256 index, SafeModuleDeployment memory tryDeployment) =
                enumerableSafeModuleSetMock.tryGet(safes[0]);
            assertTrue(tryResult);
            assertEq(index, 0);
            assertTrue(_compareSafeModule(tryDeployment, enumerableSafeModuleSetMock.at(0)));
        }
    }

    /**
     * @dev helper function to create a set for fuzz testing
     *      Safe addresses to be added to the set, non-zero addresses only
     * @param safes Array of safe addresses to be added to the set (non-zero addresses only)
     */
    function _helperCreateSafeModuleSet(address[] memory safes) private returns (uint256) {
        uint256 counter = 0;
        for (uint256 i = 0; i < safes.length; i++) {
            // only add unique non-existing safe addresses
            if (!enumerableSafeModuleSetMock.contains(safes[i])) {
                enumerableSafeModuleSetMock.add(
                    SafeModuleDeployment(
                        safes[i], safes[i]
                    )
                );
                counter++;
            }
        }
        return counter;
    }

    function _compareSafeModule(SafeModuleDeployment memory a, SafeModuleDeployment memory b)
        private
        pure
        returns (bool)
    {
        return (a.safeProxyInstance == b.safeProxyInstance && a.moduleProxyInstance == b.moduleProxyInstance);
    }
}
