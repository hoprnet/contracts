// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Vm } from "forge-std/Vm.sol";
import { ServiceRegistryFixtureTest } from "../utils/ServiceRegistry.sol";
import { HoprServiceRegistry } from "../../src/ServiceRegistry.sol";
import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";
import { ReentrantTokenHolder } from "../mocks/ServiceRegistryReentrancy.sol";
import { ReentrancyGuard } from "openzeppelin-contracts-5.4.0/utils/ReentrancyGuard.sol";
import { IERC1820Registry } from "openzeppelin-contracts-5.4.0/interfaces/IERC1820Registry.sol";
import { IERC20 } from "openzeppelin-contracts-5.4.0/token/ERC20/IERC20.sol";

/**
 * @dev Section 3.6 and the fee collection of section 5, plus invariants I4, I5 and I7.
 *
 * wxHOPR is an ERC-777 token. Its `transferFrom` calls the `tokensToSend` hook of the holder
 * before it moves the balance and before it decrements the allowance. Caller-controlled code
 * therefore runs inside every paid write, and these tests prove the two defenses of the registry
 * rather than assert them.
 */
contract HoprServiceRegistryPaymentTest is ServiceRegistryFixtureTest {
    IERC1820Registry internal constant ERC1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 internal constant TOKENS_SENDER_INTERFACE_HASH = keccak256("ERC777TokensSender");
    bytes32 internal constant TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");

    bytes32 internal constant REGISTERED_TOPIC = keccak256("Registered(bytes32,address,address,bytes,uint48,uint256)");
    bytes32 internal constant HOOK_FIRED_TOPIC = keccak256("HookFired()");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant BURNED_TOPIC = keccak256("Burned(address,address,uint256,bytes,bytes)");

    ReentrantTokenHolder internal attacker;
    address internal attackerNode;
    bytes32 internal managerRole;

    function setUp() public virtual override {
        super.setUp();

        attacker = new ReentrantTokenHolder(registry, IERC20(address(hoprToken)));
        attackerNode = vm.addr(99_001);
        managerRole = registry.MANAGER_ROLE();
        vm.label(address(attacker), "attacker");
        vm.label(attackerNode, "attackerNode");

        // `_mint` demands an ERC777TokensRecipient implementer for a contract, and `transfer` does
        // not. The attacker is funded through an EOA for that reason.
        address funder = vm.addr(99_002);
        hoprToken.mint(funder, FUNDING, hex"00", hex"00");
        vm.prank(funder);
        hoprToken.transfer(address(attacker), FUNDING);

        attacker.approveRegistry(type(uint256).max);
        _bind(attackerNode, address(attacker));

        _registerType(typeOwner, SERVICE_TYPE_GVPN, IServiceRequirement(address(0)), REGISTRATION_BURN, UPDATE_BURN);
        attacker.watch(SERVICE_TYPE_GVPN, attackerNode);
    }

    // ---------------------------------------------------------------------------------------
    // Claim 1 - the guard covers every state-mutating function
    // ---------------------------------------------------------------------------------------

    /**
     * @dev All eight guarded functions reject a reentrant call.
     *
     * The guard is a modifier, so it runs before the body of the function. The arguments of the
     * inner call therefore do not matter: the guard answers first.
     */
    function test_theGuardRejectsAReentrantCallIntoEveryGuardedFunction() public {
        _registerAttackerEntry();

        bytes[] memory innerCalls = _allGuardedCalls();
        for (uint256 i = 0; i < innerCalls.length; i++) {
            attacker.arm(innerCalls[i], true);
            attacker.callRegistry(
                abi.encodeWithSelector(
                    HoprServiceRegistry.selfUpdate.selector, SERVICE_TYPE_GVPN, attackerNode, hex"02"
                )
            );

            assertTrue(attacker.hookFired(), "the hook must fire on a paid write");
            assertFalse(attacker.lastInnerSuccess(), "the reentrant call must fail");
            assertEq(
                attacker.lastRevertData(),
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
                "the guard must be the reason"
            );
        }
    }

    /// @dev Fee-pulling outer call 1 of 3.
    function test_theGuardHoldsWhenTheOuterCallIsRegisterServiceType() public {
        attacker.arm(
            abi.encodeWithSelector(
                HoprServiceRegistry.registerServiceType.selector,
                bytes32("inner"),
                IServiceRequirement(address(0)),
                uint256(0),
                uint256(0)
            ),
            true
        );

        attacker.callRegistry(
            abi.encodeWithSelector(
                HoprServiceRegistry.registerServiceType.selector,
                SERVICE_TYPE_ALT,
                IServiceRequirement(address(0)),
                uint256(0),
                uint256(0)
            )
        );

        assertTrue(attacker.hookFired(), "the hook must fire");
        assertFalse(attacker.lastInnerSuccess(), "the reentrant call must fail");
        assertFalse(registry.isServiceType(bytes32("inner")), "the reentrant type must not exist");
        assertTrue(registry.isServiceType(SERVICE_TYPE_ALT), "the outer type must exist");
    }

    /// @dev Fee-pulling outer call 2 of 3.
    function test_theGuardHoldsWhenTheOuterCallIsSelfRegister() public {
        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_GVPN, attackerNode), true
        );

        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfRegister.selector, SERVICE_TYPE_GVPN, attackerNode, hex"01")
        );

        assertTrue(attacker.hookFired(), "the hook must fire");
        assertFalse(attacker.lastInnerSuccess(), "the reentrant call must fail");
        assertTrue(registry.isRegistered(SERVICE_TYPE_GVPN, attackerNode), "the outer entry must survive");
    }

    /// @dev Fee-pulling outer call 3 of 3.
    function test_theGuardHoldsWhenTheOuterCallIsSelfUpdate() public {
        _registerAttackerEntry();

        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_GVPN, attackerNode), true
        );
        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfUpdate.selector, SERVICE_TYPE_GVPN, attackerNode, hex"77")
        );

        assertFalse(attacker.lastInnerSuccess(), "the reentrant call must fail");
        _assertEntry(SERVICE_TYPE_GVPN, attackerNode, hex"77", uint48(FIXED_TIMESTAMP), uint48(FIXED_TIMESTAMP));
    }

    // ---------------------------------------------------------------------------------------
    // Claim 2 - a hook that does not swallow reverts the whole transaction
    // ---------------------------------------------------------------------------------------

    function testRevert_theOuterCallDueToAReentrantCallThatBubbles() public {
        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_GVPN, attackerNode), false
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfRegister.selector, SERVICE_TYPE_GVPN, attackerNode, hex"01")
        );

        _assertNoEntry(SERVICE_TYPE_GVPN, attackerNode);
        assertEq(registry.nodeCount(SERVICE_TYPE_GVPN), 0, "nothing must be written");
        _assertNoTokensAtRest();
    }

    // ---------------------------------------------------------------------------------------
    // Claim 3 - checks-effects-interactions, proved from inside the token pull
    // ---------------------------------------------------------------------------------------

    /**
     * @dev The hook sees a complete entry and an empty registry balance.
     *
     * The effects landed before the token pull started. The interaction had not happened yet. This
     * is the load-bearing evidence for the ordering rule of section 3.6.
     */
    function test_theHookObservesEffectsBeforeTheInteraction() public {
        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_GVPN, attackerNode), true
        );

        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfRegister.selector, SERVICE_TYPE_GVPN, attackerNode, hex"01")
        );

        assertTrue(attacker.seenIsRegistered(), "the hook must see a registered entry");
        assertEq(attacker.seenRegisteredAt(), uint48(FIXED_TIMESTAMP), "the hook must see the final registeredAt");
        assertEq(attacker.seenNodeCount(), 1, "the hook must see the entry in the node set");
        assertEq(attacker.seenRegistryBalance(), 0, "the hook must see no tokens in the registry yet");
    }

    // ---------------------------------------------------------------------------------------
    // Claim 4 - log ordering inside one receipt, section 7
    // ---------------------------------------------------------------------------------------

    function test_registryEventsPrecedeTheHookAndTheTokenLogs() public {
        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_GVPN, attackerNode), true
        );

        vm.recordLogs();
        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfRegister.selector, SERVICE_TYPE_GVPN, attackerNode, hex"01")
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 registeredAt = _firstIndexOf(logs, address(registry), REGISTERED_TOPIC, 0);
        uint256 hookAt = _firstIndexOf(logs, address(attacker), HOOK_FIRED_TOPIC, 0);
        uint256 pullTransferAt = _firstIndexOf(logs, address(hoprToken), TRANSFER_TOPIC, hookAt);
        uint256 burnedAt = _firstIndexOf(logs, address(hoprToken), BURNED_TOPIC, 0);

        assertTrue(registeredAt < hookAt, "the registry event must precede the hook");
        assertTrue(hookAt < pullTransferAt, "the hook must precede the token transfer");
        assertTrue(pullTransferAt < burnedAt, "the transfer must precede the burn");
    }

    // ---------------------------------------------------------------------------------------
    // Claim 5 - invariant I7, the registry has no receiver hooks
    // ---------------------------------------------------------------------------------------

    function test_theRegistryRegistersNoErc1820Interfaces() public view {
        assertEq(
            ERC1820.getInterfaceImplementer(address(registry), TOKENS_RECIPIENT_INTERFACE_HASH),
            address(0),
            "I7: no ERC777TokensRecipient implementer"
        );
        assertEq(
            ERC1820.getInterfaceImplementer(address(registry), TOKENS_SENDER_INTERFACE_HASH),
            address(0),
            "I7: no ERC777TokensSender implementer"
        );
    }

    /**
     * @dev The registry can receive through `transferFrom`, and not through `send`.
     *
     * `transfer` and `transferFrom` pass `requireReceptionAck = false`, while `send` passes true.
     * A contract with no ERC-1820 registration is therefore reachable by the first pair only, and
     * that is what makes the pull model viable without any receiver hook.
     */
    function test_theRegistryAcceptsTransferFromButRejectsSend() public {
        vm.prank(safeA);
        hoprToken.approve(stranger, 1 ether);

        vm.prank(stranger);
        hoprToken.transferFrom(safeA, address(registry), 1 ether);
        assertEq(hoprToken.balanceOf(address(registry)), 1 ether, "transferFrom must reach the registry");

        vm.prank(safeA);
        vm.expectRevert(bytes("ERC777: token recipient contract has no implementer for ERC777TokensRecipient"));
        hoprToken.send(address(registry), 1 ether, "");
    }

    /// @dev The registry has no receive function and no fallback function.
    function testRevert_aPlainValueCallToTheRegistry() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool success,) = address(registry).call{ value: 1 ether }("");
        assertFalse(success, "the registry must reject native value");
    }

    // ---------------------------------------------------------------------------------------
    // Claim 6 - invariants I4 and I5 at rest
    // ---------------------------------------------------------------------------------------

    function test_theRegistryHoldsNoTokensAfterEveryPaidPath() public {
        uint256 supplyBefore = hoprToken.totalSupply();

        _registerType(stranger, SERVICE_TYPE_ALT, IServiceRequirement(address(0)), REGISTRATION_BURN, UPDATE_BURN);
        _assertNoTokensAtRest();

        _registerEntry(safeA, SERVICE_TYPE_ALT, nodeA, hex"01");
        _assertNoTokensAtRest();

        vm.prank(safeA);
        registry.selfUpdate(SERVICE_TYPE_ALT, nodeA, hex"02");
        _assertNoTokensAtRest();

        vm.prank(safeA);
        registry.selfDeregister(SERVICE_TYPE_ALT, nodeA);
        _assertNoTokensAtRest();

        assertEq(
            hoprToken.totalSupply(),
            supplyBefore - TYPE_FEE - REGISTRATION_BURN - UPDATE_BURN,
            "the supply must fall by exactly the three configured amounts"
        );
        _assertVictimUntouched();
    }

    /**
     * @dev Invariant I4. A donation is neither burned nor visible in the burn event.
     *
     * Fee collection burns the configured amount and never `balanceOf`, so a pre-donated balance
     * survives the paid write untouched and stays reachable for `recoverTokens`.
     */
    function test_aDonationIsNeitherBurnedNorReflectedInTheEvent() public {
        vm.prank(safeB);
        hoprToken.transfer(address(registry), 777 ether);
        assertEq(hoprToken.balanceOf(address(registry)), 777 ether, "the donation must land");

        uint256 supplyBefore = hoprToken.totalSupply();

        vm.expectEmit(true, true, true, true, address(registry));
        emit Registered(SERVICE_TYPE_GVPN, nodeA, safeA, hex"01", uint48(FIXED_TIMESTAMP), REGISTRATION_BURN);
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        assertEq(
            hoprToken.totalSupply(), supplyBefore - REGISTRATION_BURN, "only the configured burn may leave the supply"
        );
        assertEq(hoprToken.balanceOf(address(registry)), 777 ether, "the donation must survive the paid write");

        vm.prank(admin);
        registry.recoverTokens(IERC20(address(hoprToken)), stranger);
        assertEq(hoprToken.balanceOf(address(registry)), 0, "recoverTokens must sweep the donation");
        assertEq(hoprToken.balanceOf(stranger), FUNDING + 777 ether, "the donation must reach the recipient");
    }

    /// @dev Invariant I5. A third party cannot spend the standing approval of `victim`.
    function test_aThirdPartyCannotSpendTheApprovalOfAnotherAccount() public {
        _registerEntry(safeA, SERVICE_TYPE_GVPN, nodeA, hex"01");

        _assertVictimUntouched();
        assertEq(hoprToken.balanceOf(safeA), FUNDING - REGISTRATION_BURN, "only the caller pays");
    }

    // ---------------------------------------------------------------------------------------
    // Zero amounts skip all token interaction
    // ---------------------------------------------------------------------------------------

    /// @dev A zero burn never reaches the token, so the hook of the caller never fires.
    function test_aZeroBurnMakesNoTokenCallAtAll() public {
        _registerType(typeOwner, SERVICE_TYPE_ALT, IServiceRequirement(address(0)), 0, 0);
        attacker.watch(SERVICE_TYPE_ALT, attackerNode);

        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_ALT, attackerNode), true
        );
        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfRegister.selector, SERVICE_TYPE_ALT, attackerNode, hex"01")
        );

        assertFalse(attacker.hookFired(), "a zero burn must not call the token");
        assertTrue(registry.isRegistered(SERVICE_TYPE_ALT, attackerNode), "the entry must still be written");
    }

    /// @dev `selfDeregister` is always free, so it never touches the token.
    function test_selfDeregisterNeverTouchesTheToken() public {
        _registerAttackerEntry();
        uint256 supplyBefore = hoprToken.totalSupply();

        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.selfUpdate.selector, SERVICE_TYPE_GVPN, attackerNode, hex"02"),
            true
        );
        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_GVPN, attackerNode)
        );

        assertFalse(attacker.hookFired(), "deregistration must not call the token");
        assertEq(hoprToken.totalSupply(), supplyBefore, "deregistration must burn nothing");
    }

    // ---------------------------------------------------------------------------------------
    // Section 3.6 - the manager setters are deliberately not guarded
    // ---------------------------------------------------------------------------------------

    /**
     * @dev A manager can raise the fee from inside the hook, and the in-flight call still burns
     * the old amount.
     *
     * The paid call reads the fee before the token pull. The exact allowance of a caller is
     * therefore the real price protection, exactly as section 3.6 claims.
     */
    function test_aManagerCanReenterTheFeeSetterAndTheInFlightBurnKeepsTheOldFee() public {
        vm.prank(admin);
        registry.grantRole(managerRole, address(attacker));

        uint256 supplyBefore = hoprToken.totalSupply();
        uint256 balanceBefore = hoprToken.balanceOf(address(attacker));

        attacker.arm(
            abi.encodeWithSelector(HoprServiceRegistry.setTypeRegistrationFee.selector, uint256(999 ether)), true
        );

        vm.expectEmit(true, true, true, true, address(registry));
        emit ServiceTypeRegistered(SERVICE_TYPE_ALT, address(attacker), TYPE_FEE);
        attacker.callRegistry(
            abi.encodeWithSelector(
                HoprServiceRegistry.registerServiceType.selector,
                SERVICE_TYPE_ALT,
                IServiceRequirement(address(0)),
                uint256(0),
                uint256(0)
            )
        );

        assertTrue(attacker.lastInnerSuccess(), "an unguarded manager setter must succeed from the hook");
        assertEq(registry.typeRegistrationFee(), 999 ether, "the new fee must be stored");
        assertEq(hoprToken.totalSupply(), supplyBefore - TYPE_FEE, "the in-flight call must burn the old fee");
        assertEq(hoprToken.balanceOf(address(attacker)), balanceBefore - TYPE_FEE, "the payer paid the old fee");
        _assertNoTokensAtRest();
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _registerAttackerEntry() internal {
        attacker.callRegistry(
            abi.encodeWithSelector(HoprServiceRegistry.selfRegister.selector, SERVICE_TYPE_GVPN, attackerNode, hex"01")
        );
    }

    /// @dev Calldata for each of the eight functions that carry the shared guard.
    function _allGuardedCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](8);
        calls[0] = abi.encodeWithSelector(
            HoprServiceRegistry.registerServiceType.selector,
            bytes32("inner"),
            IServiceRequirement(address(0)),
            uint256(0),
            uint256(0)
        );
        calls[1] = abi.encodeWithSelector(HoprServiceRegistry.setRequirement.selector, SERVICE_TYPE_GVPN, address(0));
        calls[2] =
            abi.encodeWithSelector(HoprServiceRegistry.setSelfRegistrationBurn.selector, SERVICE_TYPE_GVPN, uint256(1));
        calls[3] = abi.encodeWithSelector(HoprServiceRegistry.setSelfUpdateBurn.selector, SERVICE_TYPE_GVPN, uint256(1));
        calls[4] = abi.encodeWithSelector(
            HoprServiceRegistry.transferTypeOwnership.selector, SERVICE_TYPE_GVPN, address(attacker)
        );
        calls[5] = abi.encodeWithSelector(
            HoprServiceRegistry.selfRegister.selector, SERVICE_TYPE_GVPN, attackerNode, hex"03"
        );
        calls[6] =
            abi.encodeWithSelector(HoprServiceRegistry.selfUpdate.selector, SERVICE_TYPE_GVPN, attackerNode, hex"04");
        calls[7] = abi.encodeWithSelector(HoprServiceRegistry.selfDeregister.selector, SERVICE_TYPE_GVPN, attackerNode);
    }

    /// @dev The index of the first log of `emitter` with topic `topic0`, at or after `fromIndex`.
    function _firstIndexOf(
        Vm.Log[] memory logs,
        address emitter,
        bytes32 topic0,
        uint256 fromIndex
    )
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = fromIndex; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return i;
            }
        }
        revert("expected log not found");
    }
}
