# my-aports

Personal [Alpine Linux](https://alpinelinux.org/) aports tree and multi-arch `.apk` builder.

A package is anything with:

- `main/<name>/APKBUILD`

Shared builder image: [`docker/Dockerfile`](docker/Dockerfile) (Alpine 3.24 + `abuild`).

No `VERSION` file and no per-package entries in the Makefile or workflows — version is `pkgver=...` in the APKBUILD; arches come from `arch=...`.

## Build locally

```bash
make help
make wg-easy-x86_64
make seafile-x86_64              # builds in-tree libsearpc first
make docker-libsearpc-aarch64    # via docker compose
```

Foreign-arch builds need QEMU binfmt once:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

## Add a package

1. Create `main/<name>/` with an `APKBUILD` (and packaging files).
2. Done — `make`, CI discover, publish, and cleanup pick it up automatically.

Optional: add `name=<anitya_id>` to [`anitya.cfg`](anitya.cfg) when upstream is not on GitHub.

## CI / GitHub Releases

Push to `master` (and `workflow_dispatch`) builds a package only when there is no published prerelease with all expected `.apk`s for the current `pkgver` + `pkgrel`. To rebuild, bump `pkgver` or increase `pkgrel`. Tags look like `wg-easy-15.4.0-20261001120000`.

Releases are created as drafts, `.apk` assets are uploaded, then the prerelease is published.

Because Alpine `.apk` filenames have no architecture, CI tags them as `{name}-{pkgver}-r{pkgrel}.{arch}.apk` (and `.noarch.apk` when applicable).

A daily workflow keeps the **3** newest prereleases **per package** (stable releases are never touched) and deletes leftover draft releases.

## Layout

```
main/<name>/         # APKBUILD + packaging files
docker/Dockerfile    # shared abuild image
scripts/discover.sh  # package discovery / matrices / pkgver
Makefile             # generic targets from discover.sh
```

In-tree dependencies (e.g. `libsearpc` for `seafile`) are built automatically before the requested package.

Bump `pkgver` or increase `pkgrel` in the APKBUILD to trigger a new CI build.

## Packages

| Package | Notes |
|---------|--------|
| `wg-easy` | WireGuard UI (OpenRC), `x86_64` |
| `libsearpc` | Seafile RPC library (in-tree dep) |
| `seafile` | Client daemon + libs; subpackage **`seafile-cli`** (`seaf-cli`) |
