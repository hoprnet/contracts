//! ABI-encoded payloads for commonly used HOPR contract calls.
//!
//! The helpers in this module deliberately use the generated bindings instead of
//! duplicating function selectors or manually laying out ABI words.

use alloy::{
    primitives::{Address, Bytes, U256, aliases::U96},
    providers::bindings::IMulticall3,
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

mod multisend_binding {
    use alloy::sol;

    sol! {
        /// Minimal binding for the Safe MultiSend library.
        interface IMultiSend {
            function multiSend(bytes memory transactions) external payable;
        }
    }
}

use multisend_binding::IMultiSend;

/// One call submitted to Multicall3's `aggregate3` function.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Multicall3Call {
    pub target: Address,
    pub allow_failure: bool,
    pub action: PayloadAction,
}

/// Operation performed by a transaction in a Safe MultiSend batch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum SafeOperation {
    Call = 0,
    DelegateCall = 1,
}

/// One packed transaction in a Safe MultiSend batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SafeMultisendTransaction {
    pub operation: SafeOperation,
    pub to: Address,
    pub value: U256,
    pub action: PayloadAction,
}

/// Contract actions that may be ABI-encoded by this module.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PayloadAction {
    Approve {
        spender: Address,
        value: U256,
    },
    Transfer {
        recipient: Address,
        amount: U256,
    },
    Send {
        recipient: Address,
        amount: U256,
        data: Bytes,
    },
    RegisterSafeByNode {
        safe_addr: Address,
    },
    DeregisterNodeBySafe {
        node_addr: Address,
    },
    FundChannel {
        account: Address,
        amount: U96,
    },
    FundChannelSafe {
        self_address: Address,
        account: Address,
        amount: U96,
    },
    CloseIncomingChannel {
        source: Address,
    },
    CloseIncomingChannelSafe {
        self_address: Address,
        source: Address,
    },
    InitiateOutgoingChannelClosure {
        destination: Address,
    },
    InitiateOutgoingChannelClosureSafe {
        self_address: Address,
        destination: Address,
    },
    FinalizeOutgoingChannelClosure {
        destination: Address,
    },
    FinalizeOutgoingChannelClosureSafe {
        self_address: Address,
        destination: Address,
    },
    SelfServiceRegister {
        service_type: [u8; 32],
        node: Address,
        metadata: Bytes,
    },
    SelfUpdate {
        service_type: [u8; 32],
        node: Address,
        metadata: Bytes,
    },
    SelfDeregister {
        service_type: [u8; 32],
        node: Address,
    },
}

impl PayloadAction {
    /// ABI-encode this approved action into transaction calldata.
    pub fn encode(&self) -> Vec<u8> {
        match self {
            Self::Approve { spender, value } => approve(*spender, *value),
            Self::Transfer { recipient, amount } => transfer(*recipient, *amount),
            Self::Send {
                recipient,
                amount,
                data,
            } => send(*recipient, *amount, data.clone()),
            Self::RegisterSafeByNode { safe_addr } => register_safe_by_node(*safe_addr),
            Self::DeregisterNodeBySafe { node_addr } => deregister_node_by_safe(*node_addr),
            Self::FundChannel { account, amount } => fund_channel(*account, *amount),
            Self::FundChannelSafe {
                self_address,
                account,
                amount,
            } => fund_channel_safe(*self_address, *account, *amount),
            Self::CloseIncomingChannel { source } => close_incoming_channel(*source),
            Self::CloseIncomingChannelSafe { self_address, source } => {
                close_incoming_channel_safe(*self_address, *source)
            }
            Self::InitiateOutgoingChannelClosure { destination } => initiate_outgoing_channel_closure(*destination),
            Self::InitiateOutgoingChannelClosureSafe {
                self_address,
                destination,
            } => initiate_outgoing_channel_closure_safe(*self_address, *destination),
            Self::FinalizeOutgoingChannelClosure { destination } => finalize_outgoing_channel_closure(*destination),
            Self::FinalizeOutgoingChannelClosureSafe {
                self_address,
                destination,
            } => finalize_outgoing_channel_closure_safe(*self_address, *destination),
            Self::SelfServiceRegister {
                service_type,
                node,
                metadata,
            } => self_service_register(*service_type, *node, metadata.clone()),
            Self::SelfUpdate {
                service_type,
                node,
                metadata,
            } => self_update(*service_type, *node, metadata.clone()),
            Self::SelfDeregister { service_type, node } => self_deregister(*service_type, *node),
        }
    }
}

/// Encode `HoprToken.approve(spender, value)`.
fn approve(spender: Address, value: U256) -> Vec<u8> {
    approveCall { spender, value }.abi_encode()
}

/// Encode `HoprToken.transfer(recipient, amount)`.
fn transfer(recipient: Address, amount: U256) -> Vec<u8> {
    transferCall { recipient, amount }.abi_encode()
}

