//! HOPR Smart Contracts Addresses dumper.
//!
//! This executable dumps the content of the build state of the contracts-addresses.json file.
//!
//! ```

fn main() -> anyhow::Result<()> {
    println!("{}", hopr_bindings::CONTRACTS_ADDRESSES_FILE_CONTENT);

    Ok(())
}
