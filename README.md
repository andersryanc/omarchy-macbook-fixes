# omarchy-macbook-fixes

Notes and scripts from running [Omarchy](https://omarchy.org) (Arch Linux, Hyprland) on a
**MacBook Pro 15" 2016 (MacBookPro13,3)** with the Apple **T1** chip and a working Touch Bar
through [t1bridge](https://github.com/standardagents/t1bridge).

| File | What it's for |
| --- | --- |
| [`backup-omarchy.sh`](backup-omarchy.sh) | Full backup of a running LUKS + btrfs install to an external drive: one archive plus the disk metadata needed to rebuild the disk exactly. |
| [`restore-omarchy.sh`](restore-omarchy.sh) | Bare-metal restore of that backup from a live USB. Every identifier comes back unchanged, so the system boots without edits. On a T1 Mac it can also swap in a new `EFI/APPLE` (Touch Bar firmware) during the restore. |
| [`docs/fresh-install.md`](docs/fresh-install.md) | Fallback guide: take a **fresh Omarchy install** on this MacBook back to a fully working machine (T1 firmware, Touch Bar, Wi-Fi NVRAM, speakers, GPU fixes, USB-C, SSH, your files). |
| [`files/`](files/) | Config files the guide installs: PipeWire speaker crossover, AMD GPU udev rule, GPU switch scripts, USB-C power aliases. |

The backup and restore scripts aren't Mac-specific. They work on any machine whose layout
matches the [requirements](#requirements) (Omarchy's default install does).

---

## Requirements

The scripts detect the layout of the running system rather than hardcoding it, but they
only support this shape:

- **One disk** holding both the EFI System Partition and the LUKS partition (NVMe, SATA or
  eMMC; any partition numbers).
- **ESP**: FAT, mounted at `/boot`, `/efi` or `/boot/efi`.
- **Root**: btrfs inside **LUKS** (dm-crypt), with subvolumes mounted through `/etc/fstab`
  (e.g. `@`, `@home`, `@log`, `@pkg`).
- Optional: a swapfile on btrfs. If hibernation uses it (`resume_offset=`), the restore
  updates the text config that sets it and regenerates the boot images with `limine-update`
  (Omarchy) or `mkinitcpio -P`.
- GNU `tar` with zstd, `cryptsetup`, `btrfs-progs`, `util-linux`. For the restore, a live USB
  that has them too, plus `dosfstools`, `arch-chroot` and `efibootmgr`. The **Arch ISO** has
  everything.
- A restore target **at least as large** as the original disk (the partition table is
  replayed as-is).

Not supported: unencrypted root, LVM, ext4/xfs root, multiple disks, Secure Boot key
enrolment, GRUB-specific setups.

---

## Backup: `backup-omarchy.sh`

### What it does

Run it on the **live, installed system**. It detects the disk, ESP, LUKS partition, root
subvolume and swapfile, then writes `<destination>/full-YYYY-MM-DD/` containing:

| Path | Contents |
| --- | --- |
| `system.tar.zst` | Everything under `/`, including `/home`, the ESP and every mounted btrfs subvolume. Owners, permissions, ACLs and extended attributes are preserved. zstd-compressed (about 6 GB for a 27 GB install). |
| `system.tar.zst.sha256` | Checksum; the restore verifies it before touching the disk. |
| `meta/layout.env` | What was detected: disk, partition numbers, ESP mount point, LUKS mapper name, root subvolume, ESP serial, btrfs UUID, swapfile path, size and offset. The restore reads this. |
| `meta/disk.sfdisk` | Partition table, including the disk label ID and partition UUIDs. |
| `meta/luks-header.img`, `luksdump.txt` | LUKS header backup (the keyslots: restoring it keeps your passphrase). |
| `meta/btrfs-subvolumes.txt` | Subvolume layout. |
| `meta/fstab`, `crypttab`, `cmdline.txt`, `findmnt.txt`, `blkid.txt`, `lsblk.txt` | How everything is identified, mounted and booted. |
| `meta/efibootmgr.txt` | The firmware boot entries. |
| `meta/resume-offset-files.txt` | Config files under `/etc` that set `resume_offset=`. |
| `meta/pkglist-explicit.txt`, `pkglist-foreign.txt` | Installed packages (Arch), for reference or a rebuild from scratch. |
| `meta/archive-listing.txt` | Every path in the archive, for searching without opening it. |

Left out on purpose: `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/var/tmp`, `/mnt`, `/media`,
the swapfile (recreated on restore), snapper snapshots (`/.snapshots/*`), the pacman package
cache and `~/.cache`. The directories themselves are kept, empty.

It's one archive rather than a folder of copied files so the backup drive can be **exFAT or
NTFS**, which can't store Linux owners and permissions. `--one-file-system` isn't used because
each btrfs subvolume counts as a separate filesystem, so `/home` and the rest would be skipped.

### How to run it

1. Plug in the backup drive and check it's mounted with enough room. The archive is roughly a
   quarter of the "Used" figure from `df -h /`.

   ```sh
   lsblk -o NAME,SIZE,FSTYPE,LABEL,FSAVAIL,MOUNTPOINTS
   ```

2. Close the browser and other busy apps. Files that change mid-backup are still saved, but
   may be inconsistent.

3. Run it with a folder on the backup drive:

   ```sh
   sudo bash backup-omarchy.sh "/run/media/$USER/<backup drive>/omarchy"
   ```

4. Expected warnings, all harmless:

   ```
   tar: ./etc/pacman.d/gnupg/S.gpg-agent: socket ignored     (live sockets can't be archived)
   tar: ./sys: file changed as we read it                    (its contents are excluded anyway)
   ```

5. It's finished when it prints something like:

   ```
   done: 348953 entries, 6.1G
         /run/media/<user>/<backup drive>/omarchy/full-2026-10-04
   ```

   A line `error: MISSING from archive: …` means the check failed. Don't rely on that backup.

6. Copy `restore-omarchy.sh` next to the backup, so it's at hand on the live USB:

   ```sh
   cp restore-omarchy.sh "/run/media/$USER/<backup drive>/omarchy/"
   ```

7. Unmount the drive before unplugging it (from the file manager, or
   `udisksctl unmount -b /dev/sdXN`).

### Things to know

- **The archive is not encrypted.** Even when the internal disk is LUKS-encrypted, the backup
  is a plain file on the external drive: anyone holding the drive can read your home directory,
  SSH keys, browser profiles and so on. Keep the drive safe, or put the backup on an encrypted
  volume.
- Running it twice on the same day overwrites that day's folder.
- **Don't edit the script while it runs.** bash reads a script as it goes, so a mid-run edit
  can make it execute a garbled line. Stop it (Ctrl+C) and start again.
- To pull single files out without restoring everything:

  ```sh
  grep '.config/hypr' meta/archive-listing.txt
  mkdir -p /tmp/out && tar --zstd -xf system.tar.zst -C /tmp/out ./home/<user>/.config/hypr
  ```

---

## Restore: `restore-omarchy.sh`

### What it does

**Destroys everything on the target disk** and rebuilds it from a backup folder:

1. Reads `meta/layout.env`, checks the archive checksum and the metadata, shows a summary and
   waits for you to type the disk name (e.g. `nvme0n1`).
2. Writes the saved partition table: same layout, same PARTUUIDs. Kernel command lines often
   find the encrypted partition by PARTUUID (Omarchy's does).
3. Formats the ESP with its old serial, so the `/etc/fstab` entry still matches.
4. Restores the saved **LUKS header**. You unlock with the passphrase the disk had when the
   backup was taken, and the LUKS UUID is unchanged.
5. Creates btrfs with the old UUID and the same subvolumes (snapshots excluded), and mounts
   them the way the saved fstab does.
6. Extracts the archive with owners, permissions, ACLs and xattrs. The ESP is extracted in a
   second pass without those, because FAT can't store them.
7. Optional, T1 Macs: replaces `EFI/APPLE` on the ESP with a folder you supply. The old one
   is kept as `EFI/APPLE.from-backup`.
8. Recreates the swapfile. If its position changed, it updates `resume_offset=` in the text
   config and regenerates the boot images in a chroot (`limine-update`, else `mkinitcpio -P`).
   Binary boot images are never patched; Limine checks their hashes.
9. Recreates the firmware boot entry the system had booted from, if it's missing.

Because every identifier is reproduced, nothing inside the restored system (fstab, crypttab,
boot loader config, initramfs) needs editing.

Not restored: snapper snapshots (old snapshot entries in the boot menu will fail; the normal
entry is fine), Omarchy's `@factory` snapshot (never part of the archive, so Omarchy's factory
reset won't be available), the pacman cache and `~/.cache` (they refill).

### What you need

- The backup drive.
- A USB stick with the **Arch Linux ISO** ([archlinux.org/download](https://archlinux.org/download/)).
  Write it with `sudo dd if=archlinux-*.iso of=/dev/sdX bs=4M status=progress oflag=sync`
  (`/dev/sdX` = the whole stick, which gets erased).
- On Macs with only USB-C: adapters or a hub, so the stick and the backup drive can be
  connected at once. A USB keyboard is a good fallback if the built-in one isn't detected.
- The LUKS passphrase from when the backup was taken.
- Optional, T1 Macs: a new `EFI/APPLE` folder on the backup drive or another stick.

### Step by step

1. **Boot the live USB.** On a Mac, power on holding **⌥ (Option)** and choose the orange
   **EFI Boot** entry for the stick. Elsewhere, use the firmware boot menu. You land at a
   root shell (`root@archiso`).

2. **Mount the backup drive:**

   ```sh
   lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL
   mkdir -p /mnt/backup
   mount /dev/sdXN /mnt/backup           # the backup drive's data partition
   ls /mnt/backup/omarchy/               # full-YYYY-MM-DD folders + restore-omarchy.sh
   ```

   If you didn't copy the script next to the backup, get it from the archive (this reads
   through the whole archive, so it takes a few minutes):

   ```sh
   tar --zstd -xf /mnt/backup/omarchy/full-YYYY-MM-DD/system.tar.zst -C /tmp \
       --wildcards '*/restore-omarchy.sh'
   find /tmp -name restore-omarchy.sh
   ```

3. **Run it.** The target defaults to the disk the backup came from; check with `lsblk` that
   the name still matches (on a Mac the internal disk is the `APPLE SSD`).

   ```sh
   bash /mnt/backup/omarchy/restore-omarchy.sh /mnt/backup/omarchy/full-YYYY-MM-DD
   ```

   To restore to a different disk, or to install a new T1 firmware folder at the same time:

   ```sh
   bash restore-omarchy.sh /mnt/backup/omarchy/full-YYYY-MM-DD /dev/nvme0n1 /mnt/stick/APPLE
   ```

   Type the disk name at the prompt, enter the LUKS passphrase when `cryptsetup open` asks,
   and wait for `Restore finished.`

4. **Power off fully** (`poweroff`), remove the stick, then power on. On a T1 Mac this
   matters: the T1 only loads its firmware at power-on, and `reboot` doesn't power-cycle it.

5. If the Mac boots macOS (or the wrong disk), hold **⌥** at power-on and pick **EFI Boot**.
   To make Linux the default again, reorder with `sudo efibootmgr -o XXXX,...` (see the numbers
   with `efibootmgr`), or use Startup Disk in macOS.

### After the restore, check

```sh
findmnt -t btrfs,vfat          # root, /home and the other subvolumes, plus the ESP, mounted
swapon --show                  # swapfile active
dkms status                    # out-of-tree modules built for the running kernel
```

On a T1 MacBook with t1bridge and the Wi-Fi NVRAM fix:

```sh
sudo t1bridge status                       # T1 healthy
cat /sys/bus/usb/devices/1-3/idProduct     # 8600 (1281 = T1 stuck in recovery mode)
ip link show wlp3s0                        # MAC not 00:90:4c:... (board NVRAM loaded)
```

---

## T1 MacBook Pro notes (2016/2017 Touch Bar models)

### Where the Touch Bar firmware lives

The T1 has no firmware of its own. At every power-on the Mac's boot ROM loads it from the
ESP, from `EFI/APPLE/EMBEDDEDOS/` (`combined.memboot`, `FDRData`, `version.plist`). Installers
that reformat the ESP delete it. [t1-revive](https://github.com/niconistal/t1-revive) can
regenerate it from Linux; it installs one pinned firmware build (EmbeddedOS bundle 901, from a
2020 High Sierra update). A full macOS install writes Apple's current build instead. **Keep a
copy of `EFI/APPLE` somewhere off the disk.** The backup script includes it in the archive.

### The Touch Bar cutoff

On this machine the panel reports 2170 px, but only the first ~2060 px light up, with the
stock renderer and custom ones alike. Testing ruled out the renderer, the t1bridge daemon
and the `appletbdrm` kernel driver: a frame update covering only the last 110 px leaves them
dark, and the size comes from the T1's own reply. The remaining suspect is the T1 firmware.
The plan to test that:

1. Back up with `backup-omarchy.sh`.
2. Install macOS to an **external** drive via Internet Recovery (⌥⌘R) and boot it to the
   desktop once, so Apple writes its current T1 firmware to an ESP.
3. Copy the new `EFI/APPLE` back to the Linux ESP (below). If the macOS install damaged the
   internal disk, use `restore-omarchy.sh` and pass it the new folder instead.

### Swapping only the T1 firmware (no restore)

1. In macOS, find which ESP got the new files and copy the `EFI/APPLE` folder to a drive:

   ```sh
   diskutil list                    # EFI partitions: internal disk0s1, external diskNs1
   sudo diskutil mount disk0s1      # then check the external one too
   cat /Volumes/EFI/EFI/APPLE/EMBEDDEDOS/version.plist
   ```

2. Back in Linux:

   ```sh
   sudo mv /boot/EFI/APPLE /boot/EFI/APPLE.previous      # keep the old one
   sudo cp -r /path/to/new/APPLE /boot/EFI/APPLE
   ```

3. Power off, wait a few seconds, power on. To go back, swap the folders again.

### Installing macOS to an external drive: notes from research

- The installer may stage Mac firmware updates in `EFI/APPLE/FIRMWARE` on the **internal**
  ESP. That's a file write, not a reformat; no report was found of it erasing the ESP.
- High Sierra and later may refuse with *"You may not install to this volume because the
  computer is missing a firmware partition"* when the internal disk has no APFS/HFS+ volume.
  The usual advice online is to erase the internal disk. **Don't.** Instead, shrink the Linux
  partitions and add a small APFS one, or restore afterwards with these scripts.
- In Disk Utility, use View → Show All Devices and erase only the external target. Unplug
  the backup drive first.
- The T1 files are only written after macOS boots fully to the desktop; reaching the Recovery
  menu isn't enough. Internet Recovery itself only draws an Esc key on the Touch Bar, so it
  can't show whether the cutoff is fixed.

### Related projects

- [t1bridge](https://github.com/standardagents/t1bridge): T1 driver stack (Touch Bar, Touch ID, camera)
- [t1-revive](https://github.com/niconistal/t1-revive): regenerate T1 firmware from Linux
- [nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1): Omarchy on T1 MacBooks, Wi-Fi NVRAM fix
- [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro): speaker driver for the Cirrus CS8409 codec

---

## Not in this repo

`.gitignore` keeps local-only files out:

- `snd_hda_macbookpro/`: a clone of the upstream speaker driver. If DKMS was installed from
  it, DKMS points at that folder, so don't move it.
- `brcmfmac*.txt`: Wi-Fi board NVRAM. It contains the machine's real MAC address.
- Backups (`full-*/`, `*.tar.zst`, `*.img`), in case one ends up in this folder.
