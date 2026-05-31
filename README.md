# Photo Backup Archive - Card Mirror System

A sophisticated photo and video backup system for camera memory cards that provides intelligent mirroring, quarantine functionality, and tombstone management to prevent re-copying deleted files.

## Overview

This system automatically detects inserted camera cards (SD cards, CF cards, etc.) and mirrors their contents to a designated backup location. It includes:

- **Automatic card detection** - Identifies external camera-like volumes with FAT/exFAT filesystems
- **Intelligent mirroring** - Uses rsync with backup and tombstone support
- **Quarantine system** - Moves deleted/overwritten files to dated Attic folders instead of permanent deletion
- **Tombstone management** - Prevents re-copying of files you've intentionally deleted from your archive
- **Automated scheduling** - Optional launchd integration for hands-free operation

## Backup destinations

Scripts default to a **portable rugged SSD** volume named `Extreme SSD` — a common macOS mount name for travel drives (e.g. SanDisk Extreme). That default is intentional: many people mirror cards to a bus-powered SSD while away from home, then sync the archive to a NAS later.

| Context | Typical `DEST_ROOT` | Notes |
|---------|---------------------|--------|
| **Travel / field** | `/Volumes/Extreme SSD/PhotoVault/CardMirror` | Default in scripts; fast local USB; works offline |
| **Home / NAS** | `/Volumes/Photos/PhotoVault/CardMirror` | macOS: mounted **NAS shared folder** (not “the server”) |
| **Home / NAS (Ubuntu host)** | `/path/to/nas-share/PhotoVault/CardMirror` | Linux: same — only the **NAS share** is mounted locally |

The same `CardMirror/<CARD_ID>/` layout is used on both targets so card IDs stay consistent whether you mirror on the road or at home. Override `DEST_ROOT` in `config/config.sh` or per run — do not commit machine-specific paths unless this repo is personal-only.

**If both the travel SSD and NAS are mounted**, prefer mirroring to the travel SSD first (fast local USB); sync or copy to the NAS separately when convenient.

### What is mounted (not the media server host)

You do **not** mount the media server machine as a volume. You mount:

| Role | macOS | Ubuntu media server |
|------|--------|---------------------|
| **Source** (SD card) | `/Volumes/A2408A` | `/media/$USER/A2408A` (or `/run/media/...`) |
| **Destination** (`DEST_ROOT`) | NAS **share** e.g. `/Volumes/Photos/...` | NAS **share** e.g. `/mnt/photos/...` (your CIFS/NFS mount) |

The Ubuntu box is just the host on Ethernet; `DEST_ROOT` must be the path where the **PhotoVault share** is already mounted.

### Ubuntu media server (fastest home path)

Plug the card reader into the **Ubuntu host** and mirror into the locally mounted NAS share (no Mac Wi‑Fi hop).

```bash
# DEST_ROOT = where the NAS shared folder is mounted on this machine (set in config/config.sh)
DEST_ROOT="/mnt/photos/PhotoVault/CardMirror" ./bin/card-mirror.sh /media/$USER/A2408A
```

Auto-detect scans `/media/$USER/*` and `/run/media/$USER/*` for the card (override with `CARD_MOUNT_ROOTS`). **launchd automation is macOS only.**

**Headless Ubuntu (no desktop / no manual `udisksctl`):** install udev automount once so labeled exfat/vfat camera cards appear under `/media/$USER/<LABEL>` on insert:

```bash
sudo MOUNT_USER=$USER ./bin/install-linux-card-mount.sh
cp config/config.sh.example config/config.sh   # set DEST_ROOT to your NAS share mount
journalctl -t card-automount -n 20             # troubleshoot
```

When `DEST_ROOT` is on **NFS/SMB**, `card-mirror.sh` automatically adds `--no-owner --no-group` so rsync does not fail with exit code 23 on permission errors.

### Ubuntu prerequisites

On a headless media server, install packages once:

```bash
sudo apt install rsync util-linux exfatprogs libimage-exiftool-perl
```

| Package | Used for |
|---------|----------|
| `rsync` | `card-mirror.sh` transfers |
| `util-linux` | `findmnt`, `lsblk` — mount detection |
| `exfatprogs` | exFAT cards (`exfatlabel` to rename volume to `CARD_ID`; kernel exFAT mount) |
| `libimage-exiftool-perl` | `card-label.sh` — earliest photo date from EXIF (JPEG, ORF, etc.) |

