#!/bin/bash

# build_complete.sh - Full end-to-end shimboot-gentoo-2 build
# Downloads shim + reco, builds Gentoo rootfs, assembles image
# shimboot-gentoo-2: maximum debug, binary-only Gentoo

. ./common.sh
. ./image_utils.sh
setup_error_trap

print_help() {
  echo "Usage: ./build_complete.sh board_name [key=value ...]"
  echo ""
  echo "Positional:"
  echo "  board_name     - Chrome OS board name (e.g. 'dedede', 'octopus')"
  echo ""
  echo "Named arguments:"
  echo "  distro         - Linux distro: 'gentoo' (default), 'alpine', 'debian'"
  echo "  arch           - CPU arch: 'amd64' (default) or 'arm64'"
  echo "  release        - Gentoo: ignored (auto); Alpine: 'edge'/'latest-stable'; Debian: 'bookworm'"
  echo "  hostname       - System hostname (default: shimboot-gentoo)"
  echo "  username       - User name (default: user)"
  echo "  user_passwd    - User password (default: shimboot)"
  echo "  root_passwd    - Root password (only if enable_root is set)"
  echo "  enable_root    - Enable root login"
  echo "  disable_base   - Skip base package installation"
  echo "  custom_packages- Extra packages to install"
  echo "  data_dir       - Working directory (default: ./data)"
  echo "  compress_img   - Compress output image to .zip"
  echo "  quiet          - Suppress progress indicators"
  echo "  luks           - Enable LUKS2 rootfs encryption"
  echo "  rootfs_dir     - Pre-built rootfs directory (skip bootstrap)"
  echo "  jobs           - Parallel jobs for emerge (default: nproc)"
  echo "  profile        - Gentoo profile (default: default/linux/amd64/23.0/no-multilib/openrc)"
}

assert_root
assert_args "$1"
parse_args "$@"

base_dir="$(realpath -m "$(dirname "$0")")"
board="$1"

# ─── Parse args ──────────────────────────────────────────────────────────────
compress_img="${args['compress_img']}"
existing_rootfs_dir="${args['rootfs_dir']}"
quiet="${args['quiet']}"
data_dir="${args['data_dir']}"
arch="${args['arch']-amd64}"
distro="${args['distro']-gentoo}"
luks="${args['luks']}"
jobs="${args['jobs']-$(nproc)}"
profile="${args['profile']-default/linux/amd64/23.0/no-multilib/openrc}"

hostname="${args['hostname']-shimboot-gentoo}"
username="${args['username']-user}"
user_passwd="${args['user_passwd']-shimboot}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
disable_base="${args['disable_base']}"
custom_packages="${args['custom_packages']}"

# ─── Set release based on distro ─────────────────────────────────────────────
release="${args['release']}"
if [ -z "$release" ]; then
  case "$distro" in
    gentoo)  release="gentoo"      ;;
    alpine)  release="edge"        ;;
    debian)  release="bookworm"    ;;
    *)       release="$distro"     ;;
  esac
fi

# ─── ARM detection ───────────────────────────────────────────────────────────
arm_boards="
  corsola hana jacuzzi kukui strongbad nyan-big kevin bob
  veyron-speedy veyron-jerry veyron-minnie scarlet elm
  kukui peach-pi peach-pit stumpy daisy-spring trogdor
"
bad_boards="reef sand pyro"

if echo "$arm_boards" | grep -q "$board"; then
  print_info "Auto-detected ARM64 board: $board"
  arch="arm64"
fi

if echo "$bad_boards" | grep -q "$board"; then
  print_warn "WARNING: Board '$board' has a shim with sh1mmer fix. Image may not boot if enrolled."
  read -rp "Press ENTER to continue or Ctrl+C to abort. "
fi

if [[ "$luks" == "true" && "$arch" == "arm64" ]]; then
  print_error "LUKS2 encryption is not supported on arm64 boards."
  exit 1
fi

print_title "shimboot-gentoo-2 :: build_complete.sh"
print_info "board          : $board"
print_info "distro         : $distro"
print_info "arch           : $arch"
print_info "release        : $release"
print_info "profile        : $profile"
print_info "jobs           : $jobs"
print_info "hostname       : $hostname"
print_info "username       : $username"
print_info "luks           : ${luks:-no}"
print_info "compress_img   : ${compress_img:-no}"

# ─── Host architecture check ─────────────────────────────────────────────────
kernel_arch="$(uname -m)"
host_arch="unknown"
if [ "$kernel_arch" = "x86_64" ]; then host_arch="amd64"
elif [ "$kernel_arch" = "aarch64" ]; then host_arch="arm64"
fi
print_info "Host arch: $host_arch (kernel: $kernel_arch)"

# ─── Dependency check ────────────────────────────────────────────────────────
needed_deps="wget python3 unzip zip git cpio binwalk pcre2grep cgpt mkfs.ext4 mkfs.ext2 fdisk depmod findmnt lz4 pv cryptsetup tar"
if [ "$distro" = "gentoo" ]; then
  needed_deps="$needed_deps sha256sum"
elif [ "$distro" = "debian" ]; then
  needed_deps="$needed_deps debootstrap"
