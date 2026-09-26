#!/usr/bin/env bash
# afd-ready-probe.sh — boot the rebuilt DS41RT coordinator on the 5090 to READINESS at the
# production operating point, with loopback peers and no Sparks, and prove it serves /health.
#
# This is the last offline gate before a real four-Spark boot: it exercises everything the
# planner probe does plus API startup, lazy CUDA-graph capture and the readiness handshake.
# No request is sent, so no expert peer is ever contacted (the RoCE client connects lazily).
#
# ENGRAM_DIR, when set (see afd-stage-engram-tier.sh), holds the two Engram shards on a
# dedicated device; each is bind-mounted *over*
# its name inside /model (a nested read-only bind). Symlinked snapshot directories are
# deliberately not used: their targets are host paths that do not exist inside the
# container, so the engine cannot open them.
set -uo pipefail

MODEL_DIR=${MODEL_DIR:?set MODEL_DIR to the DeepSeek-V4.1-Flash snapshot directory}
SNAP=${SNAP:-$MODEL_DIR}
ENGRAM_DIR=${ENGRAM_DIR:-}
ENGRAM_SHARDS=(model-00047-of-00048.safetensors model-00048-of-00048.safetensors)
IMAGE=${IMAGE:-ds41rt-coordinator-rtx5090:v15}
NATIVE_LIB=${NATIVE_LIB:-/opt/ds41rt/lib/libds41rt_native.so}
PORT=${PORT:-18080}
OUT=${OUT:-$PWD/afd-plan}
BATCH=${BATCH:-80}
CONC=${CONC:-1}
DSPARK=${DSPARK:-on}
RESV=${RESV:-97%}
CTX=${CTX:-1048576}
WAIT_S=${WAIT_S:-600}
NAME=ds41rt-ready-probe
mkdir -p "$OUT"

args=(serve-native --snapshot /model --native-lib "$NATIVE_LIB"
  --peers 127.0.0.1:19441,127.0.0.1:19442,127.0.0.1:19443,127.0.0.1:19444
  --listen "0.0.0.0:$PORT"
  --prefill-batch-tokens "$BATCH" --concurrency "$CONC" --prefix-cache-entries 0
  --max-context-tokens "$CTX" --max-output-tokens 8192)
[[ "$DSPARK" == on ]] && args+=(--dspark)
[[ -n "$RESV" ]] && args+=(--memory-reservation "$RESV")

devices=(); [[ -e /dev/infiniband ]] && devices=(--device=/dev/infiniband)
mounts=(-v "$SNAP:/model:ro")
if [[ -n "$ENGRAM_DIR" ]]; then
  for s in "${ENGRAM_SHARDS[@]}"; do
    [[ -f "$ENGRAM_DIR/$s" ]] && mounts+=(-v "$ENGRAM_DIR/$s:/model/$s:ro")
  done
  echo "engram: nested binds from $ENGRAM_DIR"
fi
docker rm -f "$NAME" >/dev/null 2>&1 || true

t0=$(date +%s)
docker run -d --name "$NAME" "${devices[@]}" --gpus all --network host --ipc host \
  --ulimit memlock=-1:-1 -e RUST_LOG=info \
  "${mounts[@]}" "$IMAGE" ds41rt "${args[@]}" >/dev/null
run_rc=$?
if [[ $run_rc -ne 0 ]]; then echo "docker run failed rc=$run_rc"; exit 1; fi

ready=""; deadline=$((t0+WAIT_S))
while (( $(date +%s) < deadline )); do
  if curl -fsS -m 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ready=$(( $(date +%s) - t0 )); break
  fi
  [[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" == "true" ]] || break
  sleep 2
done

nvidia-smi --query-gpu=memory.used,memory.free,utilization.gpu --format=csv,noheader >"$OUT/ready.smi" 2>/dev/null || true
curl -s -m 5 "http://127.0.0.1:$PORT/v1/models" >"$OUT/ready-models.json" 2>/dev/null || true
curl -s -m 5 "http://127.0.0.1:$PORT/health" >"$OUT/ready-health.txt" 2>/dev/null || true
docker inspect -f 'status={{.State.Status}} started={{.State.StartedAt}}' "$NAME" >"$OUT/ready-state.txt" 2>/dev/null || true
docker logs "$NAME" >"$OUT/ready.log" 2>&1 || true
docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "=== afd-ready-probe  snap=$SNAP image=$IMAGE batch=$BATCH dspark=$DSPARK resv=$RESV ctx=$CTX"
if [[ -n "$ready" ]]; then
  echo "READY in ${ready}s"
else
  echo "NOT READY within ${WAIT_S}s"
fi
echo "state: $(cat "$OUT/ready-state.txt" 2>/dev/null)"
echo "health: $(head -c 200 "$OUT/ready-health.txt" 2>/dev/null)"
echo "models: $(head -c 300 "$OUT/ready-models.json" 2>/dev/null)"
echo "gpu: $(cat "$OUT/ready.smi" 2>/dev/null)"
echo "--- plan line"
grep -a "native KV pool reservation" "$OUT/ready.log" | tail -1 | sed 's/\x1b\[[0-9;]*m//g'
echo "--- log tail"
tail -6 "$OUT/ready.log"
