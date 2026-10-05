#!/usr/bin/env bash
# Restore a backup made by backup-omarchy.sh onto a disk, reproducing the
# partition table and PARTUUIDs, the LUKS header (same passphrase), the btrfs
# UUID and the ESP serial, so fstab, crypttab, the kernel command line and the
# boot loader need no edits.
#
# Run from a live USB (e.g. the Arch ISO), NOT from the installed system:
#   sudo bash restore-omarchy.sh BACKUP_DIR [TARGET_DISK] [NEW_EFI_APPLE_DIR]
#
#   BACKUP_DIR         the full-YYYY-MM-DD folder (system.tar.zst + meta/)
#   TARGET_DISK        defaults to the disk the backup was taken from
#   NEW_EFI_APPLE_DIR  Macs only, optional: an EFI/APPLE folder (T1 firmware,
#                      e.g. from a macOS install) to use instead of the backed-up one
#
# EVERYTHING ON THE TARGET DISK IS DESTROYED.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
src=${1:?backup folder required}
m="$src/meta"
[[ -f $m/layout.env ]] || die "$m/layout.env missing: backup made by an older script version, take a new backup"
# shellcheck source=/dev/null
source "$m/layout.env"
for v in DISK ESP_PARTNUM LUKS_PARTNUM ESP_MOUNT MAPPER ROOT_SUBVOL ESP_SERIAL BTRFS_UUID; do
  [[ -n ${!v:-} ]] || die "$v missing from layout.env"
done
disk=${2:-$DISK}
new_apple=${3:-}
mnt=/mnt/restore-target