Optional: `python3-pil` — JPEG-only fallback if `exiftool` is not installed. Mount the NAS **share** separately (e.g. `nfs-common` + `/etc/fstab` entry for `/mnt/photos`).

**New or unlabeled cards** — automount requires a filesystem label. Mount once, then name the card:

```bash
udisksctl mount -b /dev/sdX1
./bin/card-label.sh --quick I        # fast (~1 s); omit --quick for full scan
# if prompted: sudo exfatlabel /dev/sdX1 I2405A && udisksctl mount -b /dev/sdX1
./bin/card-mirror.sh
```

Cards must be **labeled** exfat/vfat with a DCIM tree for headless automount to pick them up on insert.

## Directory Structure

```
photo-backup-archive/
├── bin/                    # Main executable scripts
│   ├── card-mirror.sh      # Main mirroring script with config loading
│   ├── card-reconcile.sh   # Smart tombstone reconciliation
│   ├── reconcile-all.sh    # Batch reconciliation (for advanced users)
│   ├── install-linux-card-mount.sh  # One-time headless SD automount setup
│   ├── card-label.sh       # Linux: propose CARD_ID from EXIF + rename exfat label
│   └── lib/platform.sh     # macOS + Linux mount/detection helpers
├── config/
│   ├── config.sh.example   # Copy to config/config.sh (gitignored)
│   └── linux/              # udev/polkit templates for headless automount
│       ├── card-automount.sh
│       ├── 99-camera-sd-automount.rules
│       └── 50-udisks-mount-plugdev.rules
├── launchd/                # macOS automation
│   ├── com.cardmirror.auto.plist.tpl      # Auto-run template
│   └── com.cardmirror.reconcile.plist.tpl # Reconcile template
├── Makefile                # Installation and management commands
└── README.md              # This file
```

## Quick Start

1. **Basic usage** - Insert a camera card and run:
   ```bash
   ./bin/card-mirror.sh
   ```

2. **Dry run** to see what would happen:
   ```bash
   DRY_RUN=1 ./bin/card-mirror.sh
   ```

3. **Install automated service**:
   ```bash
   make install
   ```

## Scripts Reference

### `card-mirror.sh`
**Purpose**: Main mirroring script with config loading, card detection, and intelligent backup.

**Usage**:
```bash
./bin/card-mirror.sh [SOURCE_PATH]
```

