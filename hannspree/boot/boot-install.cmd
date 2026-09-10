echo "=== Hannspree verified eMMC installer ==="
setenv kernel_addr_r 0x02000000
setenv fdt_addr_r 0x01f00000

if test -e mmc 1:1 /INSTALL_TO_EMMC; then
    setenv bootargs 'console=ttyS2,115200n8 console=tty0 no_console_suspend consoleblank=0 coherent_pool=2M usbcore.autosuspend=-1 loglevel=8 ignore_loglevel hannspree_emmc_install=YES'
    if load mmc 1:1 ${kernel_addr_r} /openwrt-hannspree-rk3288-mm8108-initramfs-kernel.bin; then
        if load mmc 1:1 ${fdt_addr_r} /rk3288-firefly-reload.dtb; then
            bootz ${kernel_addr_r} - ${fdt_addr_r}
        fi
    fi
    echo "ERROR: installer image or DTB could not be loaded"
    while true; do sleep 60; done
fi

echo "No install marker; booting installed OpenWrt from eMMC"
if part uuid mmc 0:1 rootpartuuid; then
    setenv bootargs "root=PARTUUID=${rootpartuuid} rootwait rootfstype=ext4 rootflags=data=writeback rw console=ttyS2,115200n8 console=tty0 no_console_suspend consoleblank=0 coherent_pool=2M usbcore.autosuspend=-1 loglevel=7 net.ifnames=0"
    if load mmc 0:1 ${kernel_addr_r} /boot/openwrt-kernel.bin; then
        if load mmc 0:1 ${fdt_addr_r} /boot/rk3288-firefly-reload.dtb; then
            bootz ${kernel_addr_r} - ${fdt_addr_r}
        fi
    fi
fi
echo "ERROR: eMMC OpenWrt boot failed"
while true; do sleep 60; done
