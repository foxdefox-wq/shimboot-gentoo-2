#!/bin/bash
#
# setup_rootfs_gentoo.sh
# Runs INSIDE the Gentoo chroot to finalize the system.

DEBUG="$1"
set -e
[ "$DEBUG" ] && set -x

RELEASE_NAME="$2"
PACKAGES="$3"
HOSTNAME="$4"
ROOT_PASSWD="$5"
USERNAME="$6"
USER_PASSWD="$7"
ENABLE_ROOT="$8"
DISABLE_BASE_PKGS="$9"
ARCH="${10}"

_log()  { printf '\033[1m[SETUP] %s\033[0m\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]  %s\033[0m\n' "$*" >&2; }
_err()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; }
_step() { printf '\n\033[1;32m  ---> %s\033[0m\n' "$*"; }

_log "shimboot-gentoo-2 :: in-chroot Gentoo setup"

# ─── Hostname ────────────────────────────────────────────────────────────────
_step "Hostname"
[ -z "$HOSTNAME" ] && HOSTNAME="shimboot-gentoo"
echo "${HOSTNAME}" > /etc/hostname
mkdir -p /etc/conf.d
echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname

# ─── Timezone & locale ───────────────────────────────────────────────────────
_step "Timezone (UTC) + locale (en_US.UTF-8)"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime || true
echo "UTC" > /etc/timezone || true
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen || _warn "locale-gen failed"
eselect locale set "en_US.utf8" 2>/dev/null || true

# ─── OpenRC helpers ──────────────────────────────────────────────────────────
_step "Configuring OpenRC services"

_enable_svc() {
  local svc="$1" runlevel="${2:-default}"
  [ -e "/etc/init.d/$svc" ] || { _warn "  service missing: $svc"; return 0; }
  mkdir -p "/etc/runlevels/$runlevel"
  rc-update add "$svc" "$runlevel" >/dev/null 2>&1 \
    || ln -sf "/etc/init.d/$svc" "/etc/runlevels/$runlevel/$svc"
  _log "  enabled: $svc @ $runlevel"
}

_install_stub_service() {
  local svc="$1" provide_name="$2" desc="$3"
  local backup="/etc/init.d/${svc}.shimboot-orig"
  mkdir -p /etc/init.d
  if [ -e "/etc/init.d/$svc" ] && [ ! -e "$backup" ]; then
    mv "/etc/init.d/$svc" "$backup"
  fi
  {
    echo '#!/sbin/openrc-run'
    echo "description=\"${desc}\""
    echo 'depend() {'
    [ -n "$provide_name" ] && echo "  provide ${provide_name}"
    echo '  keyword -shutdown'
    echo '}'
    echo "start() { ebegin \"${desc}\"; eend 0; }"
    echo 'stop() { return 0; }'
  } > "/etc/init.d/$svc"
  chmod +x "/etc/init.d/$svc"
}

# 1. Stub dangerous services
_step "Stubbing dangerous services"
_install_stub_service fsck         ''      "Bypassing fsck on shimboot"
_install_stub_service root         ''      "Bypassing root remount on shimboot"
_install_stub_service hwclock      clock   "Bypassing hardware clock access on shimboot"
_install_stub_service swclock      clock   "Bypassing software clock restore on shimboot"

# R5 FIX: We NO LONGER stub localmount or udev-trigger.
# localmount is needed to mount /run and /tmp as tmpfs from /etc/fstab.
# udev-trigger is CRITICAL for hardware detection (Wi-Fi, etc).
# The previous "cannot speak to running shim udevd" error was likely due to
# /run not being writable (no tmpfs) or a version mismatch that we must solve.

# 2. kill-frecon service
_step "Installing kill-frecon service (NOT auto-enabled)"
cat > /etc/init.d/kill-frecon <<'KILL_FRECON_RC'
#!/sbin/openrc-run
description="Kill frecon-lite to hand off DRM master to Xorg/Wayland"
depend() {
  keyword -shutdown -boot
}
start() {
  ebegin "Killing frecon-lite"
  if [ -x /usr/local/bin/kill_frecon ]; then
    /usr/local/bin/kill_frecon --force || true
  else
    pkill -TERM frecon-lite 2>/dev/null || true
  fi
  eend 0
}
KILL_FRECON_RC
chmod +x /etc/init.d/kill-frecon

