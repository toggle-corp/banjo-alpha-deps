#!/usr/bin/env bash
# Vendor the Garage helm chart into chart/charts/garage/.
#
# Deuxfleurs/garage ships its Helm chart at `script/helm/garage/` inside the
# main garage repo. No standalone chart release, no OCI publish — see
# https://git.deuxfleurs.fr/Deuxfleurs/garage/issues/417.
#
# This script does a sparse shallow clone to grab just that subdir, copies it
# into chart/charts/garage/, and records the source commit in VENDORED_FROM.md.
#
# To refresh the vendored chart: re-run with a different UPSTREAM_REF (or omit
# to track main-v2 HEAD).

set -euo pipefail

UPSTREAM_REPO="https://git.deuxfleurs.fr/Deuxfleurs/garage.git"
UPSTREAM_REF="${UPSTREAM_REF:-main-v2}"
UPSTREAM_SUBPATH="script/helm/garage"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DEST="$REPO/chart/charts/garage"

TMP="$(mktemp -d -t vendor-garage-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Sparse-cloning $UPSTREAM_REPO @ $UPSTREAM_REF"
git clone --filter=blob:none --no-checkout --depth=1 --branch "$UPSTREAM_REF" \
  "$UPSTREAM_REPO" "$TMP/garage"
cd "$TMP/garage"
git sparse-checkout init --cone
git sparse-checkout set "$UPSTREAM_SUBPATH"
git checkout "$UPSTREAM_REF"

COMMIT="$(git rev-parse HEAD)"
COMMIT_DATE="$(git log -1 --format=%cI)"

echo "==> Replacing $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/garage/$UPSTREAM_SUBPATH/." "$DEST/"

cat > "$DEST/VENDORED_FROM.md" <<EOF
# Vendored from Deuxfleurs/garage

This directory is a copy of \`$UPSTREAM_SUBPATH/\` from the Garage repository.
Upstream has not yet published the Helm chart independently
(tracking: https://git.deuxfleurs.fr/Deuxfleurs/garage/issues/417).

- Source:       $UPSTREAM_REPO
- Ref:          $UPSTREAM_REF
- Commit:       $COMMIT
- Commit date:  $COMMIT_DATE
- Vendored on:  $(date -u +%Y-%m-%dT%H:%M:%SZ)

To refresh, run \`./scripts/vendor-garage.sh\` from the repo root. Do not edit
files here by hand — local changes will be wiped on the next refresh.
EOF

echo "==> Vendored garage @ $COMMIT"
ls "$DEST"
