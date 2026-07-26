#!/usr/bin/env bash
set -euo pipefail

# Sanity check requested in https://github.com/hoprnet/contracts/issues/51:
# every "staging"/"production" network listed in contracts-addresses.json must
# point at the canonical HOPR token and xHOPR token deployments.

file="${1:-ethereum/bindings/contracts-addresses.json}"

if [[ ! -f ${file} ]]; then
  echo "error: file not found: ${file}" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to check ${file}" >&2
  exit 2
fi

expected_token="0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1"
expected_xhopr_token="0xD057604A14982FE8D88c5fC25Aac3267eA142a08"

mismatches="$(
  jq -r \
    --arg token "${expected_token}" \
    --arg xhopr_token "${expected_xhopr_token}" '
    ($token | ascii_downcase) as $expected_token
    | ($xhopr_token | ascii_downcase) as $expected_xhopr_token
    | .networks
    | to_entries[]
    | select(.value.environment_type == "staging" or .value.environment_type == "production")
    | select(
        (.value.addresses.token? // "" | ascii_downcase) != $expected_token
        or (.value.addresses.xhopr_token? // "" | ascii_downcase) != $expected_xhopr_token
      )
    | "  \(.key): token=\(.value.addresses.token) xhopr_token=\(.value.addresses.xhopr_token)"
  ' "${file}"
)"

if [[ -n ${mismatches} ]]; then
  echo "error: staging/production networks in ${file} with unexpected token/xhopr_token addresses:" >&2
  echo "${mismatches}" >&2
  echo "expected: token=${expected_token} xhopr_token=${expected_xhopr_token}" >&2
  exit 1
fi

echo "OK: all staging/production networks in ${file} use the canonical token and xhopr_token addresses."
