#!/usr/bin/env bash
#
# check-upstream-version.sh — compare pkgver in the APKBUILD against upstream.
#
# Required: PACKAGE=<name>
# Optional: VERSION=<upstream> to skip the remote API
#
# Upstream resolution (scripts/discover.sh upstream):
#   1. anitya.cfg  (package=Anitya project id)
#   2. GitHub URL inferred from the APKBUILD (source=/url=)
# Exit codes:
#   0 — packaged version is up to date
#   1 — a newer stable version is available (prints version to stdout)
#   2 — API or parse error
#
set -euo pipefail

: "${PACKAGE:?PACKAGE is required}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISCOVER="${REPO_ROOT}/scripts/discover.sh"
RETRY="${REPO_ROOT}/scripts/retry-5xx.sh"
CACHE_DIR="${REPO_ROOT}/.cache"
USER_AGENT="${USER_AGENT:-my-aports/1.0 (+https://github.com/antonialoytorrens/my-aports)}"

PACKAGED_VERSION="$("${DISCOVER}" pkgver "${PACKAGE}")"

fetch_github() {
  local github_repo="$1"
  local api_url="https://api.github.com/repos/${github_repo}/releases/latest"
  local response
  response="$("${RETRY}" curl -fsS -A "${USER_AGENT}" \
    -H "Accept: application/vnd.github+json" \
    "${api_url}")" || {
    echo "Failed to query GitHub API: ${api_url}" >&2
    exit 2
  }
  printf '%s' "${response}" | python3 -c '
import json, sys, re
data = json.load(sys.stdin)
tag = data.get("tag_name") or ""
tag = re.sub(r"^v", "", tag.strip())
if not tag:
    raise SystemExit(2)
print(tag)
'
}

fetch_anitya() {
  local project_id="$1"
  local api_url="https://release-monitoring.org/api/v2/versions/?project_id=${project_id}"
  local response parsed
  response="$("${RETRY}" curl -fsS -A "${USER_AGENT}" "${api_url}")" || {
    echo "Failed to query Anitya API: ${api_url}" >&2
    exit 2
  }
  parsed="$(printf '%s' "${response}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
stable = data.get("stable_versions") or []
latest = stable[0] if stable else data.get("version") or data.get("latest_version")
created = data.get("latest_version_created_on") or ""
if not latest:
    raise SystemExit(2)
print(f"{latest}\t{created}")
')"
  LATEST_CREATED_ON="${parsed#*$'\t'}"
  printf '%s' "${parsed%%$'\t'*}"
}

if [ -n "${VERSION:-}" ]; then
  LATEST_STABLE="$(printf '%s' "${VERSION}" | tr -d '[:space:]')"
else
  if ! command -v python3 &>/dev/null; then
    echo "python3 is required" >&2
    exit 2
  fi

  UPSTREAM="$("${DISCOVER}" upstream "${PACKAGE}")"
  LATEST_CREATED_ON=""
  case "${UPSTREAM}" in
    github:*)
      LATEST_STABLE="$(fetch_github "${UPSTREAM#github:}")"
      CACHE_FILE="${CACHE_DIR}/${PACKAGE}-github-last-check"
      ;;
    anitya:*)
      LATEST_STABLE="$(fetch_anitya "${UPSTREAM#anitya:}")"
      CACHE_FILE="${CACHE_DIR}/${PACKAGE}-anitya-last-check"
      ;;
    *)
      echo "unsupported upstream: ${UPSTREAM}" >&2
      exit 2
      ;;
  esac

  mkdir -p "${CACHE_DIR}"
  {
    echo "latest_stable_version=${LATEST_STABLE}"
    [ -n "${LATEST_CREATED_ON:-}" ] && echo "latest_version_created_on=${LATEST_CREATED_ON}"
    echo "checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${CACHE_FILE}"
fi

if [ "${PACKAGED_VERSION}" = "${LATEST_STABLE}" ]; then
  echo "${PACKAGED_VERSION}"
  exit 0
fi

NEWER="$(printf '%s\n%s\n' "${PACKAGED_VERSION}" "${LATEST_STABLE}" | sort -V | tail -1)"
if [ "${NEWER}" = "${LATEST_STABLE}" ]; then
  echo "${LATEST_STABLE}"
  exit 1
fi

echo "${PACKAGED_VERSION}"
exit 0
