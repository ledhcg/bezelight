#!/usr/bin/env bash
# Runs the agent-alert soak test: 3 agents x 20 sessions behaving badly, through the real socket,
# checking invariants and for leaks. Default 10 minutes; pass seconds as the first argument.
#
#   scripts/soak.sh          # 10 minutes
#   scripts/soak.sh 86400    # a full day
set -euo pipefail
cd "$(dirname "$0")/.."
BEZELIGHT_SOAK_SECONDS="${1:-600}" swift test --filter soak
