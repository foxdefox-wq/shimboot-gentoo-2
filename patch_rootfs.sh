#!/bin/bash

# patch_rootfs.sh - Copy kernel modules and firmware into the rootfs
# shimboot-gentoo-2: verbose, debug

. ./common.sh
. ./image_utils.sh
setup_error_trap

print_help() {
  echo "Usage: ./patch_rootfs.sh shim_path reco_path rootfs_dir"
}

assert_root
assert_deps "git gunzip depmod"
assert_args "$3"

shim_path=$(realpath -m "$1")
reco_path=$(realpath -m "$2")
target_rootfs=$(realpath -m "$3")
shim_rootfs="/tmp/shim_rootfs"
reco_rootfs="/tmp/reco_rootfs"

print_title "patch_rootfs.sh"
print_info "shim_path    : $shim_path"
print_info "reco_path    : $reco_path"
print_info "target_rootfs: $target_rootfs"

copy_modules() {
  local shim_rootfs=$(realpath -m "$1")
  local reco_rootfs=$(realpath -m "$2")
  local target_rootfs=$(realpath -m "$3")

  print_step "Copying kernel modules from shim"
  rm -rf "${target_rootfs}/lib/modules"
  cp -r "${shim_rootfs}/lib/modules" "${target_rootfs}/lib/modules"
  print_info "Modules copied. Size: $(du -sh "${target_rootfs}/lib/modules" | cut -f1)"

  print_step "Copying firmware"
  mkdir -p "${target_rootfs}/lib/firmware"
  cp -r --remove-destination "${shim_rootfs}/lib/firmware/"* "${target_rootfs}/lib/firmware/" 2>&1 | \
    while IFS= read -r line; do print_debug "  cp(shim fw): $line"; done || true
  cp -r --remove-destination "${reco_rootfs}/lib/firmware/"* "${target_rootfs}/lib/firmware/" 2>&1 | \
    while IFS= read -r line; do print_debug "  cp(reco fw): $line"; done || true
  print_info "Firmware copied. Size: $(du -sh "${target_rootfs}/lib/firmware" | cut -f1)"

  print_step "Copying modprobe configuration"
  mkdir -p "${target_rootfs}/lib/modprobe.d/"
  mkdir -p "${target_rootfs}/etc/modprobe.d/"
  cp -r "${reco_rootfs}/lib/modprobe.d/"* "${target_rootfs}/lib/modprobe.d/" 2>/dev/null || true
  cp -r "${reco_rootfs}/etc/modprobe.d/"* "${target_rootfs}/etc/modprobe.d/" 2>/dev/null || true

  print_step "Decompressing kernel modules (if gzip-compressed)"
  local compressed_files
  compressed_files="$(find "${target_rootfs}/lib/modules" -name '*.gz' 2>/dev/null)"
  if [ "$compressed_files" ]; then
    local count
    count="$(echo "$compressed_files" | wc -l)"
    print_info "Decompressing $count .gz module files..."
    echo "$compressed_files" | xargs gunzip
    print_info "Decompression done."
  else
    print_info "No compressed modules found."
  fi

  print_step "Regenerating module dependency/alias indexes"
  for kernel_dir in "${target_rootfs}/lib/modules/"*; do
    [ -d "$kernel_dir" ] || continue
    local version
    version="$(basename "$kernel_dir")"
    print_info "  depmod for kernel: $version"
    depmod -b "${target_rootfs}" "$version" && print_debug "  depmod: OK" \
      || print_warn "  depmod failed for $version"
  done

  print_step "Re-applying shimboot Wi-Fi modprobe override"
  # Recovery images can copy modprobe snippets after setup_rootfs_gentoo.sh ran.
  # Keep our iwlwifi option last so forced module loading still gets ChromeOS
  # firmware debug/init support.
  mkdir -p "${target_rootfs}/etc/modprobe.d"
  cat > "${target_rootfs}/etc/modprobe.d/99-shimboot-wifi.conf" <<'MODPROBE_WIFI_EOF'
options iwlwifi enable_ini=1
MODPROBE_WIFI_EOF
}

copy_firmware() {
  local firmware_path="/tmp/chromium-firmware"
  local target_rootfs=$(realpath -m "$1")

  if [ ! -e "$firmware_path" ]; then
    download_firmware "$firmware_path"
  else
    print_info "Chromium firmware already cached at: $firmware_path"
  fi
  print_info "Copying chromium firmware to rootfs..."
  cp -r --remove-destination "${firmware_path}/"* "${target_rootfs}/lib/firmware/" 2>&1 | \
    while IFS= read -r line; do print_debug "  cp(chromium fw): $line"; done || true
  print_info "Chromium firmware copied."
}

download_firmware() {
  local firmware_url="https://chromium.googlesource.com/chromiumos/third_party/linux-firmware"
  local firmware_path=$(realpath -m "$1")
  print_info "Cloning Chromium firmware repo (shallow clone)..."
  print_warn "This may be large (~2GB). Patience..."
  git clone --branch master --depth=1 "$firmware_url" "$firmware_path" 2>&1 | \
    while IFS= read -r line; do print_debug "  git: $line"; done
  print_info "Firmware clone complete: $(du -sh "$firmware_path" | cut -f1)"
}

print_step "Mounting shim"
shim_loop=$(create_loop "${shim_path}")
print_info "Shim loop: $shim_loop"
safe_mount "${shim_loop}p3" "$shim_rootfs" ro
print_info "Shim mounted at: $shim_rootfs"

print_step "Mounting recovery image"
reco_loop=$(create_loop "${reco_path}")
print_info "Reco loop: $reco_loop"
safe_mount "${reco_loop}p3" "$reco_rootfs" ro
print_info "Recovery mounted at: $reco_rootfs"

print_step "Copying kernel modules and firmware"
copy_modules "$shim_rootfs" "$reco_rootfs" "$target_rootfs"

print_step "Downloading and copying misc Chromium firmware"
copy_firmware "$target_rootfs"

print_step "Unmounting and cleaning up"
umount "$shim_rootfs" && print_info "  shim unmounted"
umount "$reco_rootfs" && print_info "  reco unmounted"
losetup -d "$shim_loop" && print_info "  shim loop released"
losetup -d "$reco_loop" && print_info "  reco loop released"

print_title "patch_rootfs.sh DONE"
print_info "Firmware + modules installed in: $target_rootfs"
