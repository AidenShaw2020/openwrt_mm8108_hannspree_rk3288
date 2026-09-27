# SPDX-License-Identifier: GPL-2.0-or-later

RAMFS_COPY_BIN="/usr/sbin/blkid /usr/sbin/e2fsck /usr/sbin/resize2fs"

is_hannspree_rk3288() {
	case "$(board_name)" in
		firefly,firefly-rk3288-reload|hannspree,s-x20) return 0 ;;
		*) return 1 ;;
	esac
}

hannspree_find_emmc_partition() {
	local sysdev name found=""

	for sysdev in /sys/class/block/mmcblk[0-9]; do
		[ -e "$sysdev" ] || continue
		[ "$(cat "$sysdev/device/type" 2>/dev/null)" = MMC ] || continue
		[ -z "$found" ] || {
			v "More than one eMMC device found"
			return 1
		}
		name="${sysdev##*/}"
		found="/dev/${name}p1"
	done

	[ -n "$found" ] && [ -b "$found" ] || return 1
	printf '%s\n' "$found"
}

hannspree_control_value() {
	printf '%s\n' "$HANNSPREE_CONTROL" | awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }'
}

hannspree_valid_hash() {
	[ "${#1}" -eq 64 ] || return 1
	case "$1" in
		*[!0-9a-f]*) return 1 ;;
	esac
}

hannspree_validate_sysupgrade() {
	local image="$1" dir=sysupgrade-hannspree-rk3288 file hash key size

	for file in CONTROL kernel root dtb boot.scr; do
		tar tf "$image" "$dir/$file" >/dev/null 2>&1 || {
			v "Hannspree sysupgrade is missing $file"
			return 1
		}
	done

	HANNSPREE_CONTROL="$(tar xOf "$image" "$dir/CONTROL")" || return 1
	[ "$(hannspree_control_value FORMAT)" = 1 ] || return 1
	[ "$(hannspree_control_value BOARD)" = firefly,firefly-rk3288-reload ] || return 1

	size="$(hannspree_control_value ROOT_SIZE)"
	case "$size" in ''|*[!0-9]*) return 1 ;; esac
	[ "$size" -gt 16777216 ] || return 1

	for file in kernel root dtb boot.scr; do
		case "$file" in
			kernel) key=KERNEL_SHA256 ;;
			root) key=ROOT_SHA256 ;;
			dtb) key=DTB_SHA256 ;;
			boot.scr) key=BOOT_SCR_SHA256 ;;
		esac
		hash="$(hannspree_control_value "$key")"
		hannspree_valid_hash "$hash" || return 1
	done
}

hannspree_validate_payloads() {
	local image="$1" dir=sysupgrade-hannspree-rk3288 file hash key

	hannspree_validate_sysupgrade "$image" || return 1
	for file in kernel dtb boot.scr root; do
		case "$file" in
			kernel) key=KERNEL_SHA256 ;;
			root) key=ROOT_SHA256 ;;
			dtb) key=DTB_SHA256 ;;
			boot.scr) key=BOOT_SCR_SHA256 ;;
		esac
		hash="$(hannspree_control_value "$key")"
		[ "$(tar xOf "$image" "$dir/$file" | /bin/busybox sha256sum | awk '{print $1}')" = "$hash" ] || {
			v "Checksum failed for $file"
			return 1
		}
	done
}

hannspree_restore_config() {
	local mountpoint="$1" backup_hash backup_count

	[ -n "$UPGRADE_BACKUP" ] || return 0
	[ -s "$UPGRADE_BACKUP" ] || {
		v "Hannspree configuration backup is missing or empty"
		return 1
	}
	/bin/busybox tar -tzf "$UPGRADE_BACKUP" >/dev/null || {
		v "Hannspree configuration backup is not a valid tar archive"
		return 1
	}

	backup_hash="$(/bin/busybox sha256sum "$UPGRADE_BACKUP" | awk '{print $1}')"
	backup_count="$(/bin/busybox tar -tzf "$UPGRADE_BACKUP" | wc -l)"
	v "Restoring $backup_count configuration entries into the new Hannspree root filesystem"
	/bin/busybox tar -xzf "$UPGRADE_BACKUP" -C "$mountpoint" || return 1
	cp -f "$UPGRADE_BACKUP" "$mountpoint/$BACKUP_FILE" || return 1
	mkdir -p "$mountpoint/etc"
	printf 'sha256=%s\nentries=%s\n' "$backup_hash" "$backup_count" > \
		"$mountpoint/etc/hannspree-config-restored"
}

