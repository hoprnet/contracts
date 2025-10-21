// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.6.0 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { HoprChannelsEvents } from "../src/Channels.sol";
import { HoprLedger } from "../src/Ledger.sol";

uint256 constant ONE_HOUR = 60 * 60 * 1000; // in milliseconds

uint256 constant INDEX_SNAPSHOT_INTERVAL = ONE_HOUR;

// proxy contract to make modifiers testable and manipulate storage
contract HoprLedgerTest is Test, HoprLedger(INDEX_SNAPSHOT_INTERVAL), HoprChannelsEvents {
    function setUp() public { }

    function test_update_domain_separator(uint64 newId) public {
        // chain ID must be less than 2^64 - 1
        uint256 newChainId = bound(uint256(newId), 1, 0xFFFFFFFFFFFFFFFE);
        uint256 oldChainId = block.chainid;
        vm.assume(newChainId != oldChainId);
        bytes32 domainSeparatorOnDeployment = ledgerDomainSeparator;

        // call updateDomainSeparator when chainid is the same
        updateLedgerDomainSeparator();
        assertEq(ledgerDomainSeparator, domainSeparatorOnDeployment);

        // call updateDomainSeparator when chainid is different
        vm.chainId(newChainId);
        vm.expectEmit(true, true, false, false, address(this));
        emit LedgerDomainSeparatorUpdated(keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("HoprLedger")),
                    keccak256(bytes(LEDGER_VERSION)),
                    newChainId,
                    address(this)
                )
            ));
        updateLedgerDomainSeparator();
        assertTrue(ledgerDomainSeparator != domainSeparatorOnDeployment);
        vm.chainId(oldChainId);
    }

    function test_initialState() public {
        (
            bytes28 latestRootHash,
            uint32 latestTimestamp,
            bytes28 latestSnapshotRootHash,
            uint32 latestSnapshotTimestamp
        ) = _helperGetRootStructValues();
        assertEq(latestTimestamp, block.timestamp);
        assertEq(latestSnapshotTimestamp, block.timestamp);

        assertEq(latestRootHash, latestSnapshotRootHash);
    }

    function testFuzz_OneIndexEvent(uint32 firstTimestamp) public {
        (, uint32 initialTimestamp, bytes28 initialSnapshotRoot, uint32 initialSnapshotTimestamp) =
            _helperGetRootStructValues();

        firstTimestamp = uint32(bound(firstTimestamp, initialTimestamp, INDEX_SNAPSHOT_INTERVAL - initialTimestamp));
        vm.warp(firstTimestamp);

        (bytes28 firstRootHash, uint32 firstRootTimestamp, bytes28 firstSnapshotRoot, uint32 firstSnapshotTimestamp) =
            _helperGetRootStructValues();

        // bytes28 currentRootHash = latestRoot.rootHash;
        uint32 currentBlockNumber = uint32(block.number);

        uint256 beforeGas = gasleft();
        indexEvent(abi.encodePacked(ChannelOpened.selector));
        // emit log_named_uint(key: "Gas used for indexing", val: 5871)
        emit log_named_uint("Gas used for indexing", beforeGas - gasleft());

        // snapshot should be unchanged
        assertEq(initialSnapshotRoot, firstSnapshotRoot);
        assertEq(initialSnapshotTimestamp, firstSnapshotTimestamp);

        (bytes28 secondRootHash, uint32 secondTimestamp, bytes28 secondSnapshotRoot, uint32 secondSnapshotTimestamp) =
            _helperGetRootStructValues();

        // check new root
        assertEq(
            secondRootHash, // latestRoot.rootHash,
            bytes28(
                keccak256(
                    abi.encodePacked(
                        // ledger feed must be unique
                        ledgerDomainSeparator,
                        // Allows the verifier to detect up until which block the snapshot includes state changes
                        currentBlockNumber,
                        // Bind result to previous root
                        firstRootHash,
                        // Information about the happened state change
                        keccak256(abi.encodePacked(ChannelOpened.selector))
                    )
                )
            )
        );
        assertEq(currentBlockNumber, firstRootTimestamp);
    }

    function testFuzz_TwoIndexEvents(uint32 firstTimestamp, uint32 secondTimestamp) public {
        (bytes28 initialRoot, uint32 initialTimestamp,, uint32 initialSnapshotTimestamp) = _helperGetRootStructValues();

        firstTimestamp = uint32(bound(firstTimestamp, initialTimestamp, INDEX_SNAPSHOT_INTERVAL - initialTimestamp));
        vm.warp(firstTimestamp);

        (bytes28 firstRootHash,,,) = _helperGetRootStructValues();

        uint32 currentBlockNumber = uint32(block.number);

        indexEvent(abi.encodePacked(ChannelOpened.selector));

        vm.roll(currentBlockNumber + 1);

        indexEvent(abi.encodePacked(ChannelOpened.selector));

        // test chainability
        (bytes28 thirdRootHash,,,) = _helperGetRootStructValues();

        {
            assertEq(
                thirdRootHash, // latestRoot.rootHash,
                bytes28(
                    keccak256(
                        abi.encodePacked(
                            // ledger feed must be unique
                            ledgerDomainSeparator,
                            // Allows the verifier to detect up until which block the snapshot includes state changes
                            currentBlockNumber + 1,
                            // Bind result to previous root
                            bytes28(
                                keccak256(
                                    abi.encodePacked(
                                        // ledger feed must be unique
                                        ledgerDomainSeparator,
                                        // Allows the verifier to detect up until which block the snapshot includes
                                        // state
                                        // changes
                                        currentBlockNumber,
                                        // Bind result to previous root
                                        firstRootHash,
                                        // Information about the happened state change
                                        keccak256(abi.encodePacked(ChannelOpened.selector))
                                    )
                                )
                            ),
                            // Information about the happened state change
                            keccak256(abi.encodePacked(ChannelOpened.selector))
                        )
                    )
                )
            );
        }

        (,, bytes28 fourthSnapshotRoot, uint32 fourthSnapshotTimestamp) = _helperGetRootStructValues();

        // snapshot should be unchanged
        assertEq(initialRoot, fourthSnapshotRoot);
        assertEq(initialTimestamp, fourthSnapshotTimestamp);
    }

    function testFuzz_ChainedIndexEvents(uint32 firstTimestamp, uint32 secondTimestamp) public {
        (bytes28 initialRoot, uint32 initialTimestamp, bytes28 initialSnapshotRoot,) = _helperGetRootStructValues();

        firstTimestamp = uint32(bound(firstTimestamp, initialTimestamp, INDEX_SNAPSHOT_INTERVAL - initialTimestamp));
        vm.warp(firstTimestamp);

        uint32 currentBlockNumber = uint32(block.number);

        indexEvent(abi.encodePacked(ChannelOpened.selector));

        vm.roll(currentBlockNumber + 1);

        indexEvent(abi.encodePacked(ChannelOpened.selector));

        // test chainability
        (, uint32 fourthTimestamp,,) = _helperGetRootStructValues();

        secondTimestamp =
            uint32(bound(secondTimestamp, fourthTimestamp + INDEX_SNAPSHOT_INTERVAL + 1, type(uint32).max));
        // uint32(bound(secondTimestamp, latestRoot.timestamp + INDEX_SNAPSHOT_INTERVAL + 1, type(uint32).max));
        vm.warp(secondTimestamp);

        uint32 newBlockNumber = uint32(block.number);

        indexEvent(abi.encodePacked(ChannelOpened.selector));

        (bytes28 fifthRootHash, uint32 fifthTimestamp, bytes28 fifthSnapshotRoot, uint32 fifthSnapshotTimestamp) =
            _helperGetRootStructValues();

        assertTrue(fifthSnapshotRoot != initialRoot);
        assertEq(fifthRootHash, fifthSnapshotRoot);
        assertEq(fifthTimestamp, fifthSnapshotTimestamp);

        // test chainability
        assertEq(
            fifthRootHash, // latestRoot.rootHash,
            bytes28(
                keccak256(
                    abi.encodePacked(
                        // ledger feed must be unique
                        ledgerDomainSeparator,
                        // Allows the verifier to detect up until which block the snapshot includes state changes
                        newBlockNumber,
                        // Bind result to previous root
                        bytes28(
                            keccak256(
                                abi.encodePacked(
                                    // ledger feed must be unique
                                    ledgerDomainSeparator,
                                    // Allows the verifier to detect up until which block the snapshot includes state
                                    // changes
                                    currentBlockNumber + 1,
                                    // Bind result to previous root
                                    bytes28(
                                        keccak256(
                                            abi.encodePacked(
                                                // ledger feed must be unique
                                                ledgerDomainSeparator,
                                                // Allows the verifier to detect up until which block the snapshot
                                                // includes state changes
                                                currentBlockNumber,
                                                // Bind result to previous root
                                                initialSnapshotRoot,
                                                // Information about the happened state change
                                                keccak256(abi.encodePacked(ChannelOpened.selector))
                                            )
                                        )
                                    ),
                                    // Information about the happened state change
                                    keccak256(abi.encodePacked(ChannelOpened.selector))
                                )
                            )
                        ),
                        // Information about the happened state change
                        keccak256(abi.encodePacked(ChannelOpened.selector))
                    )
                )
            )
        );
    }

    function _helperGetRootStructValues()
        public
        returns (
            bytes28 latestRootHash,
            uint32 latestTimestamp,
            bytes28 latestSnapshotRootHash,
            uint32 latestSnapshotTimestamp
        )
    {
        RootStruct memory latestRoot = latestRoot();
        RootStruct memory latestSnapshotRoot = latestSnapshotRoot();
        return (latestRoot.rootHash, latestRoot.timestamp, latestSnapshotRoot.rootHash, latestSnapshotRoot.timestamp);
    }
}
