---
name: card-mirror-transfer-path
description: >-
  Advises the fastest path for camera SD card backups (travel SSD vs home NAS)
  using card-mirror.sh. Infers home vs travel from mounted volumes when possible.
  Use when backing up a memory card, mirroring DCIM to CardMirror, running
  card-mirror, choosing DEST_ROOT, diagnosing slow rsync, or before a large transfer.
---

# Card mirror — fastest transfer path

Before starting or recommending `card-mirror.sh`, **detect home vs travel from attached volumes first**; ask the user only when detection is ambiguous. Then state the recommended `DEST_ROOT`, fastest physical path, and whether to proceed.

## Path priority (fastest first)

| Rank | Setup | Typical bottleneck |
|------|--------|-------------------|
| 1 | **SD reader on media server** → Ethernet → NAS (SMB) | NAS/disk; often 50–100+ MB/s |
| 2 | **Mac on Ethernet** → NAS via **SMB3** | LAN; much better than Wi‑Fi AFP |
| 3 | **Mac on Wi‑Fi** → NAS via AFP/SMB | Network (~15–25 MB/s common) |

**Avoid** routing a full card through Mac Wi‑Fi + AFP when the media server can take the card directly.

## Home vs travel — detect, then ask only if needed

**Do not** open with “are you home or traveling?” if mounts are enough to tell. Run lightweight checks:

```bash
ls /Volumes
test -d "/Volumes/Extreme SSD/PhotoVault/CardMirror" && echo travel_dest_ok
test -d "/Volumes/Photos/PhotoVault/CardMirror" && echo home_dest_ok
mount | grep -E 'Photos|Extreme SSD'
# camera card: /Volumes/* with DCIM (or user-provided path)
```

### Inference rules (this repo)

| Signal | Likely scenario | Suggested `DEST_ROOT` |
|--------|-----------------|------------------------|
| **Extreme SSD** mounted (writable `PhotoVault/CardMirror`) | **Travel** | `/Volumes/Extreme SSD/PhotoVault/CardMirror` (script default) — **even if NAS is also mounted** |
| **Photos** (NAS) mounted, **Extreme SSD** absent | **Home** | `/Volumes/Photos/PhotoVault/CardMirror` |
| Both **Extreme SSD** and **Photos** mounted | **Travel** (default) | Use **Extreme SSD**; mention NAS as optional second copy or later sync — do not ask unless user wants NAS-only |
| Neither destination path exists | **Unknown** | Ask which target they want; suggest plugging travel SSD or mounting NAS |
| User explicitly says “traveling” / “at home” | Override detection | Use their statement |

**Confidence:** State inferred scenario in one line (e.g. “Detected: travel — Extreme SSD mounted, NAS not mounted”). If wrong, user can correct in one reply.

### When to ask the user

Use **AskQuestion** only if:

- No destination is mounted but a camera card is present
- Detection conflicts with what the user said (e.g. they insist on NAS while SSD is mounted)
- User asks for NAS-only despite SSD being available

Do **not** ask home vs travel when **Extreme SSD** is mounted — default to travel SSD. Do **not** ask when only **Photos** is mounted (use home NAS path).

## Pre-flight checklist

After detection, present:

```
Scenario: [travel | home | ambiguous] — [one-line evidence]
DEST_ROOT: [path]
Transfer path
- [ ] Fastest route for scenario (SSD USB / media server+Ethernet / Mac Ethernet SMB)?
- [ ] Card ID: {OwnerInitial}{YYMM}{Sequence} (or existing CARD_ID.txt)?
- [ ] No duplicate rsync already running?
```

## Agent behavior

1. **Detect scenario** (table above) → set `DEST_ROOT` → mention faster alternative if home + Wi‑Fi AFP (media server or wired SMB).
2. **Home + NAS:** If `afpfs` and default route is Wi‑Fi, warn before multi‑GB runs; recommend media server with card reader or Ethernet SMB.
3. **Travel:** Script default is fine; no NAS path needed unless user also wants a second copy.
4. **Dry run** when scenario was ambiguous, path is suboptimal, or first mirror on this host:
   `DEST_ROOT="…" DRY_RUN=1 ./bin/card-mirror.sh "/Volumes/CARDVOL"`
5. Do not stop a healthy in-progress mirror unless the user accepts restarting.

## Commands (this repo)

```bash
# Config (optional)
# DEST_ROOT="/Volumes/Photos/PhotoVault/CardMirror" in config/config.sh

# Dry run
DEST_ROOT="/Volumes/Photos/PhotoVault/CardMirror" DRY_RUN=1 \
  ./bin/card-mirror.sh "/Volumes/A2408A"

# Real mirror (media server or Mac — same command, different mount paths)
DEST_ROOT="/Volumes/Photos/PhotoVault/CardMirror" \
  ./bin/card-mirror.sh "/Volumes/A2408A"
```

## Card naming convention

Stable folder: `CardMirror/<CARD_ID>/`

**Pattern:** `{OwnerInitial}{YYMM}{Sequence}`

| Part | Meaning |
|------|---------|
| `{OwnerInitial}` | First letter of the card owner's first name (this household: **A**) |
| `{YYMM}` | Year + month of the **earliest** photo on the card (`DateTimeOriginal`; JPG scan is enough) |
| `{Sequence}` | Single letter **A–Z** — increments when multiple cards share the same owner + earliest month |

**Examples:** `A2408A` (first card whose earliest photos are Aug 2024), `A2408B` (second card with the same earliest month).

**Before assigning a new ID:** list `DEST_ROOT` and pick the next free sequence for that `{OwnerInitial}{YYMM}` prefix (do not reuse an existing card's ID).

```bash
# Example: earliest photo 2024-08-03, first card for that month
diskutil rename "/Volumes/OldName" "A2408A"
# On card (optional, survives renames):
# CARD_ID=A2408A
```

## Quick bottleneck diagnosis

If transfer is slow while running:

- `mount` on NAS volume — prefer `smbfs` over `afpfs`
- `route -n get default` — Wi‑Fi (`en0`) vs Ethernet
- rsync log throughput vs `du` growth on `DEST_ROOT/<CARD_ID>`
- SD read in `iostat` — if SD << network, card/USB hub may matter; if network << SD, fix path first

## Backup destinations (this setup)

| When | `DEST_ROOT` | Role |
|------|-------------|------|
| Travel | `/Volumes/Extreme SSD/PhotoVault/CardMirror` | Rugged portable SSD (script default; good for offline / USB speed) |
| Home | `/Volumes/Photos/PhotoVault/CardMirror` | NAS PhotoVault (Synology/HomeNAS) |

Repo default volume name **`Extreme SSD`** is a generic stand-in for a rugged travel drive; other users rename to their mount point. At home, prefer media server + Ethernet → NAS over Mac Wi‑Fi AFP (~18–21 MB/s observed for large cards).
