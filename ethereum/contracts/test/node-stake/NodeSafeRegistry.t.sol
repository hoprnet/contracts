// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { HoprNodeSafeRegistry, HoprNodeSafeRegistryEvents } from "../../src/node-stake/NodeSafeRegistry.sol";
import { ECDSA } from "openzeppelin-contracts-5.4.0/utils/cryptography/ECDSA.sol";
import { Test, stdStorage, StdStorage } from "forge-std/Test.sol";


// // proxy contract to manipulate storage
// contract MyNodeSafeRegistry is HoprNodeSafeRegistry {
//     constructor() {}

//     // Only for testing
//     function _storeSafeAddress(address nodeAddress, address safeAddress) public {
//         HoprNodeSafeRegistry.NodeSafeRecord storage record = _nodeToSafe[nodeAddress];
//         record.safeAddress = safeAddress;
    
//         stdstore.target(address(erc677Mock)).sig(erc677Mock.balanceOf.selector).with_key(sender).checked_write(amount);
//     }
// }

contract HoprNodeSafeRegistryTest is Test, HoprNodeSafeRegistryEvents {
    using stdStorage for StdStorage;

    address public safe;
    HoprNodeSafeRegistry public nodeSafeRegistry;
    address private constant SENTINEL_MODULES = address(0x1);
    uint256 private constant PAGE_SIZE = 100;

    function setUp() public {
        safe = vm.addr(101); // make address(101) a caller
        nodeSafeRegistry = new HoprNodeSafeRegistry();
    }

    modifier assumeDifferentAddress(address addr) {
        assumeUnusedAddress(addr);
        vm.assume(
            addr != address(this) && addr != address(nodeSafeRegistry) && addr != vm.addr(303)
        );
        _;
    }

    /**
     * @dev node can actively register a node
     */
    function testFuzz_RegisterSafeByNode(address nodeAddress) public assumeDifferentAddress(nodeAddress) {
        vm.assume(safe != nodeAddress);

        vm.prank(nodeAddress);
        vm.expectEmit(true, true, false, false, address(nodeSafeRegistry));
        emit RegisteredNodeSafe(safe, nodeAddress);
        nodeSafeRegistry.registerSafeByNode(safe);

        vm.clearMockedCalls();
    }

    /**
     * @dev any account can register a safe-node pair with valid signature
     */
    function testFuzz_RegisterSafeWithNodeSig(uint256 nodePrivateKey) public {
        nodePrivateKey = bound(nodePrivateKey, 1, 1e36);
        address nodeChainKeyAddress = vm.addr(nodePrivateKey);

        // verify the registration is not known beforehand
        assertFalse(nodeSafeRegistry.isNodeSafeRegistered(safe, nodeChainKeyAddress));

        uint256 nodeSigNonce = nodeSafeRegistry.nodeSigNonce(nodeChainKeyAddress);
        (address nodeAddress, bytes memory sig) =
            _helperBuildSig(nodePrivateKey, safe, nodeChainKeyAddress, nodeSigNonce);

        assumeUnusedAddress(nodeAddress);
        vm.assume(
            nodeAddress != address(this) && nodeAddress != address(nodeSafeRegistry) && nodeAddress != vm.addr(303)
        );

        vm.expectEmit(true, true, false, false, address(nodeSafeRegistry));
        emit RegisteredNodeSafe(safe, nodeAddress);
        nodeSafeRegistry.registerSafeWithNodeSig(safe, nodeChainKeyAddress, sig);

        // verify the registration worked
        assertTrue(nodeSafeRegistry.isNodeSafeRegistered(safe, nodeChainKeyAddress));

        vm.clearMockedCalls();
    }

    /**
     * @dev signature cannot be re-used
     */
    function testRevert_RegisterSafeWithNodeSigNonceReused(uint256 nodePrivateKey) public {
        nodePrivateKey = bound(nodePrivateKey, 1, 1e36);
        address nodeChainKeyAddress = vm.addr(nodePrivateKey);

        // verify the registration is not known beforehand
        assertFalse(nodeSafeRegistry.isNodeSafeRegistered(safe, nodeChainKeyAddress));

        uint256 nodeSigNonce = nodeSafeRegistry.nodeSigNonce(nodeChainKeyAddress);
        (, bytes memory sig) =
            _helperBuildSig(nodePrivateKey, safe, nodeChainKeyAddress, nodeSigNonce);

        assumeUnusedAddress(nodeChainKeyAddress);
        vm.assume(
            nodeChainKeyAddress != address(this) && nodeChainKeyAddress != address(nodeSafeRegistry) && nodeChainKeyAddress != vm.addr(303)
        );

        // register for the first time
        nodeSafeRegistry.registerSafeWithNodeSig(safe, nodeChainKeyAddress, sig);
        // fail to re-use the signature
        vm.expectRevert(HoprNodeSafeRegistry.NotValidSignatureFromNode.selector);
        nodeSafeRegistry.registerSafeWithNodeSig(safe, nodeChainKeyAddress, sig);

        vm.clearMockedCalls();
    }

    /**
     * @dev node fail to register a node due to it's registered
     */
    function testRevert_FailToRegisterSafeByNodeDueToRegistered(address nodeAddress) public assumeDifferentAddress(nodeAddress) {
        vm.assume(safe != nodeAddress);

        stdstore.target(address(nodeSafeRegistry)).sig(nodeSafeRegistry.nodeToSafe.selector).with_key(nodeAddress).checked_write(safe);

        vm.prank(nodeAddress);
        vm.expectRevert(HoprNodeSafeRegistry.NodeHasSafe.selector);
        nodeSafeRegistry.registerSafeByNode(safe);
        vm.clearMockedCalls();
    }

    /**
     * @dev node fail to register a node due to the provided safe address is zero
     */
    function testRevert_FailToRegisterSafeByNodeDueToSafeAddressZero(address nodeAddress) public assumeDifferentAddress(nodeAddress) {
        address safeAddress = address(0);

        stdstore.target(address(nodeSafeRegistry)).sig(nodeSafeRegistry.nodeToSafe.selector).with_key(nodeAddress).checked_write(address(1));

        vm.prank(nodeAddress);
        vm.expectRevert(HoprNodeSafeRegistry.SafeAddressZero.selector);
        nodeSafeRegistry.registerSafeByNode(safeAddress);
        vm.clearMockedCalls();
    }

    /**
     * @dev node fail to register a node due to the provided node address is zero
     */
    function testRevert_FailToRegisterSafeByNodeDueToNodeAddressZero(address safeAddress) public assumeDifferentAddress(safeAddress) {
        address nodeAddress = address(0);

        stdstore.target(address(nodeSafeRegistry)).sig(nodeSafeRegistry.nodeToSafe.selector).with_key(nodeAddress).checked_write(address(1));

        vm.prank(nodeAddress);
        vm.expectRevert(HoprNodeSafeRegistry.NodeAddressZero.selector);
        nodeSafeRegistry.registerSafeByNode(safeAddress);
        vm.clearMockedCalls();
    }

    /**
     * @dev node fail to register a node due to the provided node address is a contract
     */
    function testRevert_FailToRegisterSafeByNodeDueToNodeIsContract(address nodeAddress) public assumeDifferentAddress(nodeAddress) {
        // mock code at nodeAddress
        vm.etch(nodeAddress, hex"00010203040506070809");

        vm.prank(nodeAddress);
        vm.expectRevert(HoprNodeSafeRegistry.NodeIsContract.selector);
        nodeSafeRegistry.registerSafeByNode(safe);
        vm.clearMockedCalls();
        vm.etch(nodeAddress, hex"");
    }

    /**
     * @dev node can still be registered by the Safe although it's not a member in the module enabled by the Safe
     * @notice this was previously not possible due to an additional check ensureNodeIsSafeModuleMember
     * The said function is removed as it does not allow certian eligible setup, as reported in
     * https://github.com/hoprnet/hoprnet/issues/6466
     */
    function testFuzz_RegisterSafeByNodeAlthoughNodeIsNotModuleMember(address nodeAddress) public assumeDifferentAddress(nodeAddress) {
        vm.assume(safe != nodeAddress);

        stdstore.target(address(nodeSafeRegistry)).sig(nodeSafeRegistry.nodeToSafe.selector).with_key(nodeAddress).checked_write(address(0));

        vm.prank(nodeAddress);
        vm.expectEmit(true, true, false, false, address(nodeSafeRegistry));
        emit RegisteredNodeSafe(safe, nodeAddress);
        nodeSafeRegistry.registerSafeByNode(safe);
        vm.clearMockedCalls();
    }

    /**
     * @dev safe can deregister a node by the safe
     */
    function testFuzz_DeregisterNodeBySafeOnARegisteredNodeSafePair(address nodeAddress) public assumeDifferentAddress(nodeAddress) {
        vm.assume(safe != nodeAddress);

        vm.prank(nodeAddress);
        nodeSafeRegistry.registerSafeByNode(safe);

        vm.prank(safe);
        vm.expectEmit(true, true, false, false, address(nodeSafeRegistry));
        emit DeregisteredNodeSafe(safe, nodeAddress);
        nodeSafeRegistry.deregisterNodeBySafe(nodeAddress);

        vm.clearMockedCalls();
    }

    /**
     * @dev cannot deregister a random address
     */
    function testRevert_DeregisterNodeByADifferentSafeDueToNotValidSafe(address nodeAddress) public assumeDifferentAddress(nodeAddress) {
        vm.assume(safe != nodeAddress);

        vm.prank(nodeAddress);
        nodeSafeRegistry.registerSafeByNode(safe);

        vm.prank(address(1));
        vm.expectRevert(HoprNodeSafeRegistry.NotValidSafe.selector);
        nodeSafeRegistry.deregisterNodeBySafe(nodeAddress);

        vm.clearMockedCalls();
    }

    function test_DomainSeparator(uint64 newId) public {
        // chain ID must be less than 2^64 - 1
        uint256 newChainId = bound(uint256(newId), 1, 0xFFFFFFFFFFFFFFFE);
        uint256 oldChainId = block.chainid;
        vm.assume(newChainId != oldChainId);
        bytes32 domainSeparatorOnDeployment = nodeSafeRegistry.domainSeparator();

        // call updateDomainSeparator when chainid is the same
        nodeSafeRegistry.updateDomainSeparator();
        assertEq(nodeSafeRegistry.domainSeparator(), domainSeparatorOnDeployment);

        // call updateDomainSeparator when chainid is different
        vm.chainId(newChainId);
        vm.expectEmit(true, true, false, false, address(nodeSafeRegistry));
        emit DomainSeparatorUpdated(
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("NodeSafeRegistry")),
                    keccak256(bytes(nodeSafeRegistry.VERSION())),
                    newChainId,
                    address(nodeSafeRegistry)
                )
            )
        );
        nodeSafeRegistry.updateDomainSeparator();
        assertTrue(nodeSafeRegistry.domainSeparator() != domainSeparatorOnDeployment);
        vm.chainId(oldChainId);
    }

    // ================== helper functions ==================
    /**
     * @dev Build a registration signature for node
     */
    function _helperBuildSig(
        uint256 mockNodePrivateKey,
        address safeAddress,
        address nodeChainKeyAddress,
        uint256 nonce
    )
        private
        view
        returns (address, bytes memory)
    {
        HoprNodeSafeRegistry.NodeSafeNonce memory nodeSafeNonce = HoprNodeSafeRegistry.NodeSafeNonce({
            safeAddress: safeAddress,
            nodeChainKeyAddress: nodeChainKeyAddress,
            nodeSigNonce: nonce
        });
        bytes32 hashStruct = keccak256(abi.encode(nodeSafeRegistry.NODE_SAFE_TYPEHASH(), nodeSafeNonce));
        // build typed digest
        bytes32 registerHash =
            keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), nodeSafeRegistry.domainSeparator(), hashStruct));

        address nodeAddress = vm.addr(mockNodePrivateKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mockNodePrivateKey, registerHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        (address recovered, ECDSA.RecoverError recoverError, ) = ECDSA.tryRecover(registerHash, sig);
        assertTrue(recoverError == ECDSA.RecoverError.NoError);
        assertEq(recovered, nodeAddress);
        assertEq(recovered, nodeChainKeyAddress);

        return (nodeAddress, sig);
    }
}
