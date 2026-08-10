// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { SingleActionFromPrivateKeyScript } from "../../script/SingleAction.s.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";

/**
 * @dev The MultiSend payload that claims a service type.
 *
 * A Safe delegate-calls MultiSendCallOnly with this payload, so a wrong encoding fails on-chain
 * and costs a launch window. The builder is pure, so a test can assert the bytes directly.
 */
contract SingleActionRegisterServiceTypeTest is Test {
    SingleActionFromPrivateKeyScript internal action;

    address internal constant TOKEN = 0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1;
    address internal constant REGISTRY = 0x9A676e781A523b5d0C0e43731313A708CB607508;
    address internal constant REQUIREMENT = 0x1234567890AbcdEF1234567890aBcdef12345678;

    uint256 internal constant TYPE_FEE = 100 ether;
    uint256 internal constant REGISTRATION_BURN = 1000 ether;
    uint256 internal constant UPDATE_BURN = 100 ether;

    function setUp() public {
        action = new SingleActionFromPrivateKeyScript();
    }

    /// @dev The bundle holds exactly two calls, in the order approve then claim.
    function test_buildRegisterServiceTypePayloadEncodesBothCallsInOrder() public view {
        bytes32 serviceType = bytes32("gvpn:exit");
        bytes memory payload = action.buildRegisterServiceTypePayload(
            TOKEN, REGISTRY, TYPE_FEE, serviceType, address(0), REGISTRATION_BURN, UPDATE_BURN
        );

        assertEq(bytes4(payload), bytes4(keccak256("multiSend(bytes)")), "the payload must call multiSend");

        bytes memory bundle = abi.decode(_stripSelector(payload), (bytes));

        bytes memory approveCall = abi.encodeWithSignature("approve(address,uint256)", REGISTRY, TYPE_FEE);
        bytes memory registerCall = abi.encodeWithSignature(
            "registerServiceType(bytes32,address,uint256,uint256)",
            serviceType,
            address(0),
            REGISTRATION_BURN,
            UPDATE_BURN
        );

        bytes memory expected = abi.encodePacked(
            uint8(0),
            TOKEN,
            uint256(0),
            approveCall.length,
            approveCall,
            uint8(0),
            REGISTRY,
            uint256(0),
            registerCall.length,
            registerCall
        );

        assertEq(bundle, expected, "the bundle must approve the fee and then claim the type");
    }

    /// @dev The approval is exactly the fee, which is the price protection of section 3.6.
    function test_theApprovalIsExactlyTheTypeRegistrationFee() public view {
        bytes memory payload = action.buildRegisterServiceTypePayload(
            TOKEN, REGISTRY, TYPE_FEE, bytes32("gvpn:exit"), address(0), REGISTRATION_BURN, UPDATE_BURN
        );
        bytes memory bundle = abi.decode(_stripSelector(payload), (bytes));

        bytes memory approveCall = abi.encodeWithSignature("approve(address,uint256)", REGISTRY, TYPE_FEE);
        assertTrue(_contains(bundle, approveCall), "the bundle must approve exactly the fee");

        bytes memory tooMuch = abi.encodeWithSignature("approve(address,uint256)", REGISTRY, type(uint256).max);
        assertFalse(_contains(bundle, tooMuch), "the bundle must never approve an unlimited amount");
    }

    /// @dev Every element of the bundle is a plain call. MultiSendCallOnly rejects anything else.
    function test_everyBundledCallUsesTheCallOperation() public view {
        bytes memory payload = action.buildRegisterServiceTypePayload(
            TOKEN, REGISTRY, TYPE_FEE, bytes32("gvpn:exit"), REQUIREMENT, REGISTRATION_BURN, UPDATE_BURN
        );
        bytes memory bundle = abi.decode(_stripSelector(payload), (bytes));

        // the first byte of each element is the operation, and the first element starts at 0
        assertEq(uint8(bundle[0]), 0, "the first bundled call must be a plain call");

        bytes memory approveCall = abi.encodeWithSignature("approve(address,uint256)", REGISTRY, TYPE_FEE);
        uint256 secondElementAt = 1 + 20 + 32 + 32 + approveCall.length;
        assertEq(uint8(bundle[secondElementAt]), 0, "the second bundled call must be a plain call");
    }

    /// @dev The claim carries the exact arguments that the registry expects.
    function test_theClaimMatchesTheRegistrySelectorAndArguments() public view {
        bytes32 serviceType = bytes32("gvpn:exit");
        bytes memory payload = action.buildRegisterServiceTypePayload(
            TOKEN, REGISTRY, TYPE_FEE, serviceType, REQUIREMENT, REGISTRATION_BURN, UPDATE_BURN
        );
        bytes memory bundle = abi.decode(_stripSelector(payload), (bytes));

        bytes memory registerCall = abi.encodeWithSelector(
            HoprServiceRegistry.registerServiceType.selector, serviceType, REQUIREMENT, REGISTRATION_BURN, UPDATE_BURN
        );
        assertTrue(_contains(bundle, registerCall), "the bundle must carry the claim of the registry");
    }

    /// @dev A right-padded ASCII id survives the round trip through the Makefile conversion.
    function test_theServiceTypeIdIsRightPaddedAscii() public pure {
        assertEq(
            bytes32("gvpn:exit"),
            0x6776706e3a657869740000000000000000000000000000000000000000000000,
            "gvpn:exit must encode as right-padded ASCII"
        );
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _stripSelector(bytes memory data) internal pure returns (bytes memory stripped) {
        stripped = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; i++) {
            stripped[i - 4] = data[i];
        }
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length > haystack.length) {
            return false;
        }
        for (uint256 start = 0; start + needle.length <= haystack.length; start++) {
            bool matched = true;
            for (uint256 i = 0; i < needle.length; i++) {
                if (haystack[start + i] != needle[i]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                return true;
            }
        }
        return false;
    }
}
