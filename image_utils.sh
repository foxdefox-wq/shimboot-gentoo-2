#!/bin/bash

# image_utils.sh - Disk image utilities
# shimboot-gentoo-2: based directly on ading2210/shimboot with WSL2 offset-mount support

# CRITICAL: create_loop must ONLY echo the loop device path to stdout.
# Any other output (print_info etc) will corrupt callers that use $(...).
create_loop() {
  local loop_device=$(losetup -f)
  if [ ! -b "$loop_device" ]; then
    # We might run out of loop devices — create one
    # See: https://stackoverflow.com/a/66020349
    local major=$(grep loop /proc/devices | cut -c3)
    local number="$(echo "$loop_device" | grep -Eo '[0-9]+' | tail -n1)"
    mknod $loop_device b $major $number >&2
  fi
  losetup -P $loop_device "${1}" >&2
  # ONLY output the loop device path — nothing else
  echo $loop_device
}

make_bootable() {
  cgpt add -i 2 -S 1 -T 5 -P 10 -l kernel $1
}

partition_disk() {
  local image_path=$(realpath -m "${1}")
  local bootloader_size="$2"
  local rootfs_name="$3"
  (
    echo g

    echo n; echo; echo; echo +1M

    echo n; echo; echo; echo +32M
    echo t; echo; echo FE3A2A5D-4F32-41A7-B725-ACCC3285A309

    echo n; echo; echo; echo "+${bootloader_size}M"
    echo t; echo; echo 3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC

    echo n; echo; echo; echo
    echo x; echo n; echo; echo "shimboot_rootfs:$rootfs_name"; echo r

    echo w
  ) | fdisk $image_path > /dev/null
}

safe_mount() {
  local source="$1"
  local dest="$2"
  local opts="$3"

  umount $dest 2>/dev/null || /bin/true
  rm -rf $dest
  mkdir -p $dest
  if [ "$opts" ]; then
    mount $source $dest -o $opts
  else
    mount $source $dest
  fi
}

# WSL2-compatible partition mount.
# On WSL2, losetup -P does not create /dev/loopNpX sub-devices.
# We detect this and fall back to offset-based mounting.
safe_mount_part() {
  local image_file="$1"   # raw image path (not a loop device)
  local part_num="$2"
  local dest="$3"
  local opts="${4:-}"

  umount "$dest" 2>/dev/null || true
  rm -rf "$dest"
  mkdir -p "$dest"

  # Attach image as loop device (without -P partition scanning initially)
  local loop_dev
  loop_dev=$(losetup -f)
  losetup -P "$loop_dev" "$image_file" 2>/dev/null || losetup "$loop_dev" "$image_file"

  local part_dev="${loop_dev}p${part_num}"

  if [ -b "$part_dev" ]; then
    # Standard Linux: partition device exists
    if [ -n "$opts" ]; then
      mount -o "$opts" "$part_dev" "$dest"
    else
      mount "$part_dev" "$dest"
    fi
    # Store loop dev for cleanup
    echo "$loop_dev" > "/tmp/_smp_loop_${dest//\//_}"
    return 0
  fi

  # WSL2 fallback: compute byte offset from fdisk and mount directly
  print_info "WSL2: $part_dev not available, using offset mount for part $part_num" >&2
  losetup -d "$loop_dev" 2>/dev/null || true

  local sector_size=512
  # fdisk -l prints "Device Start End Sectors Size Type"
  # We want the Start column of the Nth partition line
  local start_sector
  start_sector=$(fdisk -l "$image_file" 2>/dev/null \
    | grep -E '^[^ ]+[[:space:]]+[0-9]' \
    | awk "NR==${part_num} {print \$2}")

  if [ -z "$start_sector" ] || [ "$start_sector" = "0" ]; then
    print_error "Cannot determine offset for partition $part_num of $image_file" >&2
    fdisk -l "$image_file" >&2
    return 1
  fi

  local offset=$(( start_sector * sector_size ))
  print_info "WSL2 offset mount: part $part_num @ sector $start_sector = byte $offset" >&2

  local mount_opts="loop,offset=${offset}"
  [ -n "$opts" ] && mount_opts="${mount_opts},${opts}"
  mount -o "$mount_opts" "$image_file" "$dest"
  # No loop device to track — kernel handles it via -o loop
}

