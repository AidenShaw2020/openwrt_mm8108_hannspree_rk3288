#!/bin/bash
set -euo pipefail

TOPDIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TOPDIR"

command -v debugfs >/dev/null
test -x staging_dir/host/bin/dtc || true
test -x staging_dir/host/bin/mkimage || true

cp hannspree/config/mm8108.diffconfig .config
make defconfig
make target/linux/clean
make -j"$(nproc)"

mapfile -t configs < <(find build_dir/target-* -path '*/linux-armsr_armv7/linux-*/.config' -print)
test "${#configs[@]}" -eq 1
KDIR=${configs[0]%/.config}
grep -qx 'CONFIG_USB_DWC2=y' "$KDIR/.config"
grep -qx 'CONFIG_USB_DWC2_DUAL_ROLE=y' "$KDIR/.config"
grep -qx '# CONFIG_USB_DWC2_HOST is not set' "$KDIR/.config"
grep -A4 'Bus speed (slot' "$KDIR/drivers/mmc/host/dw_mmc.c" | grep -q dev_dbg || \
	grep -B2 'Bus speed (slot' "$KDIR/drivers/mmc/host/dw_mmc.c" | grep -q dev_dbg

DTC=${DTC:-$TOPDIR/staging_dir/host/bin/dtc}
MKIMAGE=${MKIMAGE:-$TOPDIR/staging_dir/host/bin/mkimage}
FDTGET=${FDTGET:-$(command -v fdtget || true)}
test -x "$DTC"
test -x "$MKIMAGE"
test -n "$FDTGET"
test -x "$FDTGET"

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

test "$("$FDTGET" "$STAGE/rk3288-firefly-reload.dtb" /usb@ff540000 status)" = okay
"$FDTGET" -p "$STAGE/rk3288-firefly-reload.dtb" \
	/i2c@ff650000/act8846@5a/regulators/REG11 | grep -qx regulator-always-on

debugfs -R "dump /root/install-hannspree-emmc.sh $STAGE/installer.from-rootfs" \
	"$STAGE/openwrt-hannspree-rk3288-mm8108-rootfs.ext4"
cmp files/root/install-hannspree-emmc.sh "$STAGE/installer.from-rootfs"
rm "$STAGE/installer.from-rootfs"

cd "$STAGE"
sha256sum openwrt-hannspree-rk3288-mm8108-*.bin \
	openwrt-hannspree-rk3288-mm8108-rootfs.ext4 \
	rk3288-firefly-reload.dtb boot.scr boot-emmc.scr > SHA256SUMS
sha256sum -c SHA256SUMS
: > INSTALL_TO_EMMC
echo "BUILD_VERIFIED=$STAGE"
