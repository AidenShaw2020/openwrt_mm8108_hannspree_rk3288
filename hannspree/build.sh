#!/bin/bash
set -euo pipefail

TOPDIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TOPDIR"

command -v debugfs >/dev/null
test -x staging_dir/host/bin/dtc || true
test -x staging_dir/host/bin/mkimage || true

cp hannspree/config/mm8108.diffconfig .config
make defconfig
grep -qx 'CONFIG_PACKAGE_kmod-morse=y' .config
grep -qx 'CONFIG_PACKAGE_luci-app-ekhwizards=y' .config
grep -qx 'CONFIG_PACKAGE_morse-bcf-info=y' .config
! grep -qx 'CONFIG_PACKAGE_morse-firmware-sign=y' .config
grep -Eq '^[[:space:]]*MODPARAMS\.morse:=country=EU$' \
	feeds/morse/essentials/morse_driver/Makefile
grep -qx 'EU' files/etc/morse-persistent-vars/mm_region
if [ "${SKIP_COMPILE:-0}" != 1 ]; then
	make target/linux/clean
	make -j"$(nproc)"
fi

mapfile -t configs < <(find build_dir/target-* -path '*/linux-armsr_armv7/linux-*/.config' -print)
test "${#configs[@]}" -eq 1
KDIR=${configs[0]%/.config}
grep -qx 'CONFIG_USB_DWC2=y' "$KDIR/.config"
grep -qx 'CONFIG_USB_DWC2_DUAL_ROLE=y' "$KDIR/.config"
grep -qx '# CONFIG_USB_DWC2_HOST is not set' "$KDIR/.config"
grep -A4 'Bus speed (slot' "$KDIR/drivers/mmc/host/dw_mmc.c" | grep -q dev_dbg || \
	grep -B2 'Bus speed (slot' "$KDIR/drivers/mmc/host/dw_mmc.c" | grep -q dev_dbg

DTC=${DTC:-$TOPDIR/staging_dir/host/bin/dtc}
[ -x "$DTC" ] || DTC=$(command -v dtc || true)
MKIMAGE=${MKIMAGE:-$TOPDIR/staging_dir/host/bin/mkimage}
[ -x "$MKIMAGE" ] || MKIMAGE=$(command -v mkimage || true)
FWTOOL=${FWTOOL:-$TOPDIR/staging_dir/host/bin/fwtool}
[ -x "$FWTOOL" ] || FWTOOL=$(command -v fwtool || true)
FDTGET=${FDTGET:-$(command -v fdtget || true)}
READELF=${READELF:-$(command -v readelf || true)}
test -n "$DTC"
test -x "$DTC"
test -n "$MKIMAGE"
test -x "$MKIMAGE"
test -n "$FWTOOL"
test -x "$FWTOOL"
test -n "$FDTGET"
test -x "$FDTGET"
test -n "$READELF"
test -x "$READELF"

TARGET="$TOPDIR/bin/targets/armsr/armv7"
STAGE="$TARGET/hannspree-mm8108"
mkdir -p "$STAGE"

mapfile -t initramfs < <(find "$TARGET" -maxdepth 1 -name '*-generic-initramfs-kernel.bin')
test "${#initramfs[@]}" -eq 1
BASE=${initramfs[0]%-initramfs-kernel.bin}

cp "$BASE-initramfs-kernel.bin" "$STAGE/openwrt-hannspree-rk3288-mm8108-initramfs-kernel.bin"
cp "$BASE-kernel.bin" "$STAGE/openwrt-hannspree-rk3288-mm8108-kernel.bin"
gzip -dc "$BASE-ext4-rootfs.img.gz" > "$STAGE/openwrt-hannspree-rk3288-mm8108-rootfs.ext4"
"$DTC" -q -I dts -O dtb -o "$STAGE/rk3288-firefly-reload.dtb" hannspree/board/rk3288-firefly-reload-hannspree.dts
"$MKIMAGE" -A arm -O linux -T script -C none -n 'Hannspree verified installer' -d hannspree/boot/boot-install.cmd "$STAGE/boot.scr"
"$MKIMAGE" -A arm -O linux -T script -C none -n 'Hannspree eMMC boot' -d hannspree/boot/boot-emmc.cmd "$STAGE/boot-emmc.scr"

