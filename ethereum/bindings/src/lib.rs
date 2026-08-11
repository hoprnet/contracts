//! Crate-level documentation is pulled from `README.md` below so it also renders on docs.rs.
#![doc = include_str!("../README.md")]
#![allow(clippy::all)]

#[allow(warnings)]
#[cfg_attr(rustfmt, rustfmt_skip)]
mod codegen;

pub mod config;
pub mod constants;
pub mod curvy;
pub mod error;

// Generated bindings for every HOPR Solidity contract, re-exported at the crate root, one module
// per contract (e.g. `hopr_channels::HoprChannels`, `hopr_token::HoprToken`). See the
// crate-level docs above for an overview.
#[cfg_attr(rustfmt, rustfmt_skip)]
pub use codegen::*;

/// Re-exports of the underlying `alloy` crate used by the generated bindings, so downstream
/// crates can depend on a single, consistent `alloy` version.
pub mod exports {
    pub use alloy;
}

pub use config::{CONTRACTS_ADDRESSES_FILE_CONTENT, ContractAddresses};
