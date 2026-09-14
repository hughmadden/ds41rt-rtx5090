# The gates: what decides whether DS41RT's coordinator runs on a 32 GB RTX 5090

Three findings, each measured on the 5090 before any Spark was involved, plus the one fabric
fault that stopped the first real boot. All dates are 2026-09-13/14 (Sydney).

## 1. The published coordinator image cannot start on a 5090 (AOT SM-count gate)

**Symptom.** `ghcr.io/tpurtell/ds41rt-coordinator:v1` fails immediately, before loading any
weights:

```
ERROR ds41rt::v41_native_serve: native target worker stopped
  error=native V4.1 FP8 initialization failed with CUDA status 101
```

CUDA status 101 is `cudaErrorInvalidDevice`. The GPU is visible inside the container; this is
not a driver or container problem.

**Cause, source-level.** `native/src/v41_fp8.cc` (`ds41rt_v41_fp8_matrix_initialize`) checks

```c
if (major != 12 || minor != 0 || sms != DS41RT_V41_FP8_SMS) return cudaErrorInvalidDevice;
```

and `native/src/v41_experts.cc` has the same check twice against `DS41RT_V41_SMS`.
Neither constant is a property of the architecture: `python/tools/export_b12x_v41_fp8_aot.py`
and `export_b12x_v41_experts_aot.py` generate them from
`torch.cuda.get_device_properties(device).multi_processor_count` on **whichever GPU runs the
AOT export**, and the same value sizes the per-row launch grids and the cluster limit
(`2 * DS41RT_V41_SMS`). The published image was exported on an RTX PRO 6000 Blackwell
(188 SMs); a 5090 has 170.

**Why not patch the check.** The grids and cluster counts are sized from the same constant,
so bypassing the equality check would launch 188-SM geometry on a 170-SM device. Not safe
without the maintainer's confirmation.

**Fix.** Run the vendor's own three-step coordinator build on the 5090 host
(`scripts/afd-build-coordinator.sh`, mirroring upstream `build.sh`): dev image, then the
GPU-enabled artifact compile where the export reads this GPU, then the release image. The result
is label-identical to the published v1 (`org.opencontainers.image.revision`,
`io.ds41rt.sparkinfer.revision`, `io.ds41rt.cuda_arch`) except `V41_FP8_AOT.json`
`physical_sms` = 170. The published Spark expert image is unaffected: it was exported on GB10
and the Sparks are GB10.

## 2. The memory plan on 32 GB (measured matrix)

Method: `scripts/afd-plan-probe.sh` boots the rebuilt coordinator with four loopback peers.
DS41RT's RoCE client connects lazily on the first served request, so the memory planner runs
and reports measured device occupancy without any expert reachable. `--concurrency 1`,
`--prefix-cache-entries 0`, pool forced to 64 MiB so the residual is visible.

| prefill capacity | dSpark | device occupied | free for the KV pool | max pool at 890 B/token |
|---:|:---:|---:|---:|---:|
| 256 | off | 14.29 GiB | 15.10 GiB | 18.2M tokens |
| 1024 | off | 18.20 GiB | 11.20 GiB | 13.5M tokens |
| 256 | on | 21.99 GiB | 7.40 GiB | 8.9M tokens |
| 1024 | on | 25.98 GiB | 3.42 GiB | 4.1M tokens |
| 256, concurrency 2 | on | 22.00 GiB | 7.40 GiB | 8.9M tokens (+6 MB for the second lane) |
| 4096 | off | out of memory at `cudaMalloc` | | |
| 4096 | on | out of memory at `cudaMalloc` | | |

Readings that matter:

- **The vendor default does not fit.** The automatic pool path plans the worst case and refuses
  on 32 GB. `--memory-reservation 97%` is mandatory.
- **dSpark costs 7.95 GB resident.** Capacity 1024 with dSpark leaves 3.4 GiB for the pool;
  capacity 256 with dSpark leaves 7.4 GiB. Capacity 4096 never boots on this card.
- **Chosen operating point:** capacity 256 (`--prefill-batch-tokens 80`), dSpark on,
  `--memory-reservation 97%` → **7.79M-token pool, ~3.0 GiB device free, readiness in 4 s**
  (`scripts/afd-ready-probe.sh`; plan line `global_bytes=6934538240`; `nvidia-smi` 29,150 MiB
  used / 3,001 MiB free).
- **Prefix retention is free.** `--prefix-cache-entries 24` produces a byte-identical memory
  plan: the retention banks live in the engine's fixed 2 GiB runtime headroom.
- **Concurrency is nearly free in memory:** the second lane adds 6 MB; concurrency 16 boots.

Failure behaviour with no expert reachable is clean: a request returns a typed HTTP 500 in
about 0.1 s naming the peer, `/health` stays 200, the container stays up.

## 3. Engram tables: host tier, mounts, and the optional dedicated device

DS41RT keeps the two Engram n-gram tables (shards 47 and 48, 188.8 GiB) host-mapped on the
coordinator, never in VRAM. Two practical findings:

- **A symlinked snapshot directory does not work.** Symlink targets are host paths that do not
  exist inside the container; the engine fails with `opening /model/config.json: No such file
  or directory`. Bind the shards *over* their names inside `/model` instead (nested read-only
  binds, which Docker applies by longest path). `scripts/afd-launch-coordinator.sh` does this
  when `ENGRAM_DIR` is set.
- **Ordinary NVMe was enough.** With the tables on the coordinator host's NVMe and host RAM as
  page cache, dropping the page cache changed neither prefill (2,100 vs 1,913 tok/s at 26k
  prompt tokens, within noise) nor decode (74.3 vs 73.5 tok/s). A dedicated device
  (`scripts/afd-stage-engram-tier.sh`) is optional at this operating point.

## 4. The fabric fault that stopped the first boot: multi-port RDMA device selection

**Symptom.** Coordinator and all four ranks up and healthy, every request failing with
`verbs-host ProtocolV2 control plane closed`.

**Cause.** The expert's RoCE bootstrap failed at `ibv_modify_qp` to ready-to-receive. Its queue
pair was created on the **first** RDMA device the host enumerated, which carried no IPv4 RoCEv2
GID; the fabric address lived on the second port. Host-to-host `ib_send_bw` between the
coordinator and a Spark passed, because perftest binds by device name; that isolated the fault to
device selection inside the engine.

**Fix.** DS41RT has an undocumented, code-only map consumed for both client and server endpoint
creation:

```
DS41RT_PROTOCOL_V2_VERBS_HOST_DEVICE_MAP=<local-fabric-ip>=<rdma-device>[,<ip>=<device>...]
```

Set it on every expert rank and on the coordinator, each with its own address and device. After
the map: RTR/RTS pass, persistent connections establish, requests serve. The launchers here
require `FABRIC_IP` + `RDMA_DEVICE` (experts) and `DEVICE_MAP` (coordinator) and refuse to
start without them. Find the device with `ibv_devices` / `ibdev2netdev` and the address with
`ip -4 addr`.
