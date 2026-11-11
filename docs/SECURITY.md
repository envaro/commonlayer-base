# Security policy - CommonLayer base image

## Reporting a vulnerability

Report privately to security@commonlayer.org or through the platform's private
report form for the `base` project. Do not open a public issue for an
unpatched vulnerability.

## What is maintained

- Rebuilt weekly and whenever Alpine publishes a fix for a package in the image
  (musl, BusyBox, ca-certificates-bundle, tzdata, alpine-release, alpine-keys).
- Scanned with Trivy and Grype on every build; the build fails on a critical
  finding with a fix available that has no VEX statement.
- VEX statements: `image/vex/base.openvex.json`, also installed in the image at
  `/usr/share/commonlayer/vex/base.openvex.json` so that scans of derived images
  apply them.

## Known, assessed findings

| Id | Package | Assessment |
|---|---|---|
| CVE-2025-60876 | busybox 1.37.0-r31 | `not_affected` (vulnerable_code_not_present): the wget applet is compiled out of this BusyBox build. Reported by Grype, suppressed through VEX; Trivy does not report it. |
