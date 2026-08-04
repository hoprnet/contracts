// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8;

import { HoprCrypto } from "../../src/Crypto.sol";
import { HoprChannels, HoprChannelsType } from "../../src/Channels.sol";
import { SECP2561k } from "solcrypto/SECP2561k.sol";
import { Test } from "forge-std/Test.sol";

/// forge-lint:disable-next-item(mixed-case-variable)
abstract contract CryptoUtils is Test, HoprCrypto, SECP2561k {
    uint256 constant SECP256K1_HALF_FIELD_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    uint256 constant SECP256K1_BASEPOINT_X = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 constant SECP256K1_BASEPOINT_Y = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;

    struct RedeemTicketArgBuilder {
        uint256 privKeyA;
        uint256 privKeyB;
        bytes32 dst;
        address src;
        address dest;
        uint256 amount;
        uint256 maxTicketIndex;
        uint256 epoch;
        uint256 winProb;
        uint256 porSecret;
    }

    function _getChannelId(address source, address destination) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(source, destination));
    }

    function getRedeemableTicket(RedeemTicketArgBuilder memory args)
        internal
        view
        returns (HoprChannels.RedeemableTicket memory redeemable, VRFParameters memory vrf)
    {
        bytes32 channelId = _getChannelId(args.src, args.dest);

        HoprChannels.TicketData memory ticketData = HoprChannels.TicketData(
            channelId,
            HoprChannelsType.Balance.wrap(uint96(args.amount)),
            HoprChannelsType.TicketIndex.wrap(uint48(args.maxTicketIndex)),
            HoprChannelsType.ChannelEpoch.wrap(uint24(args.epoch)),
            HoprChannelsType.WinProb.wrap(uint56(args.winProb))
        );

        address challenge = HoprCrypto.scalarTimesBasepoint(args.porSecret);

        uint256 secondPart = (args.amount << 128) | (args.maxTicketIndex << 80) | (args.epoch << 56) | args.winProb;

        // Deviates from EIP712 due to computed property and non-standard struct property encoding
        bytes32 hashStruct = keccak256(
            abi.encode(
                HoprChannels.redeemTicket.selector,
                keccak256(abi.encodePacked(channelId, uint224(secondPart), challenge))
            )
        );

        bytes32 ticketHash = keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), args.dst, hashStruct));

        CompactSignature memory sig;

        {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(args.privKeyA, ticketHash);

            sig = toCompactSignature(v, r, s);
        }

        redeemable = HoprChannels.RedeemableTicket(ticketData, sig, args.porSecret);

        vrf = getVRFParameters(args.privKeyB, abi.encodePacked(args.dst), ticketHash);
    }

    function toCompactSignature(
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        internal
        pure
        returns (HoprCrypto.CompactSignature memory sig)
    {
        if (uint256(s) >= SECP256K1_HALF_FIELD_ORDER) {
            s = bytes32(HoprCrypto.SECP256K1_FIELD_ORDER - uint256(s));
        }
        sig.r = r;
        sig.vs = bytes32(uint256(v - 27) << 255) | s;
    }

    function decompressSignature(
        bytes32 r,
        bytes32 vs
    )
        internal
        pure
        returns (uint8 v_out, bytes32 r_out, bytes32 s_out)
    {
        s_out = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        v_out = uint8((uint256(vs) >> 255) + 27);
        r_out = r;
    }

    /// forge-lint: disable-next-line(mixed-case-function)
    function getVRFParameters(
        uint256 privKey,
        bytes memory dst,
        bytes32 vrfMessage
    )
        internal
        view
        returns (HoprCrypto.VRFParameters memory params)
    {
        HoprCrypto.VRFPayload memory payload;

        {
            address chain_addr = HoprCrypto.scalarTimesBasepoint(privKey);
            payload.message = vrfMessage;
            payload.signer = chain_addr;
            payload.dst = abi.encodePacked(dst);
        }

        // Everything after payload setup in a fresh stack frame
        _buildParams(privKey, payload, params);
    }

    /// @dev Computes all VRF parameter fields in a fresh stack frame.
    function _buildParams(
        uint256 privKey,
        HoprCrypto.VRFPayload memory payload,
        HoprCrypto.VRFParameters memory params
    )
        internal
        view
    {
        (uint256 bx, uint256 by) =
            HoprCrypto.hashToCurve(abi.encodePacked(payload.signer, payload.message), payload.dst);

        {
            (uint256 vx, uint256 vy) = SECP2561k.ecmul(bx, by, privKey);
            params.vx = vx;
            params.vy = vy;
        }

        // Compute A = a·G (redeemer's secp256k1 public key)
        (uint256 ax, uint256 ay) = ecmul(SECP256K1_BASEPOINT_X, SECP256K1_BASEPOINT_Y, privKey);
        params.ax = ax;
        params.ay = ay;

        uint256 r = HoprCrypto.hashToScalar(abi.encodePacked(privKey, bx, by, payload.message), payload.dst);

        (uint256 r_v_x, uint256 r_v_y) = SECP2561k.ecmul(bx, by, r);
        (uint256 r_g_x, uint256 r_g_y) = ecmul(SECP256K1_BASEPOINT_X, SECP256K1_BASEPOINT_Y, r);

        // Challenge binds both bases: signer || A || V || R_G || R_B || message
        bytes memory encoded = abi.encodePacked(payload.signer, params.ax, params.ay);
        encoded = abi.encodePacked(encoded, params.vx, params.vy, r_g_x, r_g_y);
        encoded = abi.encodePacked(encoded, r_v_x, r_v_y, payload.message);
        uint256 h = HoprCrypto.hashToScalar(encoded, payload.dst);

        params.s = addmod(r, mulmod(h, privKey, HoprCrypto.SECP256K1_FIELD_ORDER), HoprCrypto.SECP256K1_FIELD_ORDER);
        params.h = h;

        _addAllWitnesses(bx, by, params);
    }

    /// @dev Computes s·B, h·V, s·G, h·A in a fresh stack frame.
    function _addAllWitnesses(uint256 bx, uint256 by, HoprCrypto.VRFParameters memory params) internal view {
        (uint256 sBx, uint256 sBy) = SECP2561k.ecmul(bx, by, params.s);
        params.sBx = sBx;
        params.sBy = sBy;

        (uint256 hVx, uint256 hVy) = SECP2561k.ecmul(params.vx, params.vy, params.h);
        params.hVx = hVx;
        params.hVy = hVy;

        (uint256 sGx, uint256 sGy) = ecmul(SECP256K1_BASEPOINT_X, SECP256K1_BASEPOINT_Y, params.s);
        params.sGx = sGx;
        params.sGy = sGy;

        (uint256 hAx, uint256 hAy) = SECP2561k.ecmul(params.ax, params.ay, params.h);
        params.hAx = hAx;
        params.hAy = hAy;
    }
}
