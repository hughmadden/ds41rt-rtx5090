#!/usr/bin/env bash
# afd-build-coordinator.sh — build a DS41RT v15 coordinator image whose AOT kernels are exported
# for THIS host's GPU (physical_sms = 170 on an RTX 5090).
#
# Why: the published ghcr.io/tpurtell/ds41rt-coordinator:v15 was exported on a 188-SM RTX PRO
# 6000. native/src/v41_fp8.cc (ds41rt_v41_fp8_matrix_initialize) and native/src/v41_experts.cc
# (ds41rt_v41_expert_input_quant_initialize) still reject any device whose SM count differs from
# the export's (upstream bfae964c relaxed only the expert GEMM check), so the published image
# cannot start on a 5090. The AOT exporter reads the SM count from the GPU it runs on, so running
# the vendor's own build on the 5090 host fixes it with no source patch.
#
# Mirrors upstream build.sh's coordinator leg at the v15 image source (bd06bec): pinned
# SparkInfer/XGrammar/DLPack submodules only (NOT --recursive: v15 also registers an SSH-only
# submodule the coordinator does not need), dev image -> GPU artifact compile -> release image.
#
# PATCHES=on (default) applies this repository's patches/ with `git am`, which lands on a fixed
# commit (EXPECT_HEAD) because the patches carry their author and dates:
#   0001  streamed include_usage: usage in a final choices:[] chunk (LiteLLM keeps cached_tokens)
#   0002  host cache: RAM eviction least recently used first, not every prompt before any turn
#   0003  copy-window drafts: when a greedy request's last 8 tokens occurred earlier in its
#         history, the tokens that followed are that round's drafts instead of dSpark's (idea
#         from ashhart/TensorFold, MIT); DS41RT_COPY_DRAFTS=0 turns it off
# PATCHES=none builds upstream bd06bec unchanged.
#
# Needs the whole GPU for step 2 (the export). Run detached; watch $OUT/build.log.
set -euo pipefail

