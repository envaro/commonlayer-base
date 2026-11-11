#!/bin/sh
# sign.sh - cosign keyless signatures for every released image index and chart,
# then verification against the identity declared in commonlayer.yaml.
#
# Inputs: $CL_OUT/release.txt (build.sh merge) and, when present,
# $CL_OUT/chart-release.txt (publish-chart.sh). Runs in GitHub Actions with
# `id-token: write`: cosign obtains a short-lived certificate from Fulcio for the
# workflow identity and records the signature in the Rekor transparency log.
#   scripts/sign.sh [sign] [images|charts|all]   sign and verify (default: all)
#   scripts/sign.sh verify [images|charts|all]   verify only
# A signature states which workflow, repository and ref produced the digest; it
# does not by itself say anything about the security of the content.
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require cosign jq yq
cl_require_release

# Usage: sign.sh [sign|verify] [images|charts|all]   (default: sign all)
mode=${1:-sign}
scope=${2:-all}
issuer=$(cl_yq '.security.signing.keyless.issuer')
identity=$(cl_identity_regexp)

refs=""
if [ "$scope" != charts ]; then
	refs=$(awk -F'|' '{print $6 "@" $7}' "$(cl_release_file)")
fi
if [ "$scope" != images ] && [ -s "$CL_OUT/chart-release.txt" ]; then
	refs="$refs $(awk -F'|' '{print $3 "@" $4}' "$CL_OUT/chart-release.txt")"
fi
for ref in $refs; do
	if [ "$mode" = sign ]; then
		cl_log "signing $ref"
		cosign sign --yes "$ref"
	fi
	cl_log "verifying $ref (issuer $issuer, identity $identity)"
	cosign verify --certificate-oidc-issuer "$issuer" --certificate-identity-regexp "$identity" "$ref" > /dev/null
	cl_ok "$ref"
done
