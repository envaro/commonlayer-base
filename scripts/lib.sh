# shellcheck shell=sh
# lib.sh - shared helpers for CommonLayer project scripts.
#
# Sourced by the other scripts in this directory. Byte-identical in the project
# template and every CommonLayer project (the template's drift check verifies this).
# Do not edit a project's copy: change the template and copy it everywhere.
#
# Conventions
#   * The project root is the parent of this scripts/ directory.
#   * commonlayer.yaml is the source of truth; nothing here hardcodes a project.
#   * Build outputs go to $CL_OUT (default: <project>/.build).
#   * Locally built images are named $CL_IMAGE_PREFIX/<image>[-<variant>]:<version>-r<revision>
#     (default prefix localhost/commonlayer, default revision 0 = unreleased).
#   * Bind mounts (SELinux): every bind mount of a host path into a container,
#     in scripts and in tests/, carries the relabel option z
#     (-v "$work/conf:/etc/app/conf:ro,z"), or a host with SELinux enforcing
#     refuses the container access ("permission denied", even as root). Mount the
#     specific file or a directory the script created (mktemp -d), never $HOME, /,
#     /tmp itself or the project root. Named volumes and --tmpfs need nothing.
#     Docker's --mount (bind) cannot relabel: use -v. The CommonLayer platform
#     repository checks its first-party trees for this (check-project-trees.py).

set -eu

CL_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CL_ROOT=$(dirname -- "$CL_SCRIPTS")
CL_MANIFEST=${CL_MANIFEST:-$CL_ROOT/commonlayer.yaml}
CL_OUT=${CL_OUT:-$CL_ROOT/.build}
CL_IMAGE_PREFIX=${CL_IMAGE_PREFIX:-localhost/commonlayer}
CL_REVISION=${CL_REVISION:-0}
CL_PLATFORM=${CL_PLATFORM:-linux/$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')}
CL_DOCKER=${CL_DOCKER:-docker}
export CL_DOCKER

# Tools installed by install-tools.sh live here by default.
case ":$PATH:" in
*":${CL_TOOLS_BIN:-$HOME/.local/bin}:"*) ;;
*) PATH="${CL_TOOLS_BIN:-$HOME/.local/bin}:$PATH" ;;
esac
export PATH

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
	cl__b=$(printf '\033[1m') cl__r=$(printf '\033[31m') cl__y=$(printf '\033[33m') cl__g=$(printf '\033[32m') cl__0=$(printf '\033[0m')
else
	cl__b='' cl__r='' cl__y='' cl__g='' cl__0=''
fi

cl_log() { printf '%s==>%s %s\n' "$cl__b" "$cl__0" "$*" >&2; }
cl_ok() { printf '%s ok%s %s\n' "$cl__g" "$cl__0" "$*" >&2; }
cl_warn() { printf '%swarning:%s %s\n' "$cl__y" "$cl__0" "$*" >&2; }
cl_err() { printf '%serror:%s %s\n' "$cl__r" "$cl__0" "$*" >&2; }
cl_die() {
	cl_err "$*"
	exit 1
}

# cl_require <tool>... : fail with an installation hint when a tool is missing.
cl_require() {
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 ||
			cl_die "$t is required; install the pinned tool set with scripts/install-tools.sh"
	done
}

# cl_yq <expression> : evaluate a yq expression against the manifest.
cl_yq() {
	yq -e "$1" "$CL_MANIFEST" 2>/dev/null
}

# cl_yq_or <expression> <default>
cl_yq_or() {
	v=$(yq "$1 // \"\"" "$CL_MANIFEST")
	if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s\n' "$2"; else printf '%s\n' "$v"; fi
}

cl_project_name() { cl_yq '.metadata.name'; }

# cl_source_repo : registry.source, or $CL_SOURCE_REPOSITORY (forks, local release
# rehearsals against a throwaway registry).
cl_source_repo() { printf '%s\n' "${CL_SOURCE_REPOSITORY:-$(cl_yq '.registry.source')}"; }

# cl_schema_path : the manifest schema: $CL_SCHEMA when set, else the project's
# copy schemas/commonlayer-v1.schema.json. Nothing outside the project is searched.
cl_schema_path() {
	if [ -n "${CL_SCHEMA:-}" ]; then
		printf '%s\n' "$CL_SCHEMA"
		return 0
	fi
	[ -f "$CL_ROOT/schemas/commonlayer-v1.schema.json" ] || return 1
	printf '%s\n' "$CL_ROOT/schemas/commonlayer-v1.schema.json"
}

# cl_image_repo <image-index> : local repository name of an image entry.
cl_image_repo() {
	n=$(cl_yq ".images[$1].name")
	v=$(cl_yq_or ".images[$1].variant" "")
	if [ -n "$v" ]; then printf '%s/%s-%s\n' "$CL_IMAGE_PREFIX" "$n" "$v"; else printf '%s/%s\n' "$CL_IMAGE_PREFIX" "$n"; fi
}

