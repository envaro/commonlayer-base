#!/bin/sh
# base-image.sh - the CommonLayer base image for scripts/build.sh, by digest,
# before commonlayer.yaml pins a released one.
#
#   scripts/base-image.sh                  print the reference to build from
#   scripts/base-image.sh --build <dir>    first run `make build` in <dir>, a
#                                          checkout of the base project's repository
#
#   BASE_IMAGE=$(scripts/base-image.sh --build ../base) make build
#
# What is printed, in this order:
#   1. $BASE_IMAGE when it is set (unchanged; build.sh checks it is a digest);
#   2. nothing when every images[].base.digest is set: build.sh uses the manifest;
#   3. otherwise the locally built base $CL_IMAGE_PREFIX/base:<images[].base.tag>
#      (built from <dir> with --build), pushed to a throwaway registry on the
#      loopback interface and printed as
#      127.0.0.1:<port>/commonlayer/base:<tag>@sha256:<digest>.
# Step 3 is for builds before the first base release, and for testing a base
# change together with a project (validate.yml does this when the repository
# variable CL_BASE_REPOSITORY names the base project's repository). Releases
# never use it: build.sh refuses a pushed build without images[].base.digest.
#
# Why a registry: the final stage starts FROM ${BASE_IMAGE} pinned by digest, and
# BuildKit's docker driver does not resolve a locally built image by
# name:tag@digest; it asks the registry named in the reference. A registry on
# 127.0.0.1 gives the base a registry digest BuildKit can resolve (Docker treats
# 127.0.0.0/8 as an insecure, plain-HTTP registry). It works with Docker's classic
# and containerd image stores.
#
# Environment: CL_BASE_REGISTRY_PORT (default 5099), DOCKERHUB_REGISTRY (mirror for
# the registry image, default docker.io), CL_IMAGE_PREFIX, CL_PLATFORM.
# Needs docker, yq and curl. The registry container (cl-base-registry) is left
# running for later builds; `docker rm -f cl-base-registry` removes it.
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require yq

build_dir=""
case "${1:-}" in
"") ;;
--build)
	build_dir=${2:-}
	[ -n "$build_dir" ] || cl_die "usage: base-image.sh [--build <base-project-checkout>]"
	;;
*) cl_die "usage: base-image.sh [--build <base-project-checkout>]" ;;
esac

if [ -n "${BASE_IMAGE:-}" ]; then
	printf '%s\n' "$BASE_IMAGE"
	exit 0
fi

# Tags of the images that have no released base digest.
tags=$(yq '[.images // [] | .[] | select(.base.digest == null or .base.digest == "") | .base.tag] | unique | .[]' "$CL_MANIFEST")
if [ -z "$tags" ]; then
	cl_log "every images[].base.digest is set; build.sh uses the manifest"
	exit 0
fi
[ "$(printf '%s\n' "$tags" | wc -l)" -eq 1 ] ||
	cl_die "images without base.digest name different base tags ($(echo "$tags" | tr '\n' ' ')); set BASE_IMAGE"
tag=$tags

cl_require docker curl
local_ref="$CL_IMAGE_PREFIX/base:$tag"

if [ -n "$build_dir" ]; then
	[ -f "$build_dir/commonlayer.yaml" ] && [ -f "$build_dir/Makefile" ] ||
		cl_die "$build_dir is not a checkout of a CommonLayer project (no commonlayer.yaml and Makefile)"
	cl_log "building the base project in $build_dir"
	# The base project's own settings: none of this project's selection applies.
	(
		unset CL_VERSIONS CL_OUT CL_MANIFEST CL_REVISION CL_SCHEMA BASE_IMAGE
		cd "$build_dir" && make build
	) >&2 || cl_die "the base project in $build_dir did not build"
fi

$CL_DOCKER image inspect "$local_ref" >/dev/null 2>&1 ||
	cl_die "images[].base.digest is empty and $local_ref does not exist locally.
       Fill images[].base.digest with the digest of a base release, set
       BASE_IMAGE=<name:tag@sha256:...>, or build the base project:
       scripts/base-image.sh --build <checkout of the base project's repository>
       (in CI: set the repository variable CL_BASE_REPOSITORY to its owner/name)."

port=${CL_BASE_REGISTRY_PORT:-5099}
host="127.0.0.1:$port"
name=cl-base-registry
# registry 3.1.2 (distribution/distribution), pinned by digest.
registry_image="${DOCKERHUB_REGISTRY:-docker.io}/library/registry:3.1.2@sha256:38907510915c3f1604c7e83d6ab602ab3020d092f73bdaed8696773693ff768c"
repo_path=commonlayer/base
target="$host/$repo_path:$tag"

if [ -z "$($CL_DOCKER ps -q --filter "name=^${name}$")" ]; then
	$CL_DOCKER rm -f "$name" >/dev/null 2>&1 || true
	cl_log "starting a throwaway registry on $host"
	$CL_DOCKER run -d --name "$name" -p "$host:5000" "$registry_image" >/dev/null
fi
i=0
until curl -fs --noproxy '*' -o /dev/null "http://$host/v2/" 2>/dev/null; do
	i=$((i + 1))
	[ "$i" -lt 30 ] || {
		$CL_DOCKER logs "$name" >&2 || true
		cl_die "the registry on $host did not become ready"
	}
	sleep 1
done

$CL_DOCKER tag "$local_ref" "$target"
$CL_DOCKER push --quiet "$target" >&2

accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json'
accept="$accept, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
digest=$(curl -fsS --noproxy '*' -I -H "Accept: $accept" "http://$host/v2/$repo_path/manifests/$tag" |
	tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }')
printf '%s\n' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' ||
	cl_die "no valid digest for $target (got '$digest')"
cl_ok "$local_ref is available to builds as $target@$digest"
printf '%s@%s\n' "$target" "$digest"
