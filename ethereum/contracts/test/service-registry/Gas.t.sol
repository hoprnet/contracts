// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";

/**
 * @dev A gas baseline for the paths that a consumer feels.
 *
 * The repository keeps no gas snapshot file and disables gas reports, so these numbers are
 * recorded here instead. Each test logs the measured amount and asserts a loose ceiling. The
 * ceiling catches a large regression, and it is not a target.
 *
 * The measurement wraps one call in `gasleft()`, so it holds a small constant of test overhead.
 */
contract HoprServiceRegistryGasTest is ServiceRegistryFixtureTest {
    uint256 internal constant PAGE_SIZE = 50;

    address[PAGE_SIZE] internal pageNodes;
    address[PAGE_SIZE] internal pageSafes;

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i = 0; i < PAGE_SIZE; i++) {
            pageNodes[i] = vm.addr(30_000 + i);
            pageSafes[i] = vm.addr(31_000 + i);
            _bind(pageNodes[i], pageSafes[i]);
        }
    }

    /// @dev A registration with no metadata, and with a non-zero burn.
    function test_gasSelfRegisterWithEmptyMetadata() public {
        _registerDefaultType();

        vm.prank(safeA);
        uint256 before = gasleft();
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, "");
        uint256 used = before - gasleft();

        emit log_named_uint("gas selfRegister, 0 metadata bytes", used);
        assertLt(used, 300_000, "selfRegister with no metadata must stay well under 300k gas");
    }

    /// @dev A registration at the permanent metadata cap. This is the worst case of one write.
    function test_gasSelfRegisterAtTheMetadataCap() public {
        _registerDefaultType();
        bytes memory metadata = _metadataOfLength(registry.MAX_METADATA_LENGTH());

        vm.prank(safeA);
        uint256 before = gasleft();
        registry.selfRegister(SERVICE_TYPE_GVPN, nodeA, metadata);
        uint256 used = before - gasleft();

        emit log_named_uint("gas selfRegister, 2048 metadata bytes", used);
        assertLt(used, 2_000_000, "selfRegister at the cap must stay under 2M gas");
    }

    /// @dev An update at the cap, which is the other paid write.
    function test_gasSelfUpdateAtTheMetadataCap() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, "");
        bytes memory metadata = _metadataOfLength(registry.MAX_METADATA_LENGTH());

        vm.prank(safeA);
        uint256 before = gasleft();
        registry.selfUpdate(SERVICE_TYPE_GVPN, nodeA, metadata);
        uint256 used = before - gasleft();

        emit log_named_uint("gas selfUpdate, 2048 metadata bytes", used);
        assertLt(used, 2_000_000, "selfUpdate at the cap must stay under 2M gas");
    }

    /// @dev A free deregistration, which refunds storage.
    function test_gasSelfDeregister() public {
        _registerDefaultType();
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, "");

        vm.prank(safeA);
        uint256 before = gasleft();
        registry.selfDeregister(SERVICE_TYPE_GVPN, nodeA);
        uint256 used = before - gasleft();

        emit log_named_uint("gas selfDeregister", used);
        assertLt(used, 100_000, "selfDeregister must stay under 100k gas");
    }

    /// @dev A full page of 50 entries that carry no metadata.
    function test_gasGetEntriesPaginatedWithEmptyMetadata() public {
        _fillPage(0);

        uint256 before = gasleft();
        registry.getEntriesPaginated(SERVICE_TYPE_GVPN, 0, PAGE_SIZE);
        uint256 used = before - gasleft();

        emit log_named_uint("gas getEntriesPaginated(limit=50), 0 metadata bytes", used);
        assertLt(used, 2_000_000, "an empty page of 50 must stay under 2M gas");
    }

    /**
     * @dev A full page of 50 entries at the metadata cap.
     *
     * This is the case that the NatSpec of `getEntriesPaginated` warns about: 50 entries of 2048
     * bytes is roughly 100 KB of returned data, which can exceed the response size limit of a
     * public RPC node.
     */
    function test_gasGetEntriesPaginatedAtTheMetadataCap() public {
        _fillPage(registry.MAX_METADATA_LENGTH());

        uint256 before = gasleft();
        (address[] memory nodes, HoprServiceRegistry.Entry[] memory entries) =
            registry.getEntriesPaginated(SERVICE_TYPE_GVPN, 0, PAGE_SIZE);
        uint256 used = before - gasleft();

        assertEq(nodes.length, PAGE_SIZE, "the page must be full");
        assertEq(entries[0].metadata.length, registry.MAX_METADATA_LENGTH(), "each entry carries the cap");

        emit log_named_uint("gas getEntriesPaginated(limit=50), 2048 metadata bytes", used);
        assertLt(used, 20_000_000, "a full page of 50 at the cap must stay under 20M gas");
    }

    /// @dev Registers the default type with zero burns, then fills it with one page of entries.
    function _fillPage(uint256 metadataLength) internal {
        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), 0, 0);
        bytes memory metadata = _metadataOfLength(metadataLength);
        for (uint256 i = 0; i < PAGE_SIZE; i++) {
            vm.prank(pageSafes[i]);
            registry.selfRegister(SERVICE_TYPE_GVPN, pageNodes[i], metadata);
        }
    }
}