SYSUPGRADE_NAME=openwrt-hannspree-rk3288-mm8108-sysupgrade.tar
SYSUPGRADE_DIR="$STAGE/sysupgrade-hannspree-rk3288"
HANNSPREE_VERSION=${HANNSPREE_VERSION:-$(git rev-parse --short=12 HEAD)}
rm -rf "$SYSUPGRADE_DIR"
mkdir -p "$SYSUPGRADE_DIR"
cp "$STAGE/openwrt-hannspree-rk3288-mm8108-kernel.bin" "$SYSUPGRADE_DIR/kernel"
cp "$STAGE/openwrt-hannspree-rk3288-mm8108-rootfs.ext4" "$SYSUPGRADE_DIR/root"
cp "$STAGE/rk3288-firefly-reload.dtb" "$SYSUPGRADE_DIR/dtb"
cp "$STAGE/boot-emmc.scr" "$SYSUPGRADE_DIR/boot.scr"
cat > "$SYSUPGRADE_DIR/CONTROL" <<EOF
FORMAT=1
BOARD=firefly,firefly-rk3288-reload
VERSION=$HANNSPREE_VERSION
ROOT_SIZE=$(wc -c < "$SYSUPGRADE_DIR/root")
KERNEL_SHA256=$(sha256sum "$SYSUPGRADE_DIR/kernel" | awk '{print $1}')
ROOT_SHA256=$(sha256sum "$SYSUPGRADE_DIR/root" | awk '{print $1}')
DTB_SHA256=$(sha256sum "$SYSUPGRADE_DIR/dtb" | awk '{print $1}')
BOOT_SCR_SHA256=$(sha256sum "$SYSUPGRADE_DIR/boot.scr" | awk '{print $1}')
EOF
tar -C "$STAGE" -cf "$STAGE/$SYSUPGRADE_NAME" \
	"sysupgrade-hannspree-rk3288/CONTROL" \
	"sysupgrade-hannspree-rk3288/kernel" \
	"sysupgrade-hannspree-rk3288/dtb" \
	"sysupgrade-hannspree-rk3288/boot.scr" \
	"sysupgrade-hannspree-rk3288/root"
cat > "$STAGE/sysupgrade-metadata.json" <<EOF
{
  "metadata_version": "1.1",
  "compat_version": "1.0",
  "supported_devices": ["firefly,firefly-rk3288-reload", "hannspree,s-x20"],
  "version": {
    "dist": "OpenWrt",
    "version": "24.10.5-morse-3.1.1",
    "revision": "$HANNSPREE_VERSION",
    "target": "armsr/armv7",
    "board": "hannspree-rk3288-mm8108"
  }
}
EOF
"$FWTOOL" -I "$STAGE/sysupgrade-metadata.json" "$STAGE/$SYSUPGRADE_NAME"
rm "$STAGE/sysupgrade-metadata.json"
for file in CONTROL kernel root dtb boot.scr; do
	tar tf "$STAGE/$SYSUPGRADE_NAME" "sysupgrade-hannspree-rk3288/$file" >/dev/null
done
cp target/linux/armsr/base-files/lib/upgrade/platform.sh "$STAGE/hannspree-platform.sh"
rm -rf "$SYSUPGRADE_DIR"

BOOTSTRAP_DIR="$STAGE/hannspree-sysupgrade-bootstrap"
rm -rf "$BOOTSTRAP_DIR"
mkdir -p "$BOOTSTRAP_DIR/etc/uci-defaults" "$BOOTSTRAP_DIR/lib/upgrade"
cp files/etc/uci-defaults/95_hannspree-stable-mac \
	"$BOOTSTRAP_DIR/etc/uci-defaults/95_hannspree-stable-mac"
cp files/etc/uci-defaults/97_hannspree-sysupgrade \
	"$BOOTSTRAP_DIR/etc/uci-defaults/97_hannspree-sysupgrade"
cp target/linux/armsr/base-files/lib/upgrade/platform.sh \
	"$BOOTSTRAP_DIR/lib/upgrade/platform.sh"
tar --owner=0 --group=0 --numeric-owner -C "$BOOTSTRAP_DIR" \
	-czf "$STAGE/hannspree-sysupgrade-bootstrap.tar.gz" \
	etc/uci-defaults/95_hannspree-stable-mac \
	etc/uci-defaults/97_hannspree-sysupgrade lib/upgrade/platform.sh
tar tzf "$STAGE/hannspree-sysupgrade-bootstrap.tar.gz" | \
	grep -qx 'etc/uci-defaults/95_hannspree-stable-mac'
