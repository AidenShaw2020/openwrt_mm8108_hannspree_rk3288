#!/bin/sh
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

apply_patch_once() {
	repo=$1
	patch=$2
	if git -C "$repo" apply --reverse --check "$patch" 2>/dev/null; then
		echo "Already applied: $patch"
	elif git -C "$repo" apply --check "$patch"; then
		git -C "$repo" apply "$patch"
	else
		echo "Patch needs manual resolution on this feed version: $patch" >&2
		return 1
	fi
}

cd "$TOPDIR"
./scripts/feeds update -a
./scripts/feeds install -a

# Migrate the first Hannspree revision, which incorrectly used the ISO country
# CZ even though the certified MM8108 BCF exposes the regional code EU.
sed -i 's/MODPARAMS\.morse:=country=CZ/MODPARAMS.morse:=country=EU/' \
	"$TOPDIR/feeds/morse/essentials/morse_driver/Makefile"
sed -i 's/default_wifi_key=MM8108CZ/default_wifi_key=MM8108EU/' \
	"$TOPDIR/feeds/morse/hardware/morse-bundle/files/morse/scripts/morse-wireless-defaults"

apply_patch_once "$TOPDIR/feeds/morse" "$TOPDIR/hannspree/feeds/morse-feed.patch"
apply_patch_once "$TOPDIR/feeds/packages" "$TOPDIR/hannspree/feeds/packages-feed.patch"

collectd_patch="$TOPDIR/feeds/packages/utils/collectd/patches/951-APP-4789-iwinfo-Use-IWINFO_ASSOCLIST_BUFSIZE-for-buf.patch"
if [ ! -f "$collectd_patch" ]; then
	cp "$TOPDIR/hannspree/feeds/collectd-951.patch" "$collectd_patch"
fi

echo "Hannspree feed changes applied."
