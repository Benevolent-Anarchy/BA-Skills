#!/usr/bin/env bash
set -euo pipefail
source_dir="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
exec "$source_dir/../../../install.sh" --skill ba-bootstrap "$@"
