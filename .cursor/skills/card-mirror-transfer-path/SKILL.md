---
name: card-mirror-transfer-path
description: >-
  Advises the fastest path for camera SD card backups (travel SSD vs home NAS)
  using card-mirror.sh on macOS or Ubuntu Linux. Infers home vs travel from mounts.
  Use when backing up a memory card, mirroring DCIM, running card-mirror remotely
  on a media server, choosing DEST_ROOT, or diagnosing slow rsync.
---

# Card mirror — fastest transfer path

Before starting or recommending `card-mirror.sh`, **detect host OS and mounts**, then **home vs travel**. Ask the user only when ambiguous. State `DEST_ROOT`, fastest physical path, and whether to proceed.

Scripts run on **macOS** and **Linux** (bash). **Prefer the Ubuntu media server** with Ethernet to NAS when the card reader can plug in there.

## Path priority (fastest first)

| Rank | Setup | Typical bottleneck |
|------|--------|-------------------|
| 1 | **SD reader on Ubuntu media server** → Ethernet → NAS (local `DEST_ROOT`) | NAS/disk; often 50–100+ MB/s |
| 2 | **Mac on Ethernet** → NAS via **SMB3** | LAN; much better than Wi‑Fi AFP |
| 3 | **Mac on Wi‑Fi** → NAS via AFP/SMB | Network (~15–25 MB/s common) |
| 4 | **Mac / travel** → rugged SSD (`Extreme SSD`) | USB; offline-friendly |

**Avoid** routing a full card through Mac Wi‑Fi + AFP when the media server can take the card directly.

## Detect host and mounts

### macOS

```bash
ls /Volumes
test -d "/Volumes/Extreme SSD/PhotoVault/CardMirror" && echo travel_dest_ok
test -d "/Volumes/Photos/PhotoVault/CardMirror" && echo home_dest_ok
mount | grep -E 'Photos|Extreme SSD'
```

### Ubuntu Linux (media server)

```bash
uname -s   # Linux
ls /media/$USER /run/media/$USER 2>/dev/null
test -d "/mnt/nas/PhotoVault/CardMirror" && echo nas_dest_ok   # example DEST_ROOT
findmnt -T "$DEST_ROOT" 2>/dev/null || true
# Card with DCIM: /media/$USER/A2408A or pass path explicitly
```

Set on the server in `config/config.sh`: `DEST_ROOT` = NAS mount path; optional `CARD_MOUNT_ROOTS="/media/user:/run/media/user"`.

## Home vs travel inference

| Signal | Scenario | `DEST_ROOT` |
|--------|----------|-------------|
| **Linux host** + NAS path exists + card under `/media/...` | **Home (optimal)** | Server NAS mount, e.g. `/mnt/nas/PhotoVault/CardMirror` |
| **Extreme SSD** mounted (writable `CardMirror`) | **Travel** | `/Volumes/Extreme SSD/PhotoVault/CardMirror` — **even if NAS also mounted** |
| **Photos** NAS mounted on Mac, no Extreme SSD | **Home (Mac)** | `/Volumes/Photos/PhotoVault/CardMirror` |
| Both Extreme SSD + Photos on Mac | **Travel** | Prefer **Extreme SSD**; NAS optional later |
| Neither destination | **Unknown** | Ask; suggest SSD or mount NAS |

Do **not** ask home vs travel when **Extreme SSD** is mounted on Mac. On **Linux media server**, default to NAS `DEST_ROOT` when configured.

## Pre-flight checklist

```
Host: [macOS | Linux]
Scenario: [travel | home-mac | home-linux] — [evidence]
DEST_ROOT: [path]
- [ ] Fastest route (media server / Ethernet SMB / travel SSD)?
- [ ] Card ID: {OwnerInitial}{YYMM}{Sequence}?
- [ ] No duplicate rsync running?
```

## Commands

**macOS (NAS from Mac):**

```bash
DEST_ROOT="/Volumes/Photos/PhotoVault/CardMirror" DRY_RUN=1 \
  ./bin/card-mirror.sh "/Volumes/A2408A"
```

**Ubuntu media server (preferred at home):**

```bash
DEST_ROOT="/mnt/nas/PhotoVault/CardMirror" DRY_RUN=1 \
  ./bin/card-mirror.sh "/media/$USER/A2408A"
```

**Travel (macOS default):**

```bash
./bin/card-mirror.sh "/Volumes/A2408A"
```

## Card naming

**Pattern:** `{OwnerInitial}{YYMM}{Sequence}` — owner initial, earliest photo month, sequence letter if duplicate month.

- macOS rename: `diskutil rename "/Volumes/Old" "A2408A"`
- Linux: label when formatting, or pass mount path; `CARD_ID.txt` on card: `CARD_ID=A2408A`

## Bottleneck diagnosis

| Host | Check |
|------|--------|
| macOS | `mount` — prefer `smbfs` over `afpfs`; `route -n get default` |
| Linux | `findmnt`; `ip route`; local NAS mount vs network |
| Both | rsync throughput; `du` on `DEST_ROOT/<CARD_ID>`; `iostat` / SD removable |

## Backup destinations (this setup)

| When | macOS `DEST_ROOT` | Linux media server `DEST_ROOT` |
|------|-------------------|--------------------------------|
| Travel | `/Volumes/Extreme SSD/PhotoVault/CardMirror` | N/A (use Mac or portable host) |
| Home | `/Volumes/Photos/PhotoVault/CardMirror` (slow over Wi‑Fi AFP) | `/mnt/nas/PhotoVault/CardMirror` (example — use your NAS mount) |
