# shellcheck shell=sh
# CommonLayer entrypoint helpers, shipped in the base image at
# /usr/local/lib/commonlayer/entrypoint-lib.sh.
#
# Usage in an image's /usr/local/bin/commonlayer-entrypoint:
#
#   #!/bin/sh
#   set -eu
#   CL_APP=myapp
#   . /usr/local/lib/commonlayer/entrypoint-lib.sh
#   cl_require_non_root
#   cl_file_env MYAPP_PASSWORD
#   ...
#   exec myapp "$@"
#
# Functions never print the value of a variable they handle.
# SPDX-License-Identifier: Apache-2.0

: "${CL_APP:=app}"

cl_log() { printf '%s: %s\n' "$CL_APP" "$*" >&2; }
cl_warn() { printf '%s: warning: %s\n' "$CL_APP" "$*" >&2; }
cl_die() {
	printf '%s: error: %s\n' "$CL_APP" "$*" >&2
	exit 1
}

# cl_require_non_root: refuse to run as UID 0.
cl_require_non_root() {
	if [ "$(id -u)" = "0" ]; then
		cl_die "refusing to run as root; run as 10001:10001 (the image default)"
	fi
}

# cl_file_env VAR [default]
#   VAR_FILE set   -> VAR is read from that file (trailing newlines removed)
#   VAR set        -> kept
#   both set       -> error
#   neither        -> VAR=default when a default is given
# VAR_FILE is unset afterwards so that child processes do not see it.
cl_file_env() {
	cl__var=$1
	cl__fvar="${1}_FILE"
	case "$cl__var" in
	*[!A-Za-z0-9_]* | [0-9]*) cl_die "invalid variable name: $cl__var" ;;
	esac
	eval "cl__val=\${$cl__var:-}"
	eval "cl__file=\${$cl__fvar:-}"
	if [ -n "$cl__val" ] && [ -n "$cl__file" ]; then
		cl_die "both $cl__var and $cl__fvar are set; use one"
	fi
	if [ -n "$cl__file" ]; then
		[ -r "$cl__file" ] || cl_die "$cl__fvar points to an unreadable file: $cl__file"
		cl__val=$(cat -- "$cl__file")
	elif [ -z "$cl__val" ] && [ $# -ge 2 ]; then
		cl__val=$2
	fi
	export "$cl__var=$cl__val"
	unset "$cl__fvar" cl__val cl__file
}

# cl_check_value VAR REGEX : the value of VAR must fully match the extended
# regular expression (used before values reach configuration files).
cl_check_value() {
	eval "cl__val=\${$1:-}"
	if ! printf '%s\n' "$cl__val" | grep -Eqx -- "$2"; then
		cl_die "invalid value for $1 (must match: $2)"
	fi
	unset cl__val
	if [ "$(eval "printf '%s' \"\${$1:-}\"" | wc -l)" -gt 0 ]; then
		cl_die "invalid value for $1 (contains a newline)"
	fi
}

# cl_render_template SRC DST VAR...
#   Copies SRC to DST, replacing ${VAR} only for the listed variables (an
#   allowlist); every other "$" sequence is left untouched, so configuration
#   syntax such as nginx's $host survives. Unset listed variables render empty.
cl_render_template() {
	cl__src=$1
	cl__dst=$2
	shift 2
	for cl__v in "$@"; do
		case "$cl__v" in
		*[!A-Za-z0-9_]* | [0-9]* | '') cl_die "invalid variable name: $cl__v" ;;
		esac
	done
	CL__ALLOW="$*" awk '
		BEGIN { n = split(ENVIRON["CL__ALLOW"], names, " "); for (i = 1; i <= n; i++) allow[names[i]] = 1 }
		{
			out = ""; line = $0
			while ((p = index(line, "${")) > 0) {
				rest = substr(line, p + 2)
				q = index(rest, "}")
				name = q > 0 ? substr(rest, 1, q - 1) : ""
				if (q > 0 && (name in allow)) {
					out = out substr(line, 1, p - 1) ENVIRON[name]
					line = substr(rest, q + 1)
				} else {
					out = out substr(line, 1, p + 1)
					line = rest
				}
			}
			print out line
		}' "$cl__src" > "$cl__dst"
	unset cl__src cl__dst cl__v
}
