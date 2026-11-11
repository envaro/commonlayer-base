#!/bin/sh
# Rebuild Alpine's BusyBox package from its own source with a reduced applet set.
#
# Inputs are pinned: the aports commit, the SHA-256 of the APKBUILD at that
# commit, and (through the APKBUILD's sha512sums) the upstream tarball and every
# Alpine patch. The resulting binary has the same upstream version and the same
# Alpine patches as the busybox package recorded in the image's apk database, so
# scanners matching that database entry see the correct version; it differs only
# in the applets compiled in (config-deny.txt).
#
# Runs inside the Alpine build stage. Writes /out/busybox.
set -eu

: "${APORTS_COMMIT:?}" "${BUSYBOX_APKBUILD_SHA256:?}" "${BUSYBOX_VERSION:?}" "${BUSYBOX_PKGREL:?}"
here=$(cd "$(dirname "$0")" && pwd)
work=/work/busybox
out=/out
mkdir -p "$work" "$out"
cd "$work"

raw="https://raw.githubusercontent.com/alpinelinux/aports/${APORTS_COMMIT}/main/busybox"
fetch() { curl -fsSL --retry 4 --retry-all-errors --proto '=https' -o "$1" "$2"; }

fetch APKBUILD "$raw/APKBUILD"
echo "${BUSYBOX_APKBUILD_SHA256}  APKBUILD" | sha256sum -c -
grep -qx "pkgver=${BUSYBOX_VERSION}" APKBUILD || { echo "APKBUILD pkgver is not ${BUSYBOX_VERSION}" >&2; exit 1; }
grep -qx "pkgrel=${BUSYBOX_PKGREL}" APKBUILD || { echo "APKBUILD pkgrel is not ${BUSYBOX_PKGREL}" >&2; exit 1; }

# The sha512sums block lists sources in the order abuild applies them.
awk '/^sha512sums="/{f=1;next} f && /^"/{f=0} f && NF==2 {print}' APKBUILD > sha512sums
tarball="busybox-${BUSYBOX_VERSION}.tar.bz2"
grep -q "  ${tarball}\$" sha512sums
# Upstream first, then Alpine's distfiles mirror; the sha512 check below decides.
fetch "$tarball" "https://busybox.net/downloads/${tarball}" ||
	fetch "$tarball" "https://distfiles.alpinelinux.org/distfiles/v3.24/${tarball}"
awk '$2 ~ /\.patch$/ || $2 == "busyboxconfig" {print $2}' sha512sums | while read -r f; do
	fetch "$f" "$raw/$f"
done
awk -v t="$tarball" '$2 == t || $2 ~ /\.patch$/ || $2 == "busyboxconfig"' sha512sums > verify.sha512
sha512sum -c verify.sha512

tar -xjf "$tarball"
cd "busybox-${BUSYBOX_VERSION}"
chmod -R g-s .
awk '$2 ~ /\.patch$/ {print $2}' ../sha512sums | while read -r p; do
	patch -p1 -s -i "../$p"
done

cp ../busyboxconfig .config
grep -v '^#' "$here/config-deny.txt" | while read -r sym; do
	[ -n "$sym" ] || continue
	sed -i -e "s/^CONFIG_${sym}=.*/# CONFIG_${sym} is not set/" .config
done
yes '' | make oldconfig >/dev/null
grep -v '^#' "$here/config-deny.txt" | while read -r sym; do
	[ -n "$sym" ] || continue
	if grep -q "^CONFIG_${sym}=y" .config; then
		echo "CONFIG_${sym} is still enabled" >&2
		exit 1
	fi
done

make -j"$(nproc)" CONFIG_EXTRA_CFLAGS="-fstack-clash-protection -Wformat -Werror=format-security" >/dev/null

./busybox --list > ../applets
# shellcheck disable=SC2013 # the file is a whitespace-separated word list
for a in $(grep -v '^#' "$here/forbidden-applets.txt"); do
	if grep -qx "$a" ../applets; then
		echo "forbidden applet present: $a" >&2
		exit 1
	fi
done
# shellcheck disable=SC2016 # evaluated by the built shell
./busybox sh -c 'test "$(echo ok | sed s/o/0/)" = 0k'

install -m 0755 busybox "$out/busybox"
install -m 0644 LICENSE "$out/LICENSE.busybox"
echo "busybox ${BUSYBOX_VERSION}-r${BUSYBOX_PKGREL}: $(wc -l < ../applets) applets"
