#!/usr/bin/env bash
# afd-launch-coordinator.sh — start the rebuilt DS41RT coordinator on this host against the four
# Spark expert ranks. DRY-RUN BY DEFAULT: prints the exact command and checks preconditions;
# only --apply starts the container.
#
# Verified operating point (docs/GATES.md):
#   capacity 256 (--prefill-batch-tokens 80), dSpark, C1, prefix-cache 0,
#   --memory-reservation 97%  ->  7.79M-token pool, ~3.0 GiB device free, READY in ~4 s.
#
# The vendor run.sh is not used: it hard-codes the reference's hosts/addresses/HF layout.
set -euo pipefail

IMAGE=${IMAGE:-ds41rt-coordinator-rtx5090:v1}
NATIVE_LIB=${NATIVE_LIB:-/opt/ds41rt/lib/libds41rt_native.so}
PEERS=${PEERS:?set PEERS to the four expert ranks in rank order, e.g. <ip0>:19441,<ip1>:19441,<ip2>:19441,<ip3>:19441}
PORT=${PORT:-8000}
BATCH=${BATCH:-80}
# Production candidate (2026-09-14): concurrency 16 (the measured admission
# cap; C16 boots at +6 MB occupancy, 16/16 at 131k and 8/8 at 1M all pass),
# prefix retention 24 (byte-identical memory plan, 496x exact-reuse).
CONC=${CONC:-16}
DSPARK=${DSPARK:-on}
RESV=${RESV:-97%}
CTX=${CTX:-1048576}
MAXOUT=${MAXOUT:-393216}
MODEL_DIR=${MODEL_DIR:?set MODEL_DIR to the DeepSeek-V4.1-Flash snapshot directory}
ENGRAM_DIR=${ENGRAM_DIR:-}            # optional: dedicated device holding shards 47/48 (afd-stage-engram-tier.sh)
# The multi-port RDMA fix (docs/GATES.md): local-ip=device for THIS host's fabric address.
DEVICE_MAP=${DEVICE_MAP:?set DEVICE_MAP to <this-host-fabric-ip>=<rdma-device>, e.g. 192.0.2.3=rocep193s0f0}
ENGRAM_SHARDS=(model-00047-of-00048.safetensors model-00048-of-00048.safetensors)
NAME=${NAME:-ds41rt-afd}
FINGERPRINT=${FINGERPRINT:-unknown}

apply=0
[[ "${1:-}" == "--apply" ]] && apply=1

# Engram tier: bind each dedicated-device shard over its name inside /model. Symlinked
# snapshot directories do NOT work — their targets are host paths absent from the container.
mounts=(-v "$MODEL_DIR:/model:ro")
placed=0
if [[ -n "$ENGRAM_DIR" ]]; then
  for s in "${ENGRAM_SHARDS[@]}"; do
    if [[ -f "$ENGRAM_DIR/$s" ]]; then mounts+=(-v "$ENGRAM_DIR/$s:/model/$s:ro"); placed=$((placed+1)); fi
  done
fi
if [[ $placed -eq 2 ]]; then
  echo "engram tier: dedicated device ($ENGRAM_DIR) — both shards nested-bound into /model"
else
  echo "engram tier: served from MODEL_DIR ($MODEL_DIR) — $placed/2 dedicated-tier shards found (optional; see afd-stage-engram-tier.sh)"
fi

args=(serve-native --snapshot /model --native-lib "$NATIVE_LIB" --peers "$PEERS"
  --listen "0.0.0.0:$PORT"
  --prefill-batch-tokens "$BATCH" --concurrency "$CONC"
  --prefix-cache-entries "${PREFIX_ENTRIES:-24}"
  --max-context-tokens "$CTX" --max-output-tokens "$MAXOUT")
[[ "$DSPARK" == on ]] && args+=(--dspark)
[[ -n "$RESV" ]] && args+=(--memory-reservation "$RESV")

docker rm -f "$NAME" >/dev/null 2>&1 || true
cmd=(docker run -d --name "$NAME" --restart no
  --gpus all --network host --ipc host --ulimit memlock=-1:-1)
[[ -e /dev/infiniband ]] && cmd+=(--device=/dev/infiniband)
# The multi-port RDMA fix is load-bearing (docs/GATES.md): without it queue pairs
# bind the first RDMA device the host enumerates and the RTR transition fails on
# hosts whose fabric address lives on another device.
cmd+=(-e "DS41RT_RELEASE_CONFIG_SHA256=$FINGERPRINT" -e RUST_LOG=info
  -e "DS41RT_PROTOCOL_V2_VERBS_HOST_DEVICE_MAP=${DEVICE_MAP}"
  "${mounts[@]}" "$IMAGE" ds41rt "${args[@]}")

echo "image: $IMAGE"
echo "peers: $PEERS"
echo "model: $MODEL_DIR"
echo "config: cap=$BATCH(->256) conc=$CONC dspark=$DSPARK resv=$RESV ctx=$CTX"
printf 'command:\n  '
printf '%q ' "${cmd[@]}"; echo

if [[ $apply -eq 0 ]]; then
  echo
  echo "DRY RUN. Re-run with --apply to start it. Preconditions: the four expert ranks must"
  echo "already be listening on :19441 (worker-first ordering)."
  exit 0
fi

"${cmd[@]}" >/dev/null
echo "started $NAME; waiting for /health ..."
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "READY. models: $(curl -s -m 5 "http://127.0.0.1:$PORT/v1/models")"
    exit 0
  fi
  [[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" == "true" ]] || break
  sleep 2
done
echo "did not become ready; last log lines:" >&2
docker logs --tail 40 "$NAME" >&2 || true
exit 1
