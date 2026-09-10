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
- File-backed Morse persistent variables, CZ defaults and fixed random-key
  generation without the BusyBox `tr: Broken pipe` message.
- Ethernet management access, Dropbear and HTTP enabled on first boot.
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
and creates the one-shot `INSTALL_TO_EMMC` marker.

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
