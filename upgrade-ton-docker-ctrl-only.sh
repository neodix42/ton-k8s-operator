#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for callers using the former combined-image helper.
if [[ $# -ne 3 ]]; then
  printf '%s\n' \
    'The TON runtime now uses separate MyTonCtrl and official TON images.' \
    'Usage: ./upgrade-ton-docker-ctrl-only.sh <chart-version> <mytonctrl-tag> <ton-tag>' \
    'Preferred: ./upgrade-ton-images-only.sh <chart-version> <mytonctrl-tag> <ton-tag>' >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$ROOT_DIR/upgrade-ton-images-only.sh" "$@"
