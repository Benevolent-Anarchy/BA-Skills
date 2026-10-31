#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
python3 -m unittest discover -s tests/bootstrap-linux -p 'test_*.py' -v
