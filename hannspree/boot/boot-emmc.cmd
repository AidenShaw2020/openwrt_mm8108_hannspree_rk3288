echo "=== Hannspree OpenWrt boot from eMMC ==="
setenv kernel_addr_r 0x02000000
setenv fdt_addr_r 0x01f00000

if part uuid mmc 0:1 rootpartuuid; then
    echo "eMMC root PARTUUID: ${rootpartuuid}"
else
    echo "ERROR: cannot determine eMMC PARTUUID"
    reset
fi

setenv bootargs "root=PARTUUID=${rootpartuuid} rootwait rootfstype=ext4 rootflags=data=writeback rw console=ttyS2,115200n8 console=tty0 no_console_suspend consoleblank=0 coherent_pool=2M usbcore.autosuspend=-1 loglevel=7 net.ifnames=0"

if load mmc 0:1 ${kernel_addr_r} /boot/openwrt-kernel.bin; then
    if load mmc 0:1 ${fdt_addr_r} /boot/rk3288-firefly-reload.dtb; then
        bootz ${kernel_addr_r} - ${fdt_addr_r}
    fi
fi

echo "ERROR: eMMC OpenWrt boot failed"
reset
