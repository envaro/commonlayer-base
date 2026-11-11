#!/bin/sh
# build.sh - build every image of the project for every supported version line.
#
#   scripts/build.sh            build for $CL_PLATFORM and load into the local
#                               image store (default; what `make build` runs)
#   CL_PUSH=1 scripts/build.sh  build for $CL_PLATFORM and push by digest only
#                               (CI, one native runner per platform); records
#                               $CL_OUT/digests/*.json
#   scripts/build.sh merge      join the per-platform digests into one index per
#                               image and version, push the tags (CI); records
#                               $CL_OUT/release.txt
#
# Inputs come from commonlayer.yaml: images[] x versions[] (lines with status
# eol are skipped; CL_VERSIONS="1.30" limits the lines). Build arguments passed
# to every Dockerfile (see the CommonLayer image standard,
# https://github.com/envaro/commonlayer/blob/main/docs/contributing/image-standard.md):
#   UPSTREAM_VERSION UPSTREAM_SHA256 UPSTREAM_URL VERSION_LINE CHANNEL
#   IMAGE_REVISION VCS_REF CREATED SOURCE_REPOSITORY SOURCE_DATE_EPOCH
#   BASE_IMAGE (name:tag@digest) BASE_NAME BASE_DIGEST
#
# Environment: CL_PLATFORM, CL_REVISION, CL_IMAGE_PREFIX, CL_VERSIONS, BASE_IMAGE,
# CL_PUSH, CL_EXTRA_CA_FILE (see scripts/docker-build.sh).
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require docker yq

mode=${1:-build}

# Repository an image is pushed to in CI: registry.source for the project's
# primary image (same name, no variant), registry.source/<name>[-<variant>] otherwise.
push_repo() {
	src=$(cl_source_repo)
	n=$(cl_yq ".images[$1].name")
	v=$(cl_yq_or ".images[$1].variant" "")
	if [ "$n" = "$(cl_project_name)" ] && [ -z "$v" ]; then
		printf '%s\n' "$src"
	elif [ -n "$v" ]; then
		printf '%s/%s-%s\n' "$src" "$n" "$v"
	else
		printf '%s/%s\n' "$src" "$n"
	fi
}

# resolve_base <image-index> : print name:tag@digest for the final stage.
resolve_base() {
	if [ -n "${BASE_IMAGE:-}" ]; then
		case "$BASE_IMAGE" in *@sha256:*) ;; *) cl_die "BASE_IMAGE must be pinned by digest (name:tag@sha256:...)" ;; esac
		printf '%s\n' "$BASE_IMAGE"
		return
	fi
	img=$(cl_yq ".images[$1].base.image")
	tag=$(cl_yq ".images[$1].base.tag")
	digest=$(cl_yq_or ".images[$1].base.digest" "")
	if [ -n "$digest" ]; then
		printf '%s:%s@%s\n' "$img" "$tag" "$digest"
		return
	fi
	# No released base digest yet: use the locally built CommonLayer base,
	# still pinned by digest (requires Docker's containerd image store).
	if [ -n "${CL_PUSH:-}" ]; then
		cl_die "images[$1].base.digest is empty; a pushed build must use a released base digest"
	fi
	local_ref="$CL_IMAGE_PREFIX/base:$tag"
	rd=$($CL_DOCKER image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$local_ref" 2>/dev/null |
		grep "^$CL_IMAGE_PREFIX/base@sha256:" | head -n 1 || true)
	if [ -z "$rd" ]; then
		cl_die "images[$1].base.digest is empty and $local_ref is not available locally by digest.
       Fill images[$1].base.digest with the digest of a base release, set
       BASE_IMAGE=<name:tag@sha256:...>, or build the base project first
       (make build in a checkout of the base project's repository, or
       BASE_IMAGE=\$(scripts/base-image.sh --build <checkout>))."
	fi
	cl_warn "images[$1].base.digest is not set; using local base $local_ref@${rd#*@}"
	printf '%s@%s\n' "$local_ref" "${rd#*@}"
}

channel_of_line() {
	yq ".release.channels // {} | to_entries | map(select(.value == \"$1\")) | .[0].key // \"\"" "$CL_MANIFEST"
}

