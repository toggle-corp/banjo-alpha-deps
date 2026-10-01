#!/usr/bin/env bash
# Assert every image the MinIO subchart renders is one that gets vendored.
#
# Covers the three ways that can break, none of which helm-unittest can see:
#
#   1. The Bitnami subchart aborts rendering from NOTES.txt when an image
#      resolves outside docker.io/bitnami* — which every vendored reference
#      does — unless global.security.allowInsecureImages is set. helm-unittest
#      does not render NOTES.txt, and `helm lint` renders the subchart only
#      when minio.enabled is true, which it is not by default.
#   2. An image reference in values.yaml drifting away from the vendor plan, so
#      the chart renders a tag .github/workflows/vendor-images.yml never copied.
#   3. A subchart bump introducing an image the plan does not know about. That
#      image renders from a gated bitnami/* repo and would 401 on install, so
#      the assertion runs the other way round: every image the subchart renders
#      must appear in the plan, not merely every vendored image it renders.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

plan="$(python3 scripts/vendor-plan.py)"

# Every optional image on, so nothing an overlay can enable goes unchecked.
rendered="$(helm template vendor-check chart \
  --set minio.enabled=true \
  --set minio.ingress.hostname=s3.example.com \
  --set minio.console.enabled=true \
  --set minio.provisioning.enabled=true \
  --set minio.defaultBuckets=vendor-check \
  --set minio.defaultInitContainers.volumePermissions.enabled=true)"

# Only the subchart's own documents; the parent chart's images (postgres, curl,
# mailpit, alpine/k8s) are on healthy upstreams and are not vendored.
mapfile -t refs < <(
  printf '%s\n' "$rendered" |
    awk '
      /^# Source: / { in_minio = ($3 ~ /\/charts\/minio\//); next }
      in_minio && $1 == "image:" {
        ref = $2
        gsub(/^"|"$/, "", ref)
        print ref
      }
    ' |
    sort -u
)

if [ "${#refs[@]}" -eq 0 ]; then
  echo "error: the rendered subchart pulls no images at all — did the render change shape?" >&2
  exit 1
fi

status=0
for ref in "${refs[@]}"; do
  if printf '%s' "$plan" | jq -e --arg ref "$ref" 'any(.[]; .dest == $ref)' >/dev/null; then
    echo "ok        $ref"
  else
    echo "UNVENDORED  $ref is rendered by the subchart but is not in the vendor plan" >&2
    status=1
  fi
done

exit "$status"
