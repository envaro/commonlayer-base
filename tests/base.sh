#!/bin/sh
# Base-image specific tests (run by scripts/test.sh with CL_TEST_IMAGE set).
set -eu
img=${CL_TEST_IMAGE:?}
docker=${CL_DOCKER:-docker}
fails=0
check() { # description, command...
	d=$1
	shift
	if "$@" >/dev/null 2>&1; then echo "  ok   $d"; else echo "  FAIL $d" >&2; fails=$((fails + 1)); fi
}
run() { $docker run --rm --network none --read-only --tmpfs /tmp "$img" "$@"; }

check "runs as commonlayer (10001:10001)" sh -c "[ \"\$($docker run --rm --network none '$img' id -u):\$($docker run --rm --network none '$img' id -g)\" = 10001:10001 ]"
check "user name resolves" sh -c "[ \"\$($docker run --rm --network none '$img' id -un)\" = commonlayer ]"
# shellcheck disable=SC2016 # evaluated inside the container
check "/bin/sh works" run /bin/sh -c 'test "$(echo ok)" = ok'
check "cl-probe present and reports its version" run cl-probe --version
check "cl-probe file mode" run cl-probe file /etc/passwd
check "cl-probe returns 1 for a missing file" sh -c "! $docker run --rm --network none '$img' cl-probe file /nope"
check "cl-probe returns 1 when nothing listens" sh -c "$docker run --rm --network none '$img' cl-probe -t 2 tcp 127.0.0.1 9; [ \$? -eq 1 ]"
check "cl-probe rejects https" sh -c "$docker run --rm --network none '$img' cl-probe http https://x/; [ \$? -eq 2 ]"
check "cl-probe SBOM declaration shipped with the binary's version" sh -c "v=\$($docker run --rm --network none '$img' cl-probe --version | sed 's/^cl-probe //'); $docker run --rm --network none '$img' grep -q \"\\\"version\\\": \\\"\$v\\\"\" /usr/share/commonlayer/sbom/cl-probe.json"
check "cl-probe is statically linked" sh -c "$docker run --rm --network none --entrypoint /bin/sh '$img' -c 'head -c 4 /usr/local/bin/cl-probe' | grep -q ELF"
for a in wget nc nslookup ping su mount vi telnet; do
	check "no '$a' applet" sh -c "! $docker run --rm --network none '$img' busybox $a --help"
	check "no '$a' on PATH" sh -c "! $docker run --rm --network none '$img' sh -c 'command -v $a'"
done
check "no apk binary" sh -c "! $docker run --rm --network none '$img' sh -c 'command -v apk || ls /sbin/apk'"
check "no apk configuration" sh -c "! $docker run --rm --network none '$img' ls /etc/apk"
check "apk database lists busybox" sh -c "$docker run --rm --network none '$img' grep -qx P:busybox /lib/apk/db/installed"
check "os-release identifies Alpine (for scanners)" sh -c "$docker run --rm --network none '$img' grep -q ^ID=alpine /etc/os-release"
check "CA bundle present" run test -s /etc/ssl/certs/ca-certificates.crt
check "tzdata present" run test -f /usr/share/zoneinfo/Europe/Berlin
check "standard directories owned by 10001" sh -c "[ \"\$($docker run --rm --network none '$img' stat -c '%u:%g' /var/lib/commonlayer /var/log/commonlayer /run/commonlayer | sort -u)\" = 10001:10001 ]"
check "/app owned by root and not writable by the user" sh -c "$docker run --rm --network none '$img' sh -c '[ \$(stat -c %u /app) = 0 ] && ! touch /app/x'"
check "/tmp is world-writable with sticky bit" sh -c "[ \"\$($docker run --rm --network none '$img' stat -c %a /tmp)\" = 1777 ]"
check "root filesystem read-only, /tmp writable" run sh -c '! touch /etc/x 2>/dev/null && touch /tmp/x'
check "BusyBox license text shipped" run test -s /usr/share/licenses/busybox/LICENSE
check "license expression recorded for musl" run grep -qx MIT /usr/share/licenses/musl/LICENSE-EXPRESSION
check "no setuid/setgid files" sh -c "[ -z \"\$($docker run --rm --network none '$img' find / -xdev -perm /6000 -type f)\" ]"

# Entrypoint helper library (/usr/local/lib/commonlayer/entrypoint-lib.sh).
lib='CL_APP=t; . /usr/local/lib/commonlayer/entrypoint-lib.sh;'
lrun() { $docker run --rm --network none --read-only --tmpfs /tmp "$@"; }
check "lib: cl_file_env reads VAR_FILE and unsets it" lrun -e T_PW_FILE=/tmp/pw "$img" sh -c "printf 's3cret\n' > /tmp/pw; $lib cl_file_env T_PW; [ \"\$T_PW\" = s3cret ] && [ -z \"\${T_PW_FILE:-}\" ]"
check "lib: cl_file_env keeps VAR" lrun -e T_PW=x "$img" sh -c "$lib cl_file_env T_PW; [ \"\$T_PW\" = x ]"
check "lib: cl_file_env applies the default" lrun "$img" sh -c "$lib cl_file_env T_PW dflt; [ \"\$T_PW\" = dflt ]"
check "lib: cl_file_env refuses VAR and VAR_FILE together" sh -c "! $docker run --rm --network none -e T_PW=a -e T_PW_FILE=/etc/passwd '$img' sh -c '$lib cl_file_env T_PW'"
check "lib: cl_file_env refuses an unreadable file" sh -c "! $docker run --rm --network none -e T_PW_FILE=/etc/shadow '$img' sh -c '$lib cl_file_env T_PW'"
check "lib: errors never print the secret" sh -c "! $docker run --rm --network none -e T_PW=topsecret -e T_PW_FILE=/etc/passwd '$img' sh -c '$lib cl_file_env T_PW' 2>&1 | grep -q topsecret"
check "lib: cl_check_value accepts a match" lrun -e T_N=8080 "$img" sh -c "$lib cl_check_value T_N '[0-9]{1,5}'"
check "lib: cl_check_value rejects a mismatch" sh -c "! $docker run --rm --network none -e 'T_N=80; x' '$img' sh -c \"$lib cl_check_value T_N '[0-9]{1,5}'\""
check "lib: cl_check_value accepts an empty value when the pattern allows it" lrun "$img" sh -c "$lib T_E=; cl_check_value T_E '[a-z]*'"
check "lib: cl_check_value rejects a value with a newline" sh -c "! $docker run --rm --network none -e 'T_N=1
2' '$img' sh -c \"$lib cl_check_value T_N '[0-9]*'\""
check "lib: cl_require_non_root passes as 10001" lrun "$img" sh -c "$lib cl_require_non_root"
check "lib: cl_require_non_root refuses root" sh -c "! $docker run --rm --network none --user 0:0 '$img' sh -c '$lib cl_require_non_root'"
check "lib: cl_render_template substitutes only allowlisted variables" lrun -e A=1 -e B=2 "$img" sh -c "printf 'a=\${A} b=\${B} h=\$host c=\${C}\n' > /tmp/t; $lib cl_render_template /tmp/t /tmp/o A C; [ \"\$(cat /tmp/o)\" = 'a=1 b=\${B} h=\$host c=' ]"

[ "$fails" -eq 0 ] || { echo "$fails base test(s) failed" >&2; exit 1; }