/// Encode the ERC-777-style `HoprToken.send(recipient, amount, data)` call.
fn send(recipient: Address, amount: U256, data: impl Into<Bytes>) -> Vec<u8> {
    sendCall {
        recipient,
        amount,
        data: data.into(),
    }
    .abi_encode()
}

/// Encode `HoprNodeSafeRegistry.registerSafeByNode(safeAddr)`.
fn register_safe_by_node(safe_addr: Address) -> Vec<u8> {
    registerSafeByNodeCall { safeAddr: safe_addr }.abi_encode()
}

/// Encode `HoprNodeSafeRegistry.deregisterNodeBySafe(nodeAddr)`.
fn deregister_node_by_safe(node_addr: Address) -> Vec<u8> {
    deregisterNodeBySafeCall { nodeAddr: node_addr }.abi_encode()
}

/// Encode `HoprChannels.fundChannel(account, amount)`.
fn fund_channel(account: Address, amount: U96) -> Vec<u8> {
    fundChannelCall { account, amount }.abi_encode()
}

/// Encode `HoprChannels.fundChannelSafe(selfAddress, account, amount)`.
fn fund_channel_safe(self_address: Address, account: Address, amount: U96) -> Vec<u8> {
    fundChannelSafeCall {
        selfAddress: self_address,
        account,
        amount,
    }
    .abi_encode()
}

/// Encode `HoprChannels.closeIncomingChannel(source)`.
fn close_incoming_channel(source: Address) -> Vec<u8> {
    closeIncomingChannelCall { source }.abi_encode()
}

/// Encode `HoprChannels.closeIncomingChannelSafe(selfAddress, source)`.
fn close_incoming_channel_safe(self_address: Address, source: Address) -> Vec<u8> {
    closeIncomingChannelSafeCall {
        selfAddress: self_address,
        source,
    }
    .abi_encode()
}

/// Encode `HoprChannels.initiateOutgoingChannelClosure(destination)`.
fn initiate_outgoing_channel_closure(destination: Address) -> Vec<u8> {
    initiateOutgoingChannelClosureCall { destination }.abi_encode()
}

/// Encode `HoprChannels.initiateOutgoingChannelClosureSafe(selfAddress, destination)`.
fn initiate_outgoing_channel_closure_safe(self_address: Address, destination: Address) -> Vec<u8> {
    initiateOutgoingChannelClosureSafeCall {
        selfAddress: self_address,
        destination,
    }
    .abi_encode()
}

/// Encode `HoprChannels.finalizeOutgoingChannelClosure(destination)`.
fn finalize_outgoing_channel_closure(destination: Address) -> Vec<u8> {
    finalizeOutgoingChannelClosureCall { destination }.abi_encode()
}

/// Encode `HoprChannels.finalizeOutgoingChannelClosureSafe(selfAddress, destination)`.
fn finalize_outgoing_channel_closure_safe(self_address: Address, destination: Address) -> Vec<u8> {
    finalizeOutgoingChannelClosureSafeCall {
        selfAddress: self_address,
        destination,
    }
    .abi_encode()
}

/// Encode `HoprServiceRegistry.selfRegister(bytes32 serviceType, address node, bytes memory metadata)`
fn self_service_register(service_type: [u8; 32], node: Address, metadata: Bytes) -> Vec<u8> {
    selfRegisterCall {
        serviceType: service_type.into(),
        node,
        metadata,
    }
    .abi_encode()
}

/// Encode `HoprServiceRegistry.selfUpdate(bytes32 serviceType, address node, bytes memory metadata)`
fn self_update(service_type: [u8; 32], node: Address, metadata: Bytes) -> Vec<u8> {
    selfUpdateCall {
        serviceType: service_type.into(),
        node,
        metadata,
    }
    .abi_encode()
}

/// Encode `HoprServiceRegistry.selfDeregister(bytes32 serviceType, address node)`
fn self_deregister(service_type: [u8; 32], node: Address) -> Vec<u8> {
    selfDeregisterCall {
        serviceType: service_type.into(),
        node,
    }
    .abi_encode()
}

/// Encode `Multicall3.aggregate3((address,bool,bytes)[])`.
///
/// `allow_failure` controls whether a failed individual call reverts the entire batch.
pub fn multicall3(calls: impl IntoIterator<Item = Multicall3Call>) -> Vec<u8> {
    IMulticall3::aggregate3Call {
        calls: calls
            .into_iter()
            .map(|call| IMulticall3::Call3 {
                target: call.target,
                allowFailure: call.allow_failure,
                callData: call.action.encode().into(),
            })
            .collect(),
    }
    .abi_encode()
}

