# generate smart contract bindings
generate-bindings:
    cd ethereum/contracts; \
    forge bind --offline --bindings-path ./../bindings/src/codegen \
      --module --alloy --overwrite \
      --force --skip-cargo-toml \
      --select '^(HoprAnnouncements|HoprAnnouncementsProxy|HoprAnnouncementsEvents|HoprCapabilityPermissions|HoprChannels|HoprChannelsEvents|HoprCrypto|HoprBoost|HoprToken|HoprLedger|HoprLedgerevents|HoprMultisig|HoprNodeManagementModule|HoprNodeSafeRegistry|HoprNodeSafeRegistryEvents|HoprNodeStakeFactory|HoprNodeStakeFactoryEvents|HoprTicketPriceOracle|HoprTicketPriceOracleEvents|HoprWinningProbabilityOracle|HoprWinningProbabilityOracleEvents)$'

# smart contract tests
# we only produce gas reports on active contracts

# NOTE:gas reports are disabled currently due to OOM issues
smart-contract-test *PARAMETERS:
    forge test {{ PARAMETERS }} --root ./ethereum/contracts --match-path "./test/(static|mocks|utils)/*.t.sol"
    forge test {{ PARAMETERS }} --root ./ethereum/contracts --no-match-path "./test/(static|mocks|utils)/*.t.sol"