cleanup_mount_part() {
  local dest="$1"
  umount "$dest" 2>/dev/null || true
  local f="/tmp/_smp_loop_${dest//\//_}"
  if [ -f "$f" ]; then
    losetup -d "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  fi
}

create_partitions() {
  local image_loop=$(realpath -m "${1}")
  local kernel_path=$(realpath -m "${2}")
  local is_luks="${3}"
  local crypt_password="${4}"

  # On WSL2, loopNpX devices don't exist — use the image file for offset mounts
  local image_file="${5:-$image_loop}"

  print_info "Formatting partition 1 (stateful, ext4)"
  if [ -b "${image_loop}p1" ]; then
    mkfs.ext4 -F "${image_loop}p1"
  else
    local tmp1=/tmp/fmt_p1_mnt
    safe_mount_part "$image_file" 1 "$tmp1"
    mkfs.ext4 -F "$tmp1" 2>/dev/null || true
    cleanup_mount_part "$tmp1"
    # Direct offset approach for mkfs
    _mkfs_via_offset "$image_file" 1 ext4
  fi

  print_info "Copying kernel to partition 2"
  if [ -b "${image_loop}p2" ]; then
    dd if="$kernel_path" of="${image_loop}p2" bs=1M oflag=sync status=progress
  else
    _dd_via_offset "$image_file" 2 "$kernel_path"
  fi
  make_bootable "$image_loop"

  print_info "Formatting partition 3 (bootloader, ext2)"
  if [ -b "${image_loop}p3" ]; then
    mkfs.ext2 -F "${image_loop}p3"
  else
    _mkfs_via_offset "$image_file" 3 ext2
  fi

  print_info "Formatting partition 4 (rootfs, ext4)"
  if [ "$is_luks" ]; then
    if [ -b "${image_loop}p4" ]; then
      echo "$crypt_password" | cryptsetup luksFormat "${image_loop}p4"
      echo "$crypt_password" | cryptsetup luksOpen "${image_loop}p4" rootfs
    else
      local p4loop
      p4loop=$(_offset_loop "$image_file" 4)
      echo "$crypt_password" | cryptsetup luksFormat "$p4loop"
      echo "$crypt_password" | cryptsetup luksOpen "$p4loop" rootfs
      losetup -d "$p4loop"
    fi
    mkfs.ext4 -F /dev/mapper/rootfs
  else
    if [ -b "${image_loop}p4" ]; then
      mkfs.ext4 -F "${image_loop}p4"
    else
      _mkfs_via_offset "$image_file" 4 ext4
    fi
  fi
}

# Get start sector for partition N from image file
_get_start_sector() {
  local image_file="$1"
  local part_num="$2"
  fdisk -l "$image_file" 2>/dev/null \
    | grep -E '^[^ ]+[[:space:]]+[0-9]' \
    | awk "NR==${part_num} {print \$2}"
}

# Create an offset-based loop device for a partition
_offset_loop() {
  local image_file="$1"
  local part_num="$2"
  local sector
  sector=$(_get_start_sector "$image_file" "$part_num")
  local offset=$(( sector * 512 ))
  local dev
  dev=$(losetup -f)
  losetup -o "$offset" "$dev" "$image_file"
  echo "$dev"
}

# mkfs on a partition via offset loop device
_mkfs_via_offset() {
  local image_file="$1"
  local part_num="$2"
  local fs_type="$3"
  local dev
  dev=$(_offset_loop "$image_file" "$part_num")
  print_info "  mkfs.${fs_type} on offset-loop $dev (WSL2)" >&2
  case "$fs_type" in
    ext4) mkfs.ext4 -F "$dev" ;;
    ext2) mkfs.ext2 -F "$dev" ;;
  esac
  losetup -d "$dev"
}

# dd to a partition via offset loop device
_dd_via_offset() {
  local image_file="$1"
  local part_num="$2"
  local src="$3"
  local dev
  dev=$(_offset_loop "$image_file" "$part_num")
  print_info "  dd $src -> offset-loop $dev (WSL2)" >&2
  dd if="$src" of="$dev" bs=1M oflag=sync status=progress
  losetup -d "$dev"
}

