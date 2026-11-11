#!/bin/sh
# test.sh - test every image recorded by build.sh against the image standard,
# then run the project's own tests (tests/*.sh).
#
# Generic assertions (each skipped only when commonlayer.yaml records a
# deviation for that rule id):
#   non-root          image user is images[].user (default 10001:10001) and the
#                     running process has that UID
#   labels            required OCI and org.commonlayer.* labels, consistent values
#   multi-stage       no package manager, compiler, curl/wget/nc or similar in the
#                     filesystem or as BusyBox applets; apk database present
#   non-root          no setuid/setgid files
#   entrypoint        ENTRYPOINT is /usr/local/bin/commonlayer-entrypoint
#   healthcheck       HEALTHCHECK defined, container becomes healthy
#   read-only-rootfs  container runs with --read-only (writable: /tmp and
#                     images[].volumes as tmpfs), no "Read-only file system" errors
#   signals           `docker stop` ends the container with exit code 0 before the
#                     stop timeout
# Images that deviate from `healthcheck` (for example the base image) are run
# once with their default command, read-only, and must exit 0.
#
# Project tests: every tests/*.sh runs with these variables set:
#   CL_TEST_IMAGE, CL_TEST_VERSION, CL_TEST_LINE, CL_TEST_IMAGE_NAME,
#   CL_TEST_CONTAINER (service images; the running container),
#   CL_TEST_PORT_<port> (host address for each images[].ports entry, e.g. 127.0.0.1:49153)
# Runtime environment for the container (e.g. a required password) can be put in
# tests/run.env (docker --env-file format, test values only).
# shellcheck source=lib.sh
. "$(dirname -- "$0")/lib.sh"
cl_require docker yq jq

failures=0
fail() {
	cl_err "$*"
	failures=$((failures + 1))
}

forbidden='apk apt apt-get dpkg rpm yum dnf microdnf zypper pip pip3 npm gem curl wget nc ncat netcat socat telnet ssh scp sftp ftp tftp sudo gosu su-exec doas su gcc cc c++ g++ clang make ld gdb strace ltrace'
required_labels='org.opencontainers.image.title org.opencontainers.image.description org.opencontainers.image.version org.opencontainers.image.revision org.opencontainers.image.created org.opencontainers.image.source org.opencontainers.image.url org.opencontainers.image.documentation org.opencontainers.image.licenses org.opencontainers.image.vendor org.opencontainers.image.base.name org.opencontainers.image.base.digest org.commonlayer.project org.commonlayer.variant org.commonlayer.upstream.version org.commonlayer.revision org.commonlayer.standard'

