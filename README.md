# DS41RT on an RTX 5090: DeepSeek-V4.1-Flash, one 32 GB coordinator + four DGX Spark expert ranks

This is a **source-and-configuration research release** for running
[tpurtell/ds41rt](https://github.com/tpurtell/ds41rt) — the attention-FFN-disaggregated
(AFD) DeepSeek-V4.1-Flash engine — with the **coordinator on a 32 GB RTX 5090** instead of the
96 GB RTX PRO 6000 the upstream release targets. The four DGX Sparks run the unmodified
published expert image. It is not a prebuilt image and not a one-command installer; it is what
we ran, with our addresses and paths taken out, so you can run it on your own machines.

**Release 2.0.0 (2026-09-26) targets DS41RT v15.** Release 1.0.0 targeted v1. v15 brings request
sampling, a bounded request queue (429 + `Retry-After`), speculative decoding that stays on for
tool calls, and a live console; see upstream's release notes. Measured on our fleet on
2026-09-26 (`docs/SETTINGS.md`):
- long-prompt prefill is up to 22% faster than on v3 (218K tokens: 34.3 s cold, was 43.7 s;
  ~1M tokens: 271.7 s, was 299.3 s);
- decode is unchanged (one stream: median 86.9 tok/s on the prose cell);
- one regression: an exact repeat of a ~1M-token prompt takes 10.4 s (0.76 s on v3), because the
  repeat evicts and restores its own snapshot (`docs/GATES.md` §5).

**Release 2.1.0 (2026-09-28) adds `patches/0003`, copy-window drafts.** The rule comes from
[ashhart/TensorFold](https://github.com/ashhart/TensorFold) (MIT). When a greedy request's last 8 tokens
occurred earlier in its history, the tokens that followed are that round's drafts instead of dSpark's.
The target verifies them the same way, so outputs do not change. Measured on our fleet on 2026-09-28
(one stream, greedy, reasoning off, median of 3):
- files written back with one name changed: +7–18% (143.7 → 159.9–169.3 and 142.3 → 152.9–163.0 tok/s,
  two quiet runs);
- a function quoted verbatim: +5–6%;
- fresh code and prose: unchanged;
- 95% of copied drafts accepted.

A 6-minute, 16-worker mixed soak produced as many tokens as v15 (78,874 vs 78,541) with 0 errors.
`DS41RT_COPY_DRAFTS=0` turns it off.

The first public report (prefill, decode, 1M context, concurrency) measured DS41RT **v2**
(`9477b6e`), built on the 5090 by the same method:
**https://services.turquoisebay.ai/share/dsv41-afd-hybrid/**. To rebuild that engine with release
1.0.0's script, which defaults to v1, pass `REV=9477b6e39f4bbe431c4cd6d48c8b303045f9238f` and
`SPARKINFER_COMMIT=bae6e5cf08fc7e51e8ea40f287dcfa95440036fc` (v2's SparkInfer lock), and run the
published `ghcr.io/tpurtell/ds41rt-spark-expert:v2` on the Sparks.

## Part 2: the host-RAM snapshot cache benchmark harness

`bench/hostcache/` holds the load generators, reducers, mock server, test suite and bench plan behind the
second report in this series, **"Same hardware, double the work: a write-back KV snapshot cache for DS41RT"**
(https://services.turquoisebay.ai/share/ds41rt-hostcache/). The cache is upstream since DS41RT v6
(tpurtell/ds41rt PR #4). See `bench/hostcache/README.md`.

## What is in here

| Path | What it is |
|---|---|
| `scripts/afd-build-coordinator.sh` | Rebuilds the coordinator image at DS41RT v15 (`bd06bec`) **on the 5090**, so the AOT kernel export reads that GPU's SM count; applies `patches/` unless `PATCHES=none`. |
| `patches/` | Three patches on top of v15, all independent of the 5090 port (below): two fixes and copy-window drafts. `git am` lands on `51b85c8b`. |
| `scripts/afd-plan-probe.sh` | Boots the coordinator with loopback peers (no Sparks) far enough to read the memory planner's line. How the memory matrix in `docs/GATES.md` was measured. |
| `scripts/afd-ready-probe.sh` | Boots to readiness with loopback peers and serves `/health` and `/v1/models`. The last offline gate. |
| `scripts/afd-preflight.sh` | Read-only GO/NO-GO across the coordinator host and all four Sparks (image revisions, AOT SM count, model shards, ports, memory headroom). `--json` available. |
| `scripts/afd-launch-experts.sh` | Starts one expert rank on a Spark. Dry-run by default. Refuses to start without the fabric address and RDMA device. |
| `scripts/afd-launch-coordinator.sh` | Starts the coordinator at the measured operating point, with the 24 GiB host-RAM snapshot cache. Dry-run by default. |
| `scripts/afd-launch-fleet.sh` | Worker-first bring-up of all four ranks then the coordinator. Dry-run by default. |
| `scripts/afd-stage-engram-tier.sh` | Optional: stage the two Engram shards on a dedicated local device. Formats a device when applied; refuses on partitions or mounts. |
| `scripts/coordinator-footprint.py` | Computes the coordinator-resident weight footprint from the checkpoint's safetensors headers. |
| `docs/GATES.md` | What decides whether this works: the AOT SM-count gate, the memory plan on 32 GB, the Engram mount findings, the multi-port RDMA fix, and what changed at v15. |
| `docs/SETTINGS.md` | The operating point, the pool arithmetic, the hard constraints and the v15 measurements. |
| `docs/RUNBOOK.md` | The ordered sequence: build, stage, preflight, launch, verify, roll back. |

## The patches

- **`0001` streamed usage for proxies.** With `stream_options.include_usage`, v15 attaches the usage
  to the finish chunk, which still carries choices. LiteLLM drops usage from such chunks, so
  prefix-cache hits (`prompt_tokens_details.cached_tokens`) never reached its clients. The patch
  sends the usage in a final `choices: []` chunk before `[DONE]`, as the OpenAI spec and the
  engine's other streaming path do. Measured: an exact repeat reports all 7,112 prompt tokens as
  cached, directly and through LiteLLM.
- **`0002` host-cache RAM eviction.** v15 evicted every prompt snapshot before any turn snapshot. A
  prompt snapshot shares its pages with its conversation's turn snapshot, so under page pressure
  this deleted fresh prompt snapshots, freed almost nothing, and sent exact repeats of recent
  prompts (retries, regenerates, identical agent prompts) back to a cold prefill. The patch evicts
  the least recently used snapshot first; at equal use, a prompt before a turn. Unit-tested in the
  cache crate: 219 pass, including the two soaks. The same defect and fix were measured on our
  MiMo engine (hughmadden/mimo26f-afd v1.1.1).

- **`0003` copy-window drafts.** Agent output often repeats its context: a file written back with
  one name changed, an edit call quoting the lines it replaces.
  - **The rule.** When a greedy request's history ends with 8 tokens that occurred earlier in it, up to
    the draft limit (5 by default) of the tokens that followed the latest earlier occurrence become
    that round's drafts, and dSpark skips that request for the round. Its accepted rows still reach
    dSpark's window through the batch commit.
  - **Verification** is the same sample-and-match rule, so outputs do not change.
  - **When it stops.** A copy that accepts nothing pauses copying for that request for two rounds.
    Sampled requests never copy: in a mixed soak where a third of requests ran at temperature 0.7,
    copying for them too cost 2% of output, against parity for greedy-only copying.
  - **The length policy** learns only from dSpark's own drafts.
  - `/v1/stats` reports `copy_drafts`; `DS41RT_COPY_DRAFTS=0` turns it off.
  - The idea and its 8-token entry come from ashhart/TensorFold (MIT), reimplemented from its
    description. Measurements are above.

## Prerequisites

- **Coordinator host:** x86_64 Linux, an RTX 5090 (32 GB, compute capability 12.0, 170 SMs),
  at least 128 GB of host RAM (the snapshot cache pins 24 GiB), a local NVMe holding the full
  DeepSeek-V4.1-Flash checkpoint (48 shards, about 510 GB), Docker with the NVIDIA runtime, and an
  RDMA-capable NIC on the same RoCE fabric as the Sparks with `/dev/infiniband` exposed.
- **Four DGX Sparks** (GB10, 128 GB unified memory each) on that fabric, each with Docker, the
  published `ghcr.io/tpurtell/ds41rt-spark-expert:v15` image, and the full checkpoint reachable
  at a local path (every rank reads its slices out of all 48 shards). About 100 GiB of free
  unified memory per Spark at launch.
- A clone of `tpurtell/ds41rt` that has commit `bd06bec42e219a65097235dd9092e4a0537d4b7a` (v15).

## The short version

```sh
# 1. build the coordinator on the 5090 host (the AOT export reads this GPU's SM count)
REPO=/path/to/ds41rt scripts/afd-build-coordinator.sh          # -> ds41rt-coordinator-rtx5090:v15

# 2. on each Spark, the expert rank (dry-run first, then --apply), worker-first 3,2,1,0
FABRIC_IP=<spark fabric ip> RDMA_DEVICE=<e.g. rocep1s0f1> scripts/afd-launch-experts.sh <rank> --apply

# 3. the coordinator (capacity 1024; QUEUE_DEPTH=64 if agents send bursts)
PEERS=<ip0>:19441,<ip1>:19441,<ip2>:19441,<ip3>:19441 \
DEVICE_MAP=<coordinator fabric ip>=<coordinator rdma device> \
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-launch-coordinator.sh --apply
```

Or run `scripts/afd-preflight.sh` first and `scripts/afd-launch-fleet.sh --apply` for steps 2
and 3. Every launcher prints the exact `docker run` it would execute before it does.

## Why a rebuild and not a patch

The published coordinator image fails on a 5090 before loading any weights, with CUDA status
101 (`cudaErrorInvalidDevice`). Its native library hard-checks the device's SM count against a
constant generated at AOT export time from whichever GPU ran the export: 188 on the RTX PRO
6000, 170 on the 5090. Patching the check out would be unsound, because the same constant
sizes the launch grids and cluster limits. Running the vendor's own build on the 5090 regenerates
everything for 170 SMs (`docs/GATES.md`). At v15 this is still the case: upstream relaxed only the
expert GEMM check. The three `patches/` are unrelated to the port (two bug fixes and copy-window drafts); `PATCHES=none` builds upstream v15
with the SM count as the only delta from the published image.

The error now names the expected and observed SM counts: our diagnostic pull request was merged
upstream as tpurtell/ds41rt#1 on 2026-09-14.

## Status and honesty

- 2.1.0 (`0003`), measured on one fleet on 2026-09-28 (Sydney):
  - the copy bench above;
  - sampled decode at 200 and 512 tokens, unchanged;
  - API rows 5/5 and the v15 rows;
  - a 6-minute 16-worker soak against v15 with the same script, 0 errors on the coordinator and all
    four ranks;
  - an agent task through a LiteLLM front door, with tool calls.

  The live fleet also served requests during some runs, so single wall-clock cells carry about ±10%.
- v15: measured on one fleet on 2026-09-26 (Sydney), single runs per cell except one-stream decode
  (three runs). The v3 comparison is the same ladder run on our v3 build on 2026-09-23 and the same
  decode cell from 2026-09-15.
- A 20-minute mixed soak at 16 concurrent workers (upstream's `scripts/console-load.py`: prose, code,
  JSON schema, tool calls, reasoning, long prompts) completed 542 requests with 0 errors, 0 queue
  rejects and 0 engine errors; 71.9% of verified drafts were accepted.
- One MISS: the ~1M-token exact repeat (above). The two report pages describe v1 and have not been
  redone for v15.
- The offline probes (`afd-plan-probe.sh`, `afd-ready-probe.sh`) were verified on v1 and not re-run
  on v15.
- Known upstream defect, not fixed here: a prompt containing the fullwidth sentinel `<｜image｜>` as
  text is refused with HTTP 400 by the request adapter (`deepseek-recipe` 0.1.0).
- v1 (2026-09-14): two operating points, one flag pair: prefill capacity 1024 (default; prefill
  5,377 tok/s at 170k prompt tokens, 2.5M-token KV pool) or capacity 256 (`BATCH=80` and
  `CAPACITY=256`; prefill 2,000 tok/s, 7.79M-token pool). Decode is the same at both (74 vs 73.5
  tok/s). The widening was suggested by DS41RT's author and measured the same day. The fleet
  moved to v2 that afternoon (5,717 tok/s at 170k, decode 76.7 tok/s); the report shows v2.
- The like-for-like baseline (the same four Sparks running the reference TP4 vLLM deployment,
  same prompts, same bench) has not been run yet. The report says so where it matters.
- The Engram dedicated-tier script is optional and was **not** needed for the measured results:
  the tables were served from ordinary NVMe with host RAM as page cache and no read bottleneck.

## Credits

- **tpurtell** — the DS41RT engine, its container images, and the AFD architecture.
- **DeepSeek** — the DeepSeek-V4.1-Flash checkpoint.
- **tonyd2wild** — the TP4 DGX-Spark vLLM reference deployment the report compares against.
- **Local Inference Labs** — the standard benchmark used in the report.
- **ashhart/TensorFold** (MIT) — the copy-window drafting rule in `patches/0003` (a verbatim
  continuation from the request's own history, entered after 8 matching tokens), reimplemented
  from its description (https://github.com/ashhart/TensorFold).

The 5090 port, the scripts, the measurements and the docs here are Turquoise Bay AI's work,
released under the MIT licence (`LICENSE`). Upstream files retain their own terms (`NOTICE`),
including the upstream files the three `patches/` change.