populate_partitions() {
  local image_loop=$(realpath -m "${1}")
  local bootloader_dir=$(realpath -m "${2}")
  local rootfs_dir=$(realpath -m "${3}")
  local quiet="$4"
  local luks_enabled="$5"
  local image_file="${6:-$image_loop}"

  local git_tag="$(git tag -l --contains HEAD 2>/dev/null || true)"
  local git_hash="$(git rev-parse --short HEAD 2>/dev/null || true)"

  # ── Stateful (p1) ──────────────────────────────────────────────────────────
  local stateful_mount=/tmp/shim_stateful
  print_info "Writing stateful (p1)"
  if [ -b "${image_loop}p1" ]; then
    safe_mount "${image_loop}p1" "$stateful_mount"
  else
    safe_mount_part "$image_file" 1 "$stateful_mount"
  fi
  mkdir -p $stateful_mount/dev_image/etc/
  mkdir -p $stateful_mount/dev_image/factory/sh
  touch $stateful_mount/dev_image/etc/lsb-factory
  umount $stateful_mount
  cleanup_mount_part "$stateful_mount"

  # ── Bootloader (p3) ────────────────────────────────────────────────────────
  local bootloader_mount=/tmp/shim_bootloader
  print_info "Writing bootloader (p3)"
  if [ -b "${image_loop}p3" ]; then
    safe_mount "${image_loop}p3" "$bootloader_mount"
  else
    safe_mount_part "$image_file" 3 "$bootloader_mount"
  fi
  cp -arv $bootloader_dir/* "$bootloader_mount"
  if [ ! "$git_tag" ]; then
    printf "$git_hash" > "$bootloader_mount/opt/.shimboot_version_dev"
  fi
  umount "$bootloader_mount"
  cleanup_mount_part "$bootloader_mount"

  # ── Rootfs (p4) ────────────────────────────────────────────────────────────
  local rootfs_mount=/tmp/new_rootfs
  print_info "Writing rootfs (p4) — $(du -sh "$rootfs_dir" | cut -f1)"
  if [ "$luks_enabled" ]; then
    safe_mount /dev/mapper/rootfs $rootfs_mount
  elif [ -b "${image_loop}p4" ]; then
    safe_mount "${image_loop}p4" $rootfs_mount
  else
    safe_mount_part "$image_file" 4 "$rootfs_mount"
  fi

  if [ "$quiet" ]; then
    cp -ar $rootfs_dir/* $rootfs_mount
  else
    copy_progress $rootfs_dir $rootfs_mount
  fi
  umount $rootfs_mount
  cleanup_mount_part "$rootfs_mount"
  if [ "$luks_enabled" ]; then
    cryptsetup close rootfs
  fi
}

create_image() {
  local image_path=$(realpath -m "${1}")
  local bootloader_size="$2"
  local rootfs_size="$3"
  local rootfs_name="$4"

  local padded_rootfs=$(( rootfs_size * 13 / 10 + 128 ))
  local total_size=$(( 1 + 32 + bootloader_size + padded_rootfs ))

  print_info "Image: ${total_size}M total (rootfs raw=${rootfs_size}M padded=${padded_rootfs}M)"
  rm -rf "${image_path}"
  fallocate -l "${total_size}M" "${image_path}"
  partition_disk $image_path $bootloader_size $rootfs_name
}

patch_initramfs() {
  local initramfs_path=$(realpath -m $1)
  rm "${initramfs_path}/init" -f
  cp -r bootloader/* "${initramfs_path}/"
  find ${initramfs_path}/bin -name "*" -exec chmod +x {} \;
}

clean_loops() {
  local loop_devices="$(losetup -a | awk -F':' {'print $1'})"
  for loop_device in $loop_devices; do
    local mountpoints="$(cat /proc/mounts | grep "$loop_device")"
    if [ ! "$mountpoints" ]; then
      losetup -d $loop_device
    fi
  done
}

copy_progress() {
  local source="$1"
  local destination="$2"
  local total_bytes="$(du -sb "$source" | cut -f1)"
  mkdir -p "$destination"
  tar -cf - -C "${source}" . | pv -f -s $total_bytes | tar -xf - -C "${destination}"
}
