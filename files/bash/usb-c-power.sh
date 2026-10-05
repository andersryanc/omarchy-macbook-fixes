# USB-C / Thunderbolt (Alpine Ridge, 8086:15d4) controllers on the 2016 MacBook Pro
# don't wake up on hotplug. usbwake keeps them powered so new devices are seen;
# usbsleep lets them power down again to save battery. Source this from ~/.bashrc.
alias usbwake='for d in $(grep -l 0x15d4 /sys/bus/pci/devices/*/device); do echo on | sudo tee "${d%/device}/power/control" >/dev/null; done && echo "USB-C ports awake"'
alias usbsleep='for d in $(grep -l 0x15d4 /sys/bus/pci/devices/*/device); do echo auto | sudo tee "${d%/device}/power/control" >/dev/null; done && echo "USB-C ports back to power saving"'