REPO=${REPO:?set REPO to your ds41rt checkout (git clone https://github.com/tpurtell/ds41rt)}
OUT=${OUT:-$PWD/afd-build}
DEV_IMAGE=${DEV_IMAGE:-ds41rt-coordinator-dev:v15}
FINAL_IMAGE=${FINAL_IMAGE:-ds41rt-coordinator-rtx5090:v15}
RELEASE_VERSION=${RELEASE_VERSION:-rtx5090-aot170-v15}
CUDA_ARCH=${CUDA_ARCH:-120}
# v15: the commit both published v15 images were built from. The v15 tag (b4517141) adds only
# docs and configs on top of it.
REV=${REV:-bd06bec42e219a65097235dd9092e4a0537d4b7a}
PATCHES=${PATCHES:-on}
EXPECT_HEAD=${EXPECT_HEAD:-51b85c8bad57ed4616f72a13a4dcd2155e0f9058}
SPARKINFER_PIN=${SPARKINFER_PIN:-7fcc094edcc93af61fdfbe14300100e3204363ea}
PATCH_DIR="$(cd "$(dirname "$0")/.." && pwd)/patches"

mkdir -p "$OUT"
# Give the Docker CLI a writable config dir (some build hosts have a read-only $HOME).
export DOCKER_CONFIG="${DOCKER_CONFIG:-$OUT/docker-config}"
mkdir -p "$DOCKER_CONFIG"
log="$OUT/build.log"
step() { echo "== $* ($(date -Is))" | tee -a "$log"; }

cd "$REPO"
git checkout --detach "$REV" >/dev/null 2>&1 || { echo "ERROR: cannot checkout $REV (git fetch first?)" >&2; exit 1; }
if [[ "$PATCHES" == on ]]; then
  git -c user.name="Turquoise Bay AI" -c user.email="11993289+hughmadden@users.noreply.github.com" \
    am -q --committer-date-is-author-date "$PATCH_DIR"/*.patch
  [[ "$(git rev-parse HEAD)" == "$EXPECT_HEAD" ]] ||
    { echo "ERROR: patched HEAD is $(git rev-parse HEAD), expected $EXPECT_HEAD" >&2; exit 1; }
fi
engine_commit="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "ERROR: tracked changes in $REPO" >&2; exit 1; }
printf '%s\n' "$engine_commit" >"$OUT/build-head.txt"

step "pinned source dependencies (build.sh prepare_pinned_source_dependencies)"
git submodule sync -- third_party/sparkinfer third_party/xgrammar
git submodule update --init --checkout -- third_party/sparkinfer third_party/xgrammar
git -C third_party/xgrammar submodule sync -- 3rdparty/dlpack
git -C third_party/xgrammar submodule update --init --checkout -- 3rdparty/dlpack
sparkinfer_commit=$(python3 scripts/verify-sparkinfer-source.py --source third_party/sparkinfer \
  --lock third_party/sparkinfer.lock.json --print-revision)
[[ "$sparkinfer_commit" == "$SPARKINFER_PIN" ]] || { echo "ERROR: SparkInfer $sparkinfer_commit, expected $SPARKINFER_PIN" >&2; exit 1; }
python3 scripts/verify-xgrammar-source.py --source third_party/xgrammar --lock third_party/xgrammar.lock.json

step "[1/3] coordinator dev image from $engine_commit"
docker build \
  --build-arg DS41RT_ROLE=coordinator \
  --build-arg CUDA_ARCH="$CUDA_ARCH" \
  --build-arg TARGET_PLATFORM=linux/amd64 \
  --build-arg DS41RT_SPARKINFER_COMMIT="$sparkinfer_commit" \
  -f docker/Dockerfile.dev -t "$DEV_IMAGE" . 2>&1 | tee -a "$log"

if [[ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]]; then
  echo "ERROR: a process holds the GPU; the AOT export needs the whole device" >&2; exit 1
fi
step "[2/3] AOT artifact compile on the local GPU (export reads this host's SM count)"
mkdir -p "$REPO/.ds41rt-release-image"
docker run --rm --gpus device=0 --ipc=host --ulimit memlock=-1:-1 \
  -e CUDA_VISIBLE_DEVICES=0 -e NVIDIA_VISIBLE_DEVICES=0 \
  -v "$REPO:/source:ro" -v "$REPO/.ds41rt-release-image:/output" \
  "$DEV_IMAGE" /source/scripts/build-release-artifacts.sh /source coordinator "$CUDA_ARCH" /output \
  2>&1 | tee -a "$log"

step "AOT manifests (physical_sms must be this GPU's: 170 on a 5090)"
python3 - "$REPO/.ds41rt-release-image" <<'PY' 2>&1 | tee -a "$log"
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
for name in ("V41_FP8_AOT.json", "V41_EXPERT_AOT.json"):
    m = json.loads((d / name).read_text())
    print(name, "physical_sms =", m.get("physical_sms"), "capability =", m.get("capability"), "device =", m.get("device"))
PY

step "[3/3] coordinator release image -> $FINAL_IMAGE"
docker build \
  --build-arg DS41RT_ROLE=coordinator \
  --build-arg CUDA_ARCH="$CUDA_ARCH" \
  --build-arg DS41RT_ENGINE_COMMIT="$engine_commit" \
  --build-arg DS41RT_SPARKINFER_COMMIT="$sparkinfer_commit" \
  --build-arg DS41RT_RELEASE_VERSION="$RELEASE_VERSION" \
  --build-arg DS41RT_V41_SPARK_TP_ROLES= \
  -f docker/Dockerfile.release -t "$FINAL_IMAGE" . 2>&1 | tee -a "$log"

step "DONE"
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}} {{.ID}}' | grep -E 'ds41rt-coordinator' | tee -a "$log"
