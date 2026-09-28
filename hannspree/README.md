# Hannspree RK3288 with USB MM8108

This branch adds the changes used and tested on the Hannspree RK3288 Android
box with a Morse Micro MM8108 connected over USB. It is based on Morse Micro
OpenWrt commit `8ca817c95eab24b12de31b5cf8385e99ae6421cf` (3.1.1 release).

## Included changes

- RK3288, eMMC, Ethernet, USB PHY and DWC2 kernel support for the ARMv7 target.
- MM8108 USB transport without an SDIO/MMC dependency or GPIO chip reset.
- `vcc_18` kept enabled. On the tested board the USB hub disconnected about
  210 ms after this regulator was disabled.
- USB autosuspend disabled in both installer and persistent eMMC boot scripts.
- Repetitive DesignWare MMC bus-speed messages moved from info to debug level.
- File-backed Morse persistent variables, the certified EU region and fixed random-key
  generation without the BusyBox `tr: Broken pipe` message.
- Ethernet management access, Dropbear and HTTP enabled on first boot.
- A stable per-device Ethernet MAC derived from the unique eMMC CID, preventing
  a new DHCP address after each clean installation.
- A guarded eMMC installer that verifies its inputs, backs up the first 32 MiB,
  writes only the existing first partition, verifies the write and preserves
  the bootloader.
- Pinned feed patches required by the tested build.

## Build on Linux

Install the host dependencies required by OpenWrt, then run from the repository
root:

```sh
./hannspree/apply-feeds.sh
./hannspree/build.sh
```

The verified installation set is written to
`bin/targets/armsr/armv7/hannspree-mm8108/`.

The directory also contains
`openwrt-hannspree-rk3288-mm8108-sysupgrade.tar`. This is a guarded upgrade
archive for the Hannspree single-partition eMMC layout. It verifies every
payload, checks that the target is the active 4-16 GB eMMC partition, preserves
the bootloader area, writes and verifies the root filesystem, installs the
kernel, DTB and boot script, and supports the normal OpenWrt configuration
backup.

The custom image disables Morse Micro production-signature enforcement because
the private production signing key is not available outside Morse Micro. The
archive carries standard OpenWrt compatibility metadata, while the platform
handler verifies the board, archive structure, declared sizes and SHA256 of
every payload before writing anything to eMMC.

Builds made before this sysupgrade handler was added need the included handler
installed once before their first in-place upgrade:

From LuCI, upload `hannspree-sysupgrade-bootstrap.tar.gz` under **System →
Backup / Flash Firmware → Restore backup** and reboot. This small archive only
installs the Hannspree upgrade handler, the rule that preserves every file in
`/etc/config`, and disables production-signature enforcement. Before the first
upgrade to a release containing the verified all-configuration restore, install
the matching bootstrap archive and reboot. You can confirm that the running
system includes the rule with:

```sh
sysupgrade -l | grep '^/etc/config/' | head
```

Then upload the sysupgrade archive in the normal **Flash new firmware image**
section. The handler independently extracts the backup, compares every restored
UCI file, and refuses to reboot if the comparison fails.

The equivalent SSH procedure is:

```sh
scp hannspree-platform.sh root@DEVICE:/tmp/
scp openwrt-hannspree-rk3288-mm8108-sysupgrade.tar root@DEVICE:/tmp/
ssh root@DEVICE 'uci set system.@system[0].enforce_fw_sign=0; \
  uci commit system; cp /tmp/hannspree-platform.sh /lib/upgrade/platform.sh && \
  sysupgrade -T /tmp/openwrt-hannspree-rk3288-mm8108-sysupgrade.tar'
ssh root@DEVICE 'sysupgrade /tmp/openwrt-hannspree-rk3288-mm8108-sysupgrade.tar'
```

After this release, subsequent builds already contain the handler and only the
last `sysupgrade` command is needed. Use `sysupgrade -n` when configuration
must not be retained.

## Build remotely and prepare an SD card from Windows

Clone this branch into the configured build directory on `aiden-ubuntu`. Insert
one FAT32 SD card labelled `SD` into the Windows PC, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\hannspree\windows\Build-And-Install.ps1
```

Pass `-KeyFile C:\path\to\key` when the SSH key is not stored as
`%USERPROFILE%\.ssh\codex_audit_ed25519`.

The PowerShell script builds on the remote host, downloads only the verified
artifacts, checks SHA256 before and after copying, backs up existing SD files,
and creates the one-shot `INSTALL_TO_EMMC` marker. It also downloads the
verified sysupgrade archive and one-time handler described above.

Booting that SD card replaces the existing first eMMC partition. The installer
identifies SD and eMMC from sysfs, refuses unexpected layouts and preserves the
bootloader area before the first partition.

## Updating to a newer Morse Micro release

Fetch the new upstream release and rebase this branch onto it. Resolve changes
in `target/linux/armsr` as normal Git conflicts. Then run
`hannspree/apply-feeds.sh`. Each feed patch is checked before application and
stops on a conflict rather than silently producing a partial port. Finish with
`hannspree/build.sh`; its post-build checks verify the DWC2 mode, DTB regulator
property, embedded installer and all output hashes.

The full board DTS in `hannspree/board/` is intentionally kept as a tested,
versioned input. Compare it with the new kernel's RK3288 DTS when moving across
kernel versions.