hannspree_do_upgrade() {
	local image="$1" dir=sysupgrade-hannspree-rk3288 part disk sysdisk
	local root_size root_hash part_size disk_size part_start actual rc mountpoint root_spec partuuid arg

	hannspree_validate_payloads "$image" || return 1
	part="$(hannspree_find_emmc_partition)" || {
		v "Unable to identify the Hannspree eMMC root partition"
		return 1
	}
	disk="${part%p1}"
	sysdisk="/sys/class/block/${disk##*/}"

	disk_size=$(( $(cat "$sysdisk/size") * 512 ))
	part_size=$(( $(cat "/sys/class/block/${part##*/}/size") * 512 ))
	part_start=$(cat "/sys/class/block/${part##*/}/start")
	root_size="$(hannspree_control_value ROOT_SIZE)"
	root_hash="$(hannspree_control_value ROOT_SHA256)"
	root_spec=""
	for arg in $(cat /proc/cmdline); do
		case "$arg" in root=*) root_spec="${arg#root=}" ;; esac
	done
	partuuid="$(blkid -s PARTUUID -o value "$part")"
	case "$root_spec" in
		"$part"|"PARTUUID=$partuuid") ;;
		*)
			v "Refusing to overwrite $part because it is not the active root partition"
			return 1
			;;
	esac

	[ "$disk_size" -gt 4000000000 ] && [ "$disk_size" -lt 16000000000 ] || {
		v "Unexpected eMMC size: $disk_size"
		return 1
	}
	[ "$part_start" -ge 32768 ] || {
		v "Refusing to overwrite a partition that overlaps the bootloader area"
		return 1
	}
	[ "$root_size" -lt "$part_size" ] || {
		v "The new root filesystem does not fit in $part"
		return 1
	}

	v "Writing verified Hannspree root filesystem to $part"
	tar xOf "$image" "$dir/root" | dd of="$part" bs=4M conv=fsync || return 1
	sync
	actual=$(/bin/busybox head -c "$root_size" "$part" | /bin/busybox sha256sum | awk '{print $1}')
	[ "$actual" = "$root_hash" ] || {
		v "Root filesystem verification failed after writing"
		return 1
	}

	rc=0
	e2fsck -fy "$part" || rc=$?
	[ "$rc" -le 1 ] || return 1
	resize2fs "$part" || return 1

	mountpoint=/mnt/hannspree-upgrade
	mkdir -p "$mountpoint"
	mount -t ext4 -o rw,noatime "$part" "$mountpoint" || return 1
	mkdir -p "$mountpoint/boot" "$mountpoint/etc"
	hannspree_restore_config "$mountpoint" || {
		umount "$mountpoint"
		return 1
	}
	tar xOf "$image" "$dir/kernel" > "$mountpoint/boot/openwrt-kernel.bin" || return 1
	tar xOf "$image" "$dir/dtb" > "$mountpoint/boot/rk3288-firefly-reload.dtb" || return 1
	tar xOf "$image" "$dir/boot.scr" > "$mountpoint/boot/boot.scr" || return 1
	cp "$mountpoint/boot/boot.scr" "$mountpoint/boot.scr" || return 1

	[ "$(/bin/busybox sha256sum "$mountpoint/boot/openwrt-kernel.bin" | awk '{print $1}')" = \
		"$(hannspree_control_value KERNEL_SHA256)" ] || return 1
	[ "$(/bin/busybox sha256sum "$mountpoint/boot/rk3288-firefly-reload.dtb" | awk '{print $1}')" = \
		"$(hannspree_control_value DTB_SHA256)" ] || return 1
	[ "$(/bin/busybox sha256sum "$mountpoint/boot/boot.scr" | awk '{print $1}')" = \
		"$(hannspree_control_value BOOT_SCR_SHA256)" ] || return 1

	printf 'sysupgraded %s\n' "$(date 2>/dev/null || true)" > "$mountpoint/etc/hannspree-emmc-installed"
	sync
	umount "$mountpoint" || return 1
	HANNSPREE_EMMCPART="$part"
}

platform_check_image() {
	local board=$(board_name)
	local diskdev partdev diff
	[ "$#" -gt 1 ] && return 1

	if is_hannspree_rk3288; then
		hannspree_validate_sysupgrade "$1"
		return $?
	fi

	v "Board is ${board}"

	export_bootdevice && export_partdevice diskdev 0 || {
		v "platform_check_image: Unable to determine upgrade device"
		return 1
	}

	get_partitions "/dev/$diskdev" bootdisk

	v "Extract boot sector from the image"
	get_image_dd "$1" of=/tmp/image.bs count=63 bs=512b

	get_partitions /tmp/image.bs image

	#compare tables
	diff="$(grep -F -x -v -f /tmp/partmap.bootdisk /tmp/partmap.image)"

	rm -f /tmp/image.bs /tmp/partmap.bootdisk /tmp/partmap.image

	if [ -n "$diff" ]; then
		v "Partition layout has changed. Full image will be written."
		ask_bool 0 "Abort" && exit 1
		return 0
	fi
}

platform_copy_config() {
	local partdev parttype=ext4

	if is_hannspree_rk3288; then
		partdev="${HANNSPREE_EMMCPART:-$(hannspree_find_emmc_partition)}" || return 1
		mkdir -p /mnt
		mount -t ext4 -o rw,noatime "$partdev" /mnt || return 1
		hannspree_restore_config /mnt || {
			umount /mnt
			return 1
		}
		sync
		umount /mnt
		return 0
	fi

	if export_partdevice partdev 1; then
		part_magic_fat "/dev/$partdev" && parttype=vfat
		mount -t $parttype -o rw,noatime "/dev/$partdev" /mnt
		cp -af "$UPGRADE_BACKUP" "/mnt/$BACKUP_FILE"
		umount /mnt
	else
		v "ERROR: Unable to find partition to copy config data to"
	fi

	sleep 5
}

