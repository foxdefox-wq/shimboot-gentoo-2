#!/bin/bash

# build_rootfs_gentoo.sh
# Stage3 + emerge-webrsync + binpkg-ONLY Gentoo bootstrap
# shimboot-gentoo-2: MAXIMUM speed, MINIMAL footprint

. ./common.sh
setup_error_trap

ROOTFS_DIR="${1}"
ARCH="${2:-amd64}"
PROFILE="${3:-default/linux/amd64/23.0/no-multilib/openrc}"
JOBS="${4:-$(nproc)}"

GENTOO_MIRROR="https://distfiles.gentoo.org"
GENTOO_BINHOST="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/"
STAGE3_BASE_URL="${GENTOO_MIRROR}/releases/amd64/autobuilds"
STAGE3_FLAVOR="nomultilib-openrc"

print_title "Gentoo Binary Bootstrap"
print_info "rootfs dir    : $ROOTFS_DIR"
print_info "arch          : $ARCH"
print_info "profile       : $PROFILE"
print_info "jobs          : $JOBS"

assert_deps "wget tar pv"

STAGE3_DIR="/tmp/shimboot_stage3"
mkdir -p "$STAGE3_DIR" "$ROOTFS_DIR"

# ─── Find latest stage3 ──────────────────────────────────────────────────────
print_step "Finding latest stage3 tarball"
LATEST_TXT=""
for flavor in "nomultilib-openrc" "nomultilib" "openrc"; do
  LATEST_URL="${STAGE3_BASE_URL}/latest-stage3-amd64-${flavor}.txt"
  LATEST_TXT="$(wget -qO- "$LATEST_URL")" && break || LATEST_TXT=""
done

[ -z "$LATEST_TXT" ] && { print_error "Could not fetch stage3 manifest."; exit 1; }
STAGE3_PATH="$(echo "$LATEST_TXT" | grep '\.tar\.' | grep -v '^#' | awk '{print $1}' | head -n1)"
STAGE3_URL="${STAGE3_BASE_URL}/${STAGE3_PATH}"
STAGE3_FILENAME="$(basename "$STAGE3_PATH")"
STAGE3_FILE="$STAGE3_DIR/$STAGE3_FILENAME"

# ─── Download stage3 ─────────────────────────────────────────────────────────
if [ ! -f "$STAGE3_FILE" ]; then
  print_step "Downloading stage3"
  wget -q --show-progress -c -O "$STAGE3_FILE" "$STAGE3_URL"
fi

# ─── Extract stage3 ──────────────────────────────────────────────────────────
print_step "Extracting stage3 into $ROOTFS_DIR"
tar --xattrs-include='*.*' --numeric-owner -xJpf "$STAGE3_FILE" -C "$ROOTFS_DIR"

# ─── Portage config ───────────────────────────────────────────────────────────
print_step "Writing portage configuration"
mkdir -p "$ROOTFS_DIR/etc/portage/package.use" \
         "$ROOTFS_DIR/etc/portage/package.accept_keywords" \
         "$ROOTFS_DIR/etc/portage/package.mask" \
         "$ROOTFS_DIR/etc/portage/repos.conf" \
         "$ROOTFS_DIR/etc/portage/env" \
         "$ROOTFS_DIR/etc/portage/package.env"

cat > "$ROOTFS_DIR/etc/portage/make.conf" << MAKECONF
COMMON_FLAGS="-O2 -pipe -march=x86-64"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${JOBS}"
FEATURES="getbinpkg parallel-fetch -ipc-sandbox -network-sandbox -pid-sandbox -usersandbox -sandbox"
BINPKG_FORMAT="gpkg"
PORTAGE_BINHOST="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/"
USE="-doc -man -info -static -debug -test -nls -ipv6 -bluetooth -cups -gtk -gnome -kde -X -wayland -alsa -pulseaudio"
USE="\${USE} ssl pam crypt unicode threads openrc"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="amd64"
MAKECONF

cat > "$ROOTFS_DIR/etc/portage/package.use/shimboot" << 'PKGUSE'
# Force the eudev-style udev provider, never the systemd one
virtual/udev -systemd
virtual/libudev -systemd
sys-apps/systemd-utils udev tmpfiles sysusers
# NetworkManager without systemd / elogind / polkit / cups / gtk
net-misc/networkmanager -systemd -elogind -policykit -bluetooth -modemmanager wifi wext tools -gnutls -ovs -teamd -concheck
net-wireless/wpa_supplicant -gui -qt6 dbus
sys-apps/dbus -systemd -elogind
sys-auth/polkit -systemd -elogind
# ppp without systemd (avoids pulling sys-apps/systemd in via networkmanager)
net-dialup/ppp -systemd
# misc deps that often try to drag in systemd
sys-apps/util-linux -systemd
sys-libs/pam -systemd
PKGUSE

