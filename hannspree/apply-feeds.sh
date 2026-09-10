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

apply_patch_once "$TOPDIR/feeds/morse" "$TOPDIR/hannspree/feeds/morse-feed.patch"
apply_patch_once "$TOPDIR/feeds/packages" "$TOPDIR/hannspree/feeds/packages-feed.patch"

collectd_patch="$TOPDIR/feeds/packages/utils/collectd/patches/951-APP-4789-iwinfo-Use-IWINFO_ASSOCLIST_BUFSIZE-for-buf.patch"
if [ ! -f "$collectd_patch" ]; then
	cp "$TOPDIR/hannspree/feeds/collectd-951.patch" "$collectd_patch"
fi

echo "Hannspree feed changes applied."
