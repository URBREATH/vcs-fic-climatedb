#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m pip install -r "$BUNDLE_DIR/requirements.txt"
python3 "$BUNDLE_DIR/run_setup.py" "$@"