fi

missing="$(check_deps "$needed_deps")"
if [ "$missing" ]; then
  if [ -f "/etc/debian_version" ]; then
    print_warn "Installing missing build deps on Debian/Ubuntu..."
    apt-get install -y \
      wget python3 unzip zip debootstrap cpio binwalk pcre2grep cgpt kmod pv lz4 cryptsetup \
      2>&1 | while IFS= read -r line; do print_debug "  apt: $line"; done
  fi
  assert_deps "$needed_deps"
fi

# Install qemu for cross-arch builds
if [ "$arch" != "$host_arch" ]; then
  print_warn "Cross-arch build: $host_arch -> $arch. Checking for qemu-user-static..."
  if [ -f "/etc/debian_version" ]; then
    if ! dpkg --get-selections | grep -v deinstall | grep "qemu-user-static\|box64\|fex-emu" >/dev/null 2>&1; then
      print_info "Installing qemu-user-static for cross-arch builds..."
      apt-get install -y qemu-user-static binfmt-support
    fi
  else
    print_warn "Not Debian-based; ensure qemu-user-static is installed for cross-arch builds."
  fi
fi

# ─── Paths ────────────────────────────────────────────────────────────────────
if [ -z "$data_dir" ]; then
  data_dir="$base_dir/data"
else
  data_dir="$(realpath -m "$data_dir")"
fi
mkdir -p "$data_dir"
print_info "Data dir: $data_dir"

shim_bin="$data_dir/shim_${board}.bin"
shim_zip="$data_dir/shim_${board}.zip"
shim_dir="$data_dir/shim_${board}_chunks"
reco_bin="$data_dir/reco_${board}.bin"
reco_zip="$data_dir/reco_${board}.zip"
rootfs_dir="$data_dir/rootfs_${board}_${distro}"
output_img="$data_dir/shimboot_${board}_${distro}.img"

print_info "Paths:"
print_info "  shim_bin    : $shim_bin"
print_info "  reco_bin    : $reco_bin"
print_info "  rootfs_dir  : $rootfs_dir"
print_info "  output_img  : $output_img"

# ─── SIGINT cleanup ──────────────────────────────────────────────────────────
cleanup_path=""
sigint_handler() {
  print_warn "Build interrupted by user (SIGINT)."
  if [ "$cleanup_path" ]; then
    print_warn "Cleaning up: $cleanup_path"
    rm -rf "$cleanup_path"
  fi
  exit 1
}
trap sigint_handler SIGINT

# ─── Board / shim URL helpers ─────────────────────────────────────────────────
boards_url="https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=ChromeOS"

extract_zip() {
  local zip_path="$1"
  local bin_path="$2"
  cleanup_path="$bin_path"
  print_info "Extracting: $zip_path -> $bin_path"
  local total_bytes
  total_bytes="$(unzip -lq "$zip_path" | tail -1 | xargs | cut -d' ' -f1)"
  if [ ! "$quiet" ]; then
    unzip -p "$zip_path" | pv -s "$total_bytes" > "$bin_path"
  else
    unzip -p "$zip_path" > "$bin_path"
  fi
  rm -rf "$zip_path"
  cleanup_path=""
  print_info "Extracted: $bin_path ($(du -h "$bin_path" | cut -f1))"
}

download_and_unzip() {
  local url="$1"
  local zip_path="$2"
  local bin_path="$3"
  if [ ! -f "$bin_path" ]; then
    if [ ! "$quiet" ]; then
      wget -q --show-progress "$url" -O "$zip_path" -c
    else
      wget -q "$url" -O "$zip_path" -c
    fi
    extract_zip "$zip_path" "$bin_path"
  else
    print_info "Already downloaded: $bin_path ($(du -h "$bin_path" | cut -f1))"
  fi
}

download_shim() {
  print_step "Downloading shim file manifest"
  local boards_index
  boards_index="$(curl --no-progress-meter "https://cdn.cros.download/boards.txt")"
  local shim_url_path
  shim_url_path="$(echo "$boards_index" | grep "/$board/").manifest"
  local shim_url_dir
  shim_url_dir="$(dirname "$shim_url_path")"
  local shim_manifest
  shim_manifest="$(curl --no-progress-meter "https://cdn.cros.download/$shim_url_path")"
  local py_load="import json, sys; manifest = json.load(sys.stdin)"

  local zip_size
  zip_size="$(echo "$shim_manifest" | python3 -c "$py_load; print(manifest['size'])")"
  local zip_size_pretty
  zip_size_pretty="$(echo "$zip_size" | numfmt --format %.2f --to=iec)"
  local shim_chunks
  shim_chunks="$(echo "$shim_manifest" | python3 -c "$py_load; print('\n'.join(manifest['chunks']))")"
  local chunk_count
  chunk_count="$(echo "$shim_chunks" | wc -l)"
  local chunk_size=$(( 25 * 1024 * 1024 ))

  print_info "Shim: $zip_size_pretty across $chunk_count chunks"
  mkdir -p "$shim_dir"

  local i=0
  for shim_chunk in $shim_chunks; do
    local chunk_url="https://cdn.cros.download/$shim_url_dir/$shim_chunk"
    local chunk_path="$shim_dir/$shim_chunk"
    i=$(( i + 1 ))
    if [ -f "$chunk_path" ]; then
      local existing_size
      existing_size="$(du -b "$chunk_path" | cut -f1)"
      if [ "$existing_size" = "$chunk_size" ]; then
        print_debug "  Chunk $i/$chunk_count already complete: $chunk_path"
        continue
      fi
    fi
    print_info "Downloading chunk $i / $chunk_count"
    if [ ! "$quiet" ]; then
      wget -c -q --show-progress "$chunk_url" -O "$chunk_path"
    else
      wget -c -q "$chunk_url" -O "$chunk_path"
    fi
    print_debug "  Chunk $i OK: $chunk_path ($(du -h "$chunk_path" | cut -f1))"
  done

  print_info "Joining shim chunks..."
  cleanup_path="$shim_zip"
  if [ ! -f "$shim_bin" ]; then
    cat "$shim_dir/"* | pv -s "$zip_size" > "$shim_zip"
    rm -rf "$shim_dir"
    cleanup_path=""
    extract_zip "$shim_zip" "$shim_bin"
  fi
  cleanup_path=""
}

