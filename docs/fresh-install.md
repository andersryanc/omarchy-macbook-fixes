# Fallback: rebuild from a fresh Omarchy install

Use this if a restore with [`restore-omarchy.sh`](../README.md#restore-restore-omarchysh)
isn't possible: the backup is damaged, the disk is replaced, or you'd simply rather start
clean. It takes a fresh Omarchy install on the **MacBook Pro 15" 2016 (MacBookPro13,3)** back
to a fully working machine: Touch Bar, Touch ID, speakers, full-speed Wi-Fi, GPU stability
fixes and remote access.

Work through the sections in order. Each one ends with a check.

| Section | Fixes | Needs |
| --- | --- | --- |
| [0. Before you wipe](#0-before-you-wipe) | Nothing yet: save what can't be re-downloaded | the old system or its backup |
| [1. Install Omarchy](#1-install-omarchy) | Keyboard, trackpad, basic Wi-Fi (automatic) | Omarchy USB |
| [2. T1 firmware](#2-t1-firmware-touch-bar-touch-id-camera) | T1 chip boots (Touch Bar, Touch ID, camera) | saved `EFI/APPLE` |
| [3. Wi-Fi NVRAM](#3-wi-fi-board-nvram-5-ghz-full-signal) | 5 GHz and full signal | saved NVRAM file |
| [4. t1bridge](#4-t1bridge-touch-bar-touch-id-camera-drivers) | Touch Bar, Touch ID, camera drivers | internet |
| [5. Custom Touch Bar renderer](#5-custom-touch-bar-renderer) | Your own Touch Bar layout | internet |
| [6. Speakers](#6-speakers) | Internal speakers, tuned crossover | internet |
| [7. AMD GPU hangs](#7-amd-gpu-hangs) | Screen-blanking GPU hangs | this repo |
| [8. USB-C hotplug](#8-usb-c-hotplug) | USB-C devices not detected | this repo |
| [9. Remote access](#9-remote-access-ssh) | SSH in when the screen is black | router access |
| [10. Your files](#10-your-files) | Home folder, projects, keys | the backup archive |

What Omarchy's installer already does on this model, so you don't have to (from
`/usr/share/omarchy/install/hardware/apple/`): installs `macbook12-spi-driver-dkms` and adds
`applespi` to the initramfs (keyboard and trackpad), sets `brcmfmac feature_disable=0x82000`
(fixes Wi-Fi passwords being rejected), and sets `hid_apple fnmode=2` (F-keys).

---

## 0. Before you wipe

Some pieces can't be downloaded again. Make sure these are on the backup drive **outside**
the system archive, so you can reach them without extracting anything:

| Item | Why it matters | Where it lives on the old system |
| --- | --- | --- |
| `EFI/APPLE` folder, as a tarball | T1 firmware. Without it the Touch Bar, Touch ID and camera are dead until it's regenerated with [t1-revive](https://github.com/niconistal/t1-revive) (needs Apple's servers) or a macOS install. | `/boot/EFI/APPLE` |
| `brcmfmac43602-pcie.txt` | Wi-Fi board NVRAM with **this Mac's own MAC address** in `macaddr=`. Private: don't publish it. | `/usr/lib/firmware/brcm/` |
| The latest `full-YYYY-MM-DD/` backup | Your files (section 10). | made by `backup-omarchy.sh` |

```sh
kit="/run/media/$USER/<backup drive>/omarchy/_backup"
mkdir -p "$kit"
sudo tar -C /boot -czf "$kit/t1-firmware-EFI-APPLE-$(date +%F).tar.gz" EFI/APPLE
cp /usr/lib/firmware/brcm/brcmfmac43602-pcie.txt "$kit/"
tar -tzf "$kit"/t1-firmware-EFI-APPLE-*.tar.gz | grep combined.memboot   # must print a path
```

Also have ready: a USB stick for the Omarchy ISO, USB-C adapters or a hub, and ideally a
USB keyboard and a wired or phone-tethered network connection. Until section 3 is done, Wi-Fi
is 2.4 GHz only with a weak signal.

---

## 1. Install Omarchy

1. Write the ISO from [omarchy.org](https://omarchy.org) to the stick.
2. Power on holding **⌥ (Option)** and pick the orange **EFI Boot** entry for the stick.
3. Install as usual (full disk, LUKS encryption).
4. After first boot, update: `omarchy-update`.

**Check:** the keyboard and trackpad work, and `ls /sys/bus/usb/devices/1-3/idProduct` exists.
The T1 will still be in recovery mode (`cat` shows `1281`) until section 2. The full-disk
install recreated the ESP, which removed the T1 firmware.

---

## 2. T1 firmware (Touch Bar, Touch ID, camera)

Put the saved `EFI/APPLE` back on the new ESP:

```sh
kit="/run/media/$USER/<backup drive>/omarchy/_backup"
sudo tar -C /boot -xzf "$kit"/t1-firmware-EFI-APPLE-<date>.tar.gz   # contains EFI/APPLE/...
sudo ls /boot/EFI/APPLE/EMBEDDEDOS        # combined.memboot  FDRData  version.plist
```

Then **power off** completely, wait a few seconds and power on. `reboot` isn't enough: the
T1 only loads its firmware at power-on.

**Check:** `cat /sys/bus/usb/devices/1-3/idProduct` prints `8600` (not `1281`). The Touch Bar
stays dark until section 4.

**If the saved folder is lost:** regenerate it from Linux with
[t1-revive](https://github.com/niconistal/t1-revive) (`git clone`, `bash build.sh`,
`sudo bin/t1-revive preflight`, then `sudo bin/t1-revive regenerate`; see its README), or install
macOS and boot it to the desktop once. After a t1-revive regeneration, finish section 4
(t1bridge), then run `sudo bin/t1-revive handover` to pass the running T1 to t1bridge
without a reboot.

---

## 3. Wi-Fi board NVRAM (5 GHz, full signal)

The BCM43602 needs a board-specific NVRAM file. Without it the card runs with Broadcom's
placeholder MAC (`00:90:4c:...`), only on 2.4 GHz, with a weak signal.

```sh
kit="/run/media/$USER/<backup drive>/omarchy/_backup"
sudo cp "$kit/brcmfmac43602-pcie.txt" /usr/lib/firmware/brcm/
```

**Reboot** (reloading the module isn't enough).

**Check:** `ip link show wlp3s0` shows the Mac's real MAC, not `00:90:4c:...`, and 5 GHz
networks appear.

**If the saved file is lost:** take the template from
[nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1) (`firmware/`)
and set `macaddr=` to this Mac's Wi-Fi MAC (on the label under the machine, from macOS
System Information, or in your router's device list).

---

## 4. t1bridge (Touch Bar, Touch ID, camera drivers)

Follow the [t1bridge README](https://github.com/standardagents/t1bridge#readme). Summary:

1. Download the signing key and **check its fingerprint** against the one in the README, then
   `sudo pacman-key --add …` and `sudo pacman-key --lsign-key …`.
2. Add to `/etc/pacman.conf`:

   ```ini
   [standardagents]
   SigLevel = Required DatabaseRequired
   Server = https://linux.standardagents.ai/arch/$repo/$arch
   ```

3. Install. Omarchy blocks a plain `pacman -Syu`, so use:

   ```sh
   sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --needed \
     linux-headers t1bridge t1bridge-dkms libfprint-t1bridge fprintd-t1bridge
   ```

4. Enable it:

   ```sh
   sudo systemd-sysusers /usr/lib/sysusers.d/t1bridge.conf
   sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/t1bridge.conf
   sudo usermod -aG t1bridge "$(id -un)"
   sudo systemctl daemon-reload
   sudo systemctl enable t1-touchbar-hw.service t1-touchid-auth.socket t1bridge-fingerprint.socket
   ```

5. Reboot, then in the desktop session:

   ```sh
   systemctl --user daemon-reload
   systemctl --user enable --now t1-touchbar.service
   sudo t1bridge status
   ```

6. Touch ID: `sudo systemctl start t1bridge-import.service` (imports this Mac's data from
   `EFI/APPLE`), then enrol per the README. Check its firewall note first.

**Check:** the Touch Bar shows Esc and the stock controls, and `sudo t1bridge status` reports
healthy.

---

## 5. Custom Touch Bar renderer

Lives in its own repo: [omarchy-macbook-touchbar-custom](https://github.com/andersryanc/omarchy-macbook-touchbar-custom).
Clone it and follow its README (the `touchbar-custom on` switch links it as
`~/.config/t1bridge/renderer` and restarts the service).

**Check:** `touchbar-custom status`, and the bar shows your layout.

---

## 6. Speakers

The Cirrus CS8409 codec needs [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro).
Install it with DKMS so it survives kernel updates:

```sh
sudo pacman -S --needed dkms linux-omarchy-headers wget     # the installer downloads kernel sources with wget
mkdir -p ~/Work && cd ~/Work
git clone https://github.com/davidjo/snd_hda_macbookpro
cd snd_hda_macbookpro && sudo ./install.cirrus.driver.sh -i
```

Clone it where it will stay: DKMS links back to this folder (`/usr/src/snd_hda_macbookpro-0.1`)
to rebuild the driver for new kernels. If you do move it, repoint the link:
`sudo ln -sfn <new path> /usr/src/snd_hda_macbookpro-0.1`. Reboot.

The driver sends the same full-range sound to all four drivers, which sounds thin. The
PipeWire config in this repo splits it into tweeters and woofers (450 Hz crossover, +7 dB
bass shelf at 250 Hz, 80 Hz woofer high-pass, -3 dB tweeter shelf at 4 kHz, tuned by ear):

```sh
mkdir -p ~/.config/pipewire/pipewire.conf.d
cp files/pipewire/50-macbook-speakers.conf ~/.config/pipewire/pipewire.conf.d/
systemctl --user restart pipewire pipewire-pulse wireplumber
pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:analog-surround-40+input:analog-stereo
pactl set-default-sink effect_input.macbook_speakers
pactl set-sink-volume alsa_output.pci-0000_00_1f.3.analog-surround-40 100%
```

The last line matters: the volume keys only move the "MacBook Speakers" filter, so a low
hardware volume silently caps loudness. Restarting PipeWire resets the card to stereo, so
re-run the `set-card-profile` line after any restart. Also restart any app that was using audio
at the time (browsers, Spotify, Discord): they stay attached to the old PipeWire and lose the
mic and speakers. That's what made Chromium report "no microphone" in a meeting.

The internal mic starts muted. Unmute it in the audio settings if you need it.

**Check:** sound plays with bass, and `pactl get-default-sink` prints `effect_input.macbook_speakers`.

---

## 7. AMD GPU hangs

The Radeon (Polaris) that drives the screen can hang (`ring gfx timeout`) and blank the
screen. These mitigations were applied on 2026-10-04 and are still being evaluated:

1. Keep the GPU at its low power level (clock switching seems to trigger the hangs):

   ```sh
   sudo cp files/udev/30-amdgpu-low.rules /etc/udev/rules.d/
   ```

2. Add `iommu=pt` to the kernel command line, so a GPU reset isn't blocked by the IOMMU. Edit
   `/etc/default/limine` and append ` iommu=pt` inside the quotes of the `KERNEL_CMDLINE` line,
   then:

   ```sh
   sudo limine-update
   ```

3. Optional, experimental: the GPU switch scripts. They set the firmware's `gpu-power-prefs`
   variable, which picks the GPU the Mac starts on (Intel or AMD); the change takes effect after
   a reboot. An NVRAM reset (⌘⌥PR at power-on) clears it. Starting on Intel hasn't been
   tested yet (the firmware default is AMD). Only try it with SSH (section 9) working, because
   the screen may stay black; recover with
   `ssh <user>@<reserved IP> 'sudo -S ~/gpu-use-amd.sh && sudo reboot'`.

   ```sh
   cp files/gpu/gpu-use-intel.sh files/gpu/gpu-use-amd.sh ~/
   sudo ~/gpu-use-intel.sh      # gpu-use-amd.sh goes back
   ```

**Check:** after a reboot, `grep -o iommu=pt /proc/cmdline` prints `iommu=pt`, and
`cat /sys/class/drm/card*/device/power_dpm_force_performance_level` shows `low` for the AMD card.

Take a snapshot before changing any of this (`omarchy-snapshot create`).

Known issue, not fixed: suspend (S3) fails to resume the AMD GPU (`SMU load firmware failed`),
so avoid closing the lid to suspend. Next things to try if hangs continue: the `linux-lts`
kernel, or running the screen from the Intel GPU.

---

## 8. USB-C hotplug

The Thunderbolt controllers don't wake up when you plug something in. These aliases power
them on and off by hand (kept manual rather than always-on to save battery):

```sh
mkdir -p ~/.config/bash
cp files/bash/usb-c-power.sh ~/.config/bash/
echo '[[ -f ~/.config/bash/usb-c-power.sh ]] && source ~/.config/bash/usb-c-power.sh' >> ~/.bashrc
```

**Check:** in a new terminal, `usbwake`, then plug in a USB-C device and confirm it appears
in `lsblk` or `ip link`.

---

## 9. Remote access (SSH)

When the screen is black after a GPU hang, SSH from another computer lets you recover
without a hard reset:

```sh
sudo systemctl enable --now sshd
sudo ufw allow from <LAN subnet, e.g. 192.168.1.0/24> to any port 22 proto tcp
```

In the router's admin page, reserve a fixed IP for the Mac's Wi-Fi MAC (it's the real MAC
once section 3 is done) so you always know where to connect: `ssh <user>@<reserved IP>`.

**Check:** `ssh` in from another machine on the same network.

---

## 10. Your files

The backup archive has your whole old home folder. Restore what you want selectively rather
than all of `~/.config`: Omarchy's defaults may have moved on since the backup.

```sh
b="/run/media/$USER/<backup drive>/omarchy/full-YYYY-MM-DD"
grep -E '^\./home/[^/]+/[^/]+/?$' "$b/meta/archive-listing.txt"     # what's in the old home

# Example: projects, SSH keys and Claude Code settings/notes
tar --zstd -xpf "$b/system.tar.zst" -C / \
  "./home/$USER/Work" "./home/$USER/.ssh" "./home/$USER/.claude"
```

This works when the new username matches the old one. Otherwise extract to a temporary folder
(`-C /tmp/old`) and copy things across.

Each extract reads through the whole archive (a few minutes), so list everything you want
in one command.

---

## Verify everything

```sh
cat /sys/bus/usb/devices/1-3/idProduct     # 8600: T1 running
sudo t1bridge status                       # Touch Bar / Touch ID stack healthy
ip link show wlp3s0                        # real MAC, not 00:90:4c:...
dkms status                                # t1bridge-dkms, snd_hda_macbookpro, macbook12-spi-driver
pactl get-default-sink                     # effect_input.macbook_speakers
grep -o iommu=pt /proc/cmdline             # GPU mitigation active
systemctl is-active sshd                   # remote access
```
