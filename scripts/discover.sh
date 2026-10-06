#!/usr/bin/env bash
# discover.sh — convention-based package discovery (no per-package meta).
#
# A package exists when main/<name>/APKBUILD is present.
# Shared builder image: docker/Dockerfile (Alpine).
#
# Version = literal pkgver=... in the APKBUILD (no bash expansion).
#
# Usage:
#   discover.sh list
#   discover.sh pkgver <pkg>
#   discover.sh pkgrel <pkg>
#   discover.sh arches <pkg>
#   discover.sh pkgnames <pkg>
#   discover.sh make-targets
#   discover.sh build <target>
#   discover.sh build-matrix [pkg...]
#   discover.sh publish-matrix [pkg...]
#   discover.sh check-matrix
#   discover.sh changed [base_sha]
#   discover.sh unpublished [pkg...]
#   discover.sh upstream <pkg>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

apkbuild_path() {
  local pkg="$1"
  printf '%s\n' "${ROOT}/main/${pkg}/APKBUILD"
}

is_package() {
  local pkg="$1"
  [ -f "$(apkbuild_path "${pkg}")" ]
}

list_packages() {
  local d name
  for d in "${ROOT}"/main/*/; do
    [ -d "${d}" ] || continue
    name="$(basename "${d}")"
    if is_package "${name}"; then
      printf '%s\n' "${name}"
    fi
  done | sort
}

apkbuild_field() {
  local pkg="$1" field="$2"
  local ab
  ab="$(apkbuild_path "${pkg}")"
  # Single-line: field=value or field="value"
  if grep -qE "^${field}=[^\"']" "${ab}"; then
    sed -n "s/^${field}=//p" "${ab}" | head -n1 | sed 's/^"//; s/"$//'
    return 0
  fi
  # Quoted possibly multiline: field=" ... "
  awk -v f="${field}" '
    $0 ~ "^" f "=\"" {
      line = $0
      sub("^" f "=\"", "", line)
      if (line ~ /"/) {
        sub(/".*/, "", line)
        print line
        exit
      }
      buf = line
      while ((getline) > 0) {
        if (/"/) {
          sub(/".*/, "", $0)
          buf = buf " " $0
          print buf
          exit
        }
        buf = buf " " $0
      }
    }
  ' "${ab}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

pkgver_of() {
  local pkg="$1"
  local ver
  if [ ! -f "$(apkbuild_path "${pkg}")" ]; then
    echo "APKBUILD not found: $(apkbuild_path "${pkg}")" >&2
    return 1
  fi
  ver="$(apkbuild_field "${pkg}" pkgver)"
  if [ -z "${ver}" ]; then
    echo "pkgver=... not found in $(apkbuild_path "${pkg}")" >&2
    return 1
  fi
  printf '%s\n' "${ver}"
}

pkgrel_of() {
  local pkg="$1"
  local rel
  if [ ! -f "$(apkbuild_path "${pkg}")" ]; then
    echo "APKBUILD not found: $(apkbuild_path "${pkg}")" >&2
    return 1
  fi
  rel="$(apkbuild_field "${pkg}" pkgrel)"
  printf '%s\n' "${rel:-0}"
}

# Binary package names produced by an APKBUILD (pkgname + subpackages).
pkgnames_of() {
  local pkg="$1"
  local name subs tok expanded
  name="$(apkbuild_field "${pkg}" pkgname)"
  [ -n "${name}" ] || name="${pkg}"
  printf '%s\n' "${name}"
  subs="$(apkbuild_field "${pkg}" subpackages)"
  expanded="$(printf '%s' "${subs}" | sed "s/\$pkgname/${name}/g; s/\${pkgname}/${name}/g")"
  for tok in ${expanded}; do
    tok="${tok%%:*}"
    [ -n "${tok}" ] || continue
    printf '%s\n' "${tok}"
  done
}

