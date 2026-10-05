#!/usr/bin/env bash
# Full file-level backup of a running LUKS + btrfs Linux install (Omarchy's
# default layout) to an external drive, plus everything restore-omarchy.sh
# needs to rebuild the disk with identical identifiers.
#
# Usage: sudo bash backup-omarchy.sh DESTINATION_FOLDER
#
# Writes DESTINATION_FOLDER/full-YYYY-MM-DD/ containing:
#   system.tar.zst   everything under / (all mounted btrfs subvolumes and the
#                    ESP), with owners, permissions, ACLs and xattrs; an
#                    archive, so it also works on exFAT/NTFS drives
#   meta/            detected layout, partition table, UUIDs, LUKS header,
#                    fstab, boot entries, swapfile details, package lists
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
dest_root=${1:?destination folder required}
for c in cryptsetup btrfs sfdisk blkid findmnt lsblk tar zstd; do
  command -v $c >/dev/null || die "$c not found"
done

# --- detect the layout -----------------------------------------------------
[[ $(findmnt -no FSTYPE /) == btrfs ]] || die "/ is not btrfs"
root_dev=$(findmnt -no SOURCE / | sed 's/\[.*//')          # /dev/mapper/root
root_subvol=$(findmnt -no FSROOT /)                         # /@
[[ $root_dev == /dev/mapper/* ]] || die "/ is not on a dm-crypt device"
mapper=${root_dev#/dev/mapper/}
luks_part=$(cryptsetup status "$mapper" | awk '$1 == "device:" {print $2}')
cryptsetup isLuks "$luks_part" || die "$luks_part is not LUKS"

esp_mount=
for d in /boot /efi /boot/efi; do
  [[ $(findmnt -no FSTYPE "$d" 2>/dev/null) == vfat ]] && { esp_mount=$d; break; }
done
[[ -n $esp_mount ]] || die "no FAT ESP mounted at /boot, /efi or /boot/efi"
esp_part=$(findmnt -no SOURCE "$esp_mount")

disk=/dev/$(lsblk -dno PKNAME "$luks_part")
[[ /dev/$(lsblk -dno PKNAME "$esp_part") == "$disk" ]] \
  || die "ESP ($esp_part) and LUKS ($luks_part) are on different disks"
partnum() { cat "/sys/class/block/$(basename "$1")/partition"; }

# Swapfile on btrfs (hibernation resume_offset depends on its location).
swapfile=$(awk 'NR > 1 && $2 == "file" {print $1; exit}' /proc/swaps)
swap_size= swap_offset=
if [[ -n $swapfile && $(findmnt -no FSTYPE -T "$swapfile") == btrfs ]]; then
  swap_size=$(stat -c %s "$swapfile")
  swap_offset=$(btrfs inspect-internal map-swapfile -r "$swapfile")
else
  swapfile=
fi

dest="$dest_root/full-$(date +%F)"
m="$dest/meta"
mkdir -p "$m"

echo "== layout: disk $disk, ESP $esp_part at $esp_mount, LUKS $luks_part -> $mapper, root subvolume $root_subvol"
{
  printf '%s=%q\n' DISK "$disk" ESP_PARTNUM "$(partnum "$esp_part")" \
    LUKS_PARTNUM "$(partnum "$luks_part")" ESP_MOUNT "$esp_mount" MAPPER "$mapper" \
    ROOT_SUBVOL "$root_subvol" \
    ESP_SERIAL "$(blkid -s UUID -o value "$esp_part")" \
    BTRFS_UUID "$(blkid -s UUID -o value "$root_dev")" \
    SWAPFILE "$swapfile" SWAPFILE_SIZE "$swap_size" SWAPFILE_OFFSET "$swap_offset"
} > "$m/layout.env"

echo "== metadata -> $m"
sfdisk -d "$disk" > "$m/disk.sfdisk"
blkid > "$m/blkid.txt"
lsblk -o NAME,SIZE,FSTYPE,UUID,PARTUUID,LABEL,MOUNTPOINTS > "$m/lsblk.txt"
cryptsetup luksDump "$luks_part" > "$m/luksdump.txt"
rm -f "$m/luks-header.img"
cryptsetup luksHeaderBackup "$luks_part" --header-backup-file "$m/luks-header.img"
btrfs subvolume list / > "$m/btrfs-subvolumes.txt"
findmnt --real > "$m/findmnt.txt"
cp /etc/fstab "$m/fstab"
cp /etc/crypttab "$m/crypttab" 2>/dev/null || true
cat /proc/cmdline > "$m/cmdline.txt"
efibootmgr -v > "$m/efibootmgr.txt" 2>&1 || true
if command -v pacman >/dev/null; then
  pacman -Qqe > "$m/pkglist-explicit.txt"
  pacman -Qqem > "$m/pkglist-foreign.txt" || true
fi
# Text config files that set resume_offset=; the restore updates these and
# regenerates the boot images from them (it never patches binaries).
grep -rIl 'resume_offset=' /etc 2>/dev/null > "$m/resume-offset-files.txt" || true

echo "== archiving / -> $dest/system.tar.zst (takes a while)"
excludes=(--exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' --exclude='./run/*'
          --exclude='./tmp/*' --exclude='./var/tmp/*' --exclude='./mnt/*' --exclude='./media/*'
          --exclude='./lost+found' --exclude='./.snapshots/*' --exclude='./home/.snapshots/*'
          --exclude='./var/cache/pacman/pkg/*' --exclude='./home/*/.cache/*')
[[ -n $swapfile ]] && excludes+=(--exclude=".$swapfile")
# No --one-file-system: every btrfs subvolume counts as its own filesystem.
tar --create --preserve-permissions --numeric-owner --acls --xattrs --xattrs-include='*' \
    --sparse --zstd --anchored "${excludes[@]}" \
    --file="$dest/system.tar.zst" --directory=/ . \
  || [[ $? -eq 1 ]]   # exit 1 = "file changed as we read it": expected on a live system

echo "== verifying archive"
tar --zstd -tf "$dest/system.tar.zst" > "$m/archive-listing.txt"
count=$(wc -l < "$m/archive-listing.txt")
must=(./etc/fstab ./usr/bin/bash ".$esp_mount/EFI/")
if [[ -n ${SUDO_USER:-} ]]; then
  home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  [[ -d $home ]] && must+=(".$home/")
fi
for f in "${must[@]}"; do
  grep -qxF "$f" "$m/archive-listing.txt" || die "MISSING from archive: $f"
done
( cd "$dest" && sha256sum system.tar.zst > system.tar.zst.sha256 )
sync

echo
echo "done: $count entries, $(du -h "$dest/system.tar.zst" | cut -f1)"
echo "      $dest"
