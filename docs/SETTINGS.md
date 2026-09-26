# Settings and capacity: the measured operating point

DS41RT v15 (2026-09-26). The v1 measurements (2026-09-14) are kept below for comparison.

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
  --memory-reservation 97% \         # mandatory on 32 GB; the automatic plan refuses
  --dspark-draft-limit 5 \           # the v15 default, passed explicitly
  --http-queue-depth 64              # optional (v15): default = --concurrency; 429 after 25 s
```

Environment: `DS41RT_HOST_CACHE_BYTES=25769803776` (24 GiB host-RAM snapshot cache, upstream since
v6) and `DS41RT_HOST_CACHE_COPY_BUDGET_MS=1000`. Leave `DS41RT_CONSOLE_TEXT` unset: v15 serves a
live console at `/`, and its token-text view would show every session's text.

Container: `--gpus all --network host --ipc host --ulimit memlock=-1:-1 --device=/dev/infiniband`,
`-v <MODEL_DIR>:/model:ro`, and the env `DS41RT_PROTOCOL_V2_VERBS_HOST_DEVICE_MAP` (see
`GATES.md` §4). Result at capacity 1024 on v15: 1.86 GiB pool (about 2.2M tokens), 2.95 GiB
device free, ready 10 s after the container starts (v1: 2.07 GiB pool, 2.9 GiB free). At capacity
256 on v1: 7.79M-token pool, about 3.0 GiB free, readiness in 4 s.

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
| temperature 0-2 | v15 samples (`temperature`, `top_p`, `top_k`, `min_p`, `seed`); v1-v3 refused any temperature but 0 |
| the device map on every rank | see `GATES.md` §4 |

## What v15 measures as (2026-09-26)

Production point above, dSpark on, reasoning off (`reasoning_effort: "none"`), single runs unless
noted, coordinator port share balanced (45.1%). Raw lines: the internal receipts behind this
release; prompts are `bench/hostcache/scripts/hc-ladder.py`'s synthetic words (about 0.21
tokens per character), and the v3 column is the same ladder run on our v3 build on 2026-09-23.

| Prompt tokens | Cold TTFT v3 → v15 | Prefill tok/s (v15) | Exact repeat v3 → v15 |
|---:|---:|---:|---:|
| 6,835 | 1.03 → 1.06 s | 6,436 | 0.005 → 0.005 s |
| 27,314 | 3.62 → 3.46 s | 7,887 | 0.014 → 0.014 s |
| 54,620 | 7.57 → 6.89 s | 7,924 | 0.033 → 0.028 s |
| 218,460 | 43.7 → 34.3 s | 6,374 | 0.183 → 0.174 s |
| 678,487 | 160.5 → 150.8 s | 4,499 | 4.99 → 2.13 s |
| 1,020,840 | 299.3 → 271.7 s | 3,758 | 0.76 → **10.4 s** (MISS, `GATES.md` §5) |

Decode, 8,192-character prose prompt (about 2.3K tokens), 200 output tokens (`hc-ladder.py --mode
decode`; the v3 numbers are the same cell from the 2026-09-15 host-cache campaign):

| | v3 | v15 |
|---|---:|---:|
| 1 stream (tok/s; three runs on v15, four on v3) | 42.9-101.1, median 84.7 | 84.1-126.0, median 86.9 |
| 3 streams, per stream | 44.9 | 42.2 (87.0 aggregate) |
| 6 streams, per stream | 25.8 | 25.9 (101.0 aggregate) |
| 16 streams, per stream | not measured | 10.7 (116.8 aggregate) |

Mixed load: upstream's `scripts/console-load.py`, 16 workers for 20 minutes (prose, code, JSON schema,
tool calls, reasoning, long prompts): 542 requests completed, 0 errors, 0 queue waits, 273,892 output
tokens (about 228 tok/s aggregate), 71.9% of verified drafts accepted, 76 tool calls decoded with
drafts on.

## What v1 and v2 measured (2026-09-14)

The first measurements ran on DS41RT v1 (the table below). The fleet moved to v2 (`9477b6e`) the
same afternoon, and the report (https://services.turquoisebay.ai/share/dsv41-afd-hybrid/) shows
the v2 numbers. v2 at capacity 1024, same prompts: 21k / 85k / 170k / 1M prompt tokens at 4,101 /
5,552 / 5,717 / 4,106 tok/s cold, 1M exact reuse 0.8 s, decode 76.7 tok/s.

v1, all single runs, temperature 0, dSpark on:

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