tar tzf "$STAGE/hannspree-sysupgrade-bootstrap.tar.gz" | \
	grep -qx 'etc/uci-defaults/97_hannspree-sysupgrade'
tar tzf "$STAGE/hannspree-sysupgrade-bootstrap.tar.gz" | \
	grep -qx 'lib/upgrade/platform.sh'
rm -rf "$BOOTSTRAP_DIR"

test "$("$FDTGET" "$STAGE/rk3288-firefly-reload.dtb" /usb@ff540000 status)" = okay
"$FDTGET" -p "$STAGE/rk3288-firefly-reload.dtb" \
	/i2c@ff650000/act8846@5a/regulators/REG11 | grep -qx regulator-always-on

debugfs -R "dump /root/install-hannspree-emmc.sh $STAGE/installer.from-rootfs" \
	"$STAGE/openwrt-hannspree-rk3288-mm8108-rootfs.ext4"
cmp files/root/install-hannspree-emmc.sh "$STAGE/installer.from-rootfs"

ROOTFS="$STAGE/openwrt-hannspree-rk3288-mm8108-rootfs.ext4"
dump_rootfs_file() {
	local source=$1 destination=$2
	rm -f "$destination"
	debugfs -R "dump $source $destination" "$ROOTFS" >/dev/null 2>&1
	test -f "$destination"
}

dump_rootfs_file /etc/modules.d/morse "$STAGE/morse.modules.from-rootfs"
grep -Eq '(^|[[:space:]])country=EU($|[[:space:]])' "$STAGE/morse.modules.from-rootfs"

dump_rootfs_file /etc/morse-persistent-vars/mm_region "$STAGE/mm_region.from-rootfs"
grep -qx 'EU' "$STAGE/mm_region.from-rootfs"

dump_rootfs_file /etc/uci-defaults/97_hannspree-sysupgrade \
	"$STAGE/hannspree-sysupgrade-default.from-rootfs"
grep -q "enforce_fw_sign='0'" "$STAGE/hannspree-sysupgrade-default.from-rootfs"

dump_rootfs_file /etc/uci-defaults/95_hannspree-stable-mac \
	"$STAGE/hannspree-stable-mac.from-rootfs"
grep -q '/sys/class/block/mmcblk' "$STAGE/hannspree-stable-mac.from-rootfs"
grep -q "set network.hannspree_eth0.macaddr='\$mac'" \
	"$STAGE/hannspree-stable-mac.from-rootfs"
test "$(sh "$STAGE/hannspree-stable-mac.from-rootfs" --derive \
	15010038474d45345201e877feaf7457)" = 02:3c:98:b2:24:8b

dump_rootfs_file /usr/share/luci/menu.d/luci-app-ekhwizards.json \
	"$STAGE/ekhwizards-menu.from-rootfs"
grep -q '"admin/selectwizard"' "$STAGE/ekhwizards-menu.from-rootfs"

dump_rootfs_file /lib/firmware/morse/bcf_mf15457.bin "$STAGE/bcf_mf15457.from-rootfs"
"$READELF" -SW "$STAGE/bcf_mf15457.from-rootfs" | grep -q '\.regdom_EU'

dump_rootfs_file /lib/upgrade/platform.sh "$STAGE/platform.sh.from-rootfs"
cmp target/linux/armsr/base-files/lib/upgrade/platform.sh \
	"$STAGE/platform.sh.from-rootfs"

rm "$STAGE/installer.from-rootfs" \
	"$STAGE/morse.modules.from-rootfs" \
	"$STAGE/mm_region.from-rootfs" \
	"$STAGE/hannspree-sysupgrade-default.from-rootfs" \
	"$STAGE/hannspree-stable-mac.from-rootfs" \
	"$STAGE/ekhwizards-menu.from-rootfs" \
	"$STAGE/bcf_mf15457.from-rootfs" \
	"$STAGE/platform.sh.from-rootfs"

cd "$STAGE"
sha256sum openwrt-hannspree-rk3288-mm8108-*.bin \
	openwrt-hannspree-rk3288-mm8108-rootfs.ext4 \
	"$SYSUPGRADE_NAME" hannspree-platform.sh hannspree-sysupgrade-bootstrap.tar.gz \
	rk3288-firefly-reload.dtb boot.scr boot-emmc.scr > SHA256SUMS
sha256sum -c SHA256SUMS
: > INSTALL_TO_EMMC
echo "BUILD_VERIFIED=$STAGE"
