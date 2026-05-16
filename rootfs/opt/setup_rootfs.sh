#!/bin/bash

# setup_rootfs.sh - Debian/Ubuntu in-chroot setup
# shimboot-gentoo-2: verbose, max debug

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

_log "shimboot-gentoo-2 :: in-chroot Debian/Ubuntu setup"
_log "  release  : $release_name"
_log "  arch     : $arch"
_log "  hostname : ${hostname:-<prompt>}"
_log "  username : ${username:-<prompt>}"

custom_repo="https://shimboot.ading.dev/debian"
custom_repo_domain="shimboot.ading.dev"
sources_entry="deb [trusted=yes arch=$arch] ${custom_repo} ${release_name} main"

export DEBIAN_FRONTEND="noninteractive"

_step "Adding shimboot apt repo"
echo -e "${sources_entry}\n$(cat /etc/apt/sources.list)" > /etc/apt/sources.list
tee -a /etc/apt/preferences << END
Package: *
Pin: origin ${custom_repo_domain}
Pin-Priority: 1001
END
_log "shimboot repo added: $custom_repo"

if [ "$arch" = "amd64" ]; then
  _step "Enabling i386 architecture (for Steam)"
  dpkg --add-architecture i386
  _log "i386 added."
fi

_step "Installing CA certificates"
apt-get install -y ca-certificates 2>&1 | while IFS= read -r line; do _dbg "apt: $line"; done

_step "Running apt-get update"
apt-get update 2>&1 | while IFS= read -r line; do _dbg "apt: $line"; done

_step "Installing patched systemd"
apt-get upgrade -y --allow-downgrades 2>&1 | while IFS= read -r line; do _dbg "apt: $line"; done
installed_systemd="$(dpkg-query -W -f='${binary:Package}\n' | grep "systemd")"
_log "Reinstalling systemd packages: $installed_systemd"
apt-get clean
apt-get install -y --reinstall --allow-downgrades $installed_systemd 2>&1 | \
  while IFS= read -r line; do _dbg "apt: $line"; done

_step "Enabling shimboot systemd service"
systemctl enable kill-frecon.service && _log "kill-frecon.service enabled" \
  || _warn "Could not enable kill-frecon.service"

if [ -z "$disable_base_pkgs" ]; then
  _step "Installing base packages"
  apt-get install -y \
    cloud-utils zram-tools sudo command-not-found bash-completion \
    libfuse2 libfuse3-* 2>&1 | while IFS= read -r line; do _dbg "apt: $line"; done

  _log "Configuring zram"
  echo "ALGO=lzo" >> /etc/default/zramswap
  echo "PERCENT=100" >> /etc/default/zramswap

  if which apt-file >/dev/null 2>&1; then
    apt-file update 2>&1 | while IFS= read -r line; do _dbg "apt-file: $line"; done
  else
    apt-get update 2>&1 | while IFS= read -r line; do _dbg "apt: $line"; done
  fi
fi

_step "Setting hostname"
if [ -z "$hostname" ]; then
  read -rp "Enter hostname: " hostname
fi
echo "${hostname}" > /etc/hostname
tee -a /etc/hosts << END
127.0.0.1   localhost
127.0.1.1   ${hostname}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
END
_log "Hostname: $hostname"

_step "Installing desktop and custom packages: $packages"
apt-get install -y $packages 2>&1 | while IFS= read -r line; do _dbg "apt: $line"; done

_log "Disabling SELinux"
echo "SELINUX=disabled" >> /etc/selinux/config 2>/dev/null || true

_step "Creating user: $username"
if [ -z "$username" ]; then
  read -rp "Enter username: " username
fi
useradd -m -s /bin/bash -G sudo "$username"
_log "User $username created."

_set_password() {
  local user="$1"
  local password="$2"
  if [ -z "$password" ]; then
    _log "Interactive password for $user:"
    while ! passwd "$user"; do _warn "Retry..."; done
  else
    yes "$password" | passwd "$user"
    _log "Password set for $user"
  fi
}

if [ "$enable_root" ]; then
  _step "Enabling root login"
  _set_password root "$root_passwd"
else
  usermod -a -G sudo "$username"
fi

_step "Setting user password"
_set_password "$username" "$user_passwd"

_step "Cleaning apt caches"
apt-get clean
_log "apt cache cleaned."

_step "Adding shimboot greeter"
echo "/usr/local/bin/shimboot_greeter" >> "/home/$username/.bashrc"
_log "Greeter added to .bashrc"

_log "Debian in-chroot setup COMPLETE"
