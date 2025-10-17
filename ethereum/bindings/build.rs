use std::{env, fs, path::Path};

use anyhow::Context;

const CONTRACTS_ADDRESSES_FILENAME: &str = "contracts-addresses.json";
const CONTRACTS_ADDRESSES_PATH: &str = const_format::formatcp!("../contracts/{}", CONTRACTS_ADDRESSES_FILENAME);

fn main() -> anyhow::Result<()> {
    let out_dir = env::var("OUT_DIR").context("OUT_DIR environment variable should be set")?;
    let dest_path = Path::new(&out_dir).join(CONTRACTS_ADDRESSES_FILENAME);

    let config_path = Path::new(CONTRACTS_ADDRESSES_PATH);

    if !config_path.exists() {
        return Err(anyhow::anyhow!(
            "{} not found at expected path: {:?}",
            CONTRACTS_ADDRESSES_FILENAME,
            config_path
        ));
    } else {
        fs::copy(config_path, &dest_path)
            .context(format!("Failed to copy {CONTRACTS_ADDRESSES_FILENAME} to OUT_DIR"))?;
    }

    // Tell Cargo to rerun this build script if the config file changes
    println!("cargo:rerun-if-changed={CONTRACTS_ADDRESSES_PATH}");

    Ok(())
}
