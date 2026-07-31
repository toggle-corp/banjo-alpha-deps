#!/usr/bin/env bash
# Run before pushing: hygiene + chart lint + unit tests + shellcheck + Docker integration.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "==> pre-commit (hygiene, helm lint, helm unittest)"
pre-commit run --all-files

echo
echo "==> shellcheck (covers untracked files too — pre-commit skips those)"
find chart/scripts chart/tests/integration prepush.sh -name '*.sh' -print0 | xargs -0 shellcheck

echo
echo "==> integration tests (Docker, ~30s)"
./chart/tests/integration/run.sh

# Opt-in: creates and destroys a kind cluster, so it is too slow for every push.
# CI runs it on every PR regardless.
if [ "${RUN_E2E:-0}" = "1" ]; then
  echo
  echo "==> e2e tests (kind, ~4 min)"
  ./chart/tests/e2e/run.sh
else
  echo
  echo "==> skipping kind e2e suite (set RUN_E2E=1 to include it; ~4 min)"
fi

echo
echo "All checks passed."
