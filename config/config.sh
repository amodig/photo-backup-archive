# config/config.sh — optional overrides for card-mirror.sh
#
# macOS defaults: /Volumes/Extreme SSD/PhotoVault/CardMirror (travel SSD)
# Linux defaults:  /mnt/PhotoVault/CardMirror (override — use your NAS *share* mount path)
#
# DEST_ROOT is always a locally mounted path (travel SSD or NAS shared folder), never “the server”.
#
# Examples (uncomment one):
# DEST_ROOT="/Volumes/Extreme SSD/PhotoVault/CardMirror"   # macOS travel SSD
# DEST_ROOT="/Volumes/Photos/PhotoVault/CardMirror"        # macOS: NAS share mount
# DEST_ROOT="/mnt/photos/PhotoVault/CardMirror"          # Ubuntu: NAS share mount (CIFS/NFS)
# CARD_MOUNT_ROOTS="/media/amodig:/run/media/amodig"       # Linux SD card search paths

# KEEP_DAYS=90
# FAST_MODE=1
# DRY_RUN=0
# ATTIC_FOLDER="_Attic"
# REJECTED_FOLDER="_Rejected"
