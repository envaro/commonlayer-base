#!/bin/sh
# generate-sbom.sh - SBOMs for every built image with syft, in the formats listed
# in commonlayer.yaml (build.sbom: spdx-json, cyclonedx-json), completed with the
# declared source-built components.
#
# Outputs $CL_OUT/sbom/<image>.<format>.json.
#   scripts/generate-sbom.sh                      locally built images (build.sh)
#   scripts/generate-sbom.sh <repo@sha256:...>    pushed images
#   CL_ATTEST=1 scripts/generate-sbom.sh --release
#                                                 every platform digest of the
#                                                 released indexes (CI), attested
# The release workflow attests these files to the image digest
# (cosign attest --type spdxjson / cyclonedx).
#
# Declared components. Software compiled from source in the image build is not
# in any package database, so syft finds it only when it has a binary classifier
# for it, and scanners cannot see what syft does not list. Every such component
# is therefore declared and added to both documents as software contained in the
# image, with name, exact version, supplier, license, download location,
# checksum, purl and CPEs (scanners match NVD records by CPE):
#   * build.components in commonlayer.yaml - the upstream application
#     (fromUpstream: version, source URL and SHA-256 from the versions[] entry
#     whose version equals the image's org.commonlayer.upstream.version label,
#     license from upstream.license) and any other explicit entries;
#   * JSON documents shipped in the image under /usr/share/commonlayer/sbom/ -
#     CommonLayer's own helpers (cl-probe from the base image, ...), so that every
#     image built on the base declares them too.
# When syft already found a component with the same name and version (binary
# classifiers for nginx, PostgreSQL), that entry is completed instead of adding a
# second one. The step fails when a declared component is malformed, when the
# image's upstream version has no versions[] entry, or when a declared
# component is missing from a written document.
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require syft jq yq

dir="$CL_OUT/sbom"
mkdir -p "$dir"
formats=$(yq '.build.sbom // ["spdx-json","cyclonedx-json"] | .[]' "$CL_MANIFEST")
work="$CL_OUT/tmp/sbom"
rm -rf "$work"
mkdir -p "$work"
manifest_json="$work/manifest.json"
yq -o=json '.' "$CL_MANIFEST" > "$manifest_json"

if [ "${1:-}" = "--release" ]; then
	# Every platform manifest of every released index (CI). With CL_ATTEST=1 each
	# SBOM is attached to its platform digest as a signed cosign attestation.
	cl_require_release
	targets=""
	while IFS='|' read -r _n _v _ver _l _c repo index; do
		for d in $(cl_platform_digests "$repo@$index" | cut -d' ' -f2); do
			targets="$targets $repo@$d"
		done
	done < "$(cl_release_file)"
	scheme=registry
