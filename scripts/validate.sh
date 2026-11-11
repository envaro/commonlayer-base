#!/bin/sh
# validate.sh - static checks for a CommonLayer project.
#
#  1. commonlayer.yaml against schemas/commonlayer-v1.schema.json (kubeconform)
#  2. manifest rules beyond the schema (06 section 8): a primary and a secondary
#     maintainer, a checksum for every supported line, referenced files exist,
#     supported platforms, channels point at declared lines
#  3. Dockerfiles: ARG UPSTREAM_VERSION / UPSTREAM_SHA256 defaults match a
#     versions[] entry; final stage starts FROM ${BASE_IMAGE}; hadolint
#  4. shell scripts: shellcheck
#  5. charts: helm lint --strict, values.schema.json present, README up to date
#     with helm-docs
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require yq kubeconform hadolint shellcheck jq

errors=0
err() {
	cl_err "$*"
	errors=$((errors + 1))
}

# 1. Schema
schema=$(cl_schema_path) || cl_die "schemas/commonlayer-v1.schema.json is missing from this project (copy it from the project template, or set CL_SCHEMA)"
cl_log "manifest schema ($schema)"
if kubeconform -strict -summary -schema-location "$schema" "$CL_MANIFEST" >"$CL_OUT/validate-schema.txt" 2>&1; then
	cl_ok "commonlayer.yaml matches the schema"
else
	cat "$CL_OUT/validate-schema.txt" >&2
	cl_die "commonlayer.yaml does not match the schema"
fi
kind=$(cl_yq '.kind')
if [ "$kind" != "Project" ]; then
	cl_ok "kind $kind: schema validation only"
	exit 0
fi

# 2. Manifest rules beyond the schema
cl_log "manifest rules"
[ "$(yq '[.maintainers[] | select(.role == "primary")] | length' "$CL_MANIFEST")" -ge 1 ] || err "no primary maintainer"
[ "$(yq '[.maintainers[] | select(.role == "secondary")] | length' "$CL_MANIFEST")" -ge 1 ] || err "no secondary maintainer"
n=$(cl_version_count)
i=0
while [ "$i" -lt "$n" ]; do
	if [ "$(cl_yq ".versions[$i].status")" = "supported" ] && [ -z "$(cl_yq_or ".versions[$i].source.sha256" "")" ]; then
		err "versions[$i] ($(cl_yq ".versions[$i].line")) is supported but has no source.sha256"
	fi
	i=$((i + 1))
done
for l in $(yq '.release.channels // {} | to_entries | .[].value' "$CL_MANIFEST"); do
	[ "$(yq "[.versions[] | select(.line == \"$l\")] | length" "$CL_MANIFEST")" -gt 0 ] || err "release.channels refers to undeclared line $l"
done
for f in "$(cl_yq '.security.policy')" "$(cl_yq_or '.security.vex' '')" LICENSE NOTICE README.md; do
	[ -z "$f" ] || [ -f "$CL_ROOT/$f" ] || err "missing file: $f"
done
vex=$(cl_yq_or '.security.vex' '')
if [ -n "$vex" ] && [ -f "$CL_ROOT/$vex" ]; then
	jq -e '(."@context" | startswith("https://openvex.dev/ns")) and (.statements | type == "array")' "$CL_ROOT/$vex" >/dev/null ||
		err "$vex is not an OpenVEX document"
fi

ni=$(cl_image_count)
i=0
while [ "$i" -lt "$ni" ]; do
	name=$(cl_yq ".images[$i].name")
	df="$CL_ROOT/$(cl_yq ".images[$i].dockerfile")"
	ctx="$CL_ROOT/$(cl_yq ".images[$i].context")"
	[ -f "$df" ] || err "images[$i] ($name): dockerfile $df not found"
	[ -d "$ctx" ] || err "images[$i] ($name): context $ctx not found"
	for p in $(yq ".images[$i].platforms[]" "$CL_MANIFEST"); do
		case "$p" in linux/amd64 | linux/arm64) ;; *) err "images[$i] ($name): unsupported platform $p" ;; esac
	done
	[ -n "$(cl_yq_or ".images[$i].base.digest" "")" ] ||
		cl_warn "images[$i] ($name): base.digest is not set; local builds use a locally built base, releases are refused"
	if [ -f "$df" ]; then
		# 3. Dockerfile arguments mirror the manifest
		dv=$(sed -n 's/^ARG UPSTREAM_VERSION=\(.*\)$/\1/p' "$df" | head -n 1)
		ds=$(sed -n 's/^ARG UPSTREAM_SHA256=\(.*\)$/\1/p' "$df" | head -n 1)
		grep -q '^ARG UPSTREAM_VERSION' "$df" || err "$df: no ARG UPSTREAM_VERSION"
		grep -q '^ARG UPSTREAM_SHA256' "$df" || err "$df: no ARG UPSTREAM_SHA256"
		if [ -n "$dv" ]; then
			ms=$(yq ".versions[] | select(.version == \"$dv\") | .source.sha256" "$CL_MANIFEST")
			if [ -z "$ms" ]; then
				err "$df: default UPSTREAM_VERSION=$dv is not a version in commonlayer.yaml"
			elif [ "$ms" != "$ds" ]; then
				err "$df: default UPSTREAM_SHA256 does not match commonlayer.yaml for $dv"
			else
				cl_ok "$(basename "$df"): defaults match versions entry $dv"
			fi
		fi
		if ! cl_has_deviation "$i" base; then
			last_from=$(grep -E '^FROM ' "$df" | tail -n 1)
			# shellcheck disable=SC2016 # literal ${BASE_IMAGE}
			case "$last_from" in
			*'${BASE_IMAGE}'*) ;;
			*) err "$df: final stage must start FROM \${BASE_IMAGE} (got: $last_from)" ;;
			esac
		fi
		cl_log "hadolint $(basename "$(dirname "$df")")/$(basename "$df")"
		hadolint --config "$CL_ROOT/.hadolint.yaml" "$df" || err "hadolint reported problems in $df"
	fi
	i=$((i + 1))
done

# 4. Shell scripts
cl_log "shellcheck"
scripts=$(find "$CL_ROOT" -path "$CL_OUT" -prune -o -path "$CL_ROOT/.git" -prune -o -type f -name '*.sh' -print | sort)
if [ -n "$scripts" ]; then
	# shellcheck disable=SC2086 # list of paths without spaces
	shellcheck --severity=style $scripts || err "shellcheck reported problems"
fi

# 5. Charts
nc=$(cl_chart_count)
if [ "$nc" -gt 0 ]; then
	cl_require helm helm-docs
	for chart in $(cl_chart_dirs); do
		cl_log "chart $(basename "$chart")"
		[ -f "$chart/values.schema.json" ] || err "$chart: values.schema.json missing"
		[ -f "$chart/templates/_commonlayer.tpl" ] || err "$chart: templates/_commonlayer.tpl missing"
		helm lint --strict "$chart" >"$CL_OUT/helm-lint.txt" 2>&1 || {
			cat "$CL_OUT/helm-lint.txt" >&2
			err "helm lint --strict failed for $chart"
		}
		tmp=$(mktemp -d)
		cp -R "$chart/." "$tmp/"
		(cd "$tmp" && helm-docs --log-level warning --chart-search-root . >/dev/null)
		if ! cmp -s "$tmp/README.md" "$chart/README.md"; then
			err "$chart/README.md is out of date; run: (cd $chart && helm-docs --chart-search-root .)"
		fi
		rm -rf "$tmp"
	done
fi

if [ "$errors" -gt 0 ]; then
	cl_die "$errors validation error(s)"
fi
cl_ok "validation passed"