# Hard-mask sys-apps/systemd so portage refuses to even consider it.
# The boot log showed sys-apps/systemd being pulled in by NetworkManager and
# blocking sysvinit / systemd-utils, leaving the rootfs without NM.
cat > "$ROOTFS_DIR/etc/portage/package.mask/shimboot" << 'PKGMASK'
sys-apps/systemd
sys-apps/systemd-sysv
sys-apps/systemd-tmpfiles
PKGMASK

cat > "$ROOTFS_DIR/etc/portage/repos.conf/gentoo.conf" << 'REPOSCONF'
[DEFAULT]
main-repo = gentoo
[gentoo]
location  = /var/db/repos/gentoo
sync-type = webrsync
sync-uri  = https://distfiles.gentoo.org/snapshots/
auto-sync = yes
REPOSCONF

# ─── ChromeOS systemd-utils patches ───────────────────────────────────────────
print_step "Installing ChromeOS systemd-utils patches"
mkdir -p "$ROOTFS_DIR/etc/portage/patches/sys-apps/systemd-utils"
for patch in patches/systemd-*.patch; do
  [ -f "$patch" ] || continue
  cp "$patch" "$ROOTFS_DIR/etc/portage/patches/sys-apps/systemd-utils/$(basename "$patch")"
  print_info "  installed patch: $(basename "$patch")"
done

# Force systemd-utils to be built from source so the patches are applied.
# We no longer pin it to <260 to avoid dependency conflicts with other binpkgs.
cat > "$ROOTFS_DIR/etc/portage/env/from-source.conf" << 'ENV'
FEATURES="${FEATURES} -getbinpkg"
ENV
cat > "$ROOTFS_DIR/etc/portage/package.env/shimboot" << 'PKGENV'
sys-apps/systemd-utils from-source.conf
virtual/udev from-source.conf
virtual/libudev from-source.conf
PKGENV

# ─── Bind mounts ─────────────────────────────────────────────────────────────
unmount_gentoo() {
  for mp in run dev sys proc; do
    mountpoint -q "$ROOTFS_DIR/$mp" && umount -l "$ROOTFS_DIR/$mp" || true
  done
}
trap unmount_gentoo EXIT

for mp in proc sys dev run; do
  mkdir -p "$ROOTFS_DIR/$mp"
  mount --make-rslave --rbind "/$mp" "$ROOTFS_DIR/$mp"
done

cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# ─── Chroot setup ────────────────────────────────────────────────────────────
print_step "Syncing Portage and installing packages"
LC_ALL=C chroot "$ROOTFS_DIR" /bin/bash -c "
  emerge-webrsync --verbose || emerge --sync --quiet
  getuto
  # Build systemd-utils FIRST from source
  emerge --ask=n --verbose --usepkg=n --buildpkg sys-apps/systemd-utils || exit 1
  
  # Install the rest
  RUNTIME_PKGS='sys-apps/sysvinit sys-apps/util-linux sys-apps/shadow sys-apps/openrc sys-apps/kbd sys-process/psmisc sys-process/procps net-misc/networkmanager net-wireless/wpa_supplicant net-wireless/wireless-regdb app-admin/sudo app-editors/nano sys-apps/iproute2 sys-apps/less app-misc/ca-certificates sys-fs/e2fsprogs virtual/udev sys-apps/dbus dev-libs/openssl sys-libs/pam'
  
  emerge --ask=n --verbose -gK --keep-going --binpkg-respect-use=y \$RUNTIME_PKGS || {
    for pkg in \$RUNTIME_PKGS; do
      emerge --ask=n --usepkgonly --getbinpkg --binpkg-respect-use=n \$pkg
    done
  }
"

# ─── Finalize ─────────────────────────────────────────────────────────────────
print_step "Verifying /sbin/init"
if LC_ALL=C strings "$ROOTFS_DIR/sbin/init" 2>/dev/null | grep -qi 'openrc'; then
  print_warn "openrc-init detected, replacing with sysvinit"
  [ -x "$ROOTFS_DIR/sbin/sysvinit-init" ] && ln -sf sysvinit-init "$ROOTFS_DIR/sbin/init"
  [ -x "$ROOTFS_DIR/lib/sysvinit/init" ] && ln -sf /lib/sysvinit/init "$ROOTFS_DIR/sbin/init"
fi

trap - EXIT
unmount_gentoo
print_title "Gentoo rootfs bootstrap COMPLETE"