elif [ $# -gt 0 ]; then
	targets=$*
	scheme=registry
else
	cl_require_built
	targets=$(cut -d'|' -f8 "$(cl_images_file)")
	scheme=docker
fi

# declarations <syft-json> : JSON array of the declared components of one image.
declarations() {
	jq --slurpfile m "$manifest_json" '
		$m[0] as $m
		| (.source.metadata.labels["org.commonlayer.upstream.version"] // "") as $uv
		| ([$m.versions // [] | .[] | select(.version == $uv)] | first) as $ver
		| def need($f): if (.[$f] | type) == "string" and .[$f] != "" then . else error("declared component \(.name // "?") (\(.origin)): \($f) is missing") end;
		  def resolve: . as $c | .purl |= gsub("[{]version[}]"; $c.version) | .cpes = ((.cpes // []) | map(gsub("[{]version[}]"; $c.version)));
		  [ .files[]?
		    | select(.contents != null and (.location.path | test("^/usr/share/commonlayer/sbom/[^/]+[.]json$")))
		    | (.contents | @base64d | fromjson) + {origin: ("image " + .location.path)} ]
		  + [ $m.build.components // [] | .[]
		      | if .fromUpstream == true then
		          if $uv == "" then error("image has no org.commonlayer.upstream.version label; cannot resolve fromUpstream component \(.name)")
		          elif $ver == null then error("no versions[] entry with version \($uv) for fromUpstream component \(.name)")
		          else {name, supplier, purl, cpes, description,
		                version: $uv, license: $m.upstream.license, homepage: $m.upstream.homepage,
		                downloadLocation: $ver.source.url, sha256: $ver.source.sha256,
		                origin: "commonlayer.yaml build.components (fromUpstream, versions[] \($ver.line))"}
		          end
		        else {name, supplier, purl, cpes, description, version, license, downloadLocation, sha256,
		              origin: "commonlayer.yaml build.components"}
		        end ]
		| map(need("name") | need("version") | need("supplier") | need("license") | need("purl") | resolve
		      | if (.purl | test("^pkg:[a-z][a-z0-9.+-]*/")) then . else error("declared component \(.name): invalid purl \(.purl)") end
		      | if (.downloadLocation // "" | test("^https://")) then . else .downloadLocation = null end)
		| unique_by(.name + "@" + .version)' "$1"
}

# add_cyclonedx <file> <declarations-file>
add_cyclonedx() {
	jq --slurpfile d "$2" '
		def lc: ascii_downcase;
		def dist($d): if $d.downloadLocation then [{type: "distribution", url: $d.downloadLocation, comment: "upstream source archive; SHA-256 verified in the image build"}
			+ (if $d.sha256 then {hashes: [{alg: "SHA-256", content: $d.sha256}]} else {} end)] else [] end;
		def site($d): if $d.homepage then [{type: "website", url: $d.homepage}] else [] end;
		def marks($d): [{name: "commonlayer:declared", value: "true"}, {name: "commonlayer:declared:origin", value: $d.origin}];
		reduce $d[0][] as $d (.;
			([(.components // []) | to_entries[] | select(.value.type != "file" and (.value.name | lc) == ($d.name | lc) and .value.version == $d.version) | .key] | first) as $i
			| if $i != null then
				.components[$i] |= (
					.supplier //= {name: $d.supplier}
					| (if (.licenses // []) == [] then .licenses = [{expression: $d.license}] else . end)
					| .externalReferences = ((.externalReferences // []) + dist($d) + site($d))
					| .cpe //= ($d.cpes[0] // null) | if .cpe == null then del(.cpe) else . end
					| . as $c
					| .properties = ((.properties // [])
						+ [$d.cpes[] | select(. != $c.cpe and ([$c.properties[]? | select(.name == "syft:cpe23") | .value] | index(.) | not)) | {name: "syft:cpe23", value: .}]
						+ marks($d)))
			else
				.components = ((.components // []) + [{
					"bom-ref": ("commonlayer-declared:" + $d.name + "@" + $d.version),
					type: "application",
					supplier: {name: $d.supplier},
					name: $d.name,
					version: $d.version,
					licenses: [{expression: $d.license}],
					purl: $d.purl,
					externalReferences: (dist($d) + site($d)),
					properties: ([$d.cpes[1:][] | {name: "syft:cpe23", value: .}] + marks($d))
				}
				+ (if $d.description then {description: $d.description} else {} end)
				+ (if ($d.cpes | length) > 0 then {cpe: $d.cpes[0]} else {} end)])
			end)' "$1" > "$1.tmp"
	mv "$1.tmp" "$1"
}

# add_spdx <file> <declarations-file>
add_spdx() {
	jq --slurpfile d "$2" '
		def lc: ascii_downcase;
		def refs($d): [$d.cpes[] | {referenceCategory: "SECURITY", referenceType: "cpe23Type", referenceLocator: .}]
			+ [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl", referenceLocator: $d.purl}];
		def note($d): "Built from source in the image build; declared in \($d.origin)"
			+ (if $d.downloadLocation then " (source archive \($d.downloadLocation)" + (if $d.sha256 then ", SHA-256 \($d.sha256) verified in the build)" else ")" end) else "" end);
		([.relationships[]? | select(.spdxElementId == "SPDXRef-DOCUMENT" and .relationshipType == "DESCRIBES") | .relatedSpdxElement] | first) as $root
		| if $root == null then error("SPDX document has no DESCRIBES relationship") else . end
		| reduce $d[0][] as $d (.;
			([(.packages // []) | to_entries[] | select(.value.SPDXID != $root and (.value.name | lc) == ($d.name | lc) and .value.versionInfo == $d.version) | .key] | first) as $i
			| if $i != null then
				.packages[$i] |= (
					(if (.supplier // "NOASSERTION") == "NOASSERTION" then .supplier = "Organization: \($d.supplier)" else . end)
					| (if (.licenseDeclared // "NOASSERTION") == "NOASSERTION" then .licenseDeclared = $d.license else . end)
					| (if $d.downloadLocation and ((.downloadLocation // "NOASSERTION") | IN("NOASSERTION", "NONE")) then
						.downloadLocation = $d.downloadLocation
						| (if $d.sha256 then .checksums = ((.checksums // []) + [{algorithm: "SHA256", checksumValue: $d.sha256}]) else . end)
					  else . end)
					| (if $d.homepage and (.homepage == null) then .homepage = $d.homepage else . end)
					| .sourceInfo = (((.sourceInfo // "") | if . == "" then "" else . + "; " end) + note($d))
					| . as $p
					| .externalRefs = ((.externalRefs // []) + [refs($d)[] | select(.referenceLocator as $l | [$p.externalRefs[]?.referenceLocator] | index($l) | not)]))
			else
				("SPDXRef-Package-commonlayer-declared-" + ($d.name + "-" + $d.version | gsub("[^A-Za-z0-9.-]"; "-"))) as $id
				| .packages = ((.packages // []) + [{
					name: $d.name,
					SPDXID: $id,
					versionInfo: $d.version,
					supplier: "Organization: \($d.supplier)",
					downloadLocation: ($d.downloadLocation // "NOASSERTION"),
					filesAnalyzed: false,
					sourceInfo: note($d),
					licenseConcluded: "NOASSERTION",
					licenseDeclared: $d.license,
					copyrightText: "NOASSERTION",
					externalRefs: refs($d),
					primaryPackagePurpose: "APPLICATION"
				}
				+ (if $d.sha256 and $d.downloadLocation then {checksums: [{algorithm: "SHA256", checksumValue: $d.sha256}]} else {} end)
				+ (if $d.homepage then {homepage: $d.homepage} else {} end)
				+ (if $d.description then {description: $d.description} else {} end)])
				| .relationships = ((.relationships // []) + [{spdxElementId: $root, relatedSpdxElement: $id, relationshipType: "CONTAINS"}])
			end)' "$1" > "$1.tmp"
	mv "$1.tmp" "$1"
}

for ref in $targets; do
	slug=$(cl_slug "$ref")
	raw="$work/$slug.syft.json"
	decl="$work/$slug.declared.json"
	set -- "$scheme:$ref" --quiet --source-name "${ref%%[:@]*}" -o "syft-json=$raw"
	for f in $formats; do
		set -- "$@" -o "$f=$dir/$slug.$f.json"
	done
	cl_log "syft $ref"
	# The file-content glob makes syft keep the declaration documents shipped in
	# the image (read from the image itself, for any platform or registry).
	SYFT_CHECK_FOR_APP_UPDATE=false SYFT_FILE_CONTENT_GLOBS='/usr/share/commonlayer/sbom/*.json' syft scan "$@"
	declarations "$raw" > "$decl" || cl_die "invalid component declarations for $ref"
	for f in $formats; do
		file="$dir/$slug.$f.json"
		case "$f" in
		spdx-json)
			add_spdx "$file" "$decl"
			n=$(jq '[.packages[]? | select(.SPDXID | startswith("SPDXRef-DocumentRoot-") | not)] | length' "$file")
			missing=$(jq -r --slurpfile d "$decl" '[$d[0][] as $c | select([.packages[]? | select((.name | ascii_downcase) == ($c.name | ascii_downcase) and .versionInfo == $c.version)] | length == 0) | "\($c.name) \($c.version)"] | join(", ")' "$file")
			;;
		cyclonedx-json)
			add_cyclonedx "$file" "$decl"
			n=$(jq '[.components[]? | select(.type != "file")] | length' "$file")
			missing=$(jq -r --slurpfile d "$decl" '[$d[0][] as $c | select([.components[]? | select((.name | ascii_downcase) == ($c.name | ascii_downcase) and .version == $c.version)] | length == 0) | "\($c.name) \($c.version)"] | join(", ")' "$file")
			;;
		*) cl_die "unsupported SBOM format $f" ;;
		esac
		[ "$n" -gt 0 ] || cl_die "$file lists no components"
		[ -z "$missing" ] || cl_die "$file is missing declared components: $missing"
		cl_ok "$file ($n components)"
		if [ -n "${CL_ATTEST:-}" ]; then
			cl_require cosign
			case "$f" in spdx-json) type=spdxjson ;; cyclonedx-json) type=cyclonedx ;; esac
			cosign attest --yes --type "$type" --predicate "$file" "$ref"
			cl_ok "attested $f SBOM to $ref"
		fi
	done
	jq -r '.[] | "declared: \(.name) \(.version) [\(.purl)] " + (if (.cpes | length) > 0 then "cpe: " + (.cpes | join(" ")) else "no CPE: no CVE feed, scanners cannot match it" end) + " (\(.origin))"' "$decl" |
		while IFS= read -r line; do cl_ok "$line"; done
done
rm -rf "$work"
