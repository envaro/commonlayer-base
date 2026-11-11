#!/bin/sh
# docker-build.sh - run `docker buildx build` with proxy and extra-CA support.
#
# Usage: docker-build.sh [any `docker buildx build` arguments...]
#
# Behaves exactly like `docker buildx build "$@"` when no proxy is configured.
# When a proxy is configured in the environment it additionally:
#   * passes HTTP_PROXY/HTTPS_PROXY/NO_PROXY (both spellings) as build arguments
#     (these are predefined build arguments: they are not stored in the image
#     history or configuration);
#   * adds --network=host when the proxy listens on a loopback address, because a
#     loopback proxy is otherwise unreachable from the build container.
# When a CA bundle is available it is passed as the optional build secret
# `extra_ca`. Dockerfiles mount it over the system bundle for network-using steps:
#   RUN --mount=type=secret,id=extra_ca,target=/etc/ssl/certs/ca-certificates.crt,required=false ...
# The file must be a complete bundle (system roots plus your proxy's CA), because
# it replaces the system bundle for the duration of that RUN step only.
#
# Environment:
#   CL_EXTRA_CA_FILE   CA bundle to pass as `extra_ca` (default: $SSL_CERT_FILE if
#                      set and readable; set to "none" to disable)
#   CL_BUILD_NETWORK   force a --network value (e.g. "host" or "default")
#   CL_DOCKER          docker CLI to use (default: docker)
#
# Shared by the CommonLayer platform repository (https://github.com/envaro/commonlayer)
# and every CommonLayer project, which carries it as scripts/docker-build.sh.
# The platform repository keeps the canonical copy; change it there.
set -eu

docker_cli=${CL_DOCKER:-docker}

set -- buildx build "$@"

proxy_seen=""
for var in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
	eval "val=\${$var:-}"
	if [ -n "$val" ]; then
		set -- "$@" --build-arg "$var=$val"
		case "$var" in
		NO_PROXY | no_proxy) ;;
		*) proxy_seen="$proxy_seen $val" ;;
		esac
	fi
done

network=${CL_BUILD_NETWORK:-}
if [ -z "$network" ] && [ -n "$proxy_seen" ]; then
	for p in $proxy_seen; do
		hostport=${p#*://}
		hostport=${hostport#*@}
		case "$hostport" in
		127.* | localhost* | "[::1]"*) network=host ;;
		esac
	done
fi
if [ -n "$network" ] && [ "$network" != "default" ]; then
	set -- "$@" --network="$network"
fi

ca=${CL_EXTRA_CA_FILE:-${SSL_CERT_FILE:-}}
if [ -n "$ca" ] && [ "$ca" != "none" ]; then
	if [ -r "$ca" ]; then
		set -- "$@" --secret "id=extra_ca,src=$ca"
	else
		echo "docker-build.sh: CA bundle '$ca' is not readable; building without extra_ca" >&2
	fi
fi

exec "$docker_cli" "$@"
