#!/bin/sh
# scan.sh - scan every built image with the scanners listed in commonlayer.yaml
# (security.scanners: trivy, grype) and apply the scan gate.
#
# Gate (security.gate, default critical): the scan fails when a finding at or
# above the gate severity has a fix available, unless an OpenVEX statement says
# it is not_affected or fixed. VEX documents applied: the project's own
# (security.vex) and those shipped in the image under /usr/share/commonlayer/vex/
# (the base image's statements about the base packages). Both scanners are
# applied; a finding gates when either scanner reports it.
#
# Each scanner runs twice per image: on the image itself, and on the image's
# SBOM as written by generate-sbom.sh (run first by this script). Only the SBOM
# contains the declared source-built components (build.components and the
# image's /usr/share/commonlayer/sbom/ documents), which the scanners cannot
# find in the image; Grype matches them by CPE. Trivy evaluates only OS and
# language packages, so for declared components the gate rests on Grype.
#
# Outputs in $CL_OUT/scan/: <image>.<scanner>.json and <image>.<scanner>.sbom.json,
# sarif/<scanner>/<image>.sarif and sarif/<scanner>-sbom/<image>.sarif (one
# directory per scanner and input for code-scanning upload), summary.md (counts
# per severity, suppressed and gated findings; the declared components) and
# gated.txt.
#
# Scan a pushed image instead of the local build records:
#   scripts/scan.sh <registry/repository@sha256:...>...
# Set CL_SCAN_NO_GATE=1 to report without failing (scheduled rescans).
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require jq yq

dir="$CL_OUT/scan"
mkdir -p "$dir"
scanners=$(yq '.security.scanners // ["trivy","grype"] | .[]' "$CL_MANIFEST")
gate=$(cl_yq_or '.security.gate' critical)
gate_sev=$(cl_gate_severities "$gate")
# shellcheck disable=SC2086 # word list
gate_json=$(printf '%s\n' $gate_sev | jq -R . | jq -sc .)
vex=$(cl_yq_or '.security.vex' '')
[ -n "$vex" ] && vex="$CL_ROOT/$vex"
for s in $scanners; do cl_require "$s"; done

