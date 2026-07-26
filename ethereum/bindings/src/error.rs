//! Error types returned by this crate's helper functions.

use thiserror::Error;

/// Errors that can occur while deploying or interacting with the HOPR contracts through this crate's
/// helpers (e.g. [`crate::config::create_provider`]).
#[derive(Debug, Error)]
pub enum Error {
    /// A call to a smart contract failed, or its result could not be decoded.
    #[error(transparent)]
    Contract(#[from] alloy::contract::Error),
    /// A signer (private key) could not be constructed, e.g. because the given bytes are not a
    /// valid secp256k1 scalar.
    #[error(transparent)]
    Signer(#[from] alloy::signers::k256::ecdsa::Error),
}
