// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { EfficientHashLib } from "solady-0.1.24/utils/EfficientHashLib.sol";

abstract contract HoprLedgerEvents {
    /**
     * Emitted once the ledger domain separator is updated.
     */
    event LedgerDomainSeparatorUpdated(bytes32 indexed ledgerDomainSeparator);
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
 * Indexes data trustlessly to allow a fast-sync for nodes in the network.
 */
abstract contract HoprLedger is HoprLedgerEvents {
    // Prevents from initializing the contract with a zero interval
    error ZeroInterval();

    string public constant LEDGER_VERSION = "2.0.0";

    uint256 public immutable SNAPSHOT_INTERVAL;

    /**
     * Stores the last indexer state
     *
     * Aligned to 1 EVM word
     */
    struct RootStruct {
        bytes28 rootHash;
        // Overflow at year 2105
        uint32 timestamp;
    }

    RootStruct private _latestRoot;

    RootStruct private _latestSnapshotRoot;

    bytes32 public ledgerDomainSeparator;

    /**
     * @param _snapshotInterval time in seconds to create a new snapshot
     */
    constructor(uint256 _snapshotInterval) {
        if (_snapshotInterval == 0) {
            revert ZeroInterval();
        }
        SNAPSHOT_INTERVAL = _snapshotInterval;

        // take first 28 bytes
        _latestRoot.rootHash = bytes28(keccak256(abi.encodePacked(address(this))));
        _latestRoot.timestamp = uint32(block.timestamp);

        _latestSnapshotRoot = _latestRoot;

        // compute the domain separator on deployment
        updateLedgerDomainSeparator();
    }

    /**
     * @dev recompute the domain seperator in case of a fork
     * This function should be called by anyone when required.
     * An event is emitted when the domain separator is updated
     */
    function updateLedgerDomainSeparator() public {
        // following encoding guidelines of EIP712, with assembly for gas optimization
        bytes32 newLedgerDomainSeparator = EfficientHashLib.hash(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("HoprLedger")),
            keccak256(bytes(LEDGER_VERSION)),
            bytes32(block.chainid),
            bytes32(uint256(uint160(address(this))))
        );
        if (newLedgerDomainSeparator != ledgerDomainSeparator) {
            ledgerDomainSeparator = newLedgerDomainSeparator;
            emit LedgerDomainSeparatorUpdated(ledgerDomainSeparator);
        }
    }

    function latestRoot() public view returns (RootStruct memory) {
        return _latestRoot;
    }

    function latestSnapshotRoot() public view returns (RootStruct memory) {
        return _latestSnapshotRoot;
    }

    function indexEvent(bytes memory payload) internal {
        bool createSnapshot = false;
        if (block.timestamp > _latestRoot.timestamp + SNAPSHOT_INTERVAL) {
            createSnapshot = true;
        }

        // take first 28 bytes
        _latestRoot.rootHash = bytes28(
            keccak256(
                // keep hashed data minimal
                abi.encodePacked(
                    // ledger feed must be unique
                    ledgerDomainSeparator,
                    // Allows the verifier to detect up until which block the snapshot includes state changes
                    uint32(block.number),
                    // Bind result to previous root
                    _latestRoot.rootHash,
                    // Information about the happened state change
                    keccak256(payload)
                )
            )
        );
        _latestRoot.timestamp = uint32(block.timestamp);

        if (createSnapshot) {
            _latestSnapshotRoot = _latestRoot;
        }
    }
}
