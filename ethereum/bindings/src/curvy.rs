//! Transaction payload construction for Curvy contracts used by HOPR.

use alloy::{
    network::TransactionBuilder,
    primitives::{Address, U256},
    rpc::types::TransactionRequest,
    sol_types::SolCall,
};
use curvy_bindings::curvy_aggregator_alpha_v2::CurvyAggregatorAlphaV2::submitWithdrawalRequestCall;
pub use curvy_bindings::{
    constants::WITHDRAWAL_MAX_INPUTS,
    curvy_aggregator_alpha_v2::CurvyAggregatorAlphaV2::CurvyAggregatorAlphaV2Instance,
    portal_factory::{CurvyTypes, PortalFactory::PortalFactoryInstance},
};

/// Groth16 proof coordinates accepted by the Curvy aggregator.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Groth16Proof {
    pub a: [U256; 2],
    pub b: [[U256; 2]; 2],
    pub c: [U256; 2],
}

/// Inputs required to construct a Curvy withdrawal transaction.
///
/// `MAX_INPUTS` is part of the withdrawal verifier configuration. The fixed-size nullifier array ensures that the
/// generated public-signal vector always agrees with that configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CurvyWithdrawalRequest<const MAX_INPUTS: usize> {
    pub proof: Groth16Proof,
    pub token: U256,
    pub nullifiers: [U256; MAX_INPUTS],
    pub recipient: Address,
    pub amount: U256,
    pub notes_root: U256,
}

impl<const MAX_INPUTS: usize> CurvyWithdrawalRequest<MAX_INPUTS> {
    fn public_signals(&self) -> Vec<U256> {
        let mut public_signals = Vec::with_capacity(MAX_INPUTS + 4);
        public_signals.push(self.amount);
        public_signals.extend(self.nullifiers);
        public_signals.push(self.notes_root);
        public_signals.push(U256::from_be_slice(self.recipient.as_slice()));
        public_signals.push(self.token);
        public_signals
    }
}

/// Constructs signable Curvy aggregator transactions without handling keys or proof generation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CurvyPayloadGenerator {
    aggregator: Address,
}

impl CurvyPayloadGenerator {
    pub const fn new(aggregator: Address) -> Self {
        Self { aggregator }
    }

    /// Constructs a transaction invoking `submitWithdrawalRequest` on the configured Curvy aggregator.
    pub fn withdraw<const MAX_INPUTS: usize>(&self, request: CurvyWithdrawalRequest<MAX_INPUTS>) -> TransactionRequest {
        let call = submitWithdrawalRequestCall {
            maxInputs: U256::from(MAX_INPUTS),
            proof_a: request.proof.a,
            proof_b: request.proof.b,
            proof_c: request.proof.c,
            publicSignals: request.public_signals(),
        };

        TransactionRequest::default()
            .with_to(self.aggregator)
            .with_input(call.abi_encode())
    }
}

#[cfg(test)]
mod tests {
    use alloy::{network::TransactionBuilder, primitives::address, sol_types::SolCall};
    use curvy_bindings::curvy_aggregator_alpha_v2::CurvyAggregatorAlphaV2::submitWithdrawalRequestCall;

    use super::{CurvyPayloadGenerator, CurvyWithdrawalRequest, Groth16Proof, U256};

    #[test]
    fn withdrawal_payload_targets_aggregator_and_preserves_circuit_layout() {
        let aggregator = address!("1111111111111111111111111111111111111111");
        let recipient = address!("2222222222222222222222222222222222222222");
        let request = CurvyWithdrawalRequest {
            proof: Groth16Proof {
                a: [U256::from(11), U256::from(12)],
                b: [[U256::from(21), U256::from(22)], [U256::from(23), U256::from(24)]],
                c: [U256::from(31), U256::from(32)],
            },
            token: U256::from(1),
            nullifiers: [U256::from(41), U256::from(42)],
            recipient,
            amount: U256::from(51),
            notes_root: U256::from(61),
        };

        let transaction = CurvyPayloadGenerator::new(aggregator).withdraw(request.clone());
        assert_eq!(TransactionBuilder::to(&transaction), Some(aggregator));
        let call = submitWithdrawalRequestCall::abi_decode(
            TransactionBuilder::input(&transaction).expect("withdrawal calldata missing"),
        )
        .expect("withdrawal calldata should decode");

        assert_eq!(call.maxInputs, U256::from(2));
        assert_eq!(call.proof_a, request.proof.a);
        assert_eq!(call.proof_b, request.proof.b);
        assert_eq!(call.proof_c, request.proof.c);
        assert_eq!(
            call.publicSignals,
            vec![
                request.amount,
                request.nullifiers[0],
                request.nullifiers[1],
                request.notes_root,
                U256::from_be_slice(request.recipient.as_slice()),
                request.token,
            ]
        );
    }
}
