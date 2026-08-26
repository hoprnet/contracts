//! ABI-encoded payloads for commonly used HOPR contract calls.
//!
//! The helpers in this module deliberately use the generated bindings instead of
//! duplicating function selectors or manually laying out ABI words.

use alloy::{
    primitives::{Address, Bytes, U256, aliases::U96},
    sol_types::SolCall,
};

use crate::{
    hopr_channels::HoprChannels::{
        closeIncomingChannelCall, closeIncomingChannelSafeCall, finalizeOutgoingChannelClosureCall,
        finalizeOutgoingChannelClosureSafeCall, fundChannelCall, fundChannelSafeCall,
        initiateOutgoingChannelClosureCall, initiateOutgoingChannelClosureSafeCall,
    },
    hopr_node_management_module::HoprNodeManagementModule::execTransactionFromModuleCall,
    hopr_node_safe_registry::HoprNodeSafeRegistry::{deregisterNodeBySafeCall, registerSafeByNodeCall},
    hopr_service_registry::HoprServiceRegistry::{selfDeregisterCall, selfRegisterCall, selfUpdateCall},
    hopr_token::HoprToken::{approveCall, sendCall, transferCall},
};

/// Encode `HoprToken.approve(spender, value)`.
pub fn approve(spender: Address, value: U256) -> Vec<u8> {
    approveCall { spender, value }.abi_encode()
}

/// Encode `HoprToken.transfer(recipient, amount)`.
pub fn transfer(recipient: Address, amount: U256) -> Vec<u8> {
    transferCall { recipient, amount }.abi_encode()
}

/// Encode the ERC-777-style `HoprToken.send(recipient, amount, data)` call.
pub fn send(recipient: Address, amount: U256, data: impl Into<Bytes>) -> Vec<u8> {
    sendCall {
        recipient,
        amount,
        data: data.into(),
    }
    .abi_encode()
}

/// Encode `HoprNodeSafeRegistry.registerSafeByNode(safeAddr)`.
pub fn register_safe_by_node(safe_addr: Address) -> Vec<u8> {
    registerSafeByNodeCall { safeAddr: safe_addr }.abi_encode()
}

/// Encode `HoprNodeSafeRegistry.deregisterNodeBySafe(nodeAddr)`.
pub fn deregister_node_by_safe(node_addr: Address) -> Vec<u8> {
    deregisterNodeBySafeCall { nodeAddr: node_addr }.abi_encode()
}

/// Encode `HoprChannels.fundChannel(account, amount)`.
pub fn fund_channel(account: Address, amount: U96) -> Vec<u8> {
    fundChannelCall { account, amount }.abi_encode()
}

/// Encode `HoprChannels.fundChannelSafe(selfAddress, account, amount)`.
pub fn fund_channel_safe(self_address: Address, account: Address, amount: U96) -> Vec<u8> {
    fundChannelSafeCall {
        selfAddress: self_address,
        account,
        amount,
    }
    .abi_encode()
}

/// Encode `HoprChannels.closeIncomingChannel(source)`.
pub fn close_incoming_channel(source: Address) -> Vec<u8> {
    closeIncomingChannelCall { source }.abi_encode()
}

/// Encode `HoprChannels.closeIncomingChannelSafe(selfAddress, source)`.
pub fn close_incoming_channel_safe(self_address: Address, source: Address) -> Vec<u8> {
    closeIncomingChannelSafeCall {
        selfAddress: self_address,
        source,
    }
    .abi_encode()
}

/// Encode `HoprChannels.initiateOutgoingChannelClosure(destination)`.
pub fn initiate_outgoing_channel_closure(destination: Address) -> Vec<u8> {
    initiateOutgoingChannelClosureCall { destination }.abi_encode()
}

/// Encode `HoprChannels.initiateOutgoingChannelClosureSafe(selfAddress, destination)`.
pub fn initiate_outgoing_channel_closure_safe(self_address: Address, destination: Address) -> Vec<u8> {
    initiateOutgoingChannelClosureSafeCall {
        selfAddress: self_address,
        destination,
    }
    .abi_encode()
}

