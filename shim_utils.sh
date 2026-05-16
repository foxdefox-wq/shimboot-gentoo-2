#!/bin/bash

# shim_utils.sh - Utilities for reading Chrome OS shim disk images
# Based directly on ading2210/shimboot with added WSL2 offset support

run_binwalk() {
  if binwalk -h | grep -- '--run-as' >/dev/null; then
    binwalk "$@" --run-as=root
  else
    binwalk "$@"
  fi
}

# Extract initramfs from an x86 kernel image
extract_initramfs() {
  local kernel_bin="$1"
  local working_dir="$2"
  local output_dir="$3"

  local kernel_file="$(basename $kernel_bin)"
  local binwalk_out=$(run_binwalk --extract $kernel_bin --directory=$working_dir)
  local stage1_file=$(echo $binwalk_out | pcre2grep -o1 "\d+\s+0x([0-9A-F]+)\s+gzip compressed data")
  local stage1_dir="$working_dir/_$kernel_file.extracted"
  local stage1_path="$stage1_dir/$stage1_file"

  run_binwalk --extract $stage1_path --directory=$stage1_dir > /dev/null
  local stage2_dir="$stage1_dir/_$stage1_file.extracted/"
  local cpio_file=$(file $stage2_dir/* | pcre2grep -o1 "([0-9A-F]+):\s+ASCII cpio archive")
  local cpio_path="$stage2_dir/$cpio_file"

  rm -rf $output_dir
  cat $cpio_path | cpio -D $output_dir -imd --quiet
}

# Extract initramfs from an ARM64 kernel image
extract_initramfs_arm() {
  local kernel_bin="$1"
  local working_dir="$2"
  local output_dir="$3"

  local binwalk_out="$(run_binwalk $kernel_bin)"
  local lz4_offset="$(echo "$binwalk_out" | pcre2grep -o1 "(\d+).+?LZ4 compressed data" | head -n1)"
  local lz4_file="$working_dir/kernel.lz4"
  local kernel_img="$working_dir/kernel_decompressed.bin"
  dd if=$kernel_bin of=$lz4_file iflag=skip_bytes,count_bytes skip=$lz4_offset
  lz4 -d $lz4_file $kernel_img -q || true

  local extracted_dir="$working_dir/_kernel_decompressed.bin.extracted"
  run_binwalk --extract $kernel_img --directory=$working_dir > /dev/null
  local cpio_file=$(file $extracted_dir/* | pcre2grep -o1 "([0-9A-F]+):\s+ASCII cpio archive")
  local cpio_path="$extracted_dir/$cpio_file"

  rm -rf $output_dir
  cat $cpio_path | cpio -D $output_dir -imd --quiet
}

# Copy kernel partition from a shim image.
# On WSL2, /dev/loopNp2 may not exist — fall back to offset-based dd.
copy_kernel() {
  local shim_path="$1"
  local kernel_dir="$2"

  # create_loop only prints the loop device to stdout — no other output
  local shim_loop=$(create_loop "${shim_path}")
  local kernel_loop="${shim_loop}p2"  # KERN-A is always partition 2

  print_info "Kernel loop device: $kernel_loop" >&2

  if [ -b "$kernel_loop" ]; then
    dd if="$kernel_loop" of="$kernel_dir/kernel.bin" bs=1M status=progress
  else
    # WSL2: /dev/loopNp2 doesn't exist — use offset mount
    print_info "WSL2: $kernel_loop not found, using offset dd" >&2

    # Get sector start for partition 2
    local start_sector
    start_sector=$(fdisk -l "$shim_path" 2>/dev/null \
      | grep -E '^[^ ]+[[:space:]]+[0-9]' \
      | awk 'NR==2 {print $2}')

    if [ -z "$start_sector" ] || [ "$start_sector" = "0" ]; then
      print_error "Cannot determine kernel partition offset from shim" >&2
      fdisk -l "$shim_path" >&2
      losetup -d "$shim_loop"
      return 1
    fi

    local offset=$(( start_sector * 512 ))
    print_info "WSL2: kernel partition at sector $start_sector = byte $offset" >&2

    local part_loop
    part_loop=$(losetup -f)
    losetup -o "$offset" "$part_loop" "$shim_path"
    dd if="$part_loop" of="$kernel_dir/kernel.bin" bs=1M status=progress
    losetup -d "$part_loop"
  fi

  losetup -d "$shim_loop"
}

# Copy the kernel then extract the initramfs from it
extract_initramfs_full() {
  local shim_path="$1"
  local rootfs_dir="$2"
  local kernel_bin="$3"
  local arch="$4"
  local kernel_dir=/tmp/shim_kernel

  echo "copying the shim kernel"
  rm -rf $kernel_dir
  mkdir $kernel_dir -p
  copy_kernel $shim_path $kernel_dir

  echo "extracting initramfs from kernel (this may take a while)"
  if [ "$arch" = "arm64" ]; then
    extract_initramfs_arm $kernel_dir/kernel.bin $kernel_dir $rootfs_dir
  else
    extract_initramfs $kernel_dir/kernel.bin $kernel_dir $rootfs_dir
  fi

  if [ "$kernel_bin" ]; then
    cp $kernel_dir/kernel.bin $kernel_bin
  fi
  rm -rf $kernel_dir
}