/// Encode `MultiSend.multiSend(bytes)` with Safe's packed transaction format.
///
/// Every transaction is packed as `operation || to || value || data_length || data`.
/// Both regular calls and delegate calls are supported through [`SafeOperation`].
pub fn multisend(transactions: &[SafeMultisendTransaction]) -> Vec<u8> {
    let encoded = transactions
        .iter()
        .map(|transaction| (transaction, transaction.action.encode()))
        .collect::<Vec<_>>();
    let packed_len = encoded.iter().map(|(_, data)| 1 + 20 + 32 + 32 + data.len()).sum();
    let mut packed = Vec::with_capacity(packed_len);

    for (transaction, data) in encoded {
        packed.push(transaction.operation as u8);
        packed.extend_from_slice(transaction.to.as_slice());
        packed.extend_from_slice(&transaction.value.to_be_bytes::<32>());
        packed.extend_from_slice(&U256::from(data.len()).to_be_bytes::<32>());
        packed.extend_from_slice(&data);
    }

    IMultiSend::multiSendCall {
        transactions: packed.into(),
    }
    .abi_encode()
}

/// Wrap already encoded contract calldata in a Safe module execution payload.
///
/// The operation is `Call` (`0`) and no native token value is attached.
pub fn exec_transaction_from_module(to: Address, action: &PayloadAction) -> Vec<u8> {
    execTransactionFromModuleCall {
        to,
        value: U256::ZERO,
        data: action.encode().into(),
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
        let action = PayloadAction::FinalizeOutgoingChannelClosure { destination };
        let inner = action.encode();

        let decoded =
            execTransactionFromModuleCall::abi_decode_validate(&exec_transaction_from_module(channels, &action))
                .unwrap();

        assert_eq!(decoded.to, channels);
        assert_eq!(decoded.value, U256::ZERO);
        assert_eq!(decoded.operation, 0);
        assert_eq!(decoded.data.as_ref(), inner);

        let nested = finalizeOutgoingChannelClosureCall::abi_decode_validate(&decoded.data).unwrap();
        assert_eq!(nested.destination, destination);
    }

    #[test]
    fn multicall3_round_trips_calls_and_failure_policy() {
        let first_target = address!("7777777777777777777777777777777777777777");
        let second_target = address!("8888888888888888888888888888888888888888");
        let first_action = PayloadAction::Approve {
            spender: second_target,
            value: U256::from(123),
        };
        let second_action = PayloadAction::FinalizeOutgoingChannelClosure {
            destination: first_target,
        };

        let payload = multicall3([
            Multicall3Call {
                target: first_target,
                allow_failure: false,
                action: first_action.clone(),
            },
            Multicall3Call {
                target: second_target,
                allow_failure: true,
                action: second_action.clone(),
            },
        ]);
        let decoded = IMulticall3::aggregate3Call::abi_decode_validate(&payload).unwrap();

        assert_eq!(decoded.calls.len(), 2);
        assert_eq!(decoded.calls[0].target, first_target);
        assert!(!decoded.calls[0].allowFailure);
        assert_eq!(decoded.calls[0].callData.as_ref(), first_action.encode());
        assert_eq!(decoded.calls[1].target, second_target);
        assert!(decoded.calls[1].allowFailure);
        assert_eq!(decoded.calls[1].callData.as_ref(), second_action.encode());
        assert_eq!(&payload[..4], &hex!("82ad56cb"));
    }

    #[test]
    fn multisend_packs_call_and_delegatecall_transactions() {
        let call_target = address!("9999999999999999999999999999999999999999");
        let delegate_target = address!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        let call_action = PayloadAction::Transfer {
            recipient: delegate_target,
            amount: U256::from(9),
        };
        let delegate_action = PayloadAction::CloseIncomingChannel { source: call_target };
        let call_data = call_action.encode();
        let delegate_data = delegate_action.encode();

        let payload = multisend(&[
            SafeMultisendTransaction {
                operation: SafeOperation::Call,
                to: call_target,
                value: U256::from(42),
                action: call_action,
            },
            SafeMultisendTransaction {
                operation: SafeOperation::DelegateCall,
                to: delegate_target,
                value: U256::ZERO,
                action: delegate_action,
            },
        ]);
        let decoded = IMultiSend::multiSendCall::abi_decode_validate(&payload).unwrap();
        let packed = decoded.transactions;

        let first_len = 1 + 20 + 32 + 32 + call_data.len();
        assert_eq!(packed[0], SafeOperation::Call as u8);
        assert_eq!(&packed[1..21], call_target.as_slice());
        assert_eq!(&packed[21..53], &U256::from(42).to_be_bytes::<32>());
        assert_eq!(&packed[53..85], &U256::from(call_data.len()).to_be_bytes::<32>());
        assert_eq!(&packed[85..first_len], &call_data[..]);

        assert_eq!(packed[first_len], SafeOperation::DelegateCall as u8);
        assert_eq!(&packed[first_len + 1..first_len + 21], delegate_target.as_slice());
        assert_eq!(&packed[first_len + 21..first_len + 53], &U256::ZERO.to_be_bytes::<32>());
        assert_eq!(
            &packed[first_len + 53..first_len + 85],
            &U256::from(delegate_data.len()).to_be_bytes::<32>()
        );
        assert_eq!(&packed[first_len + 85..], &delegate_data[..]);
        assert_eq!(&payload[..4], &hex!("8d80ff0a"));
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