if [ $# -gt 0 ]; then
	targets=$*
	remote=1
else
	cl_require_built
	targets=$(cut -d'|' -f8 "$(cl_images_file)")
	remote=""
fi

# The SBOMs (with the declared source-built components) are generated here so
# that the scan always covers exactly what the published SBOM lists.
sbom_format=spdx-json
yq '.build.sbom // ["spdx-json","cyclonedx-json"] | .[]' "$CL_MANIFEST" | grep -qx cyclonedx-json && sbom_format=cyclonedx-json
if [ -n "$remote" ]; then
	# shellcheck disable=SC2086 # word list of references
	CL_ATTEST='' sh "$CL_SCRIPTS/generate-sbom.sh" $targets
else
	CL_ATTEST='' sh "$CL_SCRIPTS/generate-sbom.sh"
fi

summary="$dir/summary.md"
{
	echo "# Scan summary"
	echo
	echo "Gate: \`$gate\` and above with a fix available, excluding VEX not_affected/fixed statements."
	echo
	echo "| Image | Scanner | Input | Critical | High | Medium | Low | Other | Suppressed (VEX/ignore) | Gated |"
	echo "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"
} > "$summary"
gated_total=0
gated_list="$dir/gated.txt"
: > "$gated_list"

# embedded_vex <ref> <dir> : copy OpenVEX documents shipped in the image
# (/usr/share/commonlayer/vex/, e.g. the base image's statements) to <dir>.
embedded_vex() {
	rm -rf "$2"
	mkdir -p "$2"
	c=$($CL_DOCKER create "$1" /bin/true 2>/dev/null) || return 0
	$CL_DOCKER cp "$c:/usr/share/commonlayer/vex/." "$2/" >/dev/null 2>&1 || true
	$CL_DOCKER rm -f "$c" >/dev/null 2>&1 || true
}

# scan_one <scanner> <input> <ref> <slug> : one scan of the image ("image": the
# scanner reads the image itself) or of its SBOM ("sbom": the SBOM written by
# generate-sbom.sh, including the declared source-built components that the
# scanners cannot find in the image); appends a summary row and gated findings.
scan_one() {
	s=$1 input=$2 ref=$3 slug=$4
	if [ "$input" = image ]; then
		json="$dir/$slug.$s.json"
		mkdir -p "$dir/sarif/$s"
		sarif="$dir/sarif/$s/$slug.sarif"
	else
		json="$dir/$slug.$s.sbom.json"
		mkdir -p "$dir/sarif/$s-sbom"
		sarif="$dir/sarif/$s-sbom/$slug.sarif"
	fi
	cl_log "$s $ref ($input)"
	case "$s" in
	trivy)
		if [ "$input" = image ]; then
			set -- image --quiet --scanners vuln --format json --output "$json"
			[ -n "$remote" ] || set -- "$@" --image-src docker
		else
			set -- sbom --quiet --scanners vuln --format json --output "$json"
		fi
		for f in $vexfiles; do set -- "$@" --vex "$f"; done
		[ -n "$vexfiles" ] && set -- "$@" --show-suppressed
		[ -f "$CL_ROOT/.trivyignore.yaml" ] && set -- "$@" --ignorefile "$CL_ROOT/.trivyignore.yaml"
		if [ "$input" = image ]; then trivy "$@" "$ref"; else trivy "$@" "$sbom"; fi
		trivy convert --quiet --format sarif --output "$sarif" "$json"
		counts=$(jq -r '[.Results[]?.Vulnerabilities[]? | .Severity] | group_by(.) | map({(.[0]): length}) | add // {}' "$json")
		gated=$(jq -c --argjson g "$gate_json" '[.Results[]?.Vulnerabilities[]?
			| select(.Severity as $s | $g | index($s))
			| select((.FixedVersion // "") != "")
			| {id: .VulnerabilityID, pkg: .PkgName, installed: .InstalledVersion, fixed: .FixedVersion, severity: .Severity}]' "$json")
		suppressed=$(jq '[.Results[]?.ModifiedFindings[]?] | length' "$json")
		;;
	grype)
		if [ "$input" = image ]; then
			src="docker:$ref"
			[ -n "$remote" ] && src="registry:$ref"
		else
			src="sbom:$sbom"
		fi
		set -- "$src" --quiet -o "json=$json" -o "sarif=$sarif"
		for f in $vexfiles; do set -- "$@" --vex "$f"; done
		grype "$@"
		counts=$(jq -r '[.matches[]? | .vulnerability.severity | ascii_upcase] | group_by(.) | map({(.[0]): length}) | add // {}' "$json")
		gated=$(jq -c --argjson g "$gate_json" '[.matches[]?
			| select(.vulnerability.severity | ascii_upcase as $s | $g | index($s))
			| select(.vulnerability.fix.state == "fixed")
			| {id: .vulnerability.id, pkg: .artifact.name, installed: .artifact.version, fixed: (.vulnerability.fix.versions | join(",")), severity: (.vulnerability.severity | ascii_upcase)}]' "$json")
		suppressed=$(jq '[.ignoredMatches[]?] | length' "$json")
		;;
	*) cl_die "unknown scanner $s" ;;
	esac
	c() { printf '%s' "$counts" | jq -r --arg k "$1" '.[$k] // 0'; }
	other=$(printf '%s' "$counts" | jq -r '[to_entries[] | select(.key | IN("CRITICAL","HIGH","MEDIUM","LOW") | not) | .value] | add // 0')
	ng=$(printf '%s' "$gated" | jq 'length')
	echo "| \`$ref\` | $s | $input | $(c CRITICAL) | $(c HIGH) | $(c MEDIUM) | $(c LOW) | $other | $suppressed | $ng |" >> "$summary"
	if [ "$ng" -gt 0 ]; then
		printf '%s' "$gated" | jq -r --arg r "$ref" --arg s "$s ($input)" '.[] | "\($r)\t\($s)\t\(.severity)\t\(.id)\t\(.pkg) \(.installed) -> \(.fixed)"' >> "$gated_list"
		gated_total=$((gated_total + ng))
	fi
}

