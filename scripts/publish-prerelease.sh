#!/usr/bin/env bash
# Publish a GitHub prerelease for one package (PACKAGE=<name>).
# Creates a draft, uploads .apk assets, then publishes.
# Tag/title use the package name prefix so Releases stay distinguishable in the monorepo.
# Version is read from pkgver=... in main/<name>/APKBUILD.
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${PACKAGE:?PACKAGE is required}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISCOVER="${REPO_ROOT}/scripts/discover.sh"
RETRY="${REPO_ROOT}/scripts/retry-5xx.sh"

gh_retry() {
  "${RETRY}" gh "$@"
}

VERSION="$("${DISCOVER}" pkgver "${PACKAGE}")"
TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
TAG="${PACKAGE}-${VERSION}-${TIMESTAMP}"
RELEASE_NAME="${TAG}"

mapfile -t NAMES < <("${DISCOVER}" pkgnames "${PACKAGE}")
mapfile -t PKGS < <(
  {
    for name in "${NAMES[@]}"; do
      ls "${name}"-*.apk 2>/dev/null || true
    done
  } | sort -u
)

if [ "${#PKGS[@]}" -eq 0 ]; then
  echo "No .apk artifacts found for ${PACKAGE} (pkgnames: ${NAMES[*]})" >&2
  exit 1
fi

ASSETS=()
NOTES="package: \`${PACKAGE}\` · commit [\`${GITHUB_SHA::7}\`](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA})"

for PKG in "${PKGS[@]}"; do
  test -f "${PKG}"
  ASSETS+=("${PKG}")
done

ensure_draft() {
  local is_draft
  if is_draft="$(gh_retry release view "${TAG}" --json isDraft --jq .isDraft 2>/dev/null)"; then
    if [ "${is_draft}" = "true" ]; then
      echo "Reusing draft ${TAG}"
      return 0
    fi
    echo "Release ${TAG} is already published" >&2
    exit 0
  fi
  gh_retry release create "${TAG}" \
    --draft \
    --prerelease \
    --title "${RELEASE_NAME}" \
    --notes "${NOTES}"
}

ensure_draft

for asset in "${ASSETS[@]}"; do
  echo "Uploading ${asset}"
  gh_retry release upload "${TAG}" "${asset}" --clobber
done

echo "Publishing ${TAG}"
gh_retry release edit "${TAG}" --draft=false --prerelease