# 3. Enable services
_step "Enabling core services"
for s in sysfs devfs dmesg udev udev-trigger; do _enable_svc "$s" sysinit; done
for s in fsck root localmount hwclock loopback hostname sysctl modules; do
  _enable_svc "$s" boot
done
_enable_svc local        default
_enable_svc netmount     default

# 4. Networking
_step "Enabling networking services"
_enable_svc dbus           default
_enable_svc NetworkManager default

# 5. WiFi Drivers (R6 FIX)
_step "Configuring WiFi drivers"
# Jasper Lake / dedede commonly uses Intel CNVi/AX201.  Loading only
# iwlwifi is not enough: iwlwifi is the PCI transport, while iwlmvm is the
# op_mode that actually creates the wlan netdev.  If udev-trigger fails on the
# shimboot mount topology, OpenRC's modules service must load the whole stack.
mkdir -p /etc/conf.d /etc/modprobe.d /etc/NetworkManager/conf.d
cat > /etc/conf.d/modules <<'MODULES_EOF'
# shimboot-gentoo-2: force Chromebook Wi-Fi modules early.
# iwlmvm pulls mac80211; iwlwifi is the Intel transport used on dedede.
modules="cfg80211 mac80211 iwlwifi iwlmvm"
module_iwlwifi_args="enable_ini=1"
MODULES_EOF

# Keep a modprobe.d copy too, because ChromeOS recovery modprobe snippets are
# copied later by patch_rootfs.sh and OpenRC's modules service uses modprobe.
cat > /etc/modprobe.d/99-shimboot-wifi.conf <<'MODPROBE_WIFI_EOF'
options iwlwifi enable_ini=1
MODPROBE_WIFI_EOF

# Belt-and-suspenders loader that runs before NetworkManager.  This handles the
# exact failure mode from the boot log: udev-trigger cannot coldplug, iwlwifi
# loads, but iwlmvm never appears and ip link only shows lo.
cat > /etc/init.d/shimboot-wifi <<'SHIMBOOT_WIFI_RC'
#!/sbin/openrc-run
description="Force-load ChromeOS shim Wi-Fi module stack"

depend() {
  need modules
  before NetworkManager
  keyword -shutdown
}

_has_wifi() {
  ip -o link 2>/dev/null | grep -Eq '^[0-9]+: (wl|wlan|mlan|uap)'
}

start() {
  ebegin "Loading ChromeOS Wi-Fi modules"

  # Do not fail boot if a module is absent on a non-Intel Chromebook.
  modprobe cfg80211 2>/dev/null || true
  modprobe mac80211 2>/dev/null || true
  modprobe iwlwifi enable_ini=1 2>/dev/null || modprobe iwlwifi 2>/dev/null || true
  modprobe iwlmvm 2>/dev/null || true

  # request_module() may have missed iwlmvm when iwlwifi probed before the
  # op_mode was available.  A tiny settle delay is enough on dedede.
  sleep 1

  if ! _has_wifi && lsmod 2>/dev/null | grep -q '^iwlwifi[[:space:]]'; then
    ewarn "iwlwifi loaded but no wlan netdev yet; retrying iwlmvm"
    modprobe iwlmvm 2>/dev/null || true
    sleep 1
  fi

  if _has_wifi; then
    eend 0
  else
    ewarn "No Wi-Fi netdev detected after module load (continuing boot)"
    eend 0
  fi
}
SHIMBOOT_WIFI_RC
chmod +x /etc/init.d/shimboot-wifi
_enable_svc shimboot-wifi boot

# Make NetworkManager usable in this no-polkit/minimal-console environment.
cat > /etc/NetworkManager/conf.d/99-shimboot.conf <<'NM_EOF'
[main]
auth-polkit=false
plugins=keyfile

[device]
wifi.scan-rand-mac-address=no
NM_EOF

# 6. User service fix (R6 FIX)
_step "Disabling OpenRC user services to prevent 'user.user' errors"
# OpenRC 0.62+ autostarts per-user services through pam_openrc by default.
# shimboot does not provide elogind/XDG_RUNTIME_DIR, so opt out globally.
if grep -q '^rc_autostart_user=' /etc/rc.conf 2>/dev/null; then
  sed -i 's/^rc_autostart_user=.*/rc_autostart_user="NO"/' /etc/rc.conf
