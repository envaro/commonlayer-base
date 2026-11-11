## What changes

<!-- One or two sentences. -->

## Checklist

- [ ] `make validate build test scan sbom chart-test` passes locally (or explain why not)
- [ ] An upstream version change updates `versions[]` in `commonlayer.yaml` **and**
      the `ARG UPSTREAM_VERSION` / `ARG UPSTREAM_SHA256` defaults in `image/Dockerfile`,
      with a checksum verified from the upstream release (and its signature, where published)
- [ ] New or changed findings are fixed, or assessed in `security/vex.openvex.json`
      with a justification
- [ ] Chart changes bump `chart/Chart.yaml` `version` and regenerate `chart/README.md` (`helm-docs`)
- [ ] Shared files (`scripts/*.sh`, `chart/templates/_commonlayer.tpl`, lint configuration)
      are unchanged, or changed in the CommonLayer template first
