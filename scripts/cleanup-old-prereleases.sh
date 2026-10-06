#!/usr/bin/env bash
# cleanup-old-prereleases.sh — keep the newest KEEP_COUNT GitHub prereleases per package.
# Packages are discovered via scripts/discover.sh (main/*/APKBUILD).
# Stable (non-prerelease) releases are never touched.
# Orphan draft releases (failed publishes) are deleted.
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

KEEP_COUNT="${KEEP_COUNT:-3}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISCOVER="${REPO_ROOT}/scripts/discover.sh"
RETRY="${REPO_ROOT}/scripts/retry-5xx.sh"

gh_retry() {
  "${RETRY}" gh "$@"
}

if ! [[ "${KEEP_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "KEEP_COUNT must be a positive integer, got: ${KEEP_COUNT}" >&2
  exit 1
fi

mapfile -t PACKAGES < <("${DISCOVER}" list)

if [ "${#PACKAGES[@]}" -eq 0 ]; then
  echo "No packages found (need main/<name>/APKBUILD)" >&2
  exit 1
fi

# Longest name first so foo-bar wins over foo when matching tag prefixes.
mapfile -t PACKAGES_BY_LEN < <(printf '%s\n' "${PACKAGES[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

echo "Packages: ${PACKAGES[*]}"
echo "Keeping ${KEEP_COUNT} newest prerelease(s) per package"

mapfile -t ROWS < <(
  gh_retry release list --repo "${REPO}" --limit 1000 --json tagName,publishedAt,isPrerelease,isDraft \
    --jq '.[] | "\(.tagName)|\(.publishedAt)|\(.isPrerelease)|\(.isDraft)"'
)

match_package() {
  local tag="$1"
  local pkg
  for pkg in "${PACKAGES_BY_LEN[@]}"; do
    case "${tag}" in
      "${pkg}"-*)
        printf '%s\n' "${pkg}"
        return 0
        ;;
    esac
  done
  return 1
}

declare -A PKG_ROWS=()
for pkg in "${PACKAGES[@]}"; do
  PKG_ROWS["${pkg}"]=""
done

deleted=0
for row in "${ROWS[@]:-}"; do
  IFS='|' read -r tag published is_pre is_draft <<<"${row}"
  matched="$(match_package "${tag}" || true)"
  if [ -z "${matched}" ]; then
    continue
  fi
  if [ "${is_draft}" = "true" ]; then
    echo "${matched}: delete orphan draft ${tag}"
    gh_retry release delete "${tag}" --repo "${REPO}" --yes --cleanup-tag
    deleted=$((deleted + 1))
    continue
  fi
  if [ "${is_pre}" != "true" ]; then
    continue
  fi
  PKG_ROWS["${matched}"]+="${published}|${tag}"$'\n'
done
for pkg in "${PACKAGES[@]}"; do
  rows="${PKG_ROWS[${pkg}]:-}"
  if [ -z "${rows}" ]; then
    echo "${pkg}: 0 prereleases"
    continue
  fi

  mapfile -t sorted < <(printf '%s' "${rows}" | grep -v '^$' | sort -r)
  total="${#sorted[@]}"
  keep=$((total < KEEP_COUNT ? total : KEEP_COUNT))
  echo "${pkg}: ${total} prerelease(s), keeping ${keep}"

  if [ "${total}" -le "${KEEP_COUNT}" ]; then
    continue
  fi

  for ((i = KEEP_COUNT; i < total; i++)); do
    IFS='|' read -r _published tag <<<"${sorted[i]}"
    echo "  delete ${tag}"
    gh_retry release delete "${tag}" --repo "${REPO}" --yes --cleanup-tag
    deleted=$((deleted + 1))
  done
done

echo "Deleted ${deleted}"
