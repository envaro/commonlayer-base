#!/bin/sh
# register.sh - submit released digests to CommonLayer and wait for the outcome.
#
# POST /api/v1/projects/{slug}/submissions for every image index in
# $CL_OUT/release.txt and every chart in $CL_OUT/chart-release.txt (06 section 3),
# then poll GET /api/v1/submissions/{id} until the submission is promoted
# (success) or rejected/failed (the failed checks are printed; exit 1).
#
# Authentication, in this order:
#   CL_API_TOKEN                  an API token with artifacts:submit
#   GitHub Actions OIDC           a token for audience $CL_OIDC_AUDIENCE (default
#                                 "commonlayer"); the job needs `id-token: write`
# Environment: CL_API_URL (default https://commonlayer.org/api/v1),
# CL_REGISTER_TIMEOUT seconds (default 1800).
# The same request with curl, for reference:
#   curl -fsS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#        --data @submission.json "$CL_API_URL/projects/<slug>/submissions"
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require curl jq yq
cl_require_release

api=${CL_API_URL:-https://commonlayer.org/api/v1}
timeout=${CL_REGISTER_TIMEOUT:-1800}
slug=$(cl_project_name)

token=${CL_API_TOKEN:-}
if [ -z "$token" ]; then
	if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
		token=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
			"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${CL_OIDC_AUDIENCE:-commonlayer}" | jq -r .value)
	fi
fi
[ -n "$token" ] && [ "$token" != "null" ] || cl_die "no credentials: set CL_API_TOKEN or run in GitHub Actions with id-token: write"

submit() { # json-file -> submission id
	resp="$CL_OUT/submission-response.json"
	code=$(curl -sS -o "$resp" -w '%{http_code}' -X POST \
		-H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
		--data @"$1" "$api/projects/$slug/submissions")
	case "$code" in
	200 | 201 | 202) jq -r '.id' "$resp" ;;
	*)
		cl_err "submission refused (HTTP $code)"
		cat "$resp" >&2
		return 1
		;;
	esac
}

wait_for() { # id
	start=$(date +%s)
	while :; do
		code=$(curl -sS -o "$CL_OUT/submission-$1.json" -w '%{http_code}' \
			-H "Authorization: Bearer $token" "$api/submissions/$1")
		[ "$code" = 200 ] || cl_die "reading submission $1 failed (HTTP $code)"
		state=$(jq -r '.state' "$CL_OUT/submission-$1.json")
		case "$state" in
		promoted)
			cl_ok "submission $1 promoted"
			return 0
			;;
		rejected | failed)
			cl_err "submission $1 $state: $(jq -r '.state_reason // ""' "$CL_OUT/submission-$1.json")"
			jq -r '(.checks // .verification.checks // [])[]? | select(.result == "fail") | "  failed check: \(.id): \(.message // "")"' \
				"$CL_OUT/submission-$1.json" >&2 || true
			return 1
			;;
		esac
		[ $(($(date +%s) - start)) -lt "$timeout" ] || cl_die "submission $1 still '$state' after ${timeout}s"
		sleep 15
	done
}

build_json() { # kind name variant version line channel repository digest -> file
	f="$CL_OUT/submission-$(cl_slug "$2-$3-$4-$1").json"
	registry=${7%%/*}
	repository=${7#*/}
	tags="\"$4-r$CL_REVISION\",\"$4\""
	[ -n "$5" ] && tags="$tags,\"$5\""
	[ -n "$6" ] && tags="$tags,\"$6\""
	jq -n --arg artifact "$2" --arg kind "$1" --arg variant "$3" --arg version "$4" \
		--argjson revision "$CL_REVISION" --arg line "$5" --arg registry "$registry" \
		--arg repository "$repository" --arg digest "$8" --argjson tags "[$tags]" \
		--arg run_id "${GITHUB_RUN_ID:-}" --arg run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
		--arg commit "$(cl_git_ref)" --arg ref "${GITHUB_REF:-}" --arg workflow_ref "${GITHUB_WORKFLOW_REF:-}" \
		'{artifact: $artifact, kind: $kind, variant: $variant, version: $version, revision: $revision,
		  version_line: $line, source: {registry: $registry, repository: $repository, digest: $digest},
		  tags: $tags,
		  build: {run_id: $run_id, run_attempt: ($run_attempt | tonumber), commit: $commit, ref: $ref, workflow_ref: $workflow_ref}}' > "$f"
	printf '%s\n' "$f"
}

ids=""
while IFS='|' read -r name variant version line channel repo digest; do
	f=$(build_json container_image "$name" "$variant" "$version" "$line" "$channel" "$repo" "$digest")
	id=$(submit "$f")
	cl_log "submitted $repo@$digest as $id"
	ids="$ids $id"
done < "$(cl_release_file)"
if [ -s "$CL_OUT/chart-release.txt" ]; then
	while IFS='|' read -r name version repo digest; do
		f=$(build_json helm_chart "$name" "" "$version" "" "" "$repo" "$digest")
		id=$(submit "$f")
		cl_log "submitted chart $repo@$digest as $id"
		ids="$ids $id"
	done < "$CL_OUT/chart-release.txt"
fi
for id in $ids; do wait_for "$id"; done
cl_ok "all submissions promoted"
