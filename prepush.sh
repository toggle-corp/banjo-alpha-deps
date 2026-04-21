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

echo
echo "All checks passed."
