{
  description = "HOPR contracts";

  inputs = {
    # Core Nix ecosystem dependencies
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/release-25.11";
    flake-utils.url = "github:numtide/flake-utils";

    # HOPR Nix Library (provides flake-utils and reusable build functions)
    nix-lib.url = "github:hoprnet/nix-lib/v1.1.0";

    # Rust build system
    crane.url = "github:ipetkov/crane";
    rust-overlay.url = "github:oxalica/rust-overlay";

    # Development tools and quality assurance
    pre-commit.url = "github:cachix/git-hooks.nix";
    flake-root.url = "github:srid/flake-root";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    foundry.url = "github:shazow/foundry.nix";
    solc.url = "github:hellwolf/solc.nix";

    # Input dependency optimization
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    nix-lib.inputs.nixpkgs.follows = "nixpkgs";
    nix-lib.inputs.crane.follows = "crane";
    nix-lib.inputs.rust-overlay.follows = "rust-overlay";
    nix-lib.inputs.flake-utils.follows = "flake-utils";
    foundry.inputs.flake-utils.follows = "flake-utils";
    foundry.inputs.nixpkgs.follows = "nixpkgs";
    pre-commit.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    solc.inputs.flake-utils.follows = "flake-utils";
    solc.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-lib,
      flake-parts,
      rust-overlay,
      foundry,
      solc,
      pre-commit,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.flake-root.flakeModule
      ];
      perSystem =
        {
          config,
          lib,
          system,
          ...
        }:
        let
          localSystem = system;
          overlays = [
            (import rust-overlay)
            foundry.overlay
            solc.overlay
          ];
          pkgs = import nixpkgs { inherit localSystem overlays; };
          solcDefault = solc.mkDefault pkgs pkgs.solc_0_8_30;

          # Platform information
          buildPlatform = pkgs.stdenv.buildPlatform;

          # Import nix-lib for this system
          nixLib = nix-lib.lib.${system};

          # Create all Rust builders for cross-compilation using nix-lib
          builders = nixLib.mkRustBuilders {
            inherit localSystem;
            rustToolchainFile = ./rust-toolchain.toml;
          };

          # Import all contracts packages (uses nix-lib builders + mkRustPackage).
          # src, depsSrc, and rev are computed internally in contracts.nix.
          contractsPackages = import ./nix/packages/contracts.nix {
            inherit
              builders
              nixLib
              self
              lib
              solcDefault
              ;
            foundryBin = pkgs.foundry-bin;
          };

          # Linux packages for Docker image contents (always x86_64-linux for
          # server deployment; this lets the image be built on Darwin too)
          pkgsLinux = import nixpkgs {
            system = "x86_64-linux";
            inherit overlays;
          };
          linuxSolcDefault = solc.mkDefault pkgsLinux pkgsLinux.solc_0_8_30;

          # Import anvil Docker image and upload script packages
          anvilPackages = import ./nix/packages/anvil.nix {
            inherit
              pkgs
              pkgsLinux
              lib
              solcDefault
              linuxSolcDefault
              ;
            foundryBin = pkgsLinux.foundry-bin;
          };

          # Version extracted for check-bindings derivation
          hoprBindingsVersion =
            let
              info = builtins.fromTOML (builtins.readFile ./ethereum/bindings/Cargo.toml);
            in
            pkgs.lib.strings.concatStringsSep "." (
              pkgs.lib.lists.take 3 (builtins.splitVersion info.package.version)
            );

          # pre-commit in nixpkgs bundles heavyweight test-only dependencies
          # (dotnet-sdk, nodejs, go, coursier, …) into nativeBuildInputs via
          # its preCheck string interpolation, even though doCheck is already
          # false on Darwin. Filter them out so `direnv allow` / `nix develop`
          # doesn't have to build dotnet from source.
          pre-commit-lightweight = pkgs.pre-commit.overridePythonAttrs {
            nativeCheckInputs = [ ];
            doCheck = false;
            doInstallCheck = false;
            dontUsePytestCheck = true;
            preCheck = "";
            postCheck = "";
          };

          pre-commit-check = pre-commit.lib.${system}.run {
            src = ./.;
            package = pre-commit-lightweight;
            hooks = {
              # https://github.com/cachix/git-hooks.nix
              treefmt.enable = false;
              treefmt.package = config.treefmt.build.wrapper;
              check-executables-have-shebangs.enable = true;
              check-shebang-scripts-are-executable.enable = true;
              check-case-conflicts.enable = true;
              check-symlinks.enable = true;
              check-merge-conflicts.enable = true;
              check-added-large-files.enable = true;
              commitizen.enable = true;
              immutable-files = {
                enable = false;
                name = "Immutable files - the files should not change";
                entry = "bash .github/scripts/immutable-files-check.sh";
                files = "";
                language = "system";
              };
            };
            excludes = [
              "vendor/"
              "ethereum/contracts/"
              "ethereum/bindings/src/codegen"
              ".gcloudignore"
            ];
          };

          check-bindings = pkgs.stdenv.mkDerivation {
            pname = "check-bindings";
            version = hoprBindingsVersion;

            src = ./.;

            buildInputs = with pkgs; [
              diffutils
              foundry-bin
              solcDefault
              just
            ];

            preConfigure = ''
              mkdir -p ethereum/contracts
              sed "s|# solc = .*|solc = \"${solcDefault}/bin/solc\"|g" \
                ${./ethereum/contracts/foundry.in.toml} > ./ethereum/contracts/foundry.toml
            '';

            buildPhase = ''
              just generate-bindings
            '';

            checkPhase = ''
              echo "Checking if generated bindings introduced changes..."
              if [ -d "ethereum/bindings/src/reference" ]; then
                  echo "Generated bindings are outdated. Please run the binding generation and commit the changes."
                  exit 1
              fi
              echo "Bindings are up to date."
            '';

            # Disable the installPhase
            installPhase = "mkdir -p $out";
            doCheck = true;
          };

          # Rust toolchains
          stableToolchain =
            (pkgs.pkgsBuildHost.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml).override
              {
                targets = [
                  (
                    if buildPlatform.config == "arm64-apple-darwin" then
                      "aarch64-apple-darwin"
                    else
                      buildPlatform.config
                  )
                ];
              };

          shellArgs = {
            treefmtWrapper = config.treefmt.build.wrapper;
            treefmtPrograms = pkgs.lib.attrValues config.treefmt.build.programs;
            shellHook = ''
              echo "Running pre-commit checks..."
              ${pre-commit-check.shellHook}

              if ! { [ -f ethereum/contracts/foundry.toml ] && grep -q "solc = \"${solcDefault}/bin/solc\"" ethereum/contracts/foundry.toml; }; then
                echo "Generating foundry.toml file!" >&2
                sed "s|# solc = .*|solc = \"${solcDefault}/bin/solc\"|g" \
                  ethereum/contracts/foundry.in.toml >| \
                  ethereum/contracts/foundry.toml
              fi
              unset SOURCE_DATE_EPOCH
            '';
            extraPackages = with pkgs; [
              solcDefault
              foundry-bin
              sqlite
              gnuplot
              zizmor
              yq-go
            ];
          };

          shells = {
            default = nixLib.mkDevShell (
              {
                rustToolchain = stableToolchain;
                shellName = "Development";
              }
              // shellArgs
            );
            ci = nixLib.mkDevShell {
              rustToolchain = stableToolchain;
              shellName = "CI";
              treefmtWrapper = config.treefmt.build.wrapper;
              treefmtPrograms = pkgs.lib.attrValues config.treefmt.build.programs;
              extraPackages = with pkgs; [
                zizmor
              ];
            };
            coverage = nixLib.mkDevShell {
              rustToolchainFile = ./rust-toolchain.toml;
              shellName = "Coverage";
              withLlvmTools = true;
            };
          };
        in
        {
          treefmt = {
            inherit (config.flake-root) projectRootFile;

            settings.global.excludes = [
              "**/*.id"
              "**/.cargo-ok"
              "**/.gitignore"
              ".actrc"
              ".dockerignore"
              ".editorconfig"
              ".gcloudignore"
              ".gitattributes"
              ".yamlfmt"
              "LICENSE"
              "Makefile"
              ".github/workflows/build-binaries.yaml"
              "docs/*"
              "ethereum/bindings/src/codegen/*"
              "ethereum/contracts/Makefile"
              "ethereum/contracts/broadcast/*"
              "ethereum/bindings/contracts-addresses.json"
              "ethereum/contracts/remappings.txt"
              "ethereum/contracts/src/static/*"
              "ethereum/contracts/test/static/*"
              "nix/setup-hook-darwin.sh"
              "target/*"
              "vendor/*"
            ];

            programs.shfmt.enable = true;
            settings.formatter.shfmt.includes = [
              "*.sh"
              "ethereum/contracts/.env.example"
            ];

            programs.yamlfmt.enable = true;
            settings.formatter.yamlfmt.includes = [
              ".github/labeler.yml"
              ".github/workflows/*.yaml"
            ];
            # trying setting from https://github.com/google/yamlfmt/blob/main/docs/config-file.md
            settings.formatter.yamlfmt.settings = {
              formatter.type = "basic";
              formatter.max_line_length = 120;
              formatter.trim_trailing_whitespace = true;
              formatter.scan_folded_as_literal = true;
              formatter.include_document_start = true;
            };

            programs.prettier.enable = true;
            settings.formatter.prettier.includes = [
              "*.md"
              "*.json"
              "ethereum/contracts/README.md"
            ];
            settings.formatter.prettier.excludes = [
              "ethereum/contracts/*"
              "*.yml"
              "*.yaml"
            ];
            programs.rustfmt.enable = true;
            # using the official Nixpkgs formatting
            # see https://github.com/NixOS/rfcs/blob/master/rfcs/0166-nix-formatting.md
            programs.nixfmt.enable = true;
            programs.taplo.enable = true;
            programs.ruff-format.enable = true;

            settings.formatter.rustfmt = {
              command = "${pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default)}/bin/rustfmt";
            };
            settings.formatter.solc = {
              command = "sh";
              options = [
                "-euc"
                ''
                  # must generate the foundry.toml here, since this step could
                  # be executed in isolation
                  if ! grep -q "solc = \"${solcDefault}/bin/solc\"" ethereum/contracts/foundry.toml; then
                    echo "solc = \"${solcDefault}/bin/solc\""
                    echo "Generating foundry.toml file!"
                    sed "s|# solc = .*|solc = \"${solcDefault}/bin/solc\"|g" \
                      ethereum/contracts/foundry.in.toml >| \
                      ethereum/contracts/foundry.toml
                  else
                    echo "foundry.toml file already exists!"
                  fi

                  for file in "$@"; do
                    ${pkgs.foundry-bin}/bin/forge fmt $file \
                      --root ./ethereum/contracts;
                  done
                ''
                "--"
              ];
              includes = [ "*.sol" ];
            };
          };

          checks = {
            inherit (contractsPackages) clippy;
            inherit check-bindings;
          };

          apps = {
            update-github-labels = nixLib.mkUpdateGithubLabelsApp;
            check = nixLib.mkCheckApp { inherit system; };
            audit = nixLib.mkAuditApp { rustToolchainFile = ./rust-toolchain.toml; };
            coverage-unit = {
              type = "app";
              program = toString (
                pkgs.writeShellScript "coverage-unit" ''
                  nix develop .#coverage -c cargo llvm-cov --workspace --lib --lcov --output-path coverage.lcov
                ''
              );
            };
          };

          packages = {
            inherit (contractsPackages)
              build-dev
              test
              test-nightly
              docs
              binary
              binary-x86_64-linux
              binary-x86_64-darwin
              binary-aarch64-darwin
              lib-hopr-bindings
              lib-hopr-bindings-x86_64-linux
              lib-hopr-bindings-x86_64-darwin
              lib-hopr-bindings-aarch64-darwin
              ;
            inherit (anvilPackages) anvil-docker anvil-docker-upload;
            inherit pre-commit-check;
            default = contractsPackages.lib-hopr-bindings;
          };

          devShells = shells;

          formatter = config.treefmt.build.wrapper;
        };
      # platforms which are supported as build environments
      systems = [
        "x86_64-linux"
        # NOTE: blocked by missing support in solc, see
        # https://github.com/ethereum/solidity/issues/11351
        # "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    };
}
