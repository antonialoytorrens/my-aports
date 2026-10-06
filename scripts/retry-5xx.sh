#!/usr/bin/env bash
# Retry a command on HTTP 5xx with exponential backoff.
#
# Usage:
#   retry-5xx.sh [--] command [args...]
#   retry-5xx.sh sleep    # wait one backoff step (for GitHub Action pre_retry)
#
# Env:
#   RETRY_5XX_MAX_RETRIES     default 20
#   RETRY_5XX_INITIAL_DELAY   default 60 (seconds)
#   RETRY_5XX_MAX_DELAY       default 900 (seconds)
#   RETRY_5XX_SLEEP_ID        counter key for `sleep` (default: $GITHUB_ACTION)
set -euo pipefail

MAX_RETRIES="${RETRY_5XX_MAX_RETRIES:-20}"
INITIAL_DELAY="${RETRY_5XX_INITIAL_DELAY:-60}"
MAX_DELAY="${RETRY_5XX_MAX_DELAY:-900}"

delay_for_attempt() {
  local n="$1"
  local delay="${INITIAL_DELAY}"
  local i=1
  while [ "${i}" -lt "${n}" ]; do
    delay=$((delay * 2))
    if [ "${delay}" -ge "${MAX_DELAY}" ]; then
      printf '%s\n' "${MAX_DELAY}"
      return 0
    fi
    i=$((i + 1))
  done
  printf '%s\n' "${delay}"
}

is_5xx() {
  grep -Eiq \
    'HTTP[/0-9.]*[[:space:]]*5[0-9]{2}|returned error:[[:space:]]*5[0-9]{2}|unexpected[[:space:]]+5[0-9]{2}|status code[:[:space:]]*5[0-9]{2}' \
    "$@" 2>/dev/null
}

sleep_backoff() {
  local id="${RETRY_5XX_SLEEP_ID:-${GITHUB_ACTION:-default}}"
  local dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  local f="${dir}/retry-5xx-sleep-${id}"
  local n delay
  n=$(($(cat "${f}" 2>/dev/null || echo 0) + 1))
  printf '%s\n' "${n}" > "${f}"
  delay="$(delay_for_attempt "${n}")"
  echo "retry-5xx: waiting ${delay}s before retry ${n}/${MAX_RETRIES}" >&2
  sleep "${delay}"
}

run_with_retry() {
  local attempt=0
  local delay="${INITIAL_DELAY}"
  local status=1
  local tmp_out tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  trap 'rm -f "${tmp_out}" "${tmp_err}"' RETURN

  while true; do
    status=0
    "$@" >"${tmp_out}" 2>"${tmp_err}" || status=$?
    if [ "${status}" -eq 0 ]; then
      cat "${tmp_out}"
      cat "${tmp_err}" >&2
      return 0
    fi
    if ! is_5xx "${tmp_out}" "${tmp_err}"; then
      cat "${tmp_out}"
      cat "${tmp_err}" >&2
      return "${status}"
    fi
    attempt=$((attempt + 1))
    if [ "${attempt}" -gt "${MAX_RETRIES}" ]; then
      echo "retry-5xx: giving up after ${MAX_RETRIES} retries" >&2
      cat "${tmp_out}" >&2
      cat "${tmp_err}" >&2
      return "${status}"
    fi
    echo "retry-5xx: HTTP 5xx (attempt ${attempt}/${MAX_RETRIES}), sleeping ${delay}s" >&2
    sleep "${delay}"
    delay=$((delay * 2))
    if [ "${delay}" -gt "${MAX_DELAY}" ]; then
      delay="${MAX_DELAY}"
    fi
  done
}

if [ "${1:-}" = "--" ]; then
  shift
fi

if [ "${1:-}" = "sleep" ]; then
  sleep_backoff
  exit 0
fi

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 [--] command [args...] | $0 sleep" >&2
  exit 2
fi

run_with_retry "$@"
