#!/bin/sh
# Assemble the CommonLayer base root filesystem in /rootfs.
#
# Runs in the Alpine build stage (pinned by digest). Installs a minimal package
# set into an empty root with `apk --root --initdb` (packages are verified by
# apk against the Alpine signing keys of the build stage), never installs
# apk-tools into that root, replaces BusyBox with the reduced rebuild, and lays
# out users, directories, licenses and cl-probe.
#
# Inputs: /in/busybox, /in/LICENSE.busybox, /in/cl-probe, /src/rootfs (overlay),
# /src/licenses (SPDX reference texts); env BUSYBOX_VERSION, BUSYBOX_PKGREL,
# BASE_PACKAGES, SOURCE_DATE_EPOCH.
set -eu

: "${BUSYBOX_VERSION:?}" "${BUSYBOX_PKGREL:?}" "${BASE_PACKAGES:?}"
R=/rootfs
db="$R/lib/apk/db/installed"

mkdir -p "$R"
# shellcheck disable=SC2086 # BASE_PACKAGES is a word list
apk add --root "$R" --initdb --no-cache --no-scripts \
	--keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories \
	$BASE_PACKAGES

# Nothing that manages packages may remain: apk-tools was never installed; drop
# its configuration and caches but keep the database for scanners.
rm -rf "$R/etc/apk" "$R/var/cache/apk" "$R/lib/apk/exec" "$R/usr/lib/apk/exec"
test -s "$db"
if grep -qE '^P:(apk-tools|libapk)$' "$db"; then
	echo "apk-tools must not be installed in the base root" >&2
	exit 1
fi

# The rebuilt BusyBox must match the database entry it replaces.
installed=$(awk '/^P:busybox$/{f=1;next} f && /^V:/{print substr($0,3); exit}' "$db")
if [ "$installed" != "${BUSYBOX_VERSION}-r${BUSYBOX_PKGREL}" ]; then
	echo "Alpine now ships busybox $installed but the rebuild is ${BUSYBOX_VERSION}-r${BUSYBOX_PKGREL}." >&2
	echo "Update APORTS_COMMIT, BUSYBOX_APKBUILD_SHA256 and BUSYBOX_PKGREL in image/Dockerfile." >&2
	exit 1
fi
install -m 0755 /in/busybox "$R/bin/busybox"
# Configuration files of applets that are not compiled in.
rm -rf "$R/etc/udhcpc" "$R/usr/share/udhcpc" "$R/etc/network" "$R/etc/logrotate.d" "$R/etc/securetty"
for path in $("$R/bin/busybox" --list-full); do
	[ -e "$R/$path" ] || [ -L "$R/$path" ] || {
		mkdir -p "$R/$(dirname "$path")"
		ln -s /bin/busybox "$R/$path"
	}
done

# Users, groups and the standard layout (CommonLayer image standard, "filesystem").
install -m 0644 /src/rootfs/etc/passwd /src/rootfs/etc/group "$R/etc/"
install -m 0640 /src/rootfs/etc/shadow "$R/etc/shadow"
install -d -m 0755 "$R/app" "$R/etc/commonlayer" "$R/usr/local/bin" "$R/usr/local/lib" \
	"$R/var/lib" "$R/var/log" "$R/run" "$R/root"
chmod 0700 "$R/root"
install -d -m 0775 -o 10001 -g 10001 "$R/var/lib/commonlayer" "$R/var/log/commonlayer" "$R/run/commonlayer"
install -d -m 0750 -o 10001 -g 10001 "$R/home/commonlayer"
install -d -m 1777 "$R/tmp" "$R/var/tmp"
install -m 0755 /in/cl-probe "$R/usr/local/bin/cl-probe"
install -D -m 0644 /src/rootfs/usr/local/lib/commonlayer/entrypoint-lib.sh "$R/usr/local/lib/commonlayer/entrypoint-lib.sh"
# OpenVEX statements about the base packages; scripts/scan.sh of derived images
# applies every document in this directory.
install -D -m 0644 /src/vex/base.openvex.json "$R/usr/share/commonlayer/vex/base.openvex.json"
# SBOM declaration of cl-probe (source-built, invisible to SBOM tools);
# scripts/generate-sbom.sh adds every document in this directory to the SBOMs
# of this image and of every image built on it. The declared version must be
# the one the binary reports.
probe_version=$(/in/cl-probe --version | sed -n 's/^cl-probe //p')
declared=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' /src/sbom/cl-probe.json)
if [ -z "$probe_version" ] || [ "$probe_version" != "$declared" ]; then
	echo "sbom/cl-probe.json declares version '$declared' but cl-probe reports '$probe_version'" >&2
	exit 1
fi
install -D -m 0644 /src/sbom/cl-probe.json "$R/usr/share/commonlayer/sbom/cl-probe.json"

# Licenses: the BusyBox source's own LICENSE, the SPDX expression of every
# installed package and SPDX reference texts for those expressions.
lic="$R/usr/share/licenses"
install -d "$lic/spdx" "$lic/cl-probe"
install -m 0644 /src/licenses/*.txt "$lic/spdx/"
install -D -m 0644 /in/LICENSE.busybox "$lic/busybox/LICENSE"
install -m 0644 /src/licenses/Apache-2.0.txt "$lic/cl-probe/LICENSE"
awk '/^P:/{p=substr($0,3)} /^L:/{print p "\t" substr($0,3)}' "$db" | while IFS="$(printf '\t')" read -r pkg expr; do
	install -d "$lic/$pkg"
	printf '%s\n' "$expr" > "$lic/$pkg/LICENSE-EXPRESSION"
	for id in $(printf '%s\n' "$expr" | tr '()' '  '); do
		case "$id" in AND | OR | WITH) continue ;; esac
		[ -f "$lic/spdx/$id.txt" ] || echo "warning: no SPDX reference text for $id ($pkg)" >&2
	done
done

# No setuid/setgid files may exist.
if [ -n "$(find "$R" -xdev -perm /6000 -type f)" ]; then
	find "$R" -xdev -perm /6000 -type f >&2
	echo "setuid/setgid files found" >&2
	exit 1
fi

# Best-effort reproducibility: normalise timestamps.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	find "$R" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
fi
echo "base rootfs: $(awk '/^P:/' "$db" | wc -l) packages, $(du -sk "$R" | cut -f1) KiB"