# ─── Download recovery image ─────────────────────────────────────────────────
print_title "Downloading ChromeOS recovery image for: $board"
print_info "Fetching board list from Chromium Dash..."
reco_url="$(wget -qO- --show-progress "$boards_url" | python3 -c '
import json, sys

all_builds = json.load(sys.stdin)
board_name = sys.argv[1]
if not board_name in all_builds["builds"]:
    print("Invalid board name: " + board_name, file=sys.stderr)
    sys.exit(1)

board = all_builds["builds"][board_name]
if "models" in board:
    for device in board["models"].values():
        if device["pushRecoveries"]:
            board = device
            break

reco_url = list(board["pushRecoveries"].values())[-1]
print(reco_url)
' "$board")"

print_info "Recovery URL: $reco_url"
download_and_unzip "$reco_url" "$reco_zip" "$reco_bin"

# ─── Download shim image ──────────────────────────────────────────────────────
print_title "Downloading Chrome OS RMA shim for: $board"
if [ ! -f "$shim_bin" ]; then
  download_shim
else
  print_info "Shim already downloaded: $shim_bin ($(du -h "$shim_bin" | cut -f1))"
fi

# ─── Build or reuse rootfs ────────────────────────────────────────────────────
if [ "$existing_rootfs_dir" ]; then
  print_title "Using pre-built rootfs: $existing_rootfs_dir"
  rootfs_dir="$(realpath -m "$existing_rootfs_dir")"
else
  print_title "Building $distro rootfs for board: $board"

  if [ ! -d "$rootfs_dir" ] || [ -z "$(ls -A "$rootfs_dir" 2>/dev/null)" ]; then
    ./build_rootfs.sh "$rootfs_dir" "$release" \
      "distro=$distro" \
      "arch=$arch" \
      "hostname=$hostname" \
      "username=$username" \
      "user_passwd=$user_passwd" \
      "root_passwd=$root_passwd" \
      "enable_root=$enable_root" \
      "disable_base=$disable_base" \
      "custom_packages=$custom_packages" \
      "jobs=$jobs" \
      "profile=$profile"
  else
    print_info "Rootfs already exists, skipping bootstrap: $rootfs_dir"
    print_info "Rootfs size: $(du -sh "$rootfs_dir" | cut -f1)"
    print_warn "Delete $rootfs_dir to force a rebuild."
  fi
fi

# ─── Mark first boot ─────────────────────────────────────────────────────────
touch "$rootfs_dir/etc/shimboot-firstboot" 2>/dev/null || true

# ─── Patch rootfs with kernel modules ────────────────────────────────────────
print_title "Patching rootfs with shim kernel modules"
./patch_rootfs.sh "$shim_bin" "$reco_bin" "$rootfs_dir"

# ─── Build final image ───────────────────────────────────────────────────────
print_title "Building final shimboot image"
./build.sh "$output_img" "$shim_bin" "$rootfs_dir" \
  "arch=$arch" \
  "name=${board}_${distro}" \
  ${luks:+"luks=$luks"} \
  ${quiet:+"quiet=$quiet"}

# ─── Compress ─────────────────────────────────────────────────────────────────
if [ "$compress_img" ]; then
  print_title "Compressing output image"
  output_zip="${output_img%.img}.zip"
  print_info "Compressing $output_img -> $output_zip"
  zip -j "$output_zip" "$output_img"
  print_info "Compressed: $output_zip ($(du -h "$output_zip" | cut -f1))"
  rm "$output_img"
  output_img="$output_zip"
fi

print_title "ALL DONE!"
print_info "Output image : $output_img"
print_info "Image size   : $(du -h "$output_img" | cut -f1)"
print_info ""
print_info "Flash to USB with:"
print_info "  sudo dd if=$output_img of=/dev/sdX bs=4M status=progress oflag=sync"
print_info "Or use the Chromebook Recovery Utility."