# To avoid writing over any firmware
# files (e.g ubootefi.var or firmware/X/ aka EBBR)
# Copy efi/openwrt and efi/boot from the new image
# to the existing ESP
platform_do_upgrade_efi_system_partition() {
	local image_file=$1
	local target_partdev=$2
	local image_efisp_start=$3
	local image_efisp_size=$4

	v "Updating ESP on ${target_partdev}"
	NEW_ESP_DIR="/mnt/new_esp_loop"
	CUR_ESP_DIR="/mnt/cur_esp"
	mkdir "${NEW_ESP_DIR}"
	mkdir "${CUR_ESP_DIR}"

	get_image_dd "$image_file" of="/tmp/new_efi_sys_part.img" \
		skip="$image_efisp_start" count="$image_efisp_size"

	mount -t vfat -o loop -o ro /tmp/new_efi_sys_part.img "${NEW_ESP_DIR}"
	if [ ! -d "${NEW_ESP_DIR}/efi/boot" ]; then
		v "ERROR: Image does not contain EFI boot files (/efi/boot)"
		return 1
	fi

	mount -t vfat "/dev/$partdev" "${CUR_ESP_DIR}"

	for d in $(find "${NEW_ESP_DIR}/efi/" -mindepth 1 -maxdepth 1 -type d); do
		v "Copying ${d}"
		newdir_bname=$(basename "${d}")
		rm -rf "${CUR_ESP_DIR}/efi/${newdir_bname}"
		cp -r "${d}" "${CUR_ESP_DIR}/efi"
	done

	umount "${NEW_ESP_DIR}"
	umount "${CUR_ESP_DIR}"
}

platform_do_upgrade() {
	local board=$(board_name)
	local diskdev partdev diff

	if is_hannspree_rk3288; then
		hannspree_do_upgrade "$1"
		return $?
	fi

	export_bootdevice && export_partdevice diskdev 0 || {
		v "platform_do_upgrade: Unable to determine upgrade device"
		return 1
	}

	sync

	if [ "$UPGRADE_OPT_SAVE_PARTITIONS" = "1" ]; then
		get_partitions "/dev/$diskdev" bootdisk

		v "Extract boot sector from the image"
		get_image_dd "$1" of=/tmp/image.bs count=63 bs=512b

		get_partitions /tmp/image.bs image

		#compare tables
		diff="$(grep -F -x -v -f /tmp/partmap.bootdisk /tmp/partmap.image)"
	else
		diff=1
	fi

	# Only change the partition table if sysupgrade -p is set,
	# otherwise doing so could interfere with embedded "single storage"
	# (e.g SoC boot from SD card) setups, as well as other user
	# created storage (like uvol)
	if [ -n "$diff" ] && [ "${UPGRADE_OPT_SAVE_PARTITIONS}" = "0" ]; then
		# Need to remove partitions before dd, otherwise the partitions
		# that are added after will have minor numbers offset
		partx -d - "/dev/$diskdev"

		get_image_dd "$1" of="/dev/$diskdev" bs=4096 conv=fsync

		# Separate removal and addtion is necessary; otherwise, partition 1
		# will be missing if it overlaps with the old partition 2
		partx -a - "/dev/$diskdev"

		return 0
	fi

	#iterate over each partition from the image and write it to the boot disk
	while read part start size; do
		if export_partdevice partdev $part; then
			v "Writing image to /dev/$partdev..."
			if [ "$part" = "1" ]; then
				platform_do_upgrade_efi_system_partition \
					$1 $partdev $start $size || return 1
			else
				v "Normal partition, doing DD"
				get_image_dd "$1" of="/dev/$partdev" ibs=512 obs=1M skip="$start" \
					count="$size" conv=fsync
			fi
		else
			v "Unable to find partition $part device, skipped."
		fi
	done < /tmp/partmap.image

	local parttype=ext4

	if (blkid > /dev/null) && export_partdevice partdev 1; then
		part_magic_fat "/dev/$partdev" && parttype=vfat
		mount -t $parttype -o rw,noatime "/dev/$partdev" /mnt
		if export_partdevice partdev 2; then
			THIS_PART_BLKID=$(blkid -o value -s PARTUUID "/dev/${partdev}")
			v "Setting rootfs PARTUUID=${THIS_PART_BLKID}"
			sed -i "s/\(PARTUUID=\)[a-f0-9-]\+/\1${THIS_PART_BLKID}/ig" \
				/mnt/efi/openwrt/grub.cfg
		fi
		umount /mnt
	fi
	# Provide time for the storage medium to flush before system reset
	# (despite the sync/umount it appears NVMe etc. do it in the background)
	sleep 5
}