part() { [[ $disk =~ [0-9]$ ]] && echo "${disk}p$1" || echo "${disk}$1"; }
esp=$(part "$ESP_PARTNUM")
luks=$(part "$LUKS_PARTNUM")
root_name=${ROOT_SUBVOL#/}                                   # @

# --- preflight ---------------------------------------------------------------
for f in system.tar.zst system.tar.zst.sha256 meta/disk.sfdisk meta/luks-header.img \
         meta/fstab meta/btrfs-subvolumes.txt; do
  [[ -e "$src/$f" ]] || die "missing $src/$f"
done
for c in sfdisk wipefs cryptsetup mkfs.btrfs mkfs.fat btrfs tar zstd; do
  command -v $c >/dev/null || die "$c not found on this live system"
done
[[ -b $disk ]] || die "$disk is not a block device"
lsblk -no MOUNTPOINTS "$disk" | grep -q . && die "something on $disk is mounted (are you running from it?)"
[[ $ESP_SERIAL =~ ^[0-9A-F]{4}-[0-9A-F]{4}$ ]] || die "unexpected ESP serial '$ESP_SERIAL'"
grep -q "$BTRFS_UUID" "$m/fstab" || die "btrfs UUID $BTRFS_UUID not in the backed-up fstab"
[[ -z $new_apple || -d $new_apple/EMBEDDEDOS ]] \
  || die "$new_apple has no EMBEDDEDOS folder (pass the APPLE folder itself)"

# Subvolumes to recreate. `btrfs subvolume list /` prints top-level ones by
# name and nested ones relative to the mounted root subvolume (e.g.
# "var/lib/machines" inside @). Keep the top-level ones fstab mounts (not
# snapshots such as Omarchy's @factory, whose contents aren't archived) and
# nested ones except snapper snapshots.
mapfile -t subvols < <(
  while read -r _ _ _ _ _ _ top _ path; do
    if [[ $top == 5 ]]; then
      grep -q "subvol=/\\?$path\\(,\\|[[:space:]]\\)" "$m/fstab" && echo "$path"
    else
      [[ $path == '<FS_TREE>/'* ]] && full=${path#<FS_TREE>/} || full=$root_name/$path
      [[ $full == */.snapshots/* ]] || echo "$full"
    fi
  done < "$m/btrfs-subvolumes.txt" | LC_ALL=C sort)
printf '%s\n' "${subvols[@]}" | grep -qxF "$root_name" || die "root subvolume $root_name not found"

# btrfs mounts from the backed-up fstab: "dir options", root first.
mapfile -t mounts < <(awk -v u="UUID=$BTRFS_UUID" -v d="/dev/mapper/$MAPPER" \
  '!/^#/ && ($1 == u || $1 == d) && $3 == "btrfs" {print $2, $4}' "$m/fstab" | LC_ALL=C sort)
[[ ${mounts[0]%% *} == / ]] || die "no btrfs / entry in the backed-up fstab"

echo "== verifying archive checksum"
( cd "$src" && sha256sum -c system.tar.zst.sha256 )

cat <<EOF

About to ERASE $disk ($(lsblk -dno SIZE,MODEL "$disk")) and restore:
  partition table   from meta/disk.sfdisk (backup taken from $DISK)
  ESP               $esp, serial $ESP_SERIAL, mounted at $ESP_MOUNT
  LUKS              $luks, header from backup (same passphrase as before), opened as $MAPPER
  btrfs             UUID $BTRFS_UUID, subvolumes: ${subvols[*]}
  swapfile          ${SWAPFILE:-none}
  EFI/APPLE         ${new_apple:-as in the backup}
EOF
read -rp "Type the disk name ($(basename "$disk")) to continue: " answer
[[ $answer == "$(basename "$disk")" ]] || die "aborted"

# --- partitions, LUKS, filesystems ------------------------------------------
echo "== partition table"
cryptsetup close "$MAPPER" 2>/dev/null || true
wipefs -a "$disk"
sfdisk "$disk" < "$m/disk.sfdisk"        # restores label-id and PARTUUIDs too
udevadm settle

echo "== ESP"
mkfs.fat -F 32 -i "${ESP_SERIAL/-/}" "$esp"

echo "== LUKS (enter the passphrase the disk had when the backup was taken)"
cryptsetup luksHeaderRestore --batch-mode "$luks" --header-backup-file "$m/luks-header.img"
cryptsetup open "$luks" "$MAPPER"
dev=/dev/mapper/$MAPPER

echo "== btrfs"
mkfs.btrfs -f -U "$BTRFS_UUID" "$dev"
mkdir -p "$mnt"
mount "$dev" "$mnt"
for sv in "${subvols[@]}"; do            # sorted: parents before children
  mkdir -p "$(dirname "$mnt/$sv")"
  btrfs subvolume create "$mnt/$sv"
done
umount "$mnt"

for entry in "${mounts[@]}"; do
  dir=${entry%% *}
  opts=$(sed -E 's/(^|,)subvolid=[0-9]+//' <<<"${entry#* }")
  mkdir -p "$mnt$dir"
  mount -o "$opts" "$dev" "$mnt$dir"
done
mkdir -p "$mnt$ESP_MOUNT"
mount "$esp" "$mnt$ESP_MOUNT"

# --- files -------------------------------------------------------------------
echo "== extracting (takes a while)"
tar --extract --zstd --preserve-permissions --numeric-owner --acls --xattrs \
    --xattrs-include='*' --anchored --exclude=".$ESP_MOUNT/*" \
    --file="$src/system.tar.zst" --directory="$mnt"
# The ESP is FAT: no owners, modes, ACLs or xattrs (its mount options set them).
tar --extract --zstd --no-same-owner --no-same-permissions --no-acls --no-xattrs \
    --file="$src/system.tar.zst" --directory="$mnt" --wildcards ".$ESP_MOUNT/*"

if [[ -n $new_apple ]]; then
  echo "== installing new EFI/APPLE from $new_apple"
  apple=$mnt$ESP_MOUNT/EFI/APPLE
  [[ -d $apple ]] && mv "$apple" "$apple.from-backup"
  mkdir -p "$(dirname "$apple")"
  cp -r "$new_apple" "$apple"
fi

# --- swapfile + hibernation resume offset -----------------------------------
regen_failed=
if [[ -n ${SWAPFILE:-} ]]; then
  echo "== swapfile $SWAPFILE"
  mkdir -p "$(dirname "$mnt$SWAPFILE")"
  btrfs filesystem mkswapfile --size "$SWAPFILE_SIZE" "$mnt$SWAPFILE"
  new_offset=$(btrfs inspect-internal map-swapfile -r "$mnt$SWAPFILE")
  if [[ -n $SWAPFILE_OFFSET && $new_offset != "$SWAPFILE_OFFSET" ]]; then
    echo "   resume_offset $SWAPFILE_OFFSET -> $new_offset"
    while read -r f; do
      [[ -n $f && -f $mnt$f ]] && grep -Iq . "$mnt$f" \
        && sed -i "s/resume_offset=$SWAPFILE_OFFSET\\b/resume_offset=$new_offset/g" "$mnt$f"
    done < "$m/resume-offset-files.txt"
    # Rebuild the boot images (UKIs, boot entries) from the updated config.
    # Binary images are never patched: Limine checks their hashes.
    echo "== regenerating boot images in a chroot"
    if ! command -v arch-chroot >/dev/null; then
      regen_failed="arch-chroot not available"
    elif [[ -x $mnt/usr/bin/limine-update ]]; then
      arch-chroot "$mnt" limine-update || regen_failed="limine-update failed"
    elif [[ -x $mnt/usr/bin/mkinitcpio ]]; then
      arch-chroot "$mnt" mkinitcpio -P || regen_failed="mkinitcpio -P failed"
    else
      regen_failed="no known boot image generator"
    fi
  fi
fi

# --- boot entry ----------------------------------------------------------------
# Recreate the NVRAM entry the system booted from, if the firmware lost it.
if command -v efibootmgr >/dev/null && [[ -s $m/efibootmgr.txt ]]; then
  current=$(awk '/^BootCurrent:/ {print $2}' "$m/efibootmgr.txt")
  line=$(grep -m1 "^Boot${current:-none}" "$m/efibootmgr.txt" || true)
  loader=$(grep -o '\\EFI\\[^[:space:])]*' <<<"$line" | head -1 || true)
  label=$(sed -E 's/^Boot[0-9A-Fa-f]{4}\*? //; s/\t.*//; s/ +HD\(.*//' <<<"$line")
  if [[ -n $loader ]]; then
    if efibootmgr -v 2>/dev/null | grep -qiF "$loader"; then
      echo "== NVRAM boot entry for $loader still exists"
    else
      echo "== NVRAM boot entry: ${label:-Linux} -> $loader"
      efibootmgr --create --disk "$disk" --part "$ESP_PARTNUM" --label "${label:-Linux}" \
        --loader "$loader" >/dev/null || echo "   could not create it; pick the disk from the firmware boot menu"
    fi
  fi
fi

sync
umount -R "$mnt"
cryptsetup close "$MAPPER"
echo
echo "Restore finished. Remove the live USB, power off fully, then power on."
if [[ -n $regen_failed ]]; then
  echo "NOTE: boot images were not regenerated ($regen_failed). The system boots"
  echo "      normally, but resuming from hibernation won't work until you run"
  echo "      'sudo limine-update' (or 'sudo mkinitcpio -P') once after booting."
fi