else
  echo 'rc_autostart_user="NO"' >> /etc/rc.conf
fi
rc-update del user default >/dev/null 2>&1 || true
rc-update del user boot >/dev/null 2>&1 || true
rc-update del user nonetwork >/dev/null 2>&1 || true

# Remove any i915 blacklist
_step "Removing any i915 blacklist"
rm -f /etc/modprobe.d/i915-blacklist.conf 2>/dev/null || true

# Minimal fstab
_step "Writing /etc/fstab"
cat > /etc/fstab <<'FSTAB_EOF'
proc            /proc           proc        nosuid,nodev,noexec   0 0
sysfs           /sys            sysfs       nosuid,nodev,noexec   0 0
devpts          /dev/pts        devpts      gid=5,mode=620        0 0
tmpfs           /dev/shm        tmpfs       nosuid,nodev          0 0
tmpfs           /tmp            tmpfs       nosuid,nodev,size=50% 0 0
tmpfs           /run            tmpfs       nosuid,nodev,mode=755 0 0
FSTAB_EOF

# rc.conf
_step "Hardening /etc/rc.conf"
cat > /etc/rc.conf <<'RCCONF_EOF'
rc_shell="/sbin/sulogin"
rc_parallel="NO"
rc_logger="YES"
rc_sys=""
rc_autostart_user="NO"
clock_hctosys="NO"
clock_systohc="NO"
unicode="YES"
fsck_abort_on_errors="no"
RCCONF_EOF

# ─── inittab ─────────────────────────────────────────────────────────────────
_step "Writing /etc/inittab"
cat > /etc/inittab <<'INITTAB_EOF'
# /etc/inittab :: shimboot-gentoo-2 (R5)
id:3:initdefault:
si::sysinit:/sbin/openrc sysinit
rc::bootwait:/sbin/openrc boot
l0:0:wait:/sbin/openrc shutdown
l1:S1:wait:/sbin/openrc single
l2:2:wait:/sbin/openrc nonetwork
l3:3:wait:/sbin/openrc default
l4:4:wait:/sbin/openrc default
l5:5:wait:/sbin/openrc default
l6:6:wait:/sbin/openrc reboot
ca:12345:ctrlaltdel:/sbin/shutdown -r now
c1:2345:respawn:/sbin/agetty --autologin USER_PLACEHOLDER -L console linux
INITTAB_EOF

# ─── User account ────────────────────────────────────────────────────────────
_step "User account"
[ -z "$USERNAME" ] && USERNAME="user"
for g in wheel audio video usb plugdev netdev users; do
  getent group "$g" >/dev/null 2>&1 || groupadd -r "$g" 2>/dev/null || true
done
if ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$USERNAME" || _warn "useradd failed"
  for g in wheel audio video usb plugdev netdev users; do
    getent group "$g" >/dev/null 2>&1 && gpasswd -a "$USERNAME" "$g" >/dev/null 2>&1 || true
  done
fi
echo "${USERNAME}:${USER_PASSWD:-shimboot}" | chpasswd || true
echo "root:${ROOT_PASSWD:-shimboot}" | chpasswd || true
passwd -u root || true
sed -i "s/USER_PLACEHOLDER/${USERNAME}/" /etc/inittab

# ─── Sudoers ─────────────────────────────────────────────────────────────────
_step "Configuring sudo"
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL"               > /etc/sudoers.d/wheel
echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/shimboot-user
chmod 440 /etc/sudoers.d/wheel /etc/sudoers.d/shimboot-user

# ─── Greeter ─────────────────────────────────────────────────────────────────
_step "Installing shimboot greeter on user login"
if [ -x /usr/local/bin/shimboot_greeter ]; then
  for rcfile in "/root/.bash_profile" "/home/${USERNAME}/.bash_profile"; do
    [ -d "$(dirname "$rcfile")" ] || continue
    if ! grep -q shimboot_greeter "$rcfile" 2>/dev/null; then
      echo '[ -t 0 ] && [ -x /usr/local/bin/shimboot_greeter ] && /usr/local/bin/shimboot_greeter' >> "$rcfile"
    fi
  done
  chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.bash_profile" 2>/dev/null || true
fi

_log "Gentoo setup complete"