build_all() {
	epoch=$(cl_source_date_epoch)
	created=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
	vcs_ref=$(cl_git_ref)
	repo_url=$(cl_repo_url)
	images_file=$(cl_images_file)
	arch=${CL_PLATFORM#*/}
	arch=$(printf '%s' "$arch" | tr '/' '-')
	: > "$images_file"
	[ -n "${CL_PUSH:-}" ] && mkdir -p "$CL_OUT/digests"

	ni=$(cl_image_count)
	[ "$ni" -gt 0 ] || { cl_log "no images in manifest; nothing to build"; return 0; }
	versions=$(cl_selected_versions)
	[ -n "$versions" ] || cl_die "no version lines selected (CL_VERSIONS=${CL_VERSIONS:-})"

	i=0
	while [ "$i" -lt "$ni" ]; do
		name=$(cl_yq ".images[$i].name")
		variant=$(cl_yq_or ".images[$i].variant" "")
		dockerfile="$CL_ROOT/$(cl_yq ".images[$i].dockerfile")"
		context="$CL_ROOT/$(cl_yq ".images[$i].context")"
		platforms=$(yq ".images[$i].platforms | join(\" \")" "$CL_MANIFEST")
		case " $platforms " in
		*" $CL_PLATFORM "*) ;;
		*) cl_warn "$name does not list $CL_PLATFORM (declares: $platforms); skipping"; i=$((i + 1)); continue ;;
		esac
		base_ref=$(resolve_base "$i")
		base_name=${base_ref%@*}
		base_digest=${base_ref#*@}
		for vi in $versions; do
			version=$(cl_yq ".versions[$vi].version")
			line=$(cl_yq ".versions[$vi].line")
			url=$(cl_yq ".versions[$vi].source.url")
			sha=$(cl_yq_or ".versions[$vi].source.sha256" "")
			channel=$(cl_yq_or ".versions[$vi].channel" "")
			[ -n "$channel" ] || channel=$(channel_of_line "$line")
			tag="$version-r$CL_REVISION"
			cl_log "building $name${variant:+-$variant} $tag for $CL_PLATFORM (base $base_ref)"

			set -- -f "$dockerfile" --platform "$CL_PLATFORM" --provenance=false --sbom=false \
				--build-arg "UPSTREAM_VERSION=$version" \
				--build-arg "UPSTREAM_SHA256=$sha" \
				--build-arg "UPSTREAM_URL=$url" \
				--build-arg "VERSION_LINE=$line" \
				--build-arg "CHANNEL=$channel" \
				--build-arg "IMAGE_REVISION=$CL_REVISION" \
				--build-arg "VCS_REF=$vcs_ref" \
				--build-arg "CREATED=$created" \
				--build-arg "SOURCE_REPOSITORY=$repo_url" \
				--build-arg "SOURCE_DATE_EPOCH=$epoch" \
				--build-arg "BASE_IMAGE=$base_ref" \
				--build-arg "BASE_NAME=$base_name" \
				--build-arg "BASE_DIGEST=$base_digest"
			meta="$CL_OUT/build-$(cl_slug "$name-$variant-$line-$arch").json"
			if [ -n "${CL_PUSH:-}" ]; then
				cl_require jq
				repo=$(push_repo "$i")
				cl_docker_build "$@" --metadata-file "$meta" \
					--output "type=image,name=$repo,push-by-digest=true,name-canonical=true,push=true" \
					"$context"
				digest=$(yq -p json '.["containerimage.digest"]' "$meta")
				ref="$repo@$digest"
				jq -n --arg image "$name" --arg variant "$variant" --arg version "$version" --arg line "$line" \
					--arg channel "$channel" --arg platform "$CL_PLATFORM" --arg repository "$repo" --arg digest "$digest" \
					'$ARGS.named' > "$CL_OUT/digests/$(cl_slug "$name-$variant-$line-$arch").json"
			else
				repo=$(cl_image_repo "$i")
				ref="$repo:$tag"
				cl_docker_build "$@" --metadata-file "$meta" --load \
					-t "$ref" -t "$repo:$version" -t "$repo:$line" "$context"
				digest=$($CL_DOCKER image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" |
					grep "^$repo@" | head -n 1 | sed 's/.*@//')
				[ -n "$digest" ] || digest=$($CL_DOCKER image inspect --format '{{.Id}}' "$ref")
			fi
			printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$i" "$vi" "$name" "$variant" "$version" "$line" "$channel" "$ref" "$digest" >> "$images_file"
			cl_ok "$ref ($digest)"
		done
		i=$((i + 1))
	done
}

# merge: one index per image/version from $CL_OUT/digests/*.json, tagged
# <version>-r<rev>, <version>, <line>, <channel> and latest (stable channel).
merge_all() {
	cl_require jq
	dir="$CL_OUT/digests"
	[ -d "$dir" ] || cl_die "no $dir; run the per-platform builds first"
	out="$CL_OUT/release.txt"
	: > "$out"
	jq -r '[.image, .variant, .version, .line, .channel, .repository] | join("|")' "$dir"/*.json | sort -u |
		while IFS='|' read -r name variant version line channel repo; do
			refs=$(jq -r --arg n "$name" --arg v "$variant" --arg ver "$version" \
				'select(.image==$n and .variant==$v and .version==$ver) | "\(.repository)@\(.digest)"' "$dir"/*.json)
			set -- -t "$repo:$version-r$CL_REVISION" -t "$repo:$version" -t "$repo:$line"
			[ -n "$channel" ] && set -- "$@" -t "$repo:$channel"
			[ "$channel" = "stable" ] && set -- "$@" -t "$repo:latest"
			# shellcheck disable=SC2086 # refs is a list of name@digest
			$CL_DOCKER buildx imagetools create "$@" $refs
			index=$($CL_DOCKER buildx imagetools inspect "$repo:$version-r$CL_REVISION" --format '{{json .Manifest}}' | jq -r .digest)
			printf '%s|%s|%s|%s|%s|%s|%s\n' "$name" "$variant" "$version" "$line" "$channel" "$repo" "$index" >> "$out"
			cl_ok "$repo:$version-r$CL_REVISION -> $index"
		done
}

case "$mode" in
build) build_all ;;
merge) merge_all ;;
*) cl_die "usage: build.sh [build|merge]" ;;
esac
