#!/bin/sh
# test-chart-kind.sh - install and upgrade tests of every chart on a kind cluster.
#
# For each chart: create a kind cluster (node image pinned below), load the
# locally built image (scripts/build.sh), then
#   1. install the previous release when one is published (CL_PREVIOUS_CHART,
#      e.g. oci://registry.commonlayer.org/charts/hello, optionally
#      CL_PREVIOUS_VERSION) - otherwise install the working tree;
#   2. upgrade to the working tree (with a changed value, so the upgrade rolls
#      the pods);
#   3. run `helm test`.
# Used in CI (GitHub-hosted runners). Needs docker, kind, helm (and kubectl for
# hooks). CL_KIND_KEEP=1 keeps the cluster for debugging; CL_KIND_CHARTS="a b"
# limits the run to those charts[].name entries.
#
# Optional per-chart hooks in the project's tests/kind/ directory (<chart> is
# charts[].name; tests/kind/ is not run by scripts/test.sh):
#   <chart>.setup.sh     before the first install, e.g. install an operator
#                        whose CRDs the chart renders (verify what you download)
#   <chart>.values.yaml  extra values for every install and upgrade
#   <chart>.wait.sh      after every install and upgrade, before `helm test`:
#                        wait for what `helm --wait` cannot see (for example
#                        pods created by an operator)
#   <chart>.verify.sh    after the final `helm test`: behaviour checks against
#                        the release (failover, configuration changes, ...)
# Hooks run with sh, in the project root, with KUBECONFIG, CL_KIND_CLUSTER,
# CL_KIND_NAMESPACE, CL_KIND_RELEASE, CL_CHART_NAME, CL_CHART_DIR, CL_KIND_IMAGE
# (the loaded image reference) and CL_OUT exported; a failing hook fails the test.
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require docker kind helm

# Default node image of kind v0.33.0 (from the kind binary), pinned by digest.
KIND_NODE_IMAGE=${CL_KIND_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}

cl_require_built
nc=$(cl_chart_count)
[ "$nc" -gt 0 ] || { cl_log "no charts in manifest"; exit 0; }
cluster="cl-$(cl_project_name)-$$"
cleanup() {
	[ -n "${CL_KIND_KEEP:-}" ] || kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

cl_log "creating kind cluster $cluster ($KIND_NODE_IMAGE)"
kind create cluster --name "$cluster" --image "$KIND_NODE_IMAGE" --wait 180s
export KUBECONFIG="$CL_OUT/kubeconfig-$cluster"
kind get kubeconfig --name "$cluster" > "$KUBECONFIG"

# hook <chart> <name> : run tests/kind/<chart>.<name>.sh when it exists.
hook() {
	h="$CL_ROOT/tests/kind/$1.$2.sh"
	[ -f "$h" ] || return 0
	cl_require kubectl
	cl_log "$1: hook tests/kind/$1.$2.sh"
	(cd "$CL_ROOT" && sh "$h") || cl_die "$1: hook tests/kind/$1.$2.sh failed"
}

i=0
while [ "$i" -lt "$nc" ]; do
	chart="$CL_ROOT/$(cl_yq ".charts[$i].path")"
	cname=$(cl_yq ".charts[$i].name")
	if [ -n "${CL_KIND_CHARTS:-}" ] && ! printf ' %s ' "$CL_KIND_CHARTS" | grep -q " $cname "; then
		cl_log "$cname: skipped (CL_KIND_CHARTS)"
		i=$((i + 1))
		continue
	fi
	img_name=$(cl_yq ".charts[$i].images[0]")
	# First built image of that name (default line).
	ref=$(awk -F'|' -v n="$img_name" '$3 == n {print $8; exit}' "$(cl_images_file)")
	[ -n "$ref" ] || cl_die "no built image named $img_name; run 'make build'"
	repo=${ref%:*}
	tag=${ref##*:}
	cl_log "$cname: loading $ref into kind"
	kind load docker-image --name "$cluster" "$ref"
	set -- --set image.registry= --set "image.repository=$repo" --set "image.tag=$tag" \
		--set image.digest= --set image.pullPolicy=Never
	ns="cl-$cname"
	release="t-$cname"
	values="$CL_ROOT/tests/kind/$cname.values.yaml"
	[ -f "$values" ] && set -- "$@" -f "$values"
	export CL_KIND_CLUSTER="$cluster" CL_KIND_NAMESPACE="$ns" CL_KIND_RELEASE="$release" \
		CL_CHART_NAME="$cname" CL_CHART_DIR="$chart" CL_KIND_IMAGE="$ref" CL_OUT KUBECONFIG
	hook "$cname" setup
	if [ -n "${CL_PREVIOUS_CHART:-}" ]; then
		cl_log "$cname: installing previous release $CL_PREVIOUS_CHART ${CL_PREVIOUS_VERSION:-}"
		helm install "$release" "$CL_PREVIOUS_CHART" ${CL_PREVIOUS_VERSION:+--version "$CL_PREVIOUS_VERSION"} \
			--namespace "$ns" --create-namespace --wait --timeout 5m "$@"
	else
		cl_warn "$cname: no previous release configured (CL_PREVIOUS_CHART); installing the working tree first"
		helm install "$release" "$chart" --namespace "$ns" --create-namespace --wait --timeout 5m "$@"
	fi
	hook "$cname" wait
	cl_log "$cname: upgrading to the working tree"
	helm upgrade "$release" "$chart" --namespace "$ns" --wait --timeout 5m "$@" \
		--set-string "podAnnotations.commonlayer\.org/upgrade-test=$(date +%s)"
	hook "$cname" wait
	cl_log "$cname: helm test"
	helm test "$release" --namespace "$ns" --timeout 5m --logs
	hook "$cname" verify
	cl_ok "$cname: install, upgrade and helm test passed"
	i=$((i + 1))
done