cl_image_count() { yq '.images // [] | length' "$CL_MANIFEST"; }
cl_version_count() { yq '.versions | length' "$CL_MANIFEST"; }
cl_chart_count() { yq '.charts // [] | length' "$CL_MANIFEST"; }

# cl_selected_versions : indexes of versions[] to build. Lines with status eol are
# skipped; CL_VERSIONS="1.30 1.31" restricts to those lines.
cl_selected_versions() {
	n=$(cl_version_count)
	i=0
	while [ "$i" -lt "$n" ]; do
		line=$(cl_yq ".versions[$i].line")
		status=$(cl_yq ".versions[$i].status")
		if [ "$status" != "eol" ]; then
			if [ -z "${CL_VERSIONS:-}" ]; then
				echo "$i"
			else
				for want in $CL_VERSIONS; do [ "$want" = "$line" ] && echo "$i"; done
			fi
		fi
		i=$((i + 1))
	done
}

# cl_has_deviation <image-index> <standard-id> : true when the manifest records
# a deviation from that image-standard rule (tests for it are then skipped).
cl_has_deviation() {
	[ "$(yq "[.images[$1].deviations // [] | .[] | select(.standard == \"$2\")] | length" "$CL_MANIFEST")" -gt 0 ]
}

# Build records: one line per built image in $CL_OUT/images.txt, fields separated
# by '|' (empty fields stay in place, unlike with whitespace IFS):
# image-index|version-index|name|variant|version|line|channel|ref|digest
cl_images_file() { printf '%s\n' "$CL_OUT/images.txt"; }

cl_require_built() {
	f=$(cl_images_file)
	[ -s "$f" ] || cl_die "no built images recorded in $f; run 'make build' first"
}

# cl_built_images : print the build records (tab separated).
cl_built_images() {
	cl_require_built
	cat "$(cl_images_file)"
}

# cl_docker_build [args...] : docker buildx build with proxy/CA support.
cl_docker_build() {
	sh "$CL_SCRIPTS/docker-build.sh" "$@"
}

# cl_git_ref : commit of the working tree (or "unknown").
cl_git_ref() {
	if [ -n "${GITHUB_SHA:-}" ]; then
		printf '%s\n' "$GITHUB_SHA"
	else
		git -C "$CL_ROOT" rev-parse HEAD 2>/dev/null || echo unknown
	fi
}

# cl_source_date_epoch : SOURCE_DATE_EPOCH from the environment, else the last
# commit time, else 0.
cl_source_date_epoch() {
	if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
		printf '%s\n' "$SOURCE_DATE_EPOCH"
	else
		git -C "$CL_ROOT" log -1 --format=%ct 2>/dev/null || echo 0
	fi
}

# cl_repo_url : URL of the source repository for labels.
cl_repo_url() {
	if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
		printf '%s/%s\n' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY"
	else
		url=$(git -C "$CL_ROOT" config --get remote.origin.url 2>/dev/null || true)
		case "$url" in
		git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
		esac
		url=${url%.git}
		printf '%s\n' "${url:-unknown}"
	fi
}

# cl_slug <string> : filesystem-safe name.
cl_slug() { printf '%s\n' "$1" | tr '/:@' '___'; }

# cl_gate_severities <gate> : severities at or above the gate, upper case.
cl_gate_severities() {
	case "$1" in
	critical) echo "CRITICAL" ;;
	high) echo "CRITICAL HIGH" ;;
	medium) echo "CRITICAL HIGH MEDIUM" ;;
	low) echo "CRITICAL HIGH MEDIUM LOW" ;;
	*) cl_die "unknown gate severity: $1" ;;
	esac
}

# cl_charts_dirs : chart directories (absolute), one per line.
cl_chart_dirs() {
	n=$(cl_chart_count)
	i=0
	while [ "$i" -lt "$n" ]; do
		printf '%s/%s\n' "$CL_ROOT" "$(cl_yq ".charts[$i].path")"
		i=$((i + 1))
	done
}

# Release records written by `build.sh merge` in $CL_OUT/release.txt:
# name|variant|version|line|channel|repository|index-digest
cl_release_file() { printf '%s\n' "$CL_OUT/release.txt"; }
cl_require_release() {
	[ -s "$(cl_release_file)" ] || cl_die "no $(cl_release_file); run 'scripts/build.sh merge' first (CI)"
}

# cl_platform_digests <repository@index-digest> : platform manifest digests of an index.
cl_platform_digests() {
	$CL_DOCKER buildx imagetools inspect --raw "$1" |
		jq -r '.manifests[]? | select(.platform.os == "linux" and (.annotations["vnd.docker.reference.type"] // "") == "") | "\(.platform.os)/\(.platform.architecture) \(.digest)"'
}

# cl_identity_regexp : the manifest's keyless signing identity as an anchored
# regular expression ('*' matches any sequence of characters).
cl_identity_regexp() {
	cl_yq '.security.signing.keyless.identity' | sed -e 's/[].[^$\\+?(){}|]/\\&/g' -e 's/\*/.*/g' -e 's/^/^/' -e 's/$/$/'
}

mkdir -p "$CL_OUT"
