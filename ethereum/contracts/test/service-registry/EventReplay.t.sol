// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Vm } from "forge-std/Vm.sol";
import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry, INodeSafeRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";
import { MockNodeSafeRegistry, PermissiveRequirement } from "../mocks/ServiceRegistryMocks.sol";
import { IERC20 } from "openzeppelin-contracts-5.4.0/token/ERC20/IERC20.sol";

/**
 * @dev Invariant I8. The full state and the full configuration are reconstructible from events
 * alone, with zero `eth_call` requests.
 *
 * The test runs one scripted scenario, captures every log, and rebuilds the whole registry from
 * those logs in pure Solidity. The rebuilt state is then compared against the views. The reducer
 * reads no storage of the registry, exactly like an indexer.
 *
 * It also asserts the ordering rule of section 7: inside each paid write the registry event comes
 * before the logs of the token.
 */
contract HoprServiceRegistryEventReplayTest is ServiceRegistryFixtureTest {
    bytes32 internal constant REGISTRY_INITIALIZED =
        keccak256("RegistryInitialized(uint256,address,address,address,uint48)");
    bytes32 internal constant NODE_SAFE_REGISTRY_UPDATED = keccak256("NodeSafeRegistryUpdated(address,address)");
    bytes32 internal constant TYPE_REGISTRATION_FEE_UPDATED = keccak256("TypeRegistrationFeeUpdated(uint256)");
    bytes32 internal constant SERVICE_TYPE_REGISTERED = keccak256("ServiceTypeRegistered(bytes32,address,uint256)");
    bytes32 internal constant TYPE_OWNERSHIP_TRANSFERRED =
        keccak256("TypeOwnershipTransferred(bytes32,address,address)");
    bytes32 internal constant REQUIREMENT_UPDATED = keccak256("RequirementUpdated(bytes32,address)");
    bytes32 internal constant SELF_REGISTRATION_BURN_UPDATED =
        keccak256("SelfRegistrationBurnUpdated(bytes32,uint256)");
    bytes32 internal constant SELF_UPDATE_BURN_UPDATED = keccak256("SelfUpdateBurnUpdated(bytes32,uint256)");
    bytes32 internal constant REGISTERED = keccak256("Registered(bytes32,address,address,bytes,uint48,uint256)");
    bytes32 internal constant UPDATED = keccak256("Updated(bytes32,address,address,bytes,uint48,uint256)");
    bytes32 internal constant DEREGISTERED = keccak256("Deregistered(bytes32,address,address)");
    bytes32 internal constant TOKENS_RECOVERED = keccak256("TokensRecovered(address,address,uint256)");
    bytes32 internal constant TOKEN_BURNED = keccak256("Burned(address,address,uint256,bytes,bytes)");

    bytes32 internal constant TYPE_ONE = bytes32("replay:one");
    bytes32 internal constant TYPE_TWO = bytes32("replay:two");

    struct RebuiltType {
        bool exists;
        address owner;
        address requirement;
        uint256 registrationBurn;
        uint256 updateBurn;
    }

    struct RebuiltEntry {
        bool exists;
        bytes metadata;
        uint48 registeredAt;
        uint48 updatedAt;
    }

    // --- the state that the reducer rebuilds from logs alone ---------------------------------

    uint256 internal rebuiltVersion;
    address internal rebuiltAdmin;
    address internal rebuiltManager;
    address internal rebuiltToken;
    uint48 internal rebuiltAdminDelay;
    address internal rebuiltPointer;
    uint256 internal rebuiltFee;
    uint256 internal rebuiltRecoveredAmount;
    address internal rebuiltRecoveredTo;

    mapping(bytes32 => RebuiltType) internal rebuiltTypes;
    bytes32[] internal rebuiltTypeList;
    mapping(bytes32 => mapping(address => RebuiltEntry)) internal rebuiltEntries;
    mapping(bytes32 => address[]) internal rebuiltNodeList;

    // --- the scenario ------------------------------------------------------------------------

    HoprServiceRegistry internal replayRegistry;
    MockNodeSafeRegistry internal replayBindings;
    MockNodeSafeRegistry internal swappedBindings;
    PermissiveRequirement internal replayRequirement;

    address[3] internal replayNodes;
    address[3] internal replaySafes;

    function test_I8_theFullStateIsReconstructibleFromLogsAlone() public {
        vm.recordLogs();
        _runScenario();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _replay(logs);

        _assertConfigurationMatches();
        _assertTypesMatch();
        _assertEntriesMatch();
        _assertRegistryEventsPrecedeTokenBurns(logs);
    }

    // ---------------------------------------------------------------------------------------
    // The scripted scenario
    // ---------------------------------------------------------------------------------------

    function _runScenario() internal {
        replayBindings = new MockNodeSafeRegistry();
        swappedBindings = new MockNodeSafeRegistry();
        replayRequirement = new PermissiveRequirement();

        replayRegistry = new HoprServiceRegistry(
            address(hoprToken), INodeSafeRegistry(address(replayBindings)), ADMIN_DELAY, admin, manager, TYPE_FEE
        );

        for (uint256 i = 0; i < 3; i++) {
            replayNodes[i] = vm.addr(50_000 + i);
            replaySafes[i] = vm.addr(51_000 + i);
            hoprToken.mint(replaySafes[i], FUNDING, hex"00", hex"00");
            vm.prank(replaySafes[i]);
            hoprToken.approve(address(replayRegistry), type(uint256).max);
            replayBindings.setBinding(replayNodes[i], replaySafes[i]);
            swappedBindings.setBinding(replayNodes[i], replaySafes[i]);
        }
        vm.prank(typeOwner);
        hoprToken.approve(address(replayRegistry), type(uint256).max);
        vm.prank(stranger);
        hoprToken.approve(address(replayRegistry), type(uint256).max);

        // two types, registered by two different owners
        vm.prank(typeOwner);
        replayRegistry.registerServiceType(TYPE_ONE, IServiceRequirement(address(0)), REGISTRATION_BURN, UPDATE_BURN);
        vm.prank(stranger);
        replayRegistry.registerServiceType(TYPE_TWO, replayRequirement, 0, 0);

        // reconfigure the first type
        vm.startPrank(typeOwner);
        replayRegistry.setRequirement(TYPE_ONE, replayRequirement);
        replayRegistry.setSelfRegistrationBurn(TYPE_ONE, 2 ether);
        replayRegistry.setSelfUpdateBurn(TYPE_ONE, 1 ether);
        vm.stopPrank();

        // three nodes register, one updates, one deregisters
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(replaySafes[i]);
            replayRegistry.selfRegister(TYPE_ONE, replayNodes[i], abi.encodePacked("node", uint8(i)));
        }
        vm.warp(FIXED_TIMESTAMP + 600);
        vm.prank(replaySafes[0]);
        replayRegistry.selfUpdate(TYPE_ONE, replayNodes[0], hex"aabb");
        vm.prank(replaySafes[2]);
        replayRegistry.selfDeregister(TYPE_ONE, replayNodes[2]);

        // one node also joins the second type
        vm.prank(replaySafes[1]);
        replayRegistry.selfRegister(TYPE_TWO, replayNodes[1], hex"cc");

        // ownership transfer, then abandonment
        vm.prank(typeOwner);
        replayRegistry.transferTypeOwnership(TYPE_ONE, safeA);
        vm.prank(safeA);
        replayRegistry.transferTypeOwnership(TYPE_ONE, address(0));

        // manager and admin actions
        vm.prank(manager);
        replayRegistry.setTypeRegistrationFee(7 ether);
        vm.prank(admin);
        replayRegistry.setNodeSafeRegistry(INodeSafeRegistry(address(swappedBindings)), replayNodes[0], replaySafes[0]);

        // a stray transfer and its recovery
        vm.prank(replaySafes[1]);
        bool success = hoprToken.transfer(address(replayRegistry), 3 ether);
        require(success, "Token transfer failed");
        vm.prank(admin);
        replayRegistry.recoverTokens(IERC20(address(hoprToken)), stranger);
    }

    // ---------------------------------------------------------------------------------------
    // The reducer - it reads logs only, and never the registry
    // ---------------------------------------------------------------------------------------

    function _replay(Vm.Log[] memory logs) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(replayRegistry) || entry.topics.length == 0) {
                continue;
            }
            bytes32 topic = entry.topics[0];

            if (topic == REGISTRY_INITIALIZED) {
                (rebuiltVersion, rebuiltAdmin, rebuiltManager, rebuiltToken, rebuiltAdminDelay) =
                    abi.decode(entry.data, (uint256, address, address, address, uint48));
            } else if (topic == NODE_SAFE_REGISTRY_UPDATED) {
                (, rebuiltPointer) = abi.decode(entry.data, (address, address));
            } else if (topic == TYPE_REGISTRATION_FEE_UPDATED) {
                rebuiltFee = abi.decode(entry.data, (uint256));
            } else if (topic == SERVICE_TYPE_REGISTERED) {
                bytes32 serviceType = entry.topics[1];
                if (!rebuiltTypes[serviceType].exists) {
                    rebuiltTypes[serviceType].exists = true;
                    rebuiltTypeList.push(serviceType);
                }
            } else if (topic == TYPE_OWNERSHIP_TRANSFERRED) {
                (, address newOwner) = abi.decode(entry.data, (address, address));
                rebuiltTypes[entry.topics[1]].owner = newOwner;
            } else if (topic == REQUIREMENT_UPDATED) {
                rebuiltTypes[entry.topics[1]].requirement = abi.decode(entry.data, (address));
            } else if (topic == SELF_REGISTRATION_BURN_UPDATED) {
                rebuiltTypes[entry.topics[1]].registrationBurn = abi.decode(entry.data, (uint256));
            } else if (topic == SELF_UPDATE_BURN_UPDATED) {
                rebuiltTypes[entry.topics[1]].updateBurn = abi.decode(entry.data, (uint256));
            } else if (topic == REGISTERED) {
                _replayRegistered(entry);
            } else if (topic == UPDATED) {
                _replayUpdated(entry);
            } else if (topic == DEREGISTERED) {
                bytes32 serviceType = entry.topics[1];
                address node = address(uint160(uint256(entry.topics[2])));
                delete rebuiltEntries[serviceType][node];
            } else if (topic == TOKENS_RECOVERED) {
                (, rebuiltRecoveredTo, rebuiltRecoveredAmount) = abi.decode(entry.data, (address, address, uint256));
            }
        }
    }

    /// @dev `Registered` alone initializes an entry, because it sets `updatedAt` to `registeredAt`.
    function _replayRegistered(Vm.Log memory entry) internal {
        bytes32 serviceType = entry.topics[1];
        address node = address(uint160(uint256(entry.topics[2])));
        (bytes memory metadata, uint48 registeredAt,) = abi.decode(entry.data, (bytes, uint48, uint256));

        if (!rebuiltEntries[serviceType][node].exists) {
            rebuiltNodeList[serviceType].push(node);
        }
        rebuiltEntries[serviceType][node] =
            RebuiltEntry({ exists: true, metadata: metadata, registeredAt: registeredAt, updatedAt: registeredAt });
    }

    /// @dev `Updated` carries no `registeredAt`, so the reducer keeps the value it already holds.
    function _replayUpdated(Vm.Log memory entry) internal {
        bytes32 serviceType = entry.topics[1];
        address node = address(uint160(uint256(entry.topics[2])));
        (bytes memory metadata, uint48 updatedAt,) = abi.decode(entry.data, (bytes, uint48, uint256));

        rebuiltEntries[serviceType][node].metadata = metadata;
        rebuiltEntries[serviceType][node].updatedAt = updatedAt;
    }

    // ---------------------------------------------------------------------------------------
    // Comparison against the views
    // ---------------------------------------------------------------------------------------

    function _assertConfigurationMatches() internal view {
        assertEq(rebuiltVersion, replayRegistry.VERSION(), "version");
        assertEq(rebuiltToken, address(replayRegistry.WXHOPR_TOKEN()), "token");
        assertEq(rebuiltAdminDelay, replayRegistry.defaultAdminDelay(), "admin delay");
        assertTrue(replayRegistry.hasRole(replayRegistry.DEFAULT_ADMIN_ROLE(), rebuiltAdmin), "admin from logs");
        assertTrue(replayRegistry.hasRole(replayRegistry.MANAGER_ROLE(), rebuiltManager), "manager from logs");
        assertEq(rebuiltPointer, address(replayRegistry.nodeSafeRegistry()), "pointer");
        assertEq(rebuiltFee, replayRegistry.typeRegistrationFee(), "type registration fee");
        assertEq(rebuiltRecoveredAmount, 3 ether, "recovered amount");
        assertEq(rebuiltRecoveredTo, stranger, "recovery recipient");
    }

    function _assertTypesMatch() internal view {
        assertEq(rebuiltTypeList.length, replayRegistry.typeCount(), "type count");

        for (uint256 i = 0; i < rebuiltTypeList.length; i++) {
            bytes32 serviceType = rebuiltTypeList[i];
            RebuiltType memory rebuilt = rebuiltTypes[serviceType];

            assertTrue(replayRegistry.isServiceType(serviceType), "a rebuilt type must exist");
            assertEq(replayRegistry.typeOwner(serviceType), rebuilt.owner, "type owner");
            assertEq(address(replayRegistry.requirements(serviceType)), rebuilt.requirement, "requirement");
            assertEq(replayRegistry.selfRegistrationBurn(serviceType), rebuilt.registrationBurn, "registration burn");
            assertEq(replayRegistry.selfUpdateBurn(serviceType), rebuilt.updateBurn, "update burn");
        }
    }

    function _assertEntriesMatch() internal view {
        for (uint256 i = 0; i < rebuiltTypeList.length; i++) {
            bytes32 serviceType = rebuiltTypeList[i];
            address[] memory candidates = rebuiltNodeList[serviceType];

            uint256 liveCount = 0;
            for (uint256 j = 0; j < candidates.length; j++) {
                address node = candidates[j];
                RebuiltEntry memory rebuilt = rebuiltEntries[serviceType][node];

                assertEq(replayRegistry.isRegistered(serviceType, node), rebuilt.exists, "entry existence");
                if (!rebuilt.exists) {
                    continue;
                }
                liveCount++;

                HoprServiceRegistry.Entry memory actual = replayRegistry.getEntry(serviceType, node);
                assertEq(actual.metadata, rebuilt.metadata, "entry metadata");
                assertEq(actual.registeredAt, rebuilt.registeredAt, "entry registeredAt");
                assertEq(actual.updatedAt, rebuilt.updatedAt, "entry updatedAt");
            }
            assertEq(replayRegistry.nodeCount(serviceType), liveCount, "node count");
        }
    }

    /**
     * @dev Section 7. Inside a paid write the registry event precedes the logs of the token.
     *
     * Every paid registry event is matched against the burn log of the same write, in order. The
     * k-th paid event must come before the k-th burn.
     */
    function _assertRegistryEventsPrecedeTokenBurns(Vm.Log[] memory logs) internal view {
        uint256[] memory paidAt = new uint256[](logs.length);
        uint256[] memory burnedAt = new uint256[](logs.length);
        uint256 paidCount = 0;
        uint256 burnedCount = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 0) {
                continue;
            }
            if (entry.emitter == address(hoprToken) && entry.topics[0] == TOKEN_BURNED) {
                burnedAt[burnedCount++] = i;
                continue;
            }
            if (entry.emitter != address(replayRegistry)) {
                continue;
            }
            if (entry.topics[0] == SERVICE_TYPE_REGISTERED && abi.decode(entry.data, (uint256)) > 0) {
                paidAt[paidCount++] = i;
            } else if (entry.topics[0] == REGISTERED || entry.topics[0] == UPDATED) {
                (,, uint256 burned) = abi.decode(entry.data, (bytes, uint48, uint256));
                if (burned > 0) {
                    paidAt[paidCount++] = i;
                }
            }
        }

        assertEq(paidCount, burnedCount, "each paid registry event must have exactly one burn");
        assertTrue(paidCount > 0, "the scenario must contain paid writes");
        for (uint256 k = 0; k < paidCount; k++) {
            assertTrue(paidAt[k] < burnedAt[k], "the registry event must precede the burn of the same write");
        }
    }
}
