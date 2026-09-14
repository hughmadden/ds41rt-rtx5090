#!/usr/bin/env bash
# afd-build-coordinator.sh — build a coordinator image whose AOT kernels are exported
# for THIS host's GPU (physical_sms = 170 on an RTX 5090).
#
# Why: the published ghcr.io/tpurtell/ds41rt-coordinator:v1 was exported on a 188-SM
# RTX PRO 6000. native/src/v41_fp8.cc:66 (and v41_experts.cc:101,175) hard-reject any
# device whose SM count differs, so the published image cannot start on a 5090.
# `python/tools/export_b12x_v41_fp8_aot.py` reads the SM count from the GPU at export
# time, so running the vendor's own build on the 5090 host fixes it with no source patch.
#
# Mirrors build.sh's coordinator path (build.sh:236-269): dev image -> GPU-enabled
# artifact compile -> release image. Run detached; watch $OUT/build.log.
set -euo pipefail

REPO=${REPO:?set REPO to your ds41rt checkout (git clone --recursive https://github.com/tpurtell/ds41rt)}
OUT=${OUT:-$PWD/afd-build}
DEV_IMAGE=${DEV_IMAGE:-ds41rt-coordinator-dev}
FINAL_IMAGE=${FINAL_IMAGE:-ds41rt-coordinator-rtx5090:v1}
SPARKINFER_COMMIT=${SPARKINFER_COMMIT:-7299b3b92e70d539b2c0a63aaadce36932ceef4d}
CUDA_ARCH=${CUDA_ARCH:-120}

mkdir -p "$OUT"
# Give the Docker CLI a writable config dir (some build hosts have a read-only $HOME).
export DOCKER_CONFIG="${DOCKER_CONFIG:-$OUT/docker-config}"
mkdir -p "$DOCKER_CONFIG"
# Pin the PUBLISHED release revision so the only delta from vendor v1 is the AOT SM count.
# (v1 = 9ea5c964, the revision the published Spark expert image carries. Upstream has since
# published v2; it has not been built or tested on a 5090 by this recipe.)
REV=${REV:-9ea5c96468da690fe7dd01471d4fa2fb8555a606}
cd "$REPO"
git checkout --detach "$REV" >/dev/null 2>&1 || { echo "ERROR: cannot checkout $REV" >&2; exit 1; }
git submodule update --init --recursive >/dev/null 2>&1
engine_commit="$(git rev-parse HEAD)"
[[ "$engine_commit" == "$REV" ]] || { echo "ERROR: HEAD is $engine_commit, expected $REV" >&2; exit 1; }
printf '%s\n' "$engine_commit" >"$OUT/build-head.txt"
log="$OUT/build.log"

step() { echo "== $* ($(date -Is))" | tee -a "$log"; }

step "[1/3] coordinator dev image from $engine_commit"
docker build \
  --build-arg DS41RT_ROLE=coordinator \
  --build-arg CUDA_ARCH="$CUDA_ARCH" \
  --build-arg TARGET_PLATFORM=linux/amd64 \
  --build-arg DS41RT_SPARKINFER_COMMIT="$SPARKINFER_COMMIT" \
  -f docker/Dockerfile.dev -t "$DEV_IMAGE" . 2>&1 | tee -a "$log"

step "[2/3] AOT artifact compile on the local GPU (export reads this host's SM count)"
mkdir -p "$REPO/.ds41rt-release-image"
docker run --rm --gpus device=0 --ipc=host --ulimit memlock=-1:-1 \
  -e CUDA_VISIBLE_DEVICES=0 -e NVIDIA_VISIBLE_DEVICES=0 \
  -v "$REPO:/source:ro" -v "$REPO/.ds41rt-release-image:/output" \
  "$DEV_IMAGE" /source/scripts/build-release-artifacts.sh /source coordinator "$CUDA_ARCH" /output \
  2>&1 | tee -a "$log"

step "AOT manifest totals"
python3 - "$REPO/.ds41rt-release-image/V41_FP8_AOT.json" <<'PY' 2>&1 | tee -a "$log"
import json, sys
m = json.load(open(sys.argv[1]))
print("physical_sms =", m.get("physical_sms"), "capability =", m.get("capability"), "device =", m.get("device"))
PY

step "[3/3] coordinator release image -> $FINAL_IMAGE"
docker build \
  --build-arg DS41RT_ROLE=coordinator \
  --build-arg CUDA_ARCH="$CUDA_ARCH" \
  --build-arg DS41RT_ENGINE_COMMIT="$engine_commit" \
  --build-arg DS41RT_SPARKINFER_COMMIT="$SPARKINFER_COMMIT" \
  --build-arg DS41RT_RELEASE_VERSION="rtx5090-aot170" \
  -f docker/Dockerfile.release -t "$FINAL_IMAGE" . 2>&1 | tee -a "$log"

step "DONE"
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}} {{.ID}}' | grep -E 'ds41rt-coordinator' | tee -a "$log"
