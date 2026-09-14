# Settings and capacity: the measured operating point

## Coordinator (RTX 5090, 32 GB)

```
ds41rt serve-native --snapshot /model \
  --native-lib /opt/ds41rt/lib/libds41rt_native.so \
  --peers <ip0>:19441,<ip1>:19441,<ip2>:19441,<ip3>:19441 \
  --listen 0.0.0.0:8000 \
  --prefill-batch-tokens 1024 \      # = prefill capacity 1024 (default); 80 = capacity 256, pool-first
  --concurrency 16 \                 # the engine's admission cap; 16/16 at 105k, 8/8 at 679k served
  --prefix-cache-entries 24 \        # free in pool terms; 0.8 s exact reuse of a 679k prompt
  --max-context-tokens 1048576 \
  --max-output-tokens 393216 \
  --dspark \
  --memory-reservation 97%           # mandatory on 32 GB; the automatic plan refuses
```

Container: `--gpus all --network host --ipc host --ulimit memlock=-1:-1 --device=/dev/infiniband`,
`-v <MODEL_DIR>:/model:ro`, and the env `DS41RT_PROTOCOL_V2_VERBS_HOST_DEVICE_MAP` (see
`GATES.md` §4). Result at capacity 1024: 26.35 GiB occupied, 2.07 GiB pool (about 2.5M tokens),
about 2.9 GiB device free, readiness in seconds. At capacity 256: 7.79M-token pool, about 3.0 GiB
free, readiness in 4 s.

## Expert ranks (four DGX Sparks, published arm64 image)

```
ds41rt expertd-native --snapshot /models --native-lib /opt/ds41rt/lib/libds41rt_native.so \
  --rank <0..3> --capacity 1024 --device-budget-bytes 107374182400 --listen 0.0.0.0:19441
```

`--capacity` must equal the coordinator's rounded prefill capacity or the ranks disagree.
The published expert image's AOT export covers capacities 1, 16, 80, 256, 1024 and 4096.
Start ranks worker-first (3, 2, 1, 0), then the coordinator; rank N must be the Nth peer.

## The pool arithmetic

- KV costs **890 bytes per token** (FP4 E2M1 source KV with group-16 scales, FP8 sliding
  windows, an independent FP4 index; the planner's 455,680-byte 512-token group).
- Capacity 1024 (default): 2.07 GiB pool ≈ 2.5M tokens, 2.4× the 1,048,576 maximum context.
- Capacity 256: 7.79M tokens = 15,218 groups × 512, 7.4× the maximum context.
- The pool is a shared budget across concurrent requests; the prefill lane (capacity 256)
  admits work serially, which is why eight concurrent 679k-token requests never exhausted it.

## Hard constraints on this card

| constraint | why |
|---|---|
| `--memory-reservation 97%` | the automatic pool plan over-requests and fails |
| prefill capacity 1024 or 256 with dSpark | dSpark is 7.95 GB resident; 1024 + dSpark leaves 2.07 GiB for the pool (measured), 256 leaves 7.4 GiB |
| prefill capacity 4096 never | out of memory at `cudaMalloc`, with or without dSpark |
| temperature 0 | the engine's native sampling path requires it |
| the device map on every rank | see `GATES.md` §4 |

## What this operating point measures as

Summarised from the report (https://services.turquoisebay.ai/share/dsv41-afd-hybrid/), all
single runs, temperature 0, dSpark on:

| | value |
|---|---|
| cold prefill, capacity 1024, 21k / 85k / 170k / 679k prompt tokens | 3,848 / 5,384 / 5,377 / 4,020 tok/s |
| cold prefill, capacity 256, 26k / 105k / 170k / 679k prompt tokens | 1,913 / 1,997 / 2,000 / 1,709 tok/s |
| exact-prefix reuse, 679k-token prompt | 0.8 s (vs 169 s cold at 1024, 397 s at 256) |
| decode, one stream, essay prompt / code-and-reasoning prompt | 74.1 / 85.6 tok/s (73.5 at capacity 256) |
| decode, six streams, code-and-reasoning bench | 167.9 tok/s aggregate, 30.4 per stream |
| concurrency (measured at capacity 256) | 16 × 105k-token requests all served; 8 × 679k-token requests all served |

For scale, the upstream 96 GB reference at prefill capacity 4096 cold-prefills its 1M prompt in
322 s (upstream's figure); the 32 GB card trades some prefill speed for feasibility.