# Subpackages whose split function sets arch="noarch".
noarch_pkgnames_of() {
  local pkg="$1" ab name pkgname_val subs tok func expanded
  ab="$(apkbuild_path "${pkg}")"
  pkgname_val="$(apkbuild_field "${pkg}" pkgname)"
  [ -n "${pkgname_val}" ] || pkgname_val="${pkg}"
  subs="$(apkbuild_field "${pkg}" subpackages)"
  expanded="$(printf '%s' "${subs}" | sed "s/\$pkgname/${pkgname_val}/g; s/\${pkgname}/${pkgname_val}/g")"
  for tok in ${expanded}; do
    case "${tok}" in
      *:*)
        name="${tok%%:*}"
        func="${tok##*:}"
        ;;
      *)
        continue
        ;;
    esac
    [ -n "${name}" ] && [ -n "${func}" ] || continue
    if awk -v fn="${func}" '
      index($0, fn "()") == 1 { in_fn=1; next }
      in_fn && /^[a-zA-Z_][a-zA-Z0-9_]*[(]/ { exit }
      in_fn && /arch="noarch"/ { found=1; exit }
      END { exit found ? 0 : 1 }
    ' "${ab}"; then
      printf '%s\n' "${name}"
    fi
  done
}

# Architectures we build in CI / Make (Alpine arch names).
default_arches() {
  printf '%s\n' x86_64 aarch64
}

arches_of() {
  local pkg="$1"
  local line
  line="$(apkbuild_field "${pkg}" arch)"
  if [ -z "${line}" ]; then
    echo "x86_64"
    return 0
  fi
  # Alpine: arch="all" means every arch (native package). arch="noarch" is indep.
  if [ "${line}" = "all" ]; then
    default_arches
    return 0
  fi
  if [ "${line}" = "noarch" ]; then
    # Build once on x86_64; artifact tagged .noarch.apk
    echo "x86_64"
    return 0
  fi
  printf '%s\n' "${line}" | tr ' \t' '\n' | grep -v '^$' || true
}

expected_versioned_apks() {
  local pkg="$1"
  local ver rel arch name
  ver="$(pkgver_of "${pkg}")"
  rel="$(pkgrel_of "${pkg}")"
  while IFS= read -r arch; do
    [ -n "${arch}" ] || continue
    while IFS= read -r name; do
      [ -n "${name}" ] || continue
      # noarch subpackages: only from x86_64 build
      if printf '%s\n' "$(noarch_pkgnames_of "${pkg}")" | grep -qx "${name}"; then
        continue
      fi
      printf '%s\n' "${name}-${ver}-r${rel}.${arch}.apk"
    done < <(pkgnames_of "${pkg}")
  done < <(arches_of "${pkg}")
  # Emit noarch once
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    printf '%s\n' "${name}-${ver}-r${rel}.noarch.apk"
  done < <(noarch_pkgnames_of "${pkg}")
}

unpublished_packages() {
  local selected=("$@")
  local pkg first json_pkgs json_expected line nfirst
  local releases status

  if [ "${#selected[@]}" -eq 0 ]; then
    return 0
  fi

  json_pkgs='['
  json_expected='{'
  first=true
  for pkg in "${selected[@]}"; do
    [ -n "${pkg}" ] || continue
    is_package "${pkg}" || continue
    if [ "${first}" = true ]; then
      first=false
    else
      json_pkgs+=','
      json_expected+=','
    fi
    json_pkgs+="$(json_escape "${pkg}")"
    json_expected+="$(json_escape "${pkg}")"
    json_expected+=':['
    nfirst=true
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      if [ "${nfirst}" = true ]; then
        nfirst=false
      else
        json_expected+=','
      fi
      json_expected+="$(json_escape "${line}")"
    done < <(expected_versioned_apks "${pkg}")
    json_expected+=']'
  done
  json_pkgs+=']'
  json_expected+='}'

  if [ -z "${GITHUB_REPOSITORY:-}" ] || { [ -z "${GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ]; }; then
    echo "unpublished: no GitHub credentials; not skipping" >&2
    printf '%s\n' "${selected[@]}"
    return 0
  fi

  status=0
  releases="$("${ROOT}/scripts/retry-5xx.sh" gh api --paginate "repos/${GITHUB_REPOSITORY}/releases")" || status=$?
  if [ "${status}" -ne 0 ]; then
    echo "unpublished: failed to list releases; not skipping" >&2
    printf '%s\n' "${selected[@]}"
    return 0
  fi

  status=0
  EXPECTED_JSON="${json_expected}" SELECTED_JSON="${json_pkgs}" python3 -c '
import json, os, sys

raw = sys.stdin.read()
decoder = json.JSONDecoder()
idx = 0
releases = []
while idx < len(raw):
    while idx < len(raw) and raw[idx].isspace():
        idx += 1
    if idx >= len(raw):
        break
    obj, end = decoder.raw_decode(raw, idx)
    idx = end
    if isinstance(obj, list):
        releases.extend(obj)
    else:
        releases.append(obj)

expected = json.loads(os.environ["EXPECTED_JSON"])
order = json.loads(os.environ["SELECTED_JSON"])
published = set()
for rel in releases:
    if rel.get("draft") or not rel.get("prerelease"):
        continue
    names = {a.get("name") or "" for a in (rel.get("assets") or [])}
    for pkg, need in expected.items():
        if pkg in published or not need:
            continue
        if all(n in names for n in need):
            published.add(pkg)
            print(f"skip {pkg}: already published for current pkgver+pkgrel", file=sys.stderr)

for pkg in order:
    if pkg not in published:
        print(pkg)
' <<<"${releases}" || status=$?
  if [ "${status}" -ne 0 ]; then
    echo "unpublished: failed to parse releases; not skipping" >&2
    printf '%s\n' "${selected[@]}"
    return 0
  fi
}

make_targets() {
  local pkg arch
  while IFS= read -r pkg; do
    while IFS= read -r arch; do
      [ -n "${arch}" ] || continue
      printf '%s-%s\n' "${pkg}" "${arch}"
    done < <(arches_of "${pkg}")
  done < <(list_packages)
}

parse_target() {
  local target="$1"
  local pkg arch rest
  PKG="" ARCH=""

  if [[ "${target}" =~ ^(.+)-(x86_64|aarch64|armv7)$ ]]; then
    rest="${BASH_REMATCH[1]}"
    arch="${BASH_REMATCH[2]}"
  else
    echo "invalid target (need …-x86_64|aarch64|armv7): ${target}" >&2
    return 1
  fi

  if is_package "${rest}"; then
    PKG="${rest}"
    ARCH="${arch}"
    return 0
  fi

  echo "unknown package target: ${target}" >&2
  return 1
}

platform_of() {
  case "$1" in
    x86_64) echo linux/amd64 ;;
    aarch64) echo linux/arm64 ;;
    armv7) echo linux/arm/v7 ;;
    *) echo "unsupported arch: $1" >&2; return 1 ;;
  esac
}

runner_of() {
  case "$1" in
    x86_64) echo ubuntu-latest ;;
    aarch64|armv7) echo ubuntu-24.04-arm ;;
    *) echo ubuntu-latest ;;
  esac
}

qemu_of() {
  case "$1" in
    armv7) echo true ;;
    *) echo false ;;
  esac
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

build_target() {
  local target="$1"
  parse_target "${target}"
  local platform args=()
  platform="$(platform_of "${ARCH}")"

  args=(docker buildx build --platform "${platform}"
    -f "${ROOT}/docker/Dockerfile"
    --build-arg "PACKAGE=${PKG}"
    --target artifact
    --output "${ROOT}/."
    "${ROOT}"
  )

  echo "+ ${args[*]}"
  "${args[@]}"
}

build_matrix_json() {
  local selected=("$@")
  local pkg arch first=true
  if [ "${#selected[@]}" -eq 0 ]; then
    mapfile -t selected < <(list_packages)
  fi
  printf '['
  for pkg in "${selected[@]}"; do
    [ -n "${pkg}" ] || continue
    is_package "${pkg}" || continue
    while IFS= read -r arch; do
      [ -n "${arch}" ] || continue
      local target
      target="${pkg}-${arch}"
      if [ "${first}" = true ]; then
        first=false
      else
        printf ','
      fi
      printf '{"package":%s,"arch":%s,"runner":%s,"qemu":%s,"target":%s,"timeout_minutes":360}' \
        "$(json_escape "${pkg}")" \
        "$(json_escape "${arch}")" \
        "$(json_escape "$(runner_of "${arch}")")" \
        "$(qemu_of "${arch}")" \
        "$(json_escape "${target}")"
    done < <(arches_of "${pkg}")
  done
  printf ']\n'
}

