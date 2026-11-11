# Maintenance - CommonLayer base image

The base image is maintained by the CommonLayer platform team under the same
maintenance agreement and SLA as every project (`maintenance` in
`commonlayer.yaml`).

| Event | Action |
|---|---|
| Alpine publishes a fix for a package in the image | Rebuild (new revision) with the updated package set; `make validate build test scan sbom`. |
| New Alpine point release of the 3.24 branch | Update `versions[]` (version and the index digest of the official `alpine` image), the `ARG` defaults of `image/Dockerfile`, rebuild. |
| New BusyBox package release in Alpine | Update `APORTS_COMMIT`, `BUSYBOX_APKBUILD_SHA256` and `BUSYBOX_PKGREL` in `image/Dockerfile`; the build refuses a mismatch. |
| New Alpine release branch | Add a line, keep the previous one supported until derived images have moved; announce the end of life. |
| Vulnerability in a base package | Release within the SLA deadline of its severity; derived images rebuild on the new base digest. |

`validate.yml` rebuilds, tests and scans the image weekly, so a package fix
that needs a release shows up as a failing scan even without an advisory;
`security-scan.yml` rescans the published digests daily. Derived images pin the
base by digest (`images[].base.digest`), so a new base reaches them through
their own release, in their own repositories.

The base has no chart. It uses the template's workflows unchanged; nothing in
`.github/` differs from the project template.
