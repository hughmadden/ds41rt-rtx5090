#!/usr/bin/env bash
# afd-plan-probe.sh — measure the DS41RT coordinator's startup VRAM plan on the
# coordinator host's RTX 5090 with NO Spark involvement, by reading the "native KV pool reservation"
# log line the planner emits (v41_native_serve.rs:267).
#
# Why this works without the fleet: the RoCE client connects lazily on first
# dispatch — `LocalTp4Client::new` (transport/src/verbs/local_client.rs:15) only
# stores the peer list and empty sessions; `connect_local` runs inside `post()`,
# which is reached only when a request is served. The memory planner at
# v41_native_serve.rs:265 runs *before* readiness and after every resident
# allocation, and reports measured device occupancy. Four loopback peers are
# therefore sufficient to reach it.
#
# Usage: afd-plan-probe.sh <tag> <prefill-batch-tokens> <concurrency> <dspark on|off> [pool]
set -uo pipefail
MODEL_DIR=${MODEL_DIR:?set MODEL_DIR to the DeepSeek-V4.1-Flash snapshot directory}
IMAGE=${IMAGE:-ds41rt-coordinator-rtx5090:v15}
NATIVE_LIB=${NATIVE_LIB:-/opt/ds41rt/lib/libds41rt_native.so}
OUT=${OUT:-$PWD/afd-plan}
WAIT_S=${WAIT_S:-420}
mkdir -p "$OUT"

tag=${1:?tag}; batch=${2:?batch}; conc=${3:?conc}; dspark=${4:?dspark}; pool=${5:-}; resv=${6:-}
CTX=${CTX:-65536}
name="ds41rt-plan-$tag"
log="$OUT/$tag.log"

args=(--snapshot /model --native-lib "$NATIVE_LIB"
  --peers 127.0.0.1:19441,127.0.0.1:19442,127.0.0.1:19443,127.0.0.1:19444
  --listen 127.0.0.1:18080
  --prefill-batch-tokens "$batch" --concurrency "$conc"
  --prefix-cache-entries 0
  --max-context-tokens "$CTX" --max-output-tokens 8192)
[[ -n "$pool" ]] && args+=(--kv-pool-size "$pool")
[[ -n "$resv" ]] && args+=(--memory-reservation "$resv")
[[ "$dspark" == on ]] && args+=(--dspark)

devices=(); [[ -e /dev/infiniband ]] && devices=(--device=/dev/infiniband)

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" "${devices[@]}" --gpus all --ipc host \
  --ulimit memlock=-1:-1 -e RUST_LOG=info \
  -v "$MODEL_DIR:/model:ro" "$IMAGE" ds41rt serve-native "${args[@]}" >/dev/null

deadline=$((SECONDS+WAIT_S))
while (( SECONDS < deadline )); do
  docker logs "$name" 2>&1 | grep -q "native KV pool reservation" && break
  running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)
  [[ "$running" == "true" ]] || break
  sleep 2
done
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader > "$OUT/$tag.smi" 2>/dev/null || true
docker logs "$name" > "$log" 2>&1 || true
docker rm -f "$name" >/dev/null 2>&1 || true

echo "=== $tag  batch=$batch conc=$conc dspark=$dspark pool=${pool:-auto}  (log: $log)"
grep -nE "native KV pool reservation|insufficient|reserve|budget|Error|error:|panicked|out of memory|CUDA|failed|native target backbone|exceeds" "$log" | tail -25
echo "--- gpu during: $(cat "$OUT/$tag.smi" 2>/dev/null)"
