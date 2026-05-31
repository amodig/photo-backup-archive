---
name: card-mirror-transfer-path
description: >-
  Advises the fastest path for camera SD card backups (travel SSD vs home NAS)
  using card-mirror.sh on macOS or Ubuntu Linux. Infers home vs travel from mounts.
  Use when backing up a memory card, mirroring DCIM, running card-mirror on a Ubuntu
  host with a NAS share mounted, choosing DEST_ROOT, or diagnosing slow rsync.
---

# Card mirror — fastest transfer path

Before starting or recommending `card-mirror.sh`, **detect host OS and mounts**, then **home vs travel**. Ask only when ambiguous.

**Important:** The **media server is not mounted** — only volumes are: the **SD card** (source) and the **NAS shared folder** (`DEST_ROOT`). On Ubuntu, `DEST_ROOT` is wherever PhotoVault (or equivalent) is mounted via CIFS/NFS.

Scripts run on **macOS** and **Linux** (bash). **Prefer the Ubuntu host** with the card reader + NAS share on Ethernet when at home.

## Path priority (fastest first)

| Rank | Setup | Typical bottleneck |
|------|--------|-------------------|
| 1 | **SD on Ubuntu host** → write to **locally mounted NAS share** | NAS/disk; often 50–100+ MB/s |
| 2 | **Mac Ethernet** → NAS share via SMB3 | LAN |
| 3 | **Mac Wi‑Fi** → NAS share via AFP/SMB | ~15–25 MB/s |
| 4 | **Travel** → rugged SSD (`Extreme SSD`) | USB; offline |

## Mount model

| Role | macOS | Ubuntu host |
|------|--------|-------------|
| Card (source) | `/Volumes/<CARD_ID>` | `/media/$USER/<CARD_ID>` |
| Archive (`DEST_ROOT`) | NAS **share** `/Volumes/Photos/PhotoVault/CardMirror` | NAS **share** e.g. `/mnt/photos/PhotoVault/CardMirror` |

Do not treat the media server hostname as a mount point — only the NAS export path matters for `DEST_ROOT`.

## Detect mounts

### macOS

```bash
ls /Volumes
test -d "/Volumes/Extreme SSD/PhotoVault/CardMirror" && echo travel_dest_ok
test -d "/Volumes/Photos/PhotoVault/CardMirror" && echo nas_share_ok
```

### Ubuntu (NAS share + card only)

```bash
ls /media/$USER /run/media/$USER 2>/dev/null
test -d "$DEST_ROOT" && findmnt -T "$DEST_ROOT"    # should show cifs/nfs, not “server”
```

Set in `config/config.sh`: `DEST_ROOT` = **NAS share mount** on this machine; optional `CARD_MOUNT_ROOTS`.

## Home vs travel inference

| Signal | Scenario | `DEST_ROOT` |
|--------|----------|-------------|
| **Linux** + NAS share mounted + card in `/media/...` | **Home (optimal)** | User’s NAS share path (from config) |
| **Extreme SSD** mounted on Mac | **Travel** | `/Volumes/Extreme SSD/PhotoVault/CardMirror` (even if NAS share also mounted) |
| **Photos** share on Mac, no Extreme SSD | **Home (Mac)** | `/Volumes/Photos/PhotoVault/CardMirror` |
| Neither SSD nor NAS share path ready | **Unknown** | Ask; plug SSD or mount NAS share |

On **Linux at home**, use NAS share `DEST_ROOT` from config — not Mac paths.

## Commands

**Ubuntu host (preferred at home):**

```bash
DEST_ROOT="/mnt/photos/PhotoVault/CardMirror" DRY_RUN=1 \
  ./bin/card-mirror.sh "/media/$USER/A2408A"
```

**macOS NAS share:**

```bash
DEST_ROOT="/Volumes/Photos/PhotoVault/CardMirror" DRY_RUN=1 \
  ./bin/card-mirror.sh "/Volumes/A2408A"
```

**macOS travel:**

```bash
./bin/card-mirror.sh "/Volumes/A2408A"
```

## Card naming

`{OwnerInitial}{YYMM}{Sequence}` — macOS: `diskutil rename`; Linux: `CARD_ID.txt` on card or existing label under `/media/...`.

## This setup

| Host | `DEST_ROOT` |
|------|-------------|
| macOS travel | `/Volumes/Extreme SSD/PhotoVault/CardMirror` |
| macOS home | `/Volumes/Photos/PhotoVault/CardMirror` (NAS **share** via AFP/SMB) |
| Ubuntu home | User’s NAS **share** mount (configure in `config/config.sh`; not `/Volumes/...`) |

Prefer Ubuntu + mounted NAS share over Mac Wi‑Fi AFP for large card mirrors.

## Headless Ubuntu media server

No GNOME automount or `udisksctl` password prompts — one-time install:

```bash
sudo MOUNT_USER=$USER ./bin/install-linux-card-mount.sh
cp config/config.sh.example config/config.sh   # DEST_ROOT = NAS share mount
```

On insert, labeled exfat/vfat cards with a DCIM (or PRIVATE/AVCHD) tree mount at `/media/$USER/<LABEL>`. Logs: `journalctl -t card-automount`.

If automount misses a card, re-plug once or run `udisksctl mount -b /dev/sdX1` (polkit rule allows passwordless mount for `plugdev` after install).
