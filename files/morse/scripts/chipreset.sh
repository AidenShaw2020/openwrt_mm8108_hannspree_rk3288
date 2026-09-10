#!/bin/sh
# Hannspree RK3288 with USB MM8108: no external SDIO/GPIO chip reset.
# The vendor implementation unbinds the first MMC host and can remove eMMC.
# USB device reset is handled by the USB transport/driver.
echo "morsechipreset: Hannspree USB MM8108; skipping SDIO host/GPIO reset"
exit 0
