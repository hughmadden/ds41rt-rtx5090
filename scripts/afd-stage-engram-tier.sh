#!/usr/bin/env bash
# afd-stage-engram-tier.sh — stage the two DeepSeek-V4.1-Flash Engram shards on a
# dedicated local device (an Optane, a spare NVMe) on the coordinator host. OPTIONAL:
# the measured deployment served them from ordinary NVMe with no read bottleneck.
#
# WHY: in the AFD topology the Engram tables are coordinator-owned and host-mmap'd
# (ds41rt/architecture.md), so they attach *locally* to the coordinator host. Shards 47
# and 48 are ~196.6 GB together; a 280 GB-class device holds them with room to spare and
# the other 46 shards stay where they are.
#
# DEFAULT IS READ-ONLY. Nothing is formatted, mounted or copied without --apply.
# THIS FORMATS A DEVICE when applied: it refuses if the device has partitions or mounts.
#
# Usage:
#   EXPECT_MODEL="<NVMe model string>" MODEL_DIR=... afd-stage-engram-tier.sh           # detect + report only
#   EXPECT_MODEL="<NVMe model string>" MODEL_DIR=... afd-stage-engram-tier.sh --apply   # format, mount, copy
#   ... --apply --fs xfs
set -euo pipefail

MODEL_DIR=${MODEL_DIR:?set MODEL_DIR to the DeepSeek-V4.1-Flash snapshot directory}
ENGRAM_MNT=${ENGRAM_MNT:-/mnt/engram}
MOUNT_OPTS=${MOUNT_OPTS:-defaults,noatime}
FS=${FS:-xfs}
EXPECT_MODEL=${EXPECT_MODEL:?set EXPECT_MODEL to the target NVMe model string as shown in /sys/block/nvme*n1/device/model}
EXPECT_SERIAL=${EXPECT_SERIAL:-}      # optional: refuse-to-guess guard on the device serial
ENGRAM_SHARDS=(model-00047-of-00048.safetensors model-00048-of-00048.safetensors)

apply=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --fs) FS="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- 1. find the Optane ------------------------------------------------
say "== 1. locate the target device"
dev=""; serial=""
for d in /sys/block/nvme*n1; do
  [[ -e "$d" ]] || continue
  model="$(cat "$d/device/model" 2>/dev/null | tr -d ' ')"
  sn="$(cat "$d/device/serial" 2>/dev/null | tr -d ' ')"
  [[ -n "$model" ]] || continue
  if [[ "$model" == "${EXPECT_MODEL// /}" ]]; then
    dev="/dev/$(basename "$d")"; serial="$sn"
  fi
done
if [[ -z "$dev" ]]; then
  say "MISS: no NVMe device with model '$EXPECT_MODEL' is present."
  say "Device inventory:"
  for d in /sys/block/nvme*n1; do
    [[ -e "$d" ]] || continue
    printf '  /dev/%-8s model=%-28s serial=%s size=%s\n' "$(basename "$d")" \
      "$(cat "$d/device/model" 2>/dev/null)" "$(cat "$d/device/serial" 2>/dev/null)" \
      "$(lsblk -dno SIZE "/dev/$(basename "$d")" 2>/dev/null)"
  done
  say "-> install the card, then re-run. Nothing was changed."
  exit 1
fi
size_bytes=$(blockdev --getsize64 "$dev")
say "FOUND $dev  serial=$serial  size=$((size_bytes/1000/1000/1000)) GB ($((size_bytes/1024/1024/1024)) GiB)"
if [[ -n "$EXPECT_SERIAL" && "$serial" != "$EXPECT_SERIAL" ]]; then die "serial $serial differs from EXPECT_SERIAL ($EXPECT_SERIAL); refusing"; fi