declared_rows="$dir/declared.md"
: > "$declared_rows"
for ref in $targets; do
	slug=$(cl_slug "$ref")
	vexdir="$dir/$slug.vex"
	embedded_vex "$ref" "$vexdir"
	vexfiles=""
	[ -n "$vex" ] && vexfiles="$vex"
	for f in "$vexdir"/*.json; do
		if [ -f "$f" ]; then vexfiles="$vexfiles $f"; fi
	done
	sbom="$CL_OUT/sbom/$slug.$sbom_format.json"
	[ -s "$sbom" ] || cl_die "no SBOM $sbom (generate-sbom.sh did not write it)"
	for s in $scanners; do
		scan_one "$s" image "$ref" "$slug"
		scan_one "$s" sbom "$ref" "$slug"
	done
	case "$sbom_format" in
	cyclonedx-json) jq -r --arg r "$ref" '.components[]? | select(any(.properties[]?; .name == "commonlayer:declared")) | "| `\($r)` | \(.name) | \(.version) | `\(.purl // "-")` | " + ([.cpe // empty] + [.properties[]? | select(.name == "syft:cpe23") | .value] | if length > 0 then map("`" + . + "`") | join("<br>") else "none (no CVE feed)" end) + " |"' "$sbom" >> "$declared_rows" ;;
	spdx-json) jq -r --arg r "$ref" '.packages[]? | select((.sourceInfo // "") | contains("declared in")) | "| `\($r)` | \(.name) | \(.versionInfo) | `\([.externalRefs[]? | select(.referenceType == "purl") | .referenceLocator] | first // "-")` | " + ([.externalRefs[]? | select(.referenceType == "cpe23Type") | .referenceLocator] | if length > 0 then map("`" + . + "`") | join("<br>") else "none (no CVE feed)" end) + " |"' "$sbom" >> "$declared_rows" ;;
	esac
done

if [ -s "$declared_rows" ]; then
	{
		echo
		echo "## Declared source-built components"
		echo
		echo "Added to the SBOM by generate-sbom.sh and evaluated only in the \`sbom\` rows. Grype matches them against NVD records by CPE; Trivy matches only OS and language packages and does not evaluate them. Components without a CPE have no CVE feed: no scanner can report vulnerabilities in them."
		echo
		echo "| Image | Component | Version | purl | CPE |"
		echo "|---|---|---|---|---|"
		cat "$declared_rows"
	} >> "$summary"
fi
rm -f "$declared_rows"

if [ -s "$gated_list" ]; then
	{
		echo
		echo "## Findings that fail the gate"
		echo
		echo "| Image | Scanner (input) | Severity | Id | Package |"
		echo "|---|---|---|---|---|"
		sed 's/\t/ | /g; s/^/| /; s/$/ |/' "$gated_list"
	} >> "$summary"
fi
cat "$summary" >&2

if [ "$gated_total" -gt 0 ]; then
	if [ -n "${CL_SCAN_NO_GATE:-}" ]; then
		cl_warn "$gated_total finding(s) at or above '$gate' with a fix available (gate not enforced)"
	else
		cl_die "scan gate failed: $gated_total finding(s) at or above '$gate' with a fix available. Update the affected packages, or record a justified VEX statement in ${vex:-security/vex.openvex.json}."
	fi
fi
cl_ok "scan gate passed (gate: $gate)"