/// Encode `HoprChannels.finalizeOutgoingChannelClosure(destination)`.
pub fn finalize_outgoing_channel_closure(destination: Address) -> Vec<u8> {
    finalizeOutgoingChannelClosureCall { destination }.abi_encode()
}

/// Encode `HoprChannels.finalizeOutgoingChannelClosureSafe(selfAddress, destination)`.
pub fn finalize_outgoing_channel_closure_safe(self_address: Address, destination: Address) -> Vec<u8> {
    finalizeOutgoingChannelClosureSafeCall {
        selfAddress: self_address,
        destination,
    }
    .abi_encode()
}

/// Encode `HoprServiceRegistry.selfRegister(bytes32 serviceType, address node, bytes memory metadata)`
pub fn self_service_register(service_type: [u8; 32], node: Address, metadata: Bytes) -> Vec<u8> {
    selfRegisterCall {
        serviceType: service_type.into(),
        node,
        metadata,
    }
    .abi_encode()
}

/// Encode `HoprServiceRegistry.selfUpdate(bytes32 serviceType, address node, bytes memory metadata)`
pub fn self_update(service_type: [u8; 32], node: Address, metadata: Bytes) -> Vec<u8> {
    selfUpdateCall {
        serviceType: service_type.into(),
        node,
        metadata,
    }
    .abi_encode()
}

/// Encode `HoprServiceRegistry.selfDeregister(bytes32 serviceType, address node)`
pub fn self_deregister(service_type: [u8; 32], node: Address) -> Vec<u8> {
    selfDeregisterCall {
        serviceType: service_type.into(),
        node,
    }
    .abi_encode()
}

/// Wrap already encoded contract calldata in a Safe module execution payload.
///
/// The operation is `Call` (`0`) and no native token value is attached.
pub fn exec_transaction_from_module(to: Address, data: impl Into<Bytes>) -> Vec<u8> {
    execTransactionFromModuleCall {
        to,
        value: U256::ZERO,
        data: data.into(),
        operation: 0,
    }
    .abi_encode()
}

#[cfg(test)]
mod tests {
    use alloy::primitives::{B256, address, bytes, hex, uint};

    use super::*;

    #[test]
    fn token_payloads_round_trip_all_arguments() {
        let account = address!("1111111111111111111111111111111111111111");
        let amount = uint!(123456789_U256);

        let approve = approveCall::abi_decode_validate(&approve(account, amount)).unwrap();
        assert_eq!(approve.spender, account);
        assert_eq!(approve.value, amount);

        let transfer = transferCall::abi_decode_validate(&transfer(account, amount)).unwrap();
        assert_eq!(transfer.recipient, account);
        assert_eq!(transfer.amount, amount);

        let metadata = bytes!("deadbeef00");
        let send = sendCall::abi_decode_validate(&send(account, amount, metadata.clone())).unwrap();
        assert_eq!(send.recipient, account);
        assert_eq!(send.amount, amount);
        assert_eq!(send.data, metadata);
    }

