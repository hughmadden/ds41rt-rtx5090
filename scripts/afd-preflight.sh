#!/usr/bin/env bash
# afd-preflight.sh — READ-ONLY go/no-go gate for the AFD hybrid window. Run on the
# coordinator host (it reaches each Spark over ssh, read-only).
#
# Checks everything the four-Spark AFD boot needs, changes nothing, and prints the exact
# prep commands for whatever is missing.
#
#   SPARK_HOSTS="sparkA sparkB sparkC sparkD" ./afd-preflight.sh   # human-readable
#   ./afd-preflight.sh --json     # machine-readable
set -uo pipefail

COORD_IMAGE=${COORD_IMAGE:-ds41rt-coordinator-rtx5090:v15}
SPARK_IMAGE=${SPARK_IMAGE:-ghcr.io/tpurtell/ds41rt-spark-expert:v15}
MODEL_DIR=${MODEL_DIR:?set MODEL_DIR to the DeepSeek-V4.1-Flash snapshot directory on this host}
SPARK_MODEL_DIR=${SPARK_MODEL_DIR:-/models/DeepSeek-V4.1-Flash}
ENGRAM_MNT=${ENGRAM_MNT:-}            # optional: mount point of a dedicated Engram device
# v15 + patches/ (afd-build-coordinator.sh PATCHES=on); upstream bd06bec4 with PATCHES=none.
EXPECT_REV=${EXPECT_REV:-27ff8c731991def9708baa232cdc0c57cfeeb2d9}
EXPECT_SPARKINFER=${EXPECT_SPARKINFER:-7fcc094edcc93af61fdfbe14300100e3204363ea}
EXPECT_SMS=${EXPECT_SMS:-170}
read -r -a SPARK_HOSTS <<<"${SPARK_HOSTS:?set SPARK_HOSTS to the four expert hosts in rank order, space-separated}"
[[ ${#SPARK_HOSTS[@]} -eq 4 ]] || { echo "SPARK_HOSTS must list exactly four hosts" >&2; exit 2; }
API_PORT=${API_PORT:-8000}
EXPERT_PORT=${EXPERT_PORT:-19441}
SPARK_MIN_MEM_GIB=${SPARK_MIN_MEM_GIB:-100}
json=0; [[ "${1:-}" == "--json" ]] && json=1

pass=0; fail=0; warn=0
declare -a rows
row() { # status name detail
  rows+=("$1|$2|$3")
  case "$1" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; WARN) warn=$((warn+1));; esac
  [[ $json -eq 0 ]] && printf '[%s] %-42s %s\n' "$1" "$2" "$3"
  return 0   # MUST be 0: callers use `A && row PASS ... || row FAIL ...`
}

if [[ $json -eq 0 ]]; then
  echo "== AFD hybrid preflight ($(date -Is)) host=$(hostname) — read-only"
  echo
fi

# ---------- coordinator host: coordinator image ------------------------------------------
if ! docker image inspect "$COORD_IMAGE" >/dev/null 2>&1; then
  row FAIL "coordinator image present" "$COORD_IMAGE missing"
else
  rev=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$COORD_IMAGE" 2>/dev/null)
  si=$(docker image inspect -f '{{index .Config.Labels "io.ds41rt.sparkinfer.revision"}}' "$COORD_IMAGE" 2>/dev/null)
  [[ "$rev" == "$EXPECT_REV" ]] && row PASS "coordinator engine revision" "$rev" \
    || row FAIL "coordinator engine revision" "$rev (expected $EXPECT_REV)"
  [[ "$si" == "$EXPECT_SPARKINFER" ]] && row PASS "coordinator sparkinfer revision" "$si" \
    || row FAIL "coordinator sparkinfer revision" "$si (expected $EXPECT_SPARKINFER)"
  sms=$(docker run --rm --entrypoint python3 "$COORD_IMAGE" -c \
    'import json;print(json.load(open("/opt/ds41rt/share/V41_FP8_AOT.json"))["physical_sms"])' 2>/dev/null)
  [[ "$sms" == "$EXPECT_SMS" ]] && row PASS "coordinator AOT SM count" "$sms (this GPU)" \
    || row FAIL "coordinator AOT SM count" "$sms (expected $EXPECT_SMS — rebuild on this host)"
fi

# ---------- coordinator host: GPU ---------------------------------------------------------
gpu_free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1)
if [[ -z "$gpu_free" ]]; then row FAIL "GPU visible" "nvidia-smi returned nothing"
elif (( gpu_free > 28000 )); then row PASS "GPU free" "${gpu_free} MiB free"
else row WARN "GPU free" "${gpu_free} MiB free — a resident workload may not leave room"; fi

# ---------- coordinator host: model snapshot ---------------------------------------------
if [[ -f "$MODEL_DIR/model.safetensors.index.json" && -f "$MODEL_DIR/config.json" && -f "$MODEL_DIR/tokenizer.json" ]]; then
  n=$(ls "$MODEL_DIR"/model-*-of-00048.safetensors 2>/dev/null | wc -l || true)
  [[ "$n" == "48" ]] && row PASS "model snapshot complete" "48/48 shards + index + tokenizer" \
    || row FAIL "model snapshot complete" "$n/48 shards"
else
  row FAIL "model snapshot complete" "missing index/config/tokenizer under $MODEL_DIR"
fi

# ---------- coordinator host: Engram tier (optional) -------------------------------------
if [[ -z "$ENGRAM_MNT" ]]; then
  row WARN "Engram tier staged" "ENGRAM_MNT unset — tables served from MODEL_DIR (fine; the dedicated tier is optional)"
elif [[ -f "$ENGRAM_MNT/model-00047-of-00048.safetensors" && -f "$ENGRAM_MNT/model-00048-of-00048.safetensors" ]]; then
  a=$(stat -c%s "$ENGRAM_MNT/model-00047-of-00048.safetensors"); b=$(stat -c%s "$ENGRAM_MNT/model-00048-of-00048.safetensors")
  row PASS "Engram tier staged" "shards 47+48 present ($(( (a+b)/1000/1000/1000 )) GB) — set ENGRAM_DIR=$ENGRAM_MNT"
else
  row WARN "Engram tier staged" "$ENGRAM_MNT has no shards — run afd-stage-engram-tier.sh --apply, or unset ENGRAM_MNT"
fi

# ---------- coordinator host: API port ----------------------------------------------------
if ss -ltn "sport = :$API_PORT" 2>/dev/null | tail -n +2 | grep -q .; then
  row WARN "coordinator API port $API_PORT" "already in use"
else row PASS "coordinator API port $API_PORT" "free"; fi

# ---------- Sparks -------------------------------------------------------------
for i in 0 1 2 3; do
  h="${SPARK_HOSTS[$i]}"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" true 2>/dev/null; then
    row FAIL "spark$i ($h) reachable" "ssh failed"; continue
  fi
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" bash -s -- "$SPARK_IMAGE" "$SPARK_MODEL_DIR" "$EXPERT_PORT" "$SPARK_MIN_MEM_GIB" <<'REMOTE' 2>/dev/null
set -u
img="$1"; model="$2"; port="$3"; minmem="$4"
docker image inspect "$img" >/dev/null 2>&1 && echo "image=yes" || echo "image=no"
ls "$model"/model-*-of-00048.safetensors 2>/dev/null | wc -l | sed 's/^/shards=/'
if ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | grep -q .; then echo "port=busy"; else echo "port=free"; fi
docker ps -a --filter "name=ds41rt-expert" --format '{{.Names}}' | head -3 | tr '\n' ',' | sed 's/^/ds41rt=/'
echo
avail=$(awk '/MemAvailable/{printf "%d", $2/1024/1024}' /proc/meminfo); echo "memgib=$avail"
running=$(docker ps --format '{{.Names}}' | tr '\n' ' '); echo "running=$running"
REMOTE
)
  img=$(sed -n 's/^image=//p' <<<"$out"); shards=$(sed -n 's/^shards=//p' <<<"$out")
  port=$(sed -n 's/^port=//p' <<<"$out"); mem=$(sed -n 's/^memgib=//p' <<<"$out")
  ds41=$(sed -n 's/^ds41rt=//p' <<<"$out"); running=$(sed -n 's/^running=//p' <<<"$out")
  [[ "$img" == "yes" ]] && row PASS "spark$i image present" "$SPARK_IMAGE" \
    || row FAIL "spark$i image present" "pull: docker pull $SPARK_IMAGE"
  [[ "$shards" == "48" ]] && row PASS "spark$i model staged" "48/48 shards at $SPARK_MODEL_DIR" \
    || row FAIL "spark$i model staged" "${shards:-0}/48 shards at $SPARK_MODEL_DIR"
  [[ "$port" == "free" ]] && row PASS "spark$i port $EXPERT_PORT" "free" \
    || row FAIL "spark$i port $EXPERT_PORT" "busy"
  if [[ -n "$mem" ]] && (( mem >= SPARK_MIN_MEM_GIB )); then row PASS "spark$i memory headroom" "${mem} GiB MemAvailable"
  else row FAIL "spark$i memory headroom" "${mem:-?} GiB MemAvailable (< ${SPARK_MIN_MEM_GIB} GiB)"; fi
  [[ -z "$ds41" ]] || row FAIL "spark$i no stale ds41rt container" "$ds41"
  [[ $json -eq 0 ]] && echo "         spark$i currently running: ${running:-<none>}"
done

# ---------- summary ------------------------------------------------------------
if [[ $json -eq 0 ]]; then
echo
echo "== ${pass} PASS / ${warn} WARN / ${fail} FAIL"
if (( fail == 0 )); then
  echo "GO — launch experts (worker-first 3,2,1,0), then the coordinator."
else
  echo "NO-GO — clear the FAIL lines above. Prep for a Spark is:"
  echo "    docker pull $SPARK_IMAGE"
  echo "    rsync -a --info=progress2 $MODEL_DIR/ <spark>:$SPARK_MODEL_DIR/     # or the head+NFS route"
fi
fi
if [[ $json -eq 1 ]]; then
  printf '{"pass":%d,"warn":%d,"fail":%d,"rows":[' "$pass" "$warn" "$fail"
  first=1
  for r in "${rows[@]}"; do
    IFS='|' read -r s n d <<<"$r"
    (( first )) || printf ','; first=0
    printf '{"status":"%s","check":"%s","detail":"%s"}' "$s" "$n" "${d//\"/}"
  done
  printf ']}\n'
fi
(( fail == 0 ))
