#!/bin/bash

# build_rootfs.sh - Build the Gentoo (or Alpine/Debian) rootfs
# shimboot-gentoo-2: All-binary Gentoo, ultra-minimal, max debug

. ./common.sh
setup_error_trap

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo ""
  echo "Positional arguments:"
  echo "  rootfs_path   - Output path for the rootfs"
  echo "  release_name  - Distro release (e.g. 'gentoo' / 'edge' / 'bookworm')"
  echo ""
  echo "Named arguments (specify as 'key=value'):"
  echo "  distro        - Linux distro: 'gentoo' (default), 'alpine', 'debian'"
  echo "  arch          - CPU arch: 'amd64' (default) or 'arm64'"
  echo "  hostname      - System hostname (prompted if omitted)"
  echo "  username      - Unprivileged user name (prompted if omitted)"
  echo "  user_passwd   - User password (prompted if omitted)"
  echo "  root_passwd   - Root password (only used if enable_root is set)"
  echo "  enable_root   - Enable root login (any value = enabled)"
  echo "  disable_base  - Skip base package installation"
  echo "  custom_packages - Extra packages to install"
  echo "  profile       - Gentoo profile (default: default/linux/amd64/23.0/no-multilib/openrc)"
  echo "  jobs          - Number of parallel make jobs (default: nproc)"
}

assert_root
assert_args "$2"
parse_args "$@"

rootfs_dir=$(realpath -m "${1}")
release_name="${2}"
distro="${args['distro']-gentoo}"
arch="${args['arch']-amd64}"
chroot_mounts="proc sys dev run"

print_title "shimboot-gentoo-2 :: build_rootfs.sh"
print_info "distro     : $distro"
print_info "arch       : $arch"
print_info "release    : $release_name"
print_info "rootfs_dir : $rootfs_dir"
print_info "host kernel: $(uname -r)"
print_info "host arch  : $(uname -m)"

mkdir -p "$rootfs_dir"
print_info "rootfs_dir created/exists: $rootfs_dir"

# ─── Unmount helper ───────────────────────────────────────────────────────────
unmount_all() {
  print_info "Unmounting chroot bind mounts..."
  for mountpoint in $chroot_mounts; do
    if mountpoint -q "$rootfs_dir/$mountpoint" 2>/dev/null; then
      umount -l "$rootfs_dir/$mountpoint" && print_debug "  Unmounted: $rootfs_dir/$mountpoint" \
        || print_warn "  Failed to unmount: $rootfs_dir/$mountpoint"
    fi
  done
}

# ─── Remount helpers ──────────────────────────────────────────────────────────
need_remount() {
  local target="$1"
  local mnt_options
  mnt_options="$(findmnt -T "$target" | tail -n1 | rev | cut -f1 -d' ' | rev)"
  print_debug "Mount options for $target: $mnt_options"
  echo "$mnt_options" | grep -e "noexec" -e "nodev"
}

do_remount() {
  local target="$1"
  local mountpoint
  mountpoint="$(findmnt -T "$target" | tail -n1 | cut -f1 -d' ')"
  print_warn "Remounting $mountpoint with dev,exec permissions"
  mount -o remount,dev,exec "$mountpoint"
}

if [ "$(need_remount "$rootfs_dir")" ]; then
  do_remount "$rootfs_dir"
fi

# ─── Bootstrap distro ─────────────────────────────────────────────────────────
chroot_script=""

if [ "$distro" = "gentoo" ]; then
  print_title "Bootstrapping Gentoo (binary packages only)"
  ./build_rootfs_gentoo.sh "$rootfs_dir" "$arch" "${args['profile']}" "${args['jobs']}"
  chroot_script="/opt/setup_rootfs_gentoo.sh"

elif [ "$distro" = "alpine" ]; then
  print_title "Bootstrapping Alpine Linux"
  assert_deps "wget tar pcre2grep"

  print_step "Downloading Alpine apk-tools-static package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- --show-progress "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | pcre2grep -o1 '"(.+?.apk)"')"
  print_info "apk-tools-static URL: $pkg_url"

  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q --show-progress "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"
  print_info "apk.static extracted to: $apk_static"

  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then
    real_arch="aarch64"
  fi
  print_info "Alpine arch: $real_arch"
  $apk_static \
    --arch "$real_arch" \
    -X "http://dl-cdn.alpinelinux.org/alpine/$release_name/main/" \
    -U --allow-untrusted \
    --root "$rootfs_dir" \
    --initdb add alpine-base
  print_info "Alpine base bootstrapped into: $rootfs_dir"
  chroot_script="/opt/setup_rootfs_alpine.sh"

elif [ "$distro" = "debian" ]; then
  print_title "Bootstrapping Debian"
  assert_deps "debootstrap"
  print_info "Running debootstrap for $release_name ($arch)..."
  debootstrap --arch "$arch" --components=main,contrib,non-free,non-free-firmware \
    "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  print_info "Debootstrap complete."
  chroot_script="/opt/setup_rootfs.sh"

else
  print_error "'$distro' is not a valid distro. Use: gentoo, alpine, or debian"
  exit 1
fi

# ─── Copy rootfs scripts ──────────────────────────────────────────────────────
print_step "Copying shimboot rootfs scripts into chroot"
cp -arv rootfs/* "$rootfs_dir"
# Defensive: ensure the chroot setup scripts and runtime helpers are executable
# even if the repo loses the +x bit (e.g. via zip download or Windows checkout).
chmod +x "$rootfs_dir/opt/"*.sh 2>/dev/null || true
chmod +x "$rootfs_dir/usr/local/bin/"* 2>/dev/null || true
cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"
print_info "resolv.conf: $(cat $rootfs_dir/etc/resolv.conf)"

# ─── Bind mount for chroot ────────────────────────────────────────────────────
print_step "Creating bind mounts for chroot"
trap unmount_all EXIT
for mountpoint in $chroot_mounts; do
  print_debug "  bind mounting: /$mountpoint -> $rootfs_dir/$mountpoint"
  mount --make-rslave --rbind "/$mountpoint" "${rootfs_dir}/$mountpoint"
done
print_info "All chroot bind mounts active."

# ─── Run in-chroot setup script ───────────────────────────────────────────────
hostname="${args['hostname']}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
username="${args['username']}"
user_passwd="${args['user_passwd']}"
disable_base="${args['disable_base']}"
packages="${args['custom_packages']-}"

print_step "Running in-chroot setup script: $chroot_script"
print_info "  hostname     : '${hostname:-<prompt>}'"
print_info "  username     : '${username:-<prompt>}'"
print_info "  enable_root  : '${enable_root:-no}'"
print_info "  disable_base : '${disable_base:-no}'"

chroot_command="$chroot_script \
  '$DEBUG' '$release_name' '$packages' \
  '$hostname' '$root_passwd' '$username' \
  '$user_passwd' '$enable_root' '$disable_base' \
  '$arch'"

LC_ALL=C chroot "$rootfs_dir" /bin/sh -c "${chroot_command}"

trap - EXIT
unmount_all

print_title "Rootfs build complete!"
print_info "Rootfs location : $rootfs_dir"
print_info "Total size      : $(du -sh "$rootfs_dir" | cut -f1)"
