#!/bin/sh
set -eu

log() {
    echo "[HANNSPREE-INSTALL] $*" > /dev/console
}
fail_install() {
    log "CHYBA: $*"
    log "Instalace zastavena. eMMC uz dale nemenim."
    return 1
}

log "Start automaticke instalace OpenWrt na eMMC"

# PREINIT muze zacit velmi brzy. Pockej az kernel vytvori block devices.
SDDEV=""
EMMCDEV=""
tries=0
while [ "$tries" -lt 20 ]; do
    SDDEV=""
    EMMCDEV=""
    for sysdev in /sys/class/block/mmcblk[0-9]; do
        [ -e "$sysdev" ] || continue
        name="$(basename "$sysdev")"
        type="$(cat "$sysdev/device/type" 2>/dev/null || true)"
        case "$type" in
            SD)  SDDEV="/dev/$name" ;;
            MMC) EMMCDEV="/dev/$name" ;;
        esac
    done
    [ -n "$SDDEV" ] && [ -n "$EMMCDEV" ] && break
    tries=$((tries + 1))
    sleep 1
done

[ -n "$SDDEV" ] || { fail_install "Nenalezena SD karta"; exit 1; }
[ -n "$EMMCDEV" ] || { fail_install "Nenalezena eMMC"; exit 1; }

SDPART="${SDDEV}p1"
EMMCPART="${EMMCDEV}p1"
[ -b "$SDPART" ] || { fail_install "Chybi $SDPART"; exit 1; }
[ -b "$EMMCPART" ] || { fail_install "Chybi $EMMCPART"; exit 1; }

log "SD:   $SDDEV ($SDPART)"
log "eMMC: $EMMCDEV ($EMMCPART)"

# Safety: SD a eMMC samozrejme nesmi byt stejne zarizeni.
[ "$SDDEV" != "$EMMCDEV" ] || { fail_install "SD a eMMC ukazuji na stejne zarizeni"; exit 1; }

mkdir -p /mnt/sd /mnt/emmc
modprobe vfat 2>/dev/null || true
umount /mnt/sd 2>/dev/null || true
mount -o rw "$SDPART" /mnt/sd || { fail_install "Nelze pripojit SD $SDPART"; exit 1; }

ROOTFS=/mnt/sd/openwrt-hannspree-rk3288-mm8108-rootfs.ext4
KERNEL=/mnt/sd/openwrt-hannspree-rk3288-mm8108-kernel.bin
DTB=/mnt/sd/rk3288-firefly-reload.dtb
BOOTSCR=/mnt/sd/boot-emmc.scr
MARKER=/mnt/sd/INSTALL_TO_EMMC

for f in "$ROOTFS" "$KERNEL" "$DTB" "$BOOTSCR"; do
    [ -s "$f" ] || { fail_install "Na SD chybi $(basename "$f")"; umount /mnt/sd; exit 1; }
done
[ -e "$MARKER" ] || { fail_install "Na SD chybi INSTALL_TO_EMMC"; umount /mnt/sd; exit 1; }

# Guardrails: znamy Hannspree ma cca 8 GB eMMC a jedna root partition.
EMMC_SYS="/sys/class/block/$(basename "$EMMCDEV")"
PART_SYS="/sys/class/block/$(basename "$EMMCPART")"
EMMC_BYTES=$(( $(cat "$EMMC_SYS/size") * 512 ))
PART_BYTES=$(( $(cat "$PART_SYS/size") * 512 ))
ROOTFS_BYTES=$(wc -c < "$ROOTFS")

[ "$EMMC_BYTES" -gt 4000000000 ] || { fail_install "eMMC je podezrele mala ($EMMC_BYTES B)"; umount /mnt/sd; exit 1; }
[ "$EMMC_BYTES" -lt 16000000000 ] || { fail_install "eMMC je neocekavane velka ($EMMC_BYTES B)"; umount /mnt/sd; exit 1; }
[ "$ROOTFS_BYTES" -gt 16000000 ] || { fail_install "rootfs image je podezrele maly ($ROOTFS_BYTES B)"; umount /mnt/sd; exit 1; }
[ "$ROOTFS_BYTES" -lt "$PART_BYTES" ] || { fail_install "rootfs image se nevejde do eMMC partition"; umount /mnt/sd; exit 1; }

