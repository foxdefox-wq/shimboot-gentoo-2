# shimboot-gentoo-2 (school fork)

> Boot a **minimal Gentoo Linux** (or Alpine/Debian) from a Chrome OS RMA shim.  
> Fork of [ading2210/shimboot](https://github.com/ading2210/shimboot) — tuned for **speed** and **minimal size**.

---

## Goals

- 🏎️ **Fastest possible build** — 100% binary packages via Gentoo's official binhost  
- 📦 **Minimal size** — No docs, no man, no static libs, no debug symbols, no locale bloat  
- 🐛 **Maximum debug output** — Every script logs what it's doing in detail  
- 🧊 **Beat Alpine in efficiency** — Gentoo + musl (optional) with zero compilation overhead  

---

## Quick Start

```bash
# Clone
git clone https://github.com/foxdefox-wq/shimboot-gentoo-2.git
cd shimboot-gentoo-2

# Full build (replace 'dedede' with your board)
sudo ./build_complete.sh dedede \
  distro=gentoo \
  hostname=mychromebook \
  username=user \
  user_passwd=mypassword
```

The script will:
1. Download the ChromeOS recovery image and RMA shim for your board
2. Bootstrap a minimal Gentoo rootfs using **binary packages only** (no compilation!)
3. Patch in kernel modules from the shim
4. Assemble the final disk image

---

## Why Binary Gentoo?

Gentoo normally requires compiling everything from source, which takes hours.  
We use Gentoo's official **binary package host** (`distfiles.gentoo.org`) to install prebuilt packages — same result in minutes.

Key `make.conf` settings:
```bash
FEATURES="getbinpkg binpkg-request-signature parallel-fetch parallel-install"
PORTAGE_BINHOST="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/"
EMERGE_DEFAULT_OPTS="--jobs=$(nproc) --ask=n --getbinpkg"
```

---

## Minimization Strategy

| Technique | What it removes |
|-----------|----------------|
| `INSTALL_MASK=/usr/share/doc /usr/share/man` | Docs & manpages |
| `USE="-doc -man -info -static -debug -nls"` | Build-time doc/debug flags |
| `strip --strip-debug` on all binaries | Debug symbols |
| Delete `/var/db/repos/gentoo` after install | ~500MB portage tree |
| Delete `/var/tmp/portage` after install | Build temp files |
| Delete `/var/cache/distfiles` | Source tarballs |
| `find ... -name '*.a' -delete` | Static libraries |
| `find ... -name '__pycache__' -delete` | Python bytecache |

---

## Scripts

| Script | Purpose |
|--------|---------|
| `build_complete.sh` | Full end-to-end build |
| `build_rootfs.sh` | Bootstrap the distro rootfs |
| `build_rootfs_gentoo.sh` | Gentoo-specific bootstrap (stage3 + binpkg emerge) |
| `build.sh` | Assemble the final disk image from shim + rootfs |
| `patch_rootfs.sh` | Copy kernel modules/firmware into rootfs |
| `common.sh` | Shared logging and utility functions |
| `image_utils.sh` | Disk image creation and mounting |
| `shim_utils.sh` | Extract kernel/initramfs from Chrome OS shim |

---

## Supported Boards

Any Chrome OS board with a valid RMA shim. Tested on:
- `dedede` (Acer Chromebook 314)
- `octopus`
- `zork`
- ARM: `kukui`, `trogdor`, etc.

---

## Arguments Reference

```bash
sudo ./build_complete.sh BOARD [key=value ...]

  distro=gentoo|alpine|debian   # default: gentoo
  arch=amd64|arm64              # default: amd64 (auto-detected for ARM boards)
  release=...                   # Alpine: edge/latest-stable, Debian: bookworm
  hostname=...                  # default: shimboot-gentoo
  username=...                  # default: user
  user_passwd=...               # default: shimboot
  root_passwd=...               # only if enable_root is set
  enable_root=1                 # unlock root login
  jobs=N                        # parallel emerge jobs (default: nproc)
  profile=...                   # Gentoo profile (default: default/linux/amd64/23.0/no-multilib/openrc)
  compress_img=1                # zip the output image
  luks=1                        # LUKS2-encrypt the rootfs (amd64 only)
  rootfs_dir=PATH               # skip bootstrap, use existing rootfs
  data_dir=PATH                 # working directory (default: ./data)
  quiet=1                       # suppress progress bars
```

---

## Troubleshooting

### "No space left on device" during emerge
The rootfs partition was too small. `image_utils.sh` now adds **30% + 128MB** padding automatically. If still failing, try:
```bash
# Pre-build with more space, then use existing rootfs
sudo ./build_complete.sh dedede rootfs_dir=./data/rootfs_dedede_gentoo
```

### "Invalid Repository Location: /var/db/repos/gentoo"
This is harmless during the first `emerge-webrsync` — portage hasn't synced yet. The build handles it automatically.

### Build is slow
Make sure you have a fast internet connection. All packages come from Gentoo's CDN. The `build_rootfs_gentoo.sh` script uses `--jobs=$(nproc)` for parallel installation.

---

## Credits

- [ading2210/shimboot](https://github.com/ading2210/shimboot) — original project
- Gentoo Linux project for their binary package host
