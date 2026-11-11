#!/bin/sh
# test-chart.sh - static tests for every chart in commonlayer.yaml (charts[]).
#
#   1. helm lint --strict with the default values and each chart/ci/*.yaml
#   2. helm template for the same value sets, validated with kubeconform -strict
#      against Kubernetes $CL_KUBE_VERSIONS (and CRD schemas for ServiceMonitor,
#      HTTPRoute etc.), schema sources pinned by commit below
#   3. helm unittest (chart/tests/*_test.yaml)
#   4. policy check: trivy config on the rendered manifests, failing on HIGH or
#      CRITICAL misconfigurations
# Install/upgrade tests on a real cluster are in test-chart-kind.sh (CI).
#
# Extra schemas (custom resources whose exact schemas matter, e.g. an operator's
# CRDs of the release the chart targets), tried before the pinned catalogs:
#   tests/chart/<chart>.schemas.sh  optional project hook (<chart> is the chart
#                                   directory name); runs with CL_SCHEMA_DIR set
#                                   and writes kubeconform schemas there as
#                                   <group>/<kind lower-case>_<version>.json
#                                   (verify what it downloads)
#   CL_EXTRA_SCHEMA_LOCATIONS       further kubeconform -schema-location values,
#                                   separated by spaces
# Further static checks of a chart (for example: example manifests shipped with
# the project validated against the same schemas):
#   tests/chart/<chart>.test.sh     optional project hook, run last for that chart
#                                   in the project root with CL_CHART_DIR,
#                                   CL_RENDERED_DIR (one <value set>.yaml per
#                                   rendering above), CL_SCHEMA_DIR (empty without
#                                   a schemas hook), CL_KUBE_VERSIONS and CL_OUT
#                                   exported; a failing hook fails the chart tests
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require helm kubeconform trivy

# kubeconform schema sources, pinned (resolved 2026-11-10 with git ls-remote).
K8S_SCHEMAS_COMMIT=9367d1ce1c88b8bbf6ee06d0e80510f26394913f   # yannh/kubernetes-json-schema master
CRD_SCHEMAS_COMMIT=49729e49e8f062933e3716a26540d41b0cd0856c   # datreeio/CRDs-catalog main
CL_KUBE_VERSIONS=${CL_KUBE_VERSIONS:-"1.31.0 1.37.0"}

nc=$(cl_chart_count)
[ "$nc" -gt 0 ] || { cl_log "no charts in manifest"; exit 0; }
helm plugin list 2>/dev/null | grep -q '^unittest' || cl_die "helm-unittest plugin missing; run scripts/install-tools.sh helm-unittest"

failures=0
fail() {
	cl_err "$*"
	failures=$((failures + 1))
}

for chart in $(cl_chart_dirs); do
	name=$(basename "$chart")
	out="$CL_OUT/chart-$name"
	rm -rf "$out"
	mkdir -p "$out/rendered"
	value_sets="default"
	for f in "$chart"/ci/*.yaml; do [ -f "$f" ] && value_sets="$value_sets $f"; done
	extra="${CL_EXTRA_SCHEMA_LOCATIONS:-}"
	hook="$CL_ROOT/tests/chart/$name.schemas.sh"
	if [ -f "$hook" ]; then
		cl_log "$name: extra schemas (tests/chart/$name.schemas.sh)"
		mkdir -p "$out/schemas"
		if (cd "$CL_ROOT" && CL_SCHEMA_DIR="$out/schemas" CL_OUT="$CL_OUT" sh "$hook"); then
			extra="$out/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json $extra"
		else
			fail "$name: tests/chart/$name.schemas.sh failed"
		fi
	fi

	for vs in $value_sets; do
		label=$(basename "$vs" .yaml)
		if [ "$vs" = default ]; then set --; else set -- -f "$vs"; fi
		cl_log "$name: lint ($label)"
		helm lint --strict "$chart" "$@" >"$out/lint-$label.txt" 2>&1 || {
			cat "$out/lint-$label.txt" >&2
			fail "$name: helm lint --strict failed ($label)"
		}
		cl_log "$name: template ($label)"
		if helm template "cl-test" "$chart" --namespace cl-test "$@" > "$out/rendered/$label.yaml" 2>"$out/template-$label.err"; then
			for kv in $CL_KUBE_VERSIONS; do
				set --
				for loc in $extra; do set -- "$@" -schema-location "$loc"; done
				if kubeconform -strict -summary -kubernetes-version "$kv" "$@" \
					-schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMAS_COMMIT/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
					-schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRD_SCHEMAS_COMMIT/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
					"$out/rendered/$label.yaml" >"$out/kubeconform-$label-$kv.txt" 2>&1; then
					cl_ok "kubeconform $label (Kubernetes $kv): $(tail -n 1 "$out/kubeconform-$label-$kv.txt")"
				else
					cat "$out/kubeconform-$label-$kv.txt" >&2
					fail "$name: kubeconform failed ($label, Kubernetes $kv)"
				fi
			done
		else
			cat "$out/template-$label.err" >&2
			fail "$name: helm template failed ($label)"
		fi
	done

	cl_log "$name: helm unittest"
	helm unittest "$chart" || fail "$name: helm unittest failed"

	cl_log "$name: policy check (trivy config, HIGH/CRITICAL)"
	if trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 --format table \
		--output "$out/trivy-config.txt" "$out/rendered"; then
		cl_ok "no HIGH/CRITICAL misconfigurations"
	else
		cat "$out/trivy-config.txt" >&2
		fail "$name: trivy config reported HIGH/CRITICAL misconfigurations"
	fi

	check="$CL_ROOT/tests/chart/$name.test.sh"
	if [ -f "$check" ]; then
		cl_log "$name: further checks (tests/chart/$name.test.sh)"
		schema_dir=""
		[ -f "$hook" ] && schema_dir="$out/schemas"
		if (cd "$CL_ROOT" && CL_CHART_DIR="$chart" CL_RENDERED_DIR="$out/rendered" CL_SCHEMA_DIR="$schema_dir" \
			CL_KUBE_VERSIONS="$CL_KUBE_VERSIONS" CL_OUT="$CL_OUT" sh "$check"); then
			cl_ok "$name: tests/chart/$name.test.sh passed"
		else
			fail "$name: tests/chart/$name.test.sh failed"
		fi
	fi
done

[ "$failures" -eq 0 ] || cl_die "$failures chart test failure(s)"
cl_ok "chart tests passed"