# Verify all installation inputs before the first write to eMMC.
(cd /mnt/sd && sha256sum -c SHA256SUMS) || exit 1
case "$(awk '$2 == "/" {print $1}' /proc/mounts)" in
    /dev/mmc*|/dev/root) log "Refusing installation from a disk root"; exit 1;;
esac
if awk '{print $1}' /proc/mounts | grep -qx "$EMMCPART"; then
    log "eMMC partition is mounted; refusing overwrite"; exit 1
fi
[ "$(cat "$PART_SYS/start")" -ge 32768 ] || exit 1
log "Zalohuji prvnich 32 MiB eMMC na SD (U-Boot/SPL + tabulka + zacatek disku)"
if [ ! -s /mnt/sd/emmc-first-32MiB-backup.bin ]; then
    dd if="$EMMCDEV" of=/mnt/sd/emmc-first-32MiB-backup.bin bs=1M count=32 conv=fsync || {
        fail_install "Zaloha prvnich 32 MiB selhala"; umount /mnt/sd; exit 1;
    }
    sync
else
    log "Zaloha uz na SD existuje, neprepisuji ji"
fi

# Over, ze eMMC stale existuje tesne pred destruktivnim krokem.
[ -b "$EMMCPART" ] || { fail_install "$EMMCPART zmizela pred zapisem"; umount /mnt/sd; exit 1; }

log "Zapisuji persistentni OpenWrt rootfs do $EMMCPART"
umount "$EMMCPART" 2>/dev/null || true
dd if="$ROOTFS" of="$EMMCPART" bs=4M conv=fsync || {
    fail_install "Zapis rootfs selhal"; umount /mnt/sd; exit 1;
}
sync

log "Verifying written rootfs before resizing"
expected=$(sha256sum "$ROOTFS" | awk '{print $1}')
actual=$(head -c "$ROOTFS_BYTES" "$EMMCPART" | sha256sum | awk '{print $1}')
[ "$actual" = "$expected" ] || { log "Rootfs checksum mismatch"; exit 1; }
log "Kontroluji ext4"
rc=0
e2fsck -fy "$EMMCPART" || rc=$?
if [ "$rc" -gt 1 ]; then
    fail_install "e2fsck skoncil kodem $rc"
    umount /mnt/sd
    exit 1
fi

log "Rozsiruji ext4 na celou eMMC partition"
resize2fs "$EMMCPART" || {
    fail_install "resize2fs selhal"; umount /mnt/sd; exit 1;
}

mount "$EMMCPART" /mnt/emmc || {
    fail_install "Nelze pripojit novy rootfs"; umount /mnt/sd; exit 1;
}
mkdir -p /mnt/emmc/boot /mnt/emmc/etc
cp "$KERNEL" /mnt/emmc/boot/openwrt-kernel.bin
cp "$DTB" /mnt/emmc/boot/rk3288-firefly-reload.dtb
cp "$BOOTSCR" /mnt/emmc/boot/boot.scr
cp "$BOOTSCR" /mnt/emmc/boot.scr

cmp "$KERNEL" /mnt/emmc/boot/openwrt-kernel.bin
cmp "$DTB" /mnt/emmc/boot/rk3288-firefly-reload.dtb
cmp "$BOOTSCR" /mnt/emmc/boot/boot.scr
cmp "$BOOTSCR" /mnt/emmc/boot.scr
echo "installed $(date 2>/dev/null || true)" > /mnt/emmc/etc/hannspree-emmc-installed
sync

log "Instalace hotova. Odstranuji jednorazovy marker ze SD."
rm -f "$MARKER"
sync
umount /mnt/emmc
umount /mnt/sd

log "Reboot za 3 sekundy. Pri dalsim bootu se uz spusti OpenWrt z eMMC."
sleep 3
reboot -f
