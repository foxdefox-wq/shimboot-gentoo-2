#!/bin/bash

# build_squashfs.sh - Build a squashfs-based shimboot image
# shimboot-gentoo-2: verbose

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh
setup_error_trap

print_help() {
  echo "Usage: ./build_squashfs.sh output_path shim_path rootfs_dir"
  echo ""
  echo "Named arguments:"
  echo "  quiet  - suppress progress"
  echo "  arch   - 'arm64' or 'amd64' (default)"
  echo "  name   - partition name"
}

assert_root
assert_deps "cpio binwalk pcre2grep realpath cgpt mkfs.ext4 mkfs.ext2 fdisk lz4 mksquashfs pv"
assert_args "$3"
parse_args "$@"

output_path="$(realpath -m "${1}")"
shim_path="$(realpath -m "${2}")"
rootfs_dir="$(realpath -m "${3}")"
quiet="${args['quiet']}"
arch="${args['arch']-amd64}"
bootloader_part_name="${args['name']}"

print_title "shimboot-gentoo-2 :: build_squashfs.sh"
print_info "output : $output_path"
print_info "shim   : $shim_path"
print_info "rootfs : $rootfs_dir"
print_info "arch   : $arch"

print_step "Building squashfs from rootfs"
squashfs_file="/tmp/shimboot_rootfs.squashfs"
print_info "Creating squashfs: $squashfs_file"
mksquashfs "$rootfs_dir" "$squashfs_file" \
  -comp zstd -Xcompression-level 9 \
  -noappend \
  -processors "$(nproc)" \
  -progress \
  2>&1 | while IFS= read -r line; do print_debug "  mksquashfs: $line"; done
print_info "squashfs created: $(du -h "$squashfs_file" | cut -f1)"

print_step "Reading shim image"
initramfs_dir=/tmp/shim_initramfs
kernel_img=/tmp/kernel.img
rm -rf "$initramfs_dir" "$kernel_img"
extract_initramfs_full "$shim_path" "$initramfs_dir" "$kernel_img" "$arch"

print_step "Patching initramfs"
patch_initramfs "$initramfs_dir"

print_step "Copying squashfs into initramfs"
cp "$squashfs_file" "$initramfs_dir/rootfs.squashfs"
print_info "squashfs placed in initramfs"

rootfs_size="$(du -sm "$rootfs_dir" | cut -f1)"
print_info "Creating disk image..."
create_image "$output_path" 20 "$rootfs_size" "$bootloader_part_name"

print_step "Creating loop device"
image_loop="$(create_loop "${output_path}")"

print_step "Partitioning"
create_partitions "$image_loop" "$kernel_img" "" ""

print_step "Populating partitions"
populate_partitions "$image_loop" "$initramfs_dir" "$rootfs_dir" "$quiet" ""
rm -rf "$initramfs_dir" "$kernel_img" "$squashfs_file"

print_step "Releasing loop device"
losetup -d "$image_loop"

print_title "squashfs build DONE"
print_info "Output: $output_path ($(du -h "$output_path" | cut -f1))"
