# DS41RT on an RTX 5090: DeepSeek-V4.1-Flash, one 32 GB coordinator + four DGX Spark expert ranks

This is a **source-and-configuration research release** for running
[tpurtell/ds41rt](https://github.com/tpurtell/ds41rt) — the attention-FFN-disaggregated
(AFD) DeepSeek-V4.1-Flash engine — with the **coordinator on a 32 GB RTX 5090** instead of the
96 GB RTX PRO 6000 the upstream release targets. The four DGX Sparks run the unmodified
published expert image. It is not a prebuilt image and not a one-command installer; it is what
we ran, with our addresses and paths taken out, so you can run it on your own machines.

Measured results (prefill, decode, 1M context, concurrency) are in the public report:
**https://services.turquoisebay.ai/share/dsv41-afd-hybrid/**

## What is in here

| Path | What it is |
|---|---|
| `scripts/afd-build-coordinator.sh` | Rebuilds the coordinator image at the published v1 revision **on the 5090**, so the AOT kernel export reads that GPU's SM count. No source patch. |
| `scripts/afd-plan-probe.sh` | Boots the coordinator with loopback peers (no Sparks) far enough to read the memory planner's line. How the memory matrix in `docs/GATES.md` was measured. |
| `scripts/afd-ready-probe.sh` | Boots to readiness with loopback peers and serves `/health` and `/v1/models`. The last offline gate. |
| `scripts/afd-preflight.sh` | Read-only GO/NO-GO across the coordinator host and all four Sparks (image revisions, AOT SM count, model shards, ports, memory headroom). `--json` available. |
| `scripts/afd-launch-experts.sh` | Starts one expert rank on a Spark. Dry-run by default. Refuses to start without the fabric address and RDMA device. |
| `scripts/afd-launch-coordinator.sh` | Starts the coordinator at the measured operating point. Dry-run by default. |
| `scripts/afd-launch-fleet.sh` | Worker-first bring-up of all four ranks then the coordinator. Dry-run by default. |
| `scripts/afd-stage-engram-tier.sh` | Optional: stage the two Engram shards on a dedicated local device. Formats a device when applied; refuses on partitions or mounts. |
| `scripts/coordinator-footprint.py` | Computes the coordinator-resident weight footprint from the checkpoint's safetensors headers. |
| `docs/GATES.md` | The two findings that decide whether this works: the AOT SM-count gate, and the memory plan on 32 GB. Plus the multi-port RDMA fix. |
| `docs/SETTINGS.md` | The operating point, the pool arithmetic, and the hard constraints. |
| `docs/RUNBOOK.md` | The ordered sequence: build, stage, preflight, launch, verify, roll back. |

## Prerequisites

- **Coordinator host:** x86_64 Linux, an RTX 5090 (32 GB, compute capability 12.0, 170 SMs),
  at least 128 GB of host RAM, a local NVMe holding the full DeepSeek-V4.1-Flash checkpoint
  (48 shards, about 510 GB), Docker with the NVIDIA runtime, and an RDMA-capable NIC on the
  same RoCE fabric as the Sparks with `/dev/infiniband` exposed.
- **Four DGX Sparks** (GB10, 128 GB unified memory each) on that fabric, each with Docker, the
  published `ghcr.io/tpurtell/ds41rt-spark-expert:v1` image, and the full checkpoint reachable
  at a local path (every rank reads its slices out of all 48 shards). About 100 GiB of free
  unified memory per Spark at launch.
- A checkout of `tpurtell/ds41rt` **with submodules** at the v1 revision
  `9ea5c96468da690fe7dd01471d4fa2fb8555a606`. Upstream has since published v2; it has not
  been built or tested on a 5090 by this recipe.

## The short version

```sh
# 1. build the coordinator on the 5090 host (the AOT export reads this GPU's SM count)
REPO=/path/to/ds41rt scripts/afd-build-coordinator.sh          # -> ds41rt-coordinator-rtx5090:v1

# 2. prove it fits and boots, with no Sparks involved
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-ready-probe.sh   # READY in ~4 s

# 3. on each Spark, the expert rank (dry-run first, then --apply), worker-first 3,2,1,0
FABRIC_IP=<spark fabric ip> RDMA_DEVICE=<e.g. rocep1s0f1> scripts/afd-launch-experts.sh <rank> --apply

# 4. the coordinator (capacity 1024 default; BATCH=80 + CAPACITY=256 on the ranks = pool-first point)
PEERS=<ip0>:19441,<ip1>:19441,<ip2>:19441,<ip3>:19441 \
DEVICE_MAP=<coordinator fabric ip>=<coordinator rdma device> \
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-launch-coordinator.sh --apply
```

Or run `scripts/afd-preflight.sh` first and `scripts/afd-launch-fleet.sh --apply` for all of
step 3 and 4. Every launcher prints the exact `docker run` it would execute before it does.

## Why a rebuild and not a patch

The published coordinator image fails on a 5090 before loading any weights, with CUDA status
101 (`cudaErrorInvalidDevice`). Its native library hard-checks the device's SM count against a
constant generated at AOT export time from whichever GPU ran the export: 188 on the RTX PRO
6000, 170 on the 5090. Patching the check out would be unsound, because the same constant
sizes the launch grids and cluster limits. Running the vendor's own build on the 5090 regenerates
everything for 170 SMs and is the only delta from the published image (`docs/GATES.md`).

A small pull request to upstream that names the expected and observed SM counts in that error
is at [hughmadden/ds41rt, branch `sm-count-diagnostic`](https://github.com/hughmadden/ds41rt/tree/sm-count-diagnostic).

## Status and honesty

- Measured on one fleet, on 2026-09-14 (Sydney), single runs per cell. See the report for the
  numbers and their caveats.
- Two operating points, one flag pair: prefill capacity 1024 (default; prefill 5,377 tok/s at
  170k prompt tokens, 2.5M-token KV pool) or capacity 256 (`BATCH=80` and `CAPACITY=256`;
  prefill 2,000 tok/s, 7.79M-token pool). Decode is the same at both (74 vs 73.5 tok/s).
  The widening was suggested by DS41RT's author and measured the same day.
- The like-for-like baseline (the same four Sparks running the reference TP4 vLLM deployment,
  same prompts, same bench) has not been run yet. The report says so where it matters.
- The Engram dedicated-tier script is optional and was **not** needed for the measured results:
  the tables were served from ordinary NVMe with host RAM as page cache and no read bottleneck.

## Credits

- **tpurtell** — the DS41RT engine, its container images, and the AFD architecture.
- **DeepSeek** — the DeepSeek-V4.1-Flash checkpoint.
- **tonyd2wild** — the TP4 DGX-Spark vLLM reference deployment the report compares against.
- **Local Inference Labs** — the standard benchmark used in the report.

The 5090 port, the scripts, the measurements and the docs here are Turquoise Bay AI's work,
released under the MIT licence (`LICENSE`). Upstream files retain their own terms (`NOTICE`).
