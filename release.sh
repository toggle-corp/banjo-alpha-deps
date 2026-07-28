#!/bin/bash
# Cut a release: generate CHANGELOG.md via git-cliff, bump the chart version,
# commit, and create a signed tag. Thin wrapper around fugit/scripts/release.sh.
#
# Requires on $PATH: git-cliff, semver, typos, gh (authenticated).
#
# Usage:
#   ./release.sh            # prompts for the version
#   ./release.sh v1.2.3     # pre-fills the prompt
#
# Afterwards: `git push origin <tag> && git push`. The tag push triggers
# .github/workflows/release.yml, which publishes the chart to GHCR.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

function release_custom_hook {
    # Tags are v-prefixed (VERSION_TAG_PREFIX_MODE=require) but a helm
    # Chart.yaml `version:` is strict SemVer and rejects the leading `v`.
    # `version_tag` is set by fugit's release.sh in the surrounding shell.
    # shellcheck disable=SC2154
    chart_version="${version_tag#v}"
    sed -i.bak "s/^version: .*/version: $chart_version  # managed by release.sh/" chart/Chart.yaml
    rm -f chart/Chart.yaml.bak

    # REQUIRED: fugit's release.sh only stages CHANGELOG.md, so an unstaged
    # bump here would leave the tag pointing at the old chart version.
    git add chart/Chart.yaml
}

export -f release_custom_hook
export START_COMMIT=2a129bb4f1aef7bd4b9abaad4d859b2c8ae2ab25
export RELEASE_CUSTOM_HOOK=release_custom_hook
export REPO_NAME=toggle-corp/banjo-alpha-deps
export DEFAULT_BRANCH=main
export VERSION_TAG_PREFIX_MODE=require

export GIT_CLIFF__REMOTE__GITHUB__OWNER=toggle-corp
export GIT_CLIFF__REMOTE__GITHUB__REPO=banjo-alpha-deps

"$SCRIPT_DIR/fugit/scripts/release.sh" "${@:-}"
