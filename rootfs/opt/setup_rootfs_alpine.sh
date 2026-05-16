#!/bin/sh

# setup_rootfs_alpine.sh - Alpine Linux in-chroot setup
# shimboot-gentoo-2: verbose, minimal, fast

DEBUG="$1"
set -e
if [ "$DEBUG" ]; then
  set -x
fi

release_name="$2"
packages="$3"
hostname="$4"
root_passwd="$5"
username="$6"
user_passwd="$7"
enable_root="$8"
disable_base_pkgs="$9"
arch="${10}"

_log()  { printf '\033[1m[SETUP] %s\033[0m\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]  %s\033[0m\n' "$*" >&2; }
_err()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; }
_dbg()  { [ "$DEBUG" ] && printf '\033[1;36m[DBG]   %s\033[0m\n' "$*"; }
_step() { printf '\n\033[1;32m  ---> %s\033[0m\n' "$*"; }

_log "shimboot-gentoo-2 :: in-chroot Alpine setup"
_log "  hostname : ${hostname:-<prompt>}"
_log "  username : ${username:-<prompt>}"
_log "  release  : $release_name"
_log "  arch     : $arch"

_step "Setting up hostname and APK repos"
setup-hostname "$hostname"
setup-apkrepos \
  "http://dl-cdn.alpinelinux.org/alpine/$release_name/main/" \
  "http://dl-cdn.alpinelinux.org/alpine/$release_name/community/"
_log "APK repos configured for $release_name"

_step "Updating package index"
apk update --verbose 2>&1 | while IFS= read -r line; do _dbg "apk: $line"; done
apk upgrade --verbose 2>&1 | while IFS= read -r line; do _dbg "apk: $line"; done

_step "Enabling OpenRC services"
_svc() { rc-update add "$1" "${2:-default}" && _log "  Enabled: $1 @ ${2:-default}" || _warn "  Could not enable: $1"; }
_svc acpid default
_svc bootmisc boot
_svc crond default
_svc devfs sysinit
_svc sysfs sysinit
_svc dmesg sysinit
_svc hostname boot
_svc hwclock boot
_svc hwdrivers sysinit
_svc killprocs shutdown
_svc mdev sysinit
_svc modules boot
_svc mount-ro shutdown
_svc networking boot
_svc savecache shutdown
_svc seedrng boot
_svc swap boot
_svc syslog boot

_step "Installing kill-frecon OpenRC service"
cat > /etc/init.d/kill-frecon << 'SVC'
#!/sbin/openrc-run
description="Kill frecon-lite to allow Xorg to start"
start() {
  ebegin "Killing frecon-lite"
  /usr/local/bin/kill_frecon
  eend $?
}
SVC
chmod +x /etc/init.d/kill-frecon
_svc kill-frecon boot

_step "Installing desktop/packages"
if echo "$packages" | grep "task-" >/dev/null; then
  desktop="$(echo "$packages" | cut -d'-' -f2)"
  _log "Setting up desktop: $desktop"
  setup-desktop "$desktop" 2>&1 | while IFS= read -r line; do _dbg "setup-desktop: $line"; done
else
  _log "Installing packages: $packages"
  apk add --verbose $packages 2>&1 | while IFS= read -r line; do _dbg "apk: $line"; done
fi

_step "Copying modules-load.d to modules"
for mod_file in /etc/modules-load.d/*; do
  [ -f "$mod_file" ] || continue
  _dbg "  Adding modules from: $mod_file"
  cat "$mod_file" >> /etc/modules
  echo >> /etc/modules
done

if [ -z "$disable_base_pkgs" ]; then
  _step "Installing base packages"
  apk add --verbose \
    elogind polkit-elogind udisks2 sudo zram-init \
    networkmanager networkmanager-tui networkmanager-wifi \
    network-manager-applet wpa_supplicant \
    ca-certificates nano bash coreutils \
    2>&1 | while IFS= read -r line; do _dbg "apk: $line"; done

  _log "Enabling base services"
  _svc networkmanager default
  _svc wpa_supplicant default
  _svc zram-init default
  _svc elogind default
  _svc dbus default

  _step "Configuring zram"
  sed -i 's/=zstd/=lzo/' /etc/conf.d/zram-init 2>/dev/null || _warn "Could not set zram algo"
  sed -i '/size0=512/d' /etc/conf.d/zram-init 2>/dev/null || true
  sed -i '/blk1=1024/d' /etc/conf.d/zram-init 2>/dev/null || true
  echo "size0=\`LC_ALL=C free -m | awk '/^Mem:/{print int(\$2/2)}'\`" >> /etc/conf.d/zram-init
  _log "zram configured: size = RAM/2, algo = lzo"

  _step "Configuring NetworkManager"
  mkdir -p /etc/NetworkManager/conf.d
  printf "[main]\nauth-polkit=false\n" > /etc/NetworkManager/conf.d/any-user.conf
  _log "NetworkManager: auth-polkit=false"
fi

_step "Creating user account"
if [ -z "$username" ]; then
  read -rp "Enter username: " username
fi
useradd -m "$username" 2>/dev/null || adduser -D "$username"
usermod -G "netdev,plugdev,audio,video,wheel" -a "$username" 2>/dev/null || \
  addgroup "$username" wheel 2>/dev/null || true
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
_log "User $username created and added to wheel/netdev/plugdev"

_set_password() {
  local user="$1"
  local password="$2"
  if [ -z "$password" ]; then
    _log "Interactive password for $user:"
    while ! passwd "$user"; do _warn "Retry..."; done
  else
    echo "${user}:${password}" | chpasswd 2>/dev/null || \
      yes "$password" | passwd "$user"
    _log "Password set for $user"
  fi
}

if [ "$enable_root" ]; then
  _step "Enabling root and setting root password"
  _set_password root "$root_passwd"
else
  usermod -a -G wheel "$username" 2>/dev/null || true
fi

_step "Setting user password"
_set_password "$username" "$user_passwd"

_step "Adding shimboot greeter to .bashrc"
echo "/usr/local/bin/shimboot_greeter" >> "/home/${username}/.bashrc"
_log "Greeter added."

_log "Alpine in-chroot setup COMPLETE"
_log "  User     : $username"
_log "  Hostname : $hostname"