publish_matrix_json() {
  local selected=("$@")
  local pkg first=true
  local globs first_glob line
  if [ "${#selected[@]}" -eq 0 ]; then
    mapfile -t selected < <(list_packages)
  fi
  printf '['
  for pkg in "${selected[@]}"; do
    [ -n "${pkg}" ] || continue
    is_package "${pkg}" || continue
    globs="["
    first_glob=true
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      if [ "${first_glob}" = true ]; then
        first_glob=false
      else
        globs+=","
      fi
      # Glob form for gate check: name-*-r*.arch.apk is awkward; use exact expected name
      globs+="$(json_escape "${line}")"
    done < <(expected_versioned_apks "${pkg}")
    globs+="]"
    if [ "${first}" = true ]; then
      first=false
    else
      printf ','
    fi
    printf '{"package":%s,"expected_globs":%s}' "$(json_escape "${pkg}")" "${globs}"
  done
  printf ']\n'
}

check_matrix_json() {
  local pkg first=true
  printf '['
  while IFS= read -r pkg; do
    if [ "${first}" = true ]; then
      first=false
    else
      printf ','
    fi
    printf '{"package":%s,"title_prefix":%s}' \
      "$(json_escape "${pkg}")" \
      "$(json_escape "${pkg}")"
  done < <(list_packages)
  printf ']\n'
}

changed_packages() {
  local base_sha="${1:-}"
  local force_all=false
  local pkg changed

  mapfile -t ALL < <(list_packages)

  if [ -z "${base_sha}" ] || [ "${base_sha}" = "0000000000000000000000000000000000000000" ]; then
    force_all=true
  else
    changed="$(git -C "${ROOT}" diff --name-only "${base_sha}"...HEAD 2>/dev/null || true)"
    if printf '%s\n' "${changed}" | grep -qE '^\.github/workflows/build\.yml'; then
      force_all=true
    fi
  fi

  if [ "${force_all}" = true ]; then
    printf '%s\n' "${ALL[@]}"
    return 0
  fi

  local out=()
  for pkg in "${ALL[@]}"; do
    if printf '%s\n' "${changed}" | grep -qE "^main/${pkg}/"; then
      out+=("${pkg}")
    fi
  done
  if [ "${#out[@]}" -gt 0 ]; then
    printf '%s\n' "${out[@]}"
  fi
}

resolve_upstream() {
  local pkg="$1"
  local ab line id

  id="$(sed -n "s/^${pkg}=//p" "${ROOT}/anitya.cfg" 2>/dev/null | head -n1 || true)"
  if [ -n "${id}" ]; then
    printf 'anitya:%s\n' "${id}"
    return 0
  fi

  ab="$(apkbuild_path "${pkg}")"
  line="$(grep -E 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "${ab}" \
    | grep -v Maintainer \
    | head -n1 || true)"
  if [ -n "${line}" ]; then
    if [[ "${line}" =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]]; then
      printf 'github:%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
      return 0
    fi
  fi

  line="$(grep -E '^url="https://github\.com/' "${ab}" | head -n1 || true)"
  if [ -n "${line}" ]; then
    if [[ "${line}" =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]]; then
      printf 'github:%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
      return 0
    fi
  fi

  echo "cannot resolve upstream for ${pkg}: add an entry to anitya.cfg or a GitHub URL in the APKBUILD" >&2
  return 1
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  list)
    list_packages
    ;;
  pkgver)
    pkgver_of "${1:?package required}"
    ;;
  pkgrel)
    pkgrel_of "${1:?package required}"
    ;;
  unpublished)
    unpublished_packages "$@"
    ;;
  arches)
    arches_of "${1:?package required}"
    ;;
  pkgnames)
    pkgnames_of "${1:?package required}"
    ;;
  make-targets)
    make_targets
    ;;
  build)
    build_target "${1:?target required}"
    ;;
  build-matrix)
    build_matrix_json "$@"
    ;;
  publish-matrix)
    publish_matrix_json "$@"
    ;;
  check-matrix)
    check_matrix_json
    ;;
  changed)
    changed_packages "${1:-}"
    ;;
  upstream)
    resolve_upstream "${1:?package required}"
    ;;
  *)
    echo "Usage: $0 list|pkgver|pkgrel|arches|pkgnames|make-targets|build|build-matrix|publish-matrix|check-matrix|changed|unpublished|upstream" >&2
    exit 2
    ;;
esac