**Configuration** (via environment variables or `config/config.sh`):
- `DEST_ROOT`: Backup destination directory (default: travel SSD — `/Volumes/Extreme SSD/PhotoVault/CardMirror`; see [Backup destinations](#backup-destinations))
- `KEEP_DAYS`: Days to keep quarantined files (default: `90`)
- `FAST_MODE`: Enable speed optimizations for local disks (default: `1`)
- `DRY_RUN`: Preview mode without making changes (default: `0`)

**Features**:
- Auto-detects external camera cards (FAT/exFAT with DCIM, PRIVATE, or AVCHD folders)
- Creates stable card identifiers using `CARD_ID.txt` files
- Mirrors files with rsync, backing up overwrites/deletes to `Attic/YYYY-MM-DD/`
- Respects `.tombstones` exclusion lists
- Generates `.manifest-last.txt` for change tracking
- Automatically prunes old Attic folders based on `KEEP_DAYS`

**Card Detection Logic**:
- Must be external/removable volume
- Must have camera-like directory structure (`DCIM`, `PRIVATE`, or `AVCHD`)
- Must use FAT/exFAT filesystem
- Cannot be the destination drive

**Directory Structure Created**:
```
CardMirror/
└── [CARD_ID]/
    ├── CARD_ID.txt         # Card metadata
    ├── .manifest-last.txt  # File listing from last mirror
    ├── .tombstones         # Exclusion list (if exists)
    ├── Attic/              # Quarantined files
    │   └── YYYY-MM-DD/     # Daily quarantine folders
    └── [mirrored files]    # Your photos and videos
```

### `card-reconcile.sh`
**Purpose**: Smart tombstone reconciliation with dual modes - auto-detects recent card OR processes specified card.

**Usage**:
```bash
# Auto-detect most recent card (typical usage)
./bin/card-reconcile.sh

# Process specific card (advanced usage)
./bin/card-reconcile.sh CARD_ID [DEST_ROOT]
```

**How it works**:
1. **Auto mode**: Scans your card mirrors to find the most recently used one
2. **Manual mode**: Processes the specified card ID
3. Compares current files with the last manifest 
4. Tombstones any files you've deleted from your archive
5. Next mirror won't re-copy those deleted files

**When to use**:
After deleting unwanted photos/videos from your archive, run this before the next mirror.

**Example workflow**:
```bash
# 1. Mirror card
./bin/card-mirror.sh

# 2. Delete unwanted photos from archive
rm /path/to/CardMirror/CARD-ID/DCIM/100CANON/IMG_*.JPG

# 3. Tombstone the deletions (auto-detects recent card)
./bin/card-reconcile.sh

# 4. Next mirror ignores deleted files
```

### `reconcile-all.sh`
**Purpose**: Batch tombstone reconciliation for all cards (advanced users with many cards).

**Usage**:
```bash
./bin/reconcile-all.sh
```

**Note**: Most users should use `card-reconcile.sh` instead, which handles your most recent card automatically.

## Configuration

### Environment Variables
Set these in your shell or `config/config.sh`:

```bash
# Primary backup destination
DEST_ROOT="/path/to/your/backup/drive/CardMirror"

# Quarantine retention (days)
KEEP_DAYS=90

# Speed optimization for local drives
FAST_MODE=1

# Preview mode (1 = show what would happen, don't execute)
DRY_RUN=0
```

### Configuration File
Create `config/config.sh` from the example (gitignored — do not commit machine paths):

```bash
cp config/config.sh.example config/config.sh
```

```bash
# Travel — rugged external SSD (default volume name in scripts)
# DEST_ROOT="/Volumes/Extreme SSD/PhotoVault/CardMirror"

# Home — NAS PhotoVault share (example; use your mount name)
# DEST_ROOT="/Volumes/Photos/PhotoVault/CardMirror"

KEEP_DAYS=30
FAST_MODE=1
DRY_RUN=0
```

## Automation with launchd (macOS)

The system includes macOS launchd integration for hands-free operation:

### Installation
```bash
make install    # Install and start services
make uninstall  # Remove services
make reload     # Restart services
make test       # Test with dry run
```

### Services Created

1. **`com.cardmirror.auto`**: 
   - Watches `/Volumes` for new mounts
   - Automatically runs mirror when camera card inserted
   - Logs to `~/Library/Logs/card-mirror.log`

2. **`com.cardmirror.reconcile`**:
   - Runs daily at 3:30 AM
   - Auto-detects and reconciles your most recent card
   - Logs to `~/Library/Logs/card-reconcile.log`

### Manual Service Management
```bash
# Load/unload individual services
launchctl load ~/Library/LaunchAgents/com.cardmirror.auto.plist
launchctl unload ~/Library/LaunchAgents/com.cardmirror.auto.plist

# Check service status
launchctl list | grep cardmirror

# View logs
tail -f ~/Library/Logs/card-mirror.log
tail -f ~/Library/Logs/card-reconcile.log
```

## Card ID Management

The system uses stable card identifiers to handle volume name changes.

### Naming convention

Card IDs (and volume labels) follow **`{OwnerInitial}{YYMM}{Sequence}`**:

| Part | Meaning |
|------|---------|
| `{OwnerInitial}` | First letter of the card owner's first name |
| `{YYMM}` | Two-digit year + month of the **earliest** photo on the card (from EXIF `DateTimeOriginal`) |
| `{Sequence}` | Single letter `A`–`Z` when multiple cards share the same owner and earliest month |

Examples: `A2408A` (first card with earliest photos in Aug 2024), `A2408B` (second card with the same earliest month).

Before naming a new card, check existing folders under `CardMirror/` and use the next free sequence letter for that prefix.

**Linux:** run `./bin/card-label.sh --quick <initial>` after mounting (see [Ubuntu prerequisites](#ubuntu-prerequisites)); omit `--quick` when you need the true earliest EXIF date across the whole card. **macOS:** `diskutil rename diskXsY CARD_ID`.

### Runtime behavior

1. **First mirror**: Creates `CARD_ID.txt` in destination with card info
2. **Subsequent mirrors**: Uses existing `CARD_ID.txt` for consistency
3. **Card-side ID**: Place `CARD_ID.txt` on the card to override the volume name

Example `CARD_ID.txt`:
```
CARD_ID=A2408A
Created=2024-03-15T10:30:00Z
```

## Tombstone System

Tombstones prevent re-copying deleted files:

### Format
`.tombstones` file contains paths with leading `/` anchors:
```
/DCIM/100CANON/IMG_1234.JPG
/DCIM/101CANON/IMG_5678.CR3
/PRIVATE/M4ROOT/CLIP/0001.MP4
```

### Workflow
1. Mirror card → files copied to archive
2. You delete unwanted files from archive
3. Run tombstone reconciliation → deleted paths added to `.tombstones`
4. Next mirror skips tombstoned files

### Management
```bash
# View tombstones for a card
cat "/path/to/CardMirror/CARD-ID/.tombstones"

# Manually add path to tombstones
echo "/DCIM/100CANON/IMG_UNWANTED.JPG" >> "/path/to/CardMirror/CARD-ID/.tombstones"

# Clear all tombstones (will re-copy everything)
rm "/path/to/CardMirror/CARD-ID/.tombstones"
```

## Quarantine System (Attic)

The Attic preserves deleted/overwritten files instead of permanent deletion:

### Structure
```
CardMirror/CARD-ID/Attic/
├── 2024-01-15/    # Files deleted/overwritten on Jan 15
├── 2024-01-16/    # Files deleted/overwritten on Jan 16
└── 2024-01-20/    # etc.
```

### Automatic Cleanup
- Old Attic folders are removed after `KEEP_DAYS` (default 90)
- Only date-named folders are cleaned up
- Manual files/folders in Attic are preserved

### Manual Recovery
```bash
# Find a specific deleted file
find "/path/to/CardMirror/CARD-ID/Attic" -name "IMG_1234.JPG" -type f

# Restore a file
cp "/path/to/CardMirror/CARD-ID/Attic/2024-01-15/DCIM/100CANON/IMG_1234.JPG" \
   "/path/to/CardMirror/CARD-ID/DCIM/100CANON/"
```

## Troubleshooting

### Card Not Detected
- Ensure card is FAT/exFAT formatted
- Card must have camera directory structure (`DCIM`, `PRIVATE`, or `AVCHD`)
- Card must be external/removable (not internal drive)
- Destination drive is automatically excluded

### Manual Card Specification
```bash
# Force specific source if auto-detection fails
./bin/card-mirror.sh "/Volumes/MY-CAMERA-CARD"
```

### Permission Issues
```bash
# Ensure scripts are executable
chmod +x bin/*.sh

# Check disk permissions
ls -la "/Volumes/Your-Card/"
```

### rsync Errors
- Check available disk space on destination
- Verify destination drive is mounted and writable
- Review error output for specific file issues

### Service Issues
```bash
# Check if services are loaded
launchctl list | grep cardmirror

# View service logs
tail -f ~/Library/Logs/card-mirror.log
tail -f ~/Library/Logs/card-mirror.err.log

# Test services manually
make test
```

## Advanced Usage

### Custom rsync Options
Modify `RSYNC_FLAGS` in `card-mirror.sh` for custom behavior:
```bash
# Example modifications (edit the script):
--progress          # Show detailed progress
--exclude "*.THM"   # Skip thumbnail files  
--size-only         # Compare by size only
```

### Multiple Backup Destinations
Run multiple instances with different `DEST_ROOT`:
```bash
# Primary backup
DEST_ROOT="/Volumes/Primary/CardMirror" ./bin/card-mirror.sh

# Secondary backup  
DEST_ROOT="/Volumes/Secondary/CardMirror" ./bin/card-mirror.sh
```

### Batch Processing
```bash
# Process multiple cards sequentially
for card in /Volumes/SD-* /Volumes/CF-*; do
  [[ -d "$card" ]] || continue
  echo "Processing $card..."
  ./bin/card-mirror.sh "$card"
done
```

## Requirements

- **bash**, **rsync**
- **macOS**: `diskutil` for card auto-detect; optional **launchd** (`make install`)
- **Linux (Ubuntu media server)**: see [Ubuntu prerequisites](#ubuntu-prerequisites) — `findmnt`, `lsblk`, `exfatprogs`, `libimage-exiftool-perl`; NAS share mounted at `DEST_ROOT` parent path
- **External drive** or NAS mount for `DEST_ROOT`
- **Camera cards** formatted as FAT/exFAT

## License

See `LICENSE` file for details.