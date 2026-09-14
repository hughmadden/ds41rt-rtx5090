#!/usr/bin/env bash
# afd-launch-experts.sh -- start ONE DS41RT Spark expert rank. RUN ON THE SPARK ITSELF
# (or from the coordinator host via ssh). DRY-RUN BY DEFAULT; --apply starts the container.
#
# Mirrors the vendor run.sh:145-160 invocation exactly, with our own snapshot path
# instead of the HF-cache layout (we invoke expertd-native directly).
#
# Rank order must match the coordinator's --peers order (rank N = the Nth peer).
#
# Usage:  FABRIC_IP=<this host's fabric address> RDMA_DEVICE=<rdma device carrying it> \
#         afd-launch-experts.sh <rank> [--apply]
set -euo pipefail

IMAGE=${IMAGE:-ghcr.io/tpurtell/ds41rt-spark-expert:v1}
MODEL_DIR=${MODEL_DIR:-/models/DeepSeek-V4.1-Flash}
NATIVE_LIB=${NATIVE_LIB:-/opt/ds41rt/lib/libds41rt_native.so}
CAPACITY=${CAPACITY:-256}          # matches coordinator --prefill-batch-tokens 80
BUDGET=${BUDGET:-107374182400}     # SPARK_DEVICE_BUDGET_BYTES = 100 GiB
PORT=${PORT:-19441}
FINGERPRINT=${FINGERPRINT:-unknown}
RANK=${1:?usage: afd-launch-experts.sh <rank 0..3> [--apply]}
apply=0; [[ "${2:-}" == "--apply" ]] && apply=1
NAME=${NAME:-ds41rt-expert-$RANK}

case "$RANK" in 0|1|2|3) ;; *) echo "rank must be 0..3" >&2; exit 2 ;; esac
case "$CAPACITY" in 80|256|1024|4096) ;; *) echo "capacity must be 80/256/1024/4096" >&2; exit 2 ;; esac

# The device map is REQUIRED on Sparks with more than one RDMA device: without it
# queue pairs bind the first device the host enumerates, which may carry no IPv4
# RoCEv2 address, and the RTR transition fails (docs/GATES.md). Both values must be
# set per host; unset refuses rather than guessing. Find the device with
# `ibv_devices` / `ibdev2netdev` and the address with `ip -4 addr`.
: "${FABRIC_IP:?set FABRIC_IP to the fabric address of this host}"
: "${RDMA_DEVICE:?set RDMA_DEVICE to the RDMA device that carries FABRIC_IP (e.g. rocep1s0f1)}"

echo "== preflight (rank $RANK)"
missing=0
docker info >/dev/null 2>&1 || { echo "docker unavailable" >&2; exit 1; }
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "  image: present ($IMAGE)"
else
  echo "  image: MISSING - run: docker pull $IMAGE" >&2; missing=1
fi
for f in config.json model.safetensors.index.json; do
  if [[ -f "$MODEL_DIR/$f" ]]; then
    echo "  model: $f present"
  else
    echo "  model: MISSING $MODEL_DIR/$f" >&2; missing=1
  fi
done
n=$(ls "$MODEL_DIR"/model-*-of-00048.safetensors 2>/dev/null | wc -l || true)
echo "  model shards: $n/48"
if [[ "$n" != "48" ]]; then
  echo "  WARNING: every rank reads its routed slices out of all 48 shards; staging must be complete" >&2
  missing=1
fi
if ss -ltn "sport = :$PORT" 2>/dev/null | tail -n +2 | grep -q .; then
  echo "  port $PORT already in use - another expert may be running" >&2; missing=1
else
  echo "  port $PORT free"
fi
echo "  preflight: $([[ $missing -eq 0 ]] && echo OK || echo INCOMPLETE)"

cmd=(docker run -d --name "$NAME" --restart no --gpus all --network host --ipc host
  --ulimit memlock=-1:-1 --device=/dev/infiniband
  -e "DS41RT_PROTOCOL_V2_VERBS_HOST_DEVICE_MAP=${FABRIC_IP}=${RDMA_DEVICE}"
  -e "DS41RT_RELEASE_CONFIG_SHA256=$FINGERPRINT"
  -v "$MODEL_DIR:/models:ro" "$IMAGE"
  ds41rt expertd-native --snapshot /models --native-lib "$NATIVE_LIB"
  --rank "$RANK" --capacity "$CAPACITY" --device-budget-bytes "$BUDGET"
  --listen "0.0.0.0:$PORT")

echo "command:"
printf '  '; printf '%q ' "${cmd[@]}"; echo
if [[ $apply -eq 0 ]]; then
  echo; echo "DRY RUN. Re-run with --apply. Start ranks in worker-first order (3,2,1,0) as the reference does."
  exit 0
fi
if [[ $missing -eq 1 ]]; then echo "preflight incomplete - refusing --apply" >&2; exit 1; fi

docker rm -f "$NAME" >/dev/null 2>&1 || true
"${cmd[@]}" >/dev/null
echo "started $NAME (rank $RANK) on port $PORT"
for _ in $(seq 1 60); do
  st=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo gone)
  [[ "$st" == "running" ]] || { echo "container is $st; logs:" >&2; docker logs --tail 30 "$NAME" >&2 || true; exit 1; }
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then echo "rank $RANK listening on $PORT"; exit 0; fi
  sleep 2
done
echo "rank $RANK did not begin listening; logs:" >&2; docker logs --tail 30 "$NAME" >&2 || true; exit 1
