# generate smart contract bindings
#
# `forge bind` runs its own build with an ABI-only output selection, and that build overwrites the
# artifacts in `out`. Bindings generated from those artifacts carry no creation bytecode, so they
# expose no `deploy` function. Build first and pass `--skip-build`, so that `forge bind` reads the
# full artifacts. `--force` would clear them again, so it must stay away.
generate-bindings:
    cd ethereum/contracts; \
    forge build; \
    forge bind --offline --bindings-path ./../bindings/src/codegen \
      --module --alloy --overwrite \
      --skip-build --skip-cargo-toml \
      --select '^(HoprAnnouncements|HoprAnnouncementsProxy|HoprAnnouncementsEvents|HoprCapabilityPermissions|HoprChannels|HoprChannelsEvents|HoprCrypto|HoprBoost|HoprToken|HoprLedger|HoprLedgerEvents|HoprMultisig|HoprNodeManagementModule|HoprNodeSafeRegistry|HoprNodeSafeRegistryEvents|HoprNodeStakeFactory|HoprNodeStakeFactoryEvents|HoprServiceRegistry|HoprServiceRegistryEvents|HoprTicketPriceOracle|HoprTicketPriceOracleEvents|HoprWinningProbabilityOracle|HoprWinningProbabilityOracleEvents|HoprNodeSafeMigration|HoprNodeSafeMigrationEvents|ERC677Mock)$'

# smart contract tests
# we only produce gas reports on active contracts

# NOTE:gas reports are disabled currently due to OOM issues
smart-contract-test *PARAMETERS:
    forge test {{ PARAMETERS }} --root ./ethereum/contracts --match-path "./test/(static|mocks|utils)/*.t.sol"
    forge test {{ PARAMETERS }} --root ./ethereum/contracts --no-match-path "./test/(static|mocks|utils)/*.t.sol"
