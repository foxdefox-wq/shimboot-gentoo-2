#!/bin/bash

# build.sh - Build the shimboot bootloader image
# shimboot-gentoo-2: max debug, verbose

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh
setup_error_trap

print_help() {
  echo "Usage: ./build.sh output_path shim_path rootfs_dir"
  echo ""
  echo "Named arguments (key=value):"
  echo "  quiet    - Suppress progress bars (useful for log files)"
  echo "  arch     - 'arm64' for ARM Chromebooks, default: amd64"
  echo "  name     - Name for the shimboot rootfs partition"
  echo "  luks     - Encrypt the rootfs with LUKS2"
}

assert_root
assert_deps "cpio binwalk pcre2grep realpath cgpt mkfs.ext4 mkfs.ext2 fdisk lz4 pv"
assert_args "$3"
parse_args "$@"

output_path="$(realpath -m "${1}")"
shim_path="$(realpath -m "${2}")"
rootfs_dir="$(realpath -m "${3}")"

quiet="${args['quiet']}"
arch="${args['arch']-amd64}"
bootloader_part_name="${args['name']}"
luks_enabled="${args['luks']}"

print_title "shimboot-gentoo-2 :: build.sh"
print_info "output_path  : $output_path"
print_info "shim_path    : $shim_path"
print_info "rootfs_dir   : $rootfs_dir"
print_info "arch         : $arch"
print_info "luks         : ${luks_enabled:-no}"

# ─── LUKS password ───────────────────────────────────────────────────────────
if [ "$luks_enabled" ]; then
  print_info "LUKS encryption requested."
  while true; do
    read -rsp "Enter LUKS2 password for the image: " crypt_password
    echo ""
    read -rsp "Retype the password: " crypt_password_confirm
    echo ""
    if [ "$crypt_password" = "$crypt_password_confirm" ]; then
      print_info "Passwords match."
      break
    else
      print_error "Passwords do not match. Please try again."
    fi
  done

  print_step "Downloading shimboot-binaries (cryptsetup)"
  temp_shimboot_binaries="/tmp/shimboot-binaries.tar.gz"
  wget -q --show-progress \
    "https://github.com/ading2210/shimboot-binaries/releases/latest/download/shimboot_binaries_${arch}.tar.gz" \
    -O "$temp_shimboot_binaries"
  tar -xf "$temp_shimboot_binaries" -C "$(realpath -m "bootloader/bin/")" "cryptsetup"
  rm "$temp_shimboot_binaries"
  chmod +x "$(realpath -m "bootloader/bin/")/cryptsetup"
  print_info "cryptsetup installed to bootloader/bin/"
fi

# ─── Extract shim initramfs ──────────────────────────────────────────────────
print_title "Extracting shim initramfs"
initramfs_dir=/tmp/shim_initramfs
kernel_img=/tmp/kernel.img
print_info "Cleaning old extracted data..."
rm -rf "$initramfs_dir" "$kernel_img"

print_info "Reading shim image: $shim_path"
extract_initramfs_full "$shim_path" "$initramfs_dir" "$kernel_img" "$arch"
print_info "Initramfs extracted to: $initramfs_dir"
print_info "Kernel image at: $kernel_img ($(du -h $kernel_img | cut -f1))"

# ─── Patch initramfs ─────────────────────────────────────────────────────────
print_title "Patching initramfs"
patch_initramfs "$initramfs_dir"

# ─── Create disk image ───────────────────────────────────────────────────────
print_title "Creating disk image"
rootfs_size="$(du -sm "$rootfs_dir" | cut -f1)"
print_info "Raw rootfs size: ${rootfs_size}M"

# image_utils.sh::create_image adds 30% + 128M padding automatically
create_image "$output_path" 20 "$rootfs_size" "$bootloader_part_name"
print_info "Disk image created: $output_path ($(du -h "$output_path" | cut -f1))"

# ─── Loop device ─────────────────────────────────────────────────────────────
print_step "Creating loop device"
image_loop="$(create_loop "${output_path}")"
print_info "Loop device: $image_loop"

# ─── Partitions ──────────────────────────────────────────────────────────────
print_title "Creating and formatting partitions"
create_partitions "$image_loop" "$kernel_img" "$luks_enabled" "$crypt_password"

# ─── Populate ────────────────────────────────────────────────────────────────
print_title "Copying data into image partitions"
populate_partitions "$image_loop" "$initramfs_dir" "$rootfs_dir" "$quiet" "$luks_enabled"
rm -rf "$initramfs_dir" "$kernel_img"
print_info "Temporary files cleaned up."

# ─── Release loop device ─────────────────────────────────────────────────────
print_step "Releasing loop device: $image_loop"
losetup -d "$image_loop"
print_info "Loop device released."

print_title "BUILD COMPLETE"
print_info "Output image  : $output_path"
print_info "Image size    : $(du -h "$output_path" | cut -f1)"
