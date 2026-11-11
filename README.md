# CommonLayer base image

The root filesystem every CommonLayer image starts from (`FROM` in the final
stage, pinned by digest). It is a CommonLayer project in a repository of its
own (`envaro/commonlayer-base`), built, released and rescanned by this repository's
workflows. Image standard:
[CommonLayer image standard](https://github.com/envaro/commonlayer/blob/main/docs/contributing/image-standard.md).

| | |
|---|---|
| Image | `registry.commonlayer.org/base:3.24` (mutable), `:3.24.4-r<revision>` (immutable) |
| Contents | musl, BusyBox (reduced), CA certificates, tzdata, `cl-probe`, entrypoint helper library, apk database |
| User | `commonlayer`, UID/GID `10001:10001` (default) |
| Not included | package manager (apk), curl, wget, nc and every other network client, compilers, `su`/`login`/`passwd`, `mount`, editors |
| Size | about 1.1 MB compressed (linux/amd64) |

## How it is built

`image/Dockerfile`, four build stages and a `scratch` final stage:

1. **toolchain** - `docker.io/library/alpine:3.24.4` pinned by its index digest,
   with `build-base`.
2. **probe** - compiles `cl-probe` (`image/probe/`, C, static PIE, hardening
   flags) and runs its tests (`make test`: 67 checks of URL/status parsing and of
   the http/tcp/file probes against loopback servers). The build fails if a test
   fails.
3. **busybox** - rebuilds Alpine's BusyBox package from Alpine's own source:
   the `APKBUILD` of `main/busybox` at a pinned aports commit (checked against a
   pinned SHA-256), the upstream tarball and every Alpine patch (checked against
   the APKBUILD's SHA-512 list), Alpine's `busyboxconfig`, and then switches off
   the applets listed in `image/busybox/config-deny.txt` (network clients and
   servers, account and privilege tools, device/kernel administration, editors
   and debugging tools). The build fails if any applet in
   `image/busybox/forbidden-applets.txt` is still present. The result has the
   same version and patches as the `busybox` entry in the apk database, so
   scanners match the right version; it differs only in the applets compiled in.
4. **rootfs** - `apk add --root /rootfs --initdb --no-scripts` installs
   `musl busybox busybox-binsh ca-certificates-bundle tzdata alpine-release`
   (packages verified by apk against Alpine's keys). apk-tools is never
   installed into that root; `/etc/apk` is removed; the database
   (`/lib/apk/db/installed`) is kept. The rebuilt BusyBox replaces Alpine's
   binary (the build stops if Alpine has moved to a newer busybox revision than
   the rebuild), applet links are created for the compiled-in applets, then
   users, directories, licenses, `cl-probe`, the entrypoint library and the VEX
   document are added. The step fails if any setuid/setgid file exists.
   Timestamps are set to `SOURCE_DATE_EPOCH` (best-effort reproducibility; not
   claimed to be bit-for-bit reproducible).

## Layout

| Path | Owner, mode | Purpose |
|---|---|---|
| `/app` | root, 0755 | application files (read-only) |
| `/etc/commonlayer` | root, 0755 | configuration (`/etc/commonlayer/<app>`) |
| `/var/lib/commonlayer` | 10001, 0775 | data (`/var/lib/commonlayer/<app>`) |
| `/var/log/commonlayer` | 10001, 0775 | logs, when not on stdout/stderr |
| `/run/commonlayer` | 10001, 0775 | runtime files |
| `/tmp` | root, 1777 | scratch; mount an emptyDir/tmpfs with a read-only root |
| `/usr/local/bin/cl-probe` | root, 0755 | health probe |
| `/usr/local/lib/commonlayer/entrypoint-lib.sh` | root, 0644 | entrypoint helpers |
| `/usr/share/licenses/` | root | license texts and SPDX expressions |
| `/usr/share/commonlayer/vex/base.openvex.json` | root | VEX statements about the base packages |

## cl-probe

```
cl-probe [-t seconds] http <url> [expected-status]   # plain HTTP; status like 200 or 2xx (default 200)
cl-probe [-t seconds] tcp <host> <port>
cl-probe file <path>
```

Exit status 0 healthy, 1 unhealthy, 2 usage error. Default timeout 5 s
(`CL_PROBE_TIMEOUT`). No TLS, no redirects, nothing written to disk; meant for
loopback health endpoints. Example: `HEALTHCHECK CMD ["cl-probe", "http", "http://127.0.0.1:8080/healthz"]`.

cl-probe is CommonLayer's own code, so no SBOM tool can identify it and no
vulnerability database has entries for it. The image ships a declaration of it,
`/usr/share/commonlayer/sbom/cl-probe.json` (name, version 1.0.0, Apache-2.0,
`pkg:generic/commonlayer/cl-probe@1.0.0`, no CPE); the build fails if that
version differs from `cl-probe --version`. `scripts/generate-sbom.sh` of this
and of every image built on the base adds it to the SPDX and CycloneDX SBOMs.
That makes it visible in the inventory; it does not make it scannable: a
vulnerability in cl-probe would be found by review and fixed here, not reported
by Trivy or Grype.

## Entrypoint library

`/usr/local/lib/commonlayer/entrypoint-lib.sh` (POSIX sh) provides
`cl_file_env VAR [default]` (`<VAR>_FILE` support; refuses both being set; never
prints values), `cl_check_value VAR REGEX`, `cl_require_non_root`,
`cl_render_template SRC DST VAR...` (substitutes `${VAR}` only for the listed
variables), `cl_log`, `cl_warn`, `cl_die`. Tested by `tests/base.sh`.

## Build and test

```sh
scripts/install-tools.sh        # pinned, checksum-verified tools into ~/.local/bin
make validate build test scan sbom licenses
```

Local builds are `linux/amd64` (or the machine's architecture). `linux/arm64`
is built in CI on native arm64 runners. `tests/base.sh` checks the user, the
absence of network clients and package managers, the apk database, directory
ownership, read-only operation, the entrypoint library and cl-probe. The base
has no chart, so `make chart-test` and `make chart-test-kind` do nothing.

A test or script that mounts a host file into a container uses
`-v <file or temporary directory>:<path>:ro,z` (or `:z`): the `z` option relabels
the mount for SELinux, and without it a host with SELinux enforcing (Fedora, RHEL)
refuses the container access. Mount the specific file or a directory the test
created, never `$HOME`, `/`, `/tmp` itself or the repository root (see the header
of `scripts/lib.sh`).

The base is the one project that needs no other: its build stages start from
the official `alpine` image pinned by digest (`images[].base.digest` in
`commonlayer.yaml`) and its final stage is `scratch`.

## Workflows

The template's workflows, unchanged (`.github/workflows/`): `validate.yml` on
pull requests, pushes to `main` and weekly (rebuild, test and scan of the
current package set), `release.yml` on a tag `v<version>-r<revision>`, and
`security-scan.yml` daily (rescan of the published digests). The base has no
chart, so the chart steps of the release publish nothing.

## Using the base before its first release, and testing a base change

A project builds `FROM registry.commonlayer.org/base:<tag>@sha256:<digest>`,
the digest in its `images[].base.digest`. Until the base has a release, or to
test a change of this repository with a project before releasing it:

- locally, in a checkout of the project:
  `BASE_IMAGE=$(scripts/base-image.sh --build <checkout of this repository>) make build`
  (builds this repository, serves the image by digest from a registry on
  127.0.0.1 and prints the reference);
- in the project's CI: set the project repository's variable
  `CL_BASE_REPOSITORY` to `envaro/commonlayer-base` (or a fork); `validate.yml` then checks
  out this repository and builds it whenever the project's `base.digest` is empty.

Releases never do this: a release needs `images[].base.digest`.

## Releasing: the one-time bootstrap order

Every other image is built from the base by digest, so the base has to be
released before anything else can be, once:

1. **Release the base**: push the tag `v3.24.4-r1` to this repository
   (`.github/workflows/release.yml`). It is the only project whose release does
   not need a CommonLayer base digest.
2. **Record its digest**, the index digest the release printed (the same digest
   on GHCR and, after promotion, on `registry.commonlayer.org`; check with
   `docker buildx imagetools inspect registry.commonlayer.org/base:3.24`):
   - `images[].base.digest` in `commonlayer.yaml` of every project repository
     built on the base (`envaro/commonlayer-nginx`, `envaro/commonlayer-valkey`, `envaro/commonlayer-postgresql`,
     and the project template); `scripts/validate.sh` warns while it is empty;
   - the platform's repository variable `CL_BASE_IMAGE` =
     `registry.commonlayer.org/base:3.24@sha256:<digest>` (the platform's own
     images; see the
     [repository settings](https://github.com/envaro/commonlayer/blob/main/docs/operations/repository-settings.md)).
3. **Release the projects** (`v1.30.6-r1` in `envaro/commonlayer-nginx`, ...) and the platform.

Nothing skips step 2: every project's `release.yml` stops while any
`images[].base.digest` is empty, `scripts/build.sh` refuses a pushed build
(`CL_PUSH=1`) without a released base digest, and the platform's release stops
while `CL_BASE_IMAGE` is unset or not pinned by digest.

Preconditions to check before step 1, not done by any workflow: the release
must run in the repository that `commonlayer.yaml` names. `registry.source` is
`ghcr.io/envaro/commonlayer-base` and `security.signing.keyless.identity` is
`https://github.com/envaro/commonlayer-base/.github/workflows/*@refs/tags/v*`; a release
from a repository with another owner can neither push to that GHCR package with
its job token nor produce signatures the platform accepts for this manifest (a
fork changes both lines first). Promotion to `registry.commonlayer.org` needs a
running platform (`COMMONLAYER_API_URL`); without it the projects of step 3
cannot pull the base from `registry.commonlayer.org` and step 2 has to wait.
When the base is released again later (for a security fix or a package
update), steps 2-3 apply to adopt the new digest.

## Deviations from the image standard

Recorded in `commonlayer.yaml`: `base` (final stage is `scratch`), `source`
(assembled from Alpine binary packages; BusyBox from Alpine's source package),
`entrypoint`, `healthcheck`, `signals` (no long-running process).

## Licenses

- Build configuration (this repository): Apache-2.0 ([LICENSE](LICENSE)).
- Upstream: Alpine Linux packages, each under its own license.
- Bundled components: see [NOTICE](NOTICE), `/usr/share/licenses/` in the image
  and the `THIRD_PARTY_LICENSES.md` generated from the SBOM (`make sbom licenses`).
