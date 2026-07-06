use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    Contract(#[from] alloy::contract::Error),
    #[error(transparent)]
    Signer(#[from] alloy::signers::k256::ecdsa::Error),
}