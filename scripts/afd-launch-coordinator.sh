#!/usr/bin/env bash
# afd-launch-coordinator.sh — start the rebuilt DS41RT coordinator on this host against the four
# Spark expert ranks. DRY-RUN BY DEFAULT: prints the exact command and checks preconditions;
# only --apply starts the container.
#
# Verified operating points (docs/GATES.md):
#   capacity 1024 (--prefill-batch-tokens 1024), dSpark, C16, prefix-cache 24,
#   --memory-reservation 97%  ->  v15: KV pool 1.86 GiB, 2.95 GiB device free   (default)
#   capacity 256  (--prefill-batch-tokens 80),   same otherwise -> 7.79M-token pool (BATCH=80,
#   measured on v1)
#
# The vendor run.sh is not used: it hard-codes the reference's hosts/addresses/HF layout.
set -euo pipefail

IMAGE=${IMAGE:-ds41rt-coordinator-rtx5090:v15}
NATIVE_LIB=${NATIVE_LIB:-/opt/ds41rt/lib/libds41rt_native.so}
PEERS=${PEERS:?set PEERS to the four expert ranks in rank order, e.g. <ip0>:19441,<ip1>:19441,<ip2>:19441,<ip3>:19441}
PORT=${PORT:-8000}
# Default 1024 (2026-09-14): the prefill-first operating point -- prefill 5,377 tok/s at
# 170k prompt tokens vs 2,000 at capacity 256 (2.69x), decode unchanged, pool 2.07 GiB
# (~2.5M tokens). BATCH=80 selects capacity 256, the pool-first point (7.79M tokens).
BATCH=${BATCH:-1024}
# Production candidate (2026-09-14): concurrency 16 (the measured admission
# cap; C16 boots at +6 MB occupancy, 16/16 at 131k and 8/8 at 1M all pass),
# prefix retention 24 (byte-identical memory plan, 496x exact-reuse).
CONC=${CONC:-16}
DSPARK=${DSPARK:-on}
RESV=${RESV:-97%}
CTX=${CTX:-1048576}
MAXOUT=${MAXOUT:-393216}
DRAFT_LIMIT=${DRAFT_LIMIT:-5}         # dSpark draft length cap (the v15 default, passed explicitly)
# Host-RAM snapshot cache (upstream since v6): 24 GiB of page-locked RAM holds evicted prompt and
# turn snapshots, so a returning conversation restores instead of prefilling. 0 turns it off;
# `auto` sizes it from retained entries x context (not measured here).
HOST_CACHE_BYTES=${HOST_CACHE_BYTES:-25769803776}
HOST_CACHE_COPY_BUDGET_MS=${HOST_CACHE_COPY_BUDGET_MS:-1000}
# Bounded HTTP queue (v15): requests waiting for a slot before callers are held up to
# QUEUE_WAIT_MS and then answered 429 + Retry-After. Unset = the engine default (depth =
# --concurrency, 25 s); agent fan-outs of 30-100 requests fit with QUEUE_DEPTH=64.
QUEUE_DEPTH=${QUEUE_DEPTH:-}
QUEUE_WAIT_MS=${QUEUE_WAIT_MS:-}
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
[[ "$DSPARK" == on && -n "$DRAFT_LIMIT" ]] && args+=(--dspark-draft-limit "$DRAFT_LIMIT")
[[ -n "$QUEUE_DEPTH" ]] && args+=(--http-queue-depth "$QUEUE_DEPTH")
[[ -n "$QUEUE_WAIT_MS" ]] && args+=(--http-queue-wait-ms "$QUEUE_WAIT_MS")

cmd=(docker run -d --name "$NAME" --restart no
  --gpus all --network host --ipc host --ulimit memlock=-1:-1)
[[ -e /dev/infiniband ]] && cmd+=(--device=/dev/infiniband)
# The multi-port RDMA fix is load-bearing (docs/GATES.md): without it queue pairs
# bind the first RDMA device the host enumerates and the RTR transition fails on
# hosts whose fabric address lives on another device.
# The live console at / keeps its token-text view off (it would show every session's text to
# anyone who reaches the port): do not set DS41RT_CONSOLE_TEXT.
cmd+=(-e "DS41RT_RELEASE_CONFIG_SHA256=$FINGERPRINT" -e RUST_LOG=info
  -e "DS41RT_PROTOCOL_V2_VERBS_HOST_DEVICE_MAP=${DEVICE_MAP}"
  -e "DS41RT_HOST_CACHE_BYTES=$HOST_CACHE_BYTES" -e "DS41RT_HOST_CACHE_COPY_BUDGET_MS=$HOST_CACHE_COPY_BUDGET_MS"
  "${mounts[@]}" "$IMAGE" ds41rt "${args[@]}")

echo "image: $IMAGE"
echo "peers: $PEERS"
echo "model: $MODEL_DIR"
echo "config: batch=$BATCH conc=$CONC dspark=$DSPARK(limit $DRAFT_LIMIT) resv=$RESV ctx=$CTX host-cache=$HOST_CACHE_BYTES queue=${QUEUE_DEPTH:-default}"
printf 'command:\n  '
printf '%q ' "${cmd[@]}"; echo

if [[ $apply -eq 0 ]]; then
  echo
  echo "DRY RUN. Re-run with --apply to start it. Preconditions: the four expert ranks must"
  echo "already be listening on :19441 (worker-first ordering)."
  exit 0
fi

# Only --apply replaces an existing container of this name (a dry run used to remove it too):
# keep a rollback container under another NAME.
docker rm -f "$NAME" >/dev/null 2>&1 || true
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
