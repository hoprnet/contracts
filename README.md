# Smart Contracts

[![codecov](https://codecov.io/gh/hoprnet/contracts/branch/main/graph/badge.svg)](https://codecov.io/gh/hoprnet/contracts)

Smart Contracts for the HOPR mixnet.

## Deprecated Smart Contracts

### v2

```json
{
  "networks": {
    "monte_rosa": {
      "indexer_start_block_number": 24097267,
      "addresses": {
        "announcements": "0x0000000000000000000000000000000000000000",
        "channels": "0xFaBeE463f31E39eC8952bBfB4490C41103bf573e",
        "network_registry": "0x819E6a81e1e3f96CF1ac9200477C2d09c676959D",
        "network_registry_proxy": "0xcA9B1bC189F977B2A9217598D0300d956b6a719f",
        "token": "0x66225dE86Cac02b32f34992eb3410F59DE416698",
        "node_stake_v2_factory": "0x0000000000000000000000000000000000000000",
        "node_safe_registry": "0x0000000000000000000000000000000000000000",
        "module_implementation": "0x0000000000000000000000000000000000000000",
        "ticket_price_oracle": "0x0000000000000000000000000000000000000000",
        "winning_probability_oracle": "0x0000000000000000000000000000000000000000"
      }
    }
  }
}
```

### v3

```json
{
  "networks": {
    "rotsee": {
      "environment_type": "staging",
      "indexer_start_block_number": 29521261,
      "addresses": {
        "announcements": "0xf1c143B1bA20C7606d56aA2FA94502D25744b982",
        "channels": "0x77C9414043d27fdC98A6A2d73fc77b9b383092a7",
        "module_implementation": "0x32863c4974fBb6253E338a0cb70C382DCeD2eFCb",
        "network_registry": "0x15a315E1320cFF0de84671c0139042EE320CE38d",
        "network_registry_proxy": "0x20559cbD3C2eDcD0b396431226C00D2Cd102eB3F",
        "node_safe_registry": "0x4F7C7dE3BA2B29ED8B2448dF2213cA43f94E45c0",
        "node_stake_v2_factory": "0x791d190b2c95397F4BcE7bD8032FD67dCEA7a5F2",
        "token": "0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1",
        "ticket_price_oracle": "0x442df1d946303fB088C9377eefdaeA84146DA0A6",
        "winning_probability_oracle": "0x09635f643e140090a9a8dcd712ed6285858cebef"
      }
    },
    "dufour": {
      "environment_type": "production",
      "indexer_start_block_number": 29706814,
      "addresses": {
        "announcements": "0x619eabE23FD0E2291B50a507719aa633fE6069b8",
        "channels": "0x693Bac5ce61c720dDC68533991Ceb41199D8F8ae",
        "network_registry": "0x582b4b586168621dAf83bEb2AeADb5fb20F8d50d",
        "network_registry_proxy": "0x2bc6b78B0aA892e97714F0e3b1c74487f92C5884",
        "token": "0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1",
        "node_stake_v2_factory": "0x098B275485c406573D042848D66eb9d63fca311C",
        "node_safe_registry": "0xe15C24a0910311c83aC78B5930d771089E93077b",
        "module_implementation": "0xB7397C218766eBe6A1A634df523A1a7e412e67eA",
        "ticket_price_oracle": "0xcA5656Fe6F2d847ACA32cf5f38E51D2054cA1273",
        "winning_probability_oracle": "0x7Eb8d762fe794A108e568aD2097562cc5D3A1359"
      }
    }
  }
}
```
