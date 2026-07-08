# contracts.nix - HOPR contracts Rust package definitions
#
# Builds the hopr-bindings crate for multiple platforms using nix-lib builders.
# Source filtering, rev, and build arguments are all defined here.
# The contracts-specific preConfigure generates foundry.toml from foundry.in.toml
# (only for the main build; the deps-only build does not need it).

{
  builders,
  nixLib,
  self,
  lib,
  foundryBin,
  solcDefault,
}:
let
  fs = lib.fileset;
  root = ./../..;

  rev = toString (self.shortRev or self.dirtyShortRev);

  depsSrc = nixLib.mkDepsSrc {
    inherit root fs;
  };

  src = nixLib.mkSrc {
    inherit root fs;
    # Extra files not covered by the default .rs/.toml extensions
    extraFiles = [
      (root + "/ethereum/bindings/contracts-addresses.json")
      (root + "/ethereum/contracts/remappings.txt")
      (fs.fileFilter (file: file.hasExt "sol") (root + "/vendor/solidity"))
      (fs.fileFilter (file: file.hasExt "sol") (root + "/ethereum/contracts/src"))
    ];
  };

  cargoToml = ./../../ethereum/bindings/Cargo.toml;

  buildArgs = {
    inherit
      src
      depsSrc
      rev
      cargoToml
      ;
    # foundryBin and solcDefault are required as native build tools
    extraNativeBuildInputs = [
      foundryBin
      solcDefault
    ];
  };

  # Extend a package's preConfigure to generate foundry.toml from foundry.in.toml.
  # This is only added to the main package derivation, not to the cargoArtifacts
  # (deps-only build), since depsSrc does not include foundry.in.toml.
  withFoundryPreConfigure =
    pkg:
    pkg.overrideAttrs (old: {
      preConfigure = (old.preConfigure or "") + ''
        sed "s|# solc = .*|solc = \"${solcDefault}/bin/solc\"|g" \
          ethereum/contracts/foundry.in.toml > \
          ethereum/contracts/foundry.toml
      '';
    });

  buildBinary =
    builder: args:
    withFoundryPreConfigure (builder.callPackage nixLib.mkRustPackage (buildArgs // args));

  buildLib =
    builder: args:
    builder.callPackage nixLib.mkRustLibrary (
      {
        inherit
          src
          depsSrc
          cargoToml
          rev
          ;
      }
      // args
    );
in
{
  build-dev = buildBinary builders.local {
    CARGO_PROFILE = "dev";
    cargoExtraArgs = "-F capture";
  };

  clippy = buildLib builders.local { runClippy = true; };

  test = buildLib builders.local {
    runTests = true;
    extraNativeBuildInputs = [ foundryBin ];
  };

  test-nightly = buildLib builders.localNightly {
    runTests = true;
    cargoExtraArgs = "-Z panic-abort-tests";
    extraNativeBuildInputs = [ foundryBin ];
  };

  docs = buildBinary builders.localNightly { buildDocs = true; };

  # Cross-compiled binary packages
  binary-x86_64-linux = buildBinary builders."x86_64-linux" { };
  binary-x86_64-darwin = buildBinary builders."x86_64-darwin" { };
  binary-aarch64-darwin = buildBinary builders."aarch64-darwin" { };
  binary = buildBinary builders.local { };

  # Cross-compiled rlib packages
  # Artifacts are available at: ./result/lib/libhopr_bindings.rlib
  lib-hopr-bindings-x86_64-linux = buildLib builders."x86_64-linux" { };
  lib-hopr-bindings-x86_64-darwin = buildLib builders."x86_64-darwin" { };
  lib-hopr-bindings-aarch64-darwin = buildLib builders."aarch64-darwin" { };
  lib-hopr-bindings = buildLib builders.local { };

}
