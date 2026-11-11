#!/bin/sh
# publish-chart.sh - package every chart with the released image digest filled in
# and push it to an OCI registry. Records $CL_OUT/chart-release.txt
# (name|version|repository|digest) for sign.sh and register.sh.
#
# image.registry/repository are set to registry.destinations.images (the
# CommonLayer registry, where the digest is identical after mirroring),
# image.tag to <version>-r<revision> and image.digest to the released index
# digest of the chart's image for the stable channel (or the first line).
# CL_CHART_REPO overrides the push target (default oci://<registry.source>-charts
# parent: oci://ghcr.io/<owner>/charts). CL_PLAIN_HTTP=1 pushes over plain HTTP
# (local rehearsal against a throwaway registry only).
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require helm yq
cl_require_release

src=$(cl_source_repo)
dest=$(cl_yq_or '.registry.destinations.images' "$src")
chart_repo=${CL_CHART_REPO:-oci://${src%/*}/charts}
out="$CL_OUT/chart-release.txt"
: > "$out"
mkdir -p "$CL_OUT/charts"

n=$(cl_chart_count)
i=0
while [ "$i" -lt "$n" ]; do
	path="$CL_ROOT/$(cl_yq ".charts[$i].path")"
	cname=$(cl_yq ".charts[$i].name")
	img=$(cl_yq ".charts[$i].images[0]")
	rec=$(awk -F'|' -v n="$img" '$1 == n && $5 == "stable" {print; exit}' "$(cl_release_file)")
	[ -n "$rec" ] || rec=$(awk -F'|' -v n="$img" '$1 == n {print; exit}' "$(cl_release_file)")
	[ -n "$rec" ] || cl_die "no released image $img for chart $cname"
	version=$(printf '%s' "$rec" | cut -d'|' -f3)
	digest=$(printf '%s' "$rec" | cut -d'|' -f7)
	work="$CL_OUT/charts/$cname"
	rm -rf "$work"
	cp -R "$path" "$work"
	DEST_REG=${dest%%/*} DEST_REPO=${dest#*/} TAG="$version-r$CL_REVISION" DIGEST=$digest \
		yq -i '.image.registry = strenv(DEST_REG) | .image.repository = strenv(DEST_REPO) | .image.tag = strenv(TAG) | .image.digest = strenv(DIGEST)' "$work/values.yaml"
	APP=$version yq -i '.appVersion = strenv(APP)' "$work/Chart.yaml"
	helm lint --strict "$work" >/dev/null
	pkg=$(helm package "$work" -d "$CL_OUT/charts" | sed -n 's/.*saved it to: //p')
	cl_log "pushing $pkg to $chart_repo"
	# shellcheck disable=SC2086 # optional flag
	push=$(helm push "$pkg" "$chart_repo" ${CL_PLAIN_HTTP:+--plain-http} 2>&1)
	printf '%s\n' "$push"
	cdigest=$(printf '%s\n' "$push" | sed -n 's/^Digest: //p')
	cversion=$(yq '.version' "$work/Chart.yaml")
	printf '%s|%s|%s|%s\n' "$cname" "$cversion" "${chart_repo#oci://}/$cname" "$cdigest" >> "$out"
	cl_ok "$cname $cversion -> ${chart_repo#oci://}/$cname@$cdigest (image $dest@$digest)"
	i=$((i + 1))
done
