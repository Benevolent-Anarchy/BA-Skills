#!/usr/bin/env bash
# Native aggregate gate. Never mask a failing suite with logging or a pipeline.
set -uo pipefail
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
failed=0
for suite in bootstrap integrate release; do
  printf '\nRunning %s Linux tests\n' "$suite"
  if ! bash "$root/tests/$suite-linux/run-tests.sh"; then
    printf 'FAILED: %s Linux tests\n' "$suite" >&2
    failed=1
  fi
done
if (( failed )); then exit 1; fi
printf '\nVerification passed: BA-Skills (Linux).\n'