# ---------- 2. is it safe to take over? ---------------------------------------
say
say "== 2. current contents"
parts=$(lsblk -rno NAME "$dev" | tail -n +2 | wc -l)
mounted=$(lsblk -rno MOUNTPOINT "$dev" | grep -c . || true)
sig=$(blkid "$dev" 2>/dev/null || true)
say "partitions=$parts mounted=$mounted blkid=${sig:-<none>} holders=$(ls /sys/block/$(basename "$dev")/holders 2>/dev/null | wc -l)"
if [[ $apply -eq 1 ]]; then
  [[ "$mounted" == "0" ]] || die "$dev has mounted children; refusing"
  [[ "$parts" == "0" ]] || die "$dev has partitions; refusing to reformat"
fi

# ---------- 3. source shards --------------------------------------------------
say
say "== 3. Engram shards to place"
total=0
for s in "${ENGRAM_SHARDS[@]}"; do
  p="$MODEL_DIR/$s"
  [[ -f "$p" ]] || die "missing $p"
  b=$(stat -c%s "$p"); total=$((total+b))
  printf '  %-34s %s B\n' "$s" "$b"
done
say "  total = $((total/1000/1000/1000)) GB ($((total/1024/1024/1024)) GiB); device holds $((size_bytes/1024/1024/1024)) GiB"
(( size_bytes > total )) || die "device is smaller than the two shards"

if [[ $apply -eq 0 ]]; then
  say
  say "READ-ONLY REPORT. Re-run with --apply to format, mount and copy to $ENGRAM_MNT"
  exit 0
fi

# ---------- 4. format + mount -------------------------------------------------
say
say "== 4. format + mount $dev -> $ENGRAM_MNT ($FS)"
sudo -n mkfs."$FS" -f -L ds41rt-engram "$dev"
uuid=$(sudo -n blkid -s UUID -o value "$dev") || die "no UUID after mkfs"
sudo -n mkdir -p "$ENGRAM_MNT"
sudo -n mount -o "$MOUNT_OPTS" "UUID=$uuid" "$ENGRAM_MNT"
fstab_line="UUID=$uuid $ENGRAM_MNT $FS $MOUNT_OPTS 0 2"
grep -q "UUID=$uuid" /etc/fstab || echo "$fstab_line" | sudo -n tee -a /etc/fstab >/dev/null
sudo -n chown "$(id -u):$(id -g)" "$ENGRAM_MNT"
say "mounted $(findmnt -no SOURCE,TARGET,FSTYPE "$ENGRAM_MNT")"

# ---------- 5. copy + verify --------------------------------------------------
say
say "== 5. copy shards (this is ~197 GB; watch it)"
for s in "${ENGRAM_SHARDS[@]}"; do
  if [[ -f "$ENGRAM_MNT/$s" ]] && cmp -s "$MODEL_DIR/$s" "$ENGRAM_MNT/$s"; then
    say "  $s already present and byte-identical, skipping"
    continue
  fi
  rsync -a --inplace --info=progress2 "$MODEL_DIR/$s" "$ENGRAM_MNT/$s"
  cmp -s "$MODEL_DIR/$s" "$ENGRAM_MNT/$s" || die "$s differs after copy"
  say "  $s verified byte-identical"
done

# ---------- 6. launch wiring ------------------------------------------------
# Do NOT build a symlinked snapshot directory: the container only ever sees the mount
# points, so a symlink to the model directory is a dangling link inside the container and the
# engine cannot open the shard. Instead the two Optane files are bind-mounted *over* their
# names inside /model (a nested read-only bind), which docker applies by longest path.
say
say "== 6. launch wiring (nested read-only binds over /model)"
for s in "${ENGRAM_SHARDS[@]}"; do
  say "  -v $ENGRAM_MNT/$s:/model/$s:ro"
done
say "  (afd-launch-coordinator.sh adds these automatically when ENGRAM_DIR=$ENGRAM_MNT is populated)"

say
say "DONE. Coordinator command:"
say "  ENGRAM_DIR=$ENGRAM_MNT scripts/afd-launch-coordinator.sh --apply"
