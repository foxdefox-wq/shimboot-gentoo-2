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

# ─── CRITICAL FIX: Disable systemd-tmpfiles OpenRC services ─────────────────
# These are installed by sys-apps/systemd-utils (udev provider) but they:
# 1. Try to talk to systemd D-Bus (which doesn't exist on OpenRC-only system)
# 2. Trigger EPROTO/"Protocol driver not attached" on ChromeOS kernel's pivot_root
# This caused boot to hang forever after "Starting local" in the shimboot selector.
_step "Disabling systemd-tmpfiles services (CRITICAL FIX)"
for svc in systemd-tmpfiles-setup-dev systemd-tmpfiles-setup; do
  rm -f "/etc/init.d/$svc" 2>/dev/null || true
  for rl in boot shutdown default; do
    rm -rf "/etc/runlevels/$rl/$svc" 2>/dev/null || true
  done
  _log "  removed: $svc"
done
_log "  systemd-tmpfiles services disabled"

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

_disable_svc() {
  local svc="$1" runlevel="${2:-default}"
  rc-update del "$svc" "$runlevel" >/dev/null 2>&1 || true
  rm -f "/etc/runlevels/$runlevel/$svc"
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

# R10 FIX: Do NOT enable netmount in default runlevel.
# In Gentoo's OpenRC, NetworkManager provides the "net" virtual only AFTER it
# establishes a connection. On a fresh Chromebook boot with no saved Wi-Fi
# profile, NM stays "inactive" indefinitely. Any service in the default runlevel
# that "need"s "net" (like netmount) will then block OpenRC from completing the
# runlevel transition, causing boot to hang forever after "Starting local".
# netmount is only useful for mounting NFS/CIFS shares at boot — not needed here.
# _enable_svc netmount     default   <-- intentionally disabled

# 4. Networking
_step "Enabling networking services"
_enable_svc dbus           default
_enable_svc NetworkManager default

# R10 FIX: rc.conf tweaks
# - rc_autostart_user="NO" prevents OpenRC 0.62+ from trying to start user
#   sessions via pam_openrc on login. Without elogind/XDG_RUNTIME_DIR this
#   results in a failing "user.user" dynamic service.
# - rc_parallel="YES" speeds up boot slightly (safe for our use case).
_step "Patching /etc/rc.conf"
mkdir -p /etc
# Append only if not already present
grep -qx 'rc_autostart_user="NO"' /etc/rc.conf 2>/dev/null \
  || echo 'rc_autostart_user="NO"' >> /etc/rc.conf
grep -qx 'rc_parallel="YES"'      /etc/rc.conf 2>/dev/null \
  || echo 'rc_parallel="YES"'      >> /etc/rc.conf
_log "  rc.conf patched"

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

# Make NetworkManager usable and force wlan0 managed
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-shimboot.conf <<'NM_EOF'
[main]
auth-polkit=false
plugins=keyfile

[wifi]
scan-rand-mac-address=no

[device]
match-device=interface-name:wlan0
managed=1
NM_EOF

# ─── CRITICAL FIX: Enable agetty on tty2/tty3/tty4 (NOT tty1) ───────────────
# tty1 is bound to frecon-lite's pseudo-TTY via the shim's /dev/console bind-mount.
# Starting agetty on tty1 causes kernel panics or ChromeOS verified-boot watchdog
# reboots. We therefore enable getty only on tty2, tty3, and tty4.
_step "Enabling agetty login services (tty2/tty3/tty4)"
for tty in tty2 tty3 tty4; do
  if [ -e "/etc/init.d/agetty" ]; then
    # Gentoo provides a single agetty init script that takes a TTY argument
    ln -sf /etc/init.d/agetty "/etc/init.d/agetty.$tty" 2>/dev/null || true
    _enable_svc "agetty.$tty" default
  else
    _warn "agetty init script not found — skipping $tty"
  fi
done
_log "  agetty enabled on tty2/tty3/tty4 (tty1 deliberately skipped)"