    #[test]
    fn channel_payloads_round_trip_basic_and_safe_arguments() {
        let own = address!("1111111111111111111111111111111111111111");
        let peer = address!("2222222222222222222222222222222222222222");
        let amount = U96::from(42);

        let fund = fundChannelCall::abi_decode_validate(&fund_channel(peer, amount)).unwrap();
        assert_eq!((fund.account, fund.amount), (peer, amount));

        let fund_safe = fundChannelSafeCall::abi_decode_validate(&fund_channel_safe(own, peer, amount)).unwrap();
        assert_eq!(
            (fund_safe.selfAddress, fund_safe.account, fund_safe.amount),
            (own, peer, amount)
        );

        let close = closeIncomingChannelCall::abi_decode_validate(&close_incoming_channel(peer)).unwrap();
        assert_eq!(close.source, peer);
        let close_safe =
            closeIncomingChannelSafeCall::abi_decode_validate(&close_incoming_channel_safe(own, peer)).unwrap();
        assert_eq!((close_safe.selfAddress, close_safe.source), (own, peer));

        let initiate =
            initiateOutgoingChannelClosureCall::abi_decode_validate(&initiate_outgoing_channel_closure(peer)).unwrap();
        assert_eq!(initiate.destination, peer);
        let initiate_safe = initiateOutgoingChannelClosureSafeCall::abi_decode_validate(
            &initiate_outgoing_channel_closure_safe(own, peer),
        )
        .unwrap();
        assert_eq!((initiate_safe.selfAddress, initiate_safe.destination), (own, peer));

        let finalize =
            finalizeOutgoingChannelClosureCall::abi_decode_validate(&finalize_outgoing_channel_closure(peer)).unwrap();
        assert_eq!(finalize.destination, peer);
        let finalize_safe = finalizeOutgoingChannelClosureSafeCall::abi_decode_validate(
            &finalize_outgoing_channel_closure_safe(own, peer),
        )
        .unwrap();
        assert_eq!((finalize_safe.selfAddress, finalize_safe.destination), (own, peer));
    }

    #[test]
    fn registry_payloads_round_trip_static_and_dynamic_arguments() {
        let node = address!("3333333333333333333333333333333333333333");
        let safe = address!("4444444444444444444444444444444444444444");

        let register = registerSafeByNodeCall::abi_decode_validate(&register_safe_by_node(safe)).unwrap();
        assert_eq!(register.safeAddr, safe);
        let deregister = deregisterNodeBySafeCall::abi_decode_validate(&deregister_node_by_safe(node)).unwrap();
        assert_eq!(deregister.nodeAddr, node);

        let service_type = [0xabu8; 32];
        let metadata = bytes!("000102030405");
        let register_service =
            selfRegisterCall::abi_decode_validate(&self_service_register(service_type, node, metadata.clone()))
                .unwrap();
        assert_eq!(register_service.serviceType, B256::from(service_type));
        assert_eq!(register_service.node, node);
        assert_eq!(register_service.metadata, metadata);

        let updated_metadata = bytes!("feedface");
        let update =
            selfUpdateCall::abi_decode_validate(&self_update(service_type, node, updated_metadata.clone())).unwrap();
        assert_eq!(update.serviceType, B256::from(service_type));
        assert_eq!(update.node, node);
        assert_eq!(update.metadata, updated_metadata);

        let deregister_service = selfDeregisterCall::abi_decode_validate(&self_deregister(service_type, node)).unwrap();
        assert_eq!(deregister_service.serviceType, B256::from(service_type));
        assert_eq!(deregister_service.node, node);
    }

    #[test]
    fn safe_wrapper_round_trips_nested_calldata() {
        let channels = address!("5555555555555555555555555555555555555555");
        let destination = address!("6666666666666666666666666666666666666666");
        let inner = finalize_outgoing_channel_closure(destination);

        let decoded =
            execTransactionFromModuleCall::abi_decode_validate(&exec_transaction_from_module(channels, inner.clone()))
                .unwrap();

        assert_eq!(decoded.to, channels);
        assert_eq!(decoded.value, U256::ZERO);
        assert_eq!(decoded.operation, 0);
        assert_eq!(decoded.data.as_ref(), inner);

        let nested = finalizeOutgoingChannelClosureCall::abi_decode_validate(&decoded.data).unwrap();
        assert_eq!(nested.destination, destination);
    }

    #[test]
    fn static_payload_matches_known_abi_encoding() {
        let spender = address!("1111111111111111111111111111111111111111");
        let expected = hex!(
            "095ea7b3"
            "0000000000000000000000001111111111111111111111111111111111111111"
            "000000000000000000000000000000000000000000000000000000000000002a"
        );

        assert_eq!(approve(spender, U256::from(42)), expected);
    }

    #[test]
    fn decoder_rejects_payload_for_a_different_function() {
        let payload = transfer(Address::ZERO, U256::ZERO);

        assert!(approveCall::abi_decode_validate(&payload).is_err());
        assert_eq!(&payload[..4], &hex!("a9059cbb"));
    }
}
