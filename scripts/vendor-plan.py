#!/usr/bin/env python3
"""Emit the image vendor plan as JSON.

Pairs each image the Bitnami MinIO subchart can pull with its upstream source
and our GHCR destination:

  docker.io/bitnamilegacy/<name>:<tag>  ->  ghcr.io/toggle-corp/banjo-alpha-deps/<name>:<tag>

The destination comes from chart/values.yaml (the same value the chart renders
into a pod spec) and the tag comes from the pinned subchart's own defaults, so
the plan cannot drift from what an install actually pulls. Run it directly to
inspect the plan; .github/workflows/vendor-images.yml consumes its output.

Requires chart/charts/minio-*.tgz, which `helm dep build chart` fetches.
"""

import argparse
import glob
import json
import os
import sys
import tarfile

import yaml

UPSTREAM_REGISTRY = "docker.io"
UPSTREAM_NAMESPACE = "bitnamilegacy"
VENDOR_REGISTRY = "ghcr.io"
VENDOR_NAMESPACE = "toggle-corp/banjo-alpha-deps"

# (path within the minio values tree, upstream/vendored image name)
IMAGES = [
    (("image",), "minio"),
    (("clientImage",), "minio-client"),
    (("console", "image"), "minio-object-browser"),
    (("defaultInitContainers", "volumePermissions", "image"), "os-shell"),
]


def dig(tree, path, source):
    node = tree
    for i, key in enumerate(path):
        if not isinstance(node, dict) or key not in node:
            sys.exit(f"{source}: no value at minio.{'.'.join(path[: i + 1])}")
        node = node[key]
    return node


def subchart_values(chart_dir):
    matches = sorted(glob.glob(os.path.join(chart_dir, "charts", "minio-*.tgz")))
    if not matches:
        sys.exit(
            f"{chart_dir}/charts: no minio-*.tgz — run `helm dep build {chart_dir}` first"
        )
    if len(matches) > 1:
        sys.exit(f"{chart_dir}/charts: several minio tarballs: {', '.join(matches)}")
    tarball = matches[0]
    with tarfile.open(tarball) as tar:
        member = tar.extractfile("minio/values.yaml")
        if member is None:
            sys.exit(f"{tarball}: no minio/values.yaml")
        return tarball, yaml.safe_load(member.read())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chart-dir", default="chart")
    args = parser.parse_args()

    values_path = os.path.join(args.chart_dir, "values.yaml")
    with open(values_path, encoding="utf-8") as handle:
        parent = yaml.safe_load(handle).get("minio") or {}

    tarball, upstream = subchart_values(args.chart_dir)

    plan = []
    for path, name in IMAGES:
        tag = dig(upstream, path + ("tag",), tarball)
        registry = dig(parent, path + ("registry",), values_path)
        repository = dig(parent, path + ("repository",), values_path)

        # `src` is built from the hardcoded name, so a subchart that renames an
        # image would otherwise pair the new tag with the old upstream name and
        # only fail partway through the copy loop, after earlier tags were
        # already pushed.
        upstream_repository = dig(upstream, path + ("repository",), tarball)
        if upstream_repository != f"bitnami/{name}":
            sys.exit(
                f"{tarball}: minio.{'.'.join(path)}.repository is "
                f"{upstream_repository}, expected bitnami/{name}"
            )

        # Vendoring only republishes; a destination pointing anywhere else means
        # values.yaml was repointed and this plan would push to the wrong place.
        expected = f"{VENDOR_NAMESPACE}/{name}"
        if (registry, repository) != (VENDOR_REGISTRY, expected):
            sys.exit(
                f"{values_path}: minio.{'.'.join(path)} is "
                f"{registry}/{repository}, expected {VENDOR_REGISTRY}/{expected}"
            )
        if dig(upstream, path + ("digest",), tarball):
            sys.exit(
                f"{tarball}: minio.{'.'.join(path)}.digest is set; the plan keys off tags"
            )

        plan.append(
            {
                "name": name,
                "src": f"{UPSTREAM_REGISTRY}/{UPSTREAM_NAMESPACE}/{name}:{tag}",
                "dest": f"{registry}/{repository}:{tag}",
            }
        )

    json.dump(plan, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
