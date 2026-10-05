#!/bin/sh
# Make the firmware start on the Intel GPU for the built-in screen. Takes effect on reboot.
V=/sys/firmware/efi/efivars/gpu-power-prefs-fa4ce28d-b62f-4c99-9cc3-6815686e30f9
chattr -i "$V"
printf '\x07\x00\x00\x00\x01\x00\x00\x00' > "$V"
od -An -tx1 "$V"
