#!/bin/sh
# Run inside docker/Dockerfile build stage: build PACKAGE (+ in-tree deps) with abuild.
set -eu

APORTSDIR="${APORTSDIR:-/home/builder/aports}"
REPODEST="${REPODEST:-/home/builder/packages}"
OUTDIR="${OUTDIR:-/out}"
PACKAGE="${PACKAGE:?PACKAGE is required}"

export APORTSDIR REPODEST

mkdir -p "${REPODEST}/main" "${OUTDIR}"

# Local repo for in-tree dependencies (libsearpc → seafile, …).
if ! grep -qF "${REPODEST}/main" /etc/apk/repositories 2>/dev/null; then
	echo "${REPODEST}/main" | sudo tee -a /etc/apk/repositories >/dev/null
fi

is_package() {
	[ -f "${APORTSDIR}/main/$1/APKBUILD" ]
}

apkbuild_field() {
	# Usage: apkbuild_field <pkg> <field>
	pkg="$1"
	field="$2"
	ab="${APORTSDIR}/main/${pkg}/APKBUILD"
	if grep -qE "^${field}=[^\"']" "${ab}"; then
		sed -n "s/^${field}=//p" "${ab}" | head -n1 | sed 's/^"//; s/"$//'
		return 0
	fi
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

# Map a depends/makedepends token to an in-tree package directory, if any.
resolve_in_tree() {
	dep="$1"
	case "${dep}" in
	'' | *[=\<\>]* ) return 1 ;;
	esac
	case "${dep}" in
	*[!a-zA-Z0-9._+-]* ) return 1 ;;
	esac
	if is_package "${dep}"; then
		printf '%s\n' "${dep}"
		return 0
	fi
	base="${dep}"
	base="${base%-dev}"
	base="${base%-doc}"
	base="${base%-libs}"
	base="${base%-static}"
	base="${base%-dbg}"
	base="${base%-openrc}"
	base="${base%-daemon}"
	base="${base%-cli}"
	if [ "${base}" != "${dep}" ] && is_package "${base}"; then
		printf '%s\n' "${base}"
		return 0
	fi
	case "${dep}" in
	py3-*)
		rest="${dep#py3-}"
		if is_package "${rest}"; then
			printf '%s\n' "${rest}"
			return 0
		fi
		if is_package "lib${rest}"; then
			printf '%s\n' "lib${rest}"
			return 0
		fi
		;;
	esac
	return 1
}

# Emit dependency tokens from depends* / makedepends* (handles multiline + $depends_dev).
dep_tokens() {
	pkg="$1"
	ab="${APORTSDIR}/main/${pkg}/APKBUILD"
	python3 - "$ab" <<'PY' || true
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
fields = {}
for name in ("depends", "depends_dev", "makedepends", "makedepends_dev"):
    m = re.search(rf'^{name}="([^"]*)"', text, re.M | re.S)
    if m:
        fields[name] = m.group(1)
raw = " ".join(fields.get(k, "") for k in ("depends", "depends_dev", "makedepends", "makedepends_dev"))
# Expand common Alpine APKBUILD indirections once.
raw = raw.replace("$depends_dev", fields.get("depends_dev", ""))
raw = raw.replace("${depends_dev}", fields.get("depends_dev", ""))
raw = raw.replace("$makedepends_dev", fields.get("makedepends_dev", ""))
for tok in re.findall(r"[A-Za-z0-9._+-]+", raw):
    if tok.startswith("$"):
        continue
    print(tok)
PY
}

# DFS post-order: dependencies before PACKAGE.
build_order() {
	pkg="$1"
	visited_file="$2"
	if grep -qx "${pkg}" "${visited_file}" 2>/dev/null; then
		return 0
	fi
	echo "${pkg}" >>"${visited_file}"
	for tok in $(dep_tokens "${pkg}"); do
		dep="$(resolve_in_tree "${tok}" || true)"
		[ -n "${dep}" ] || continue
		[ "${dep}" = "${pkg}" ] && continue
		build_order "${dep}" "${visited_file}"
	done
	printf '%s\n' "${pkg}"
}

build_one() {
	pkg="$1"
	echo "==> abuild ${pkg}"
	cd "${APORTSDIR}/main/${pkg}"
	abuild checksum
	abuild -r
	sudo apk update >/dev/null
}

visited="$(mktemp)"
trap 'rm -f "${visited}"' EXIT
: >"${visited}"

order="$(build_order "${PACKAGE}" "${visited}" | awk '!seen[$0]++')"

for pkg in ${order}; do
	build_one "${pkg}"
done

CARCH="$(abuild -A)"
pkgname="$(apkbuild_field "${PACKAGE}" pkgname)"
pkgver="$(apkbuild_field "${PACKAGE}" pkgver)"
pkgrel="$(apkbuild_field "${PACKAGE}" pkgrel)"
subpackages="$(apkbuild_field "${PACKAGE}" subpackages)"

names="${pkgname}"
subs="$(printf '%s' "${subpackages}" | sed "s/\$pkgname/${pkgname}/g; s/\${pkgname}/${pkgname}/g")"
for tok in ${subs}; do
	name="${tok%%:*}"
	[ -n "${name}" ] || continue
	names="${names} ${name}"
done

for name in ${names}; do
	for archdir in "${CARCH}" noarch; do
		src="${REPODEST}/main/${archdir}/${name}-${pkgver}-r${pkgrel}.apk"
		if [ -f "${src}" ]; then
			cp -f "${src}" "${OUTDIR}/${name}-${pkgver}-r${pkgrel}.${archdir}.apk"
			echo "exported ${name}-${pkgver}-r${pkgrel}.${archdir}.apk"
		fi
	done
done

ls -la "${OUTDIR}"