containers=""
cleanup() {
	for c in $containers; do $CL_DOCKER rm -f "$c" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT INT TERM

test_labels() { # ref idx version variant
	labels=$($CL_DOCKER image inspect --format '{{json .Config.Labels}}' "$1")
	for l in $required_labels; do
		printf '%s' "$labels" | jq -e --arg k "$l" 'has($k)' >/dev/null || fail "$1: label $l missing"
	done
	lv() { printf '%s' "$labels" | jq -r --arg k "$1" '.[$k] // ""'; }
	[ "$(lv org.commonlayer.project)" = "$(cl_project_name)" ] || fail "$1: org.commonlayer.project is '$(lv org.commonlayer.project)'"
	[ "$(lv org.commonlayer.variant)" = "$4" ] || fail "$1: org.commonlayer.variant is '$(lv org.commonlayer.variant)', expected '$4'"
	[ "$(lv org.commonlayer.upstream.version)" = "$3" ] || fail "$1: org.commonlayer.upstream.version is '$(lv org.commonlayer.upstream.version)', expected $3"
	[ "$(lv org.opencontainers.image.version)" = "$3-r$CL_REVISION" ] || fail "$1: org.opencontainers.image.version is '$(lv org.opencontainers.image.version)'"
	[ "$(lv org.commonlayer.revision)" = "$CL_REVISION" ] || fail "$1: org.commonlayer.revision is '$(lv org.commonlayer.revision)'"
	lv org.opencontainers.image.base.digest | grep -Eq '^sha256:[a-f0-9]{64}$' || fail "$1: base.digest label is not a digest"
	[ "$(lv org.commonlayer.standard)" = "image-standard-v1" ] || fail "$1: org.commonlayer.standard is '$(lv org.commonlayer.standard)'"
}

test_filesystem() { # ref idx
	listing="$CL_OUT/test-fs-$(cl_slug "$1").txt"
	c=$($CL_DOCKER create "$1" /bin/true)
	containers="$containers $c"
	$CL_DOCKER export "$c" | tar -tvf - > "$listing"
	$CL_DOCKER rm -f "$c" >/dev/null
	for b in $forbidden; do
		if grep -Eq "[[:space:]](\./)?((usr/)?(local/)?s?bin)/$b( |$)" "$listing"; then
			fail "$1: forbidden binary present: $b"
		fi
	done
	if ! cl_has_deviation "$2" non-root; then
		if awk '{print $1}' "$listing" | grep -Eq '^.{3}[sS]|^.{6}[sS]'; then
			fail "$1: setuid/setgid files present: $(awk '$1 ~ /^.{3}[sS]|^.{6}[sS]/ {print $NF}' "$listing" | tr '\n' ' ')"
		fi
	fi
	grep -Eq '[[:space:]](\./)?lib/apk/db/installed$' "$listing" || fail "$1: apk database (lib/apk/db/installed) missing; scanners cannot identify packages"
	if grep -Eq '[[:space:]](\./)?bin/busybox$' "$listing"; then
		applets=$($CL_DOCKER run --rm --network none --entrypoint /bin/busybox "$1" --list)
		for b in $forbidden; do
			printf '%s\n' "$applets" | grep -qx "$b" && fail "$1: BusyBox applet present: $b"
		done
	fi
	return 0
}

run_project_tests() { # ref version line name
	[ -d "$CL_ROOT/tests" ] || return 0
	for t in "$CL_ROOT"/tests/*.sh; do
		[ -f "$t" ] || continue
		cl_log "project test $(basename "$t") on $1"
		if CL_TEST_IMAGE=$1 CL_TEST_VERSION=$2 CL_TEST_LINE=$3 CL_TEST_IMAGE_NAME=$4 sh "$t" </dev/null; then
			cl_ok "$(basename "$t")"
		else
			fail "$1: project test $(basename "$t") failed"
		fi
	done
}

test_service() { # ref idx version line name version-index
	ref=$1 idx=$2 t_version=$3 t_line=$4 t_name=$5 t_vi=$6
	uid=$(cl_yq_or ".images[$idx].user.uid" 10001)
	gid=$(cl_yq_or ".images[$idx].user.gid" 10001)
	health=$($CL_DOCKER image inspect --format '{{json .Config.Healthcheck}}' "$ref")
	if [ "$health" = "null" ] || [ -z "$health" ]; then
		fail "$ref: no HEALTHCHECK"
		return
	fi
	name="cl-test-$(cl_project_name)-$$-$idx-$t_vi"
	set -- -d --name "$name" --cap-drop ALL --security-opt no-new-privileges \
		--tmpfs "/tmp:rw,nosuid,nodev,mode=1777"
	if ! cl_has_deviation "$idx" read-only-rootfs; then
		set -- "$@" --read-only
	fi
	for v in $(yq ".images[$idx].volumes // [] | .[]" "$CL_MANIFEST"); do
		set -- "$@" --tmpfs "$v:rw,nosuid,nodev,uid=$uid,gid=$gid,mode=0750"
	done
	for p in $(yq ".images[$idx].ports // [] | .[]" "$CL_MANIFEST"); do
		set -- "$@" -p "127.0.0.1::$p"
	done
	[ -f "$CL_ROOT/tests/run.env" ] && set -- "$@" --env-file "$CL_ROOT/tests/run.env"
	$CL_DOCKER run "$@" "$ref" >/dev/null
	containers="$containers $name"

	timeout=${CL_TEST_TIMEOUT:-120}
	waited=0
	status=starting
	while [ "$waited" -lt "$timeout" ]; do
		state=$($CL_DOCKER inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")
		status=${state#* }
		[ "${state%% *}" = "running" ] || break
		[ "$status" = "healthy" ] && break
		sleep 1
		waited=$((waited + 1))
	done
	if [ "$status" != "healthy" ]; then
		fail "$ref: container did not become healthy within ${timeout}s (state: $state)"
		$CL_DOCKER logs --tail 50 "$name" >&2 2>&1 || true
		return
	fi
	cl_ok "healthy after ${waited}s"

	proc_uid=$($CL_DOCKER exec "$name" cat /proc/1/status | awk '/^Uid:/{print $2}')
	[ "$proc_uid" = "$uid" ] || fail "$ref: PID 1 runs as UID $proc_uid, expected $uid"

	for p in $(yq ".images[$idx].ports // [] | .[]" "$CL_MANIFEST"); do
		# shellcheck disable=SC2034 # read through eval below
		hp=$($CL_DOCKER port "$name" "$p/tcp" | head -n 1)
		eval "CL_TEST_PORT_$p=\$hp"
		export "CL_TEST_PORT_$p"
	done
	CL_TEST_CONTAINER=$name
	export CL_TEST_CONTAINER
	run_project_tests "$ref" "$t_version" "$t_line" "$t_name"

	stop_timeout=$($CL_DOCKER image inspect --format '{{json .Config}}' "$ref" | jq -r '.StopTimeout // empty')
	stop_timeout=${CL_STOP_TIMEOUT:-${stop_timeout:-10}}
	start=$(date +%s)
	$CL_DOCKER stop -t "$stop_timeout" "$name" >/dev/null
	elapsed=$(($(date +%s) - start))
	code=$($CL_DOCKER inspect --format '{{.State.ExitCode}}' "$name")
	logs=$($CL_DOCKER logs "$name" 2>&1 || true)
	if ! cl_has_deviation "$idx" signals; then
		if [ "$code" != "0" ] || [ "$elapsed" -ge "$stop_timeout" ]; then
			fail "$ref: graceful stop failed (exit code $code after ${elapsed}s, timeout ${stop_timeout}s)"
		else
			cl_ok "stopped gracefully in ${elapsed}s"
		fi
	fi
	if printf '%s' "$logs" | grep -Eqi 'read-only file system|permission denied'; then
		fail "$ref: container log reports a read-only or permission error"
		printf '%s\n' "$logs" | grep -Ei 'read-only file system|permission denied' | head -n 5 >&2
	fi
	unset CL_TEST_CONTAINER
	$CL_DOCKER rm -f "$name" >/dev/null 2>&1 || true
}

test_oneshot() { # ref idx version line name
	if cl_has_deviation "$2" read-only-rootfs; then ro=""; else ro="--read-only"; fi
	# shellcheck disable=SC2086 # ro is empty or one flag
	if $CL_DOCKER run --rm --network none --cap-drop ALL --security-opt no-new-privileges $ro \
		--tmpfs /tmp:rw,mode=1777 "$1" </dev/null >/dev/null; then
		cl_ok "default command exits 0 with a read-only root filesystem"
	else
		fail "$1: default command failed"
	fi
	uid=$(cl_yq_or ".images[$2].user.uid" 10001)
	proc_uid=$($CL_DOCKER run --rm --network none --entrypoint /bin/cat "$1" /proc/self/status 2>/dev/null | awk '/^Uid:/{print $2}')
	[ "$proc_uid" = "$uid" ] || fail "$1: runs as UID '$proc_uid', expected $uid"
	run_project_tests "$1" "$3" "$4" "$5"
}

cl_built_images > "$CL_OUT/test-images.txt"
while IFS='|' read -r idx vi name variant version line _channel ref _digest; do
	cl_log "testing $ref"
	uid=$(cl_yq_or ".images[$idx].user.uid" 10001)
	gid=$(cl_yq_or ".images[$idx].user.gid" 10001)
	if ! cl_has_deviation "$idx" non-root; then
		user=$($CL_DOCKER image inspect --format '{{.Config.User}}' "$ref")
		[ "$user" = "$uid:$gid" ] || fail "$ref: image user is '$user', expected $uid:$gid"
	fi
	cl_has_deviation "$idx" labels || test_labels "$ref" "$idx" "$version" "$variant"
	cl_has_deviation "$idx" multi-stage || test_filesystem "$ref" "$idx"
	if ! cl_has_deviation "$idx" entrypoint; then
		ep=$($CL_DOCKER image inspect --format '{{json .Config.Entrypoint}}' "$ref")
		[ "$ep" = '["/usr/local/bin/commonlayer-entrypoint"]' ] || fail "$ref: ENTRYPOINT is $ep"
	fi
	if cl_has_deviation "$idx" healthcheck; then
		test_oneshot "$ref" "$idx" "$version" "$line" "$name"
	else
		test_service "$ref" "$idx" "$version" "$line" "$name" "$vi"
	fi
done < "$CL_OUT/test-images.txt"

if [ "$failures" -gt 0 ]; then
	cl_die "$failures test failure(s)"
fi
cl_ok "all image tests passed ($(wc -l < "$CL_OUT/test-images.txt") image(s))"
