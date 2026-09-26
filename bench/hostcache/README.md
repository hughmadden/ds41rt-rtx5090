# Host-cache benchmark harness (DS41RT host-RAM snapshot cache)

The harness behind the public report **"Same hardware, double the work: a write-back KV snapshot cache
for DS41RT"** — https://services.turquoisebay.ai/share/ds41rt-hostcache/ — published so the report's
numbers can be reproduced and the load models reused. Addresses and paths are taken out (the repo's
convention); everything else is exactly what ran on our fleet on 2026-09-15.

The cache itself (the `ds41rt-hostcache` crate and the engine binding) is upstream: it was merged into
tpurtell/ds41rt as PR #4 on 2026-09-17 and ships from DS41RT v6. The two engine-limit fixes are upstream
too (v6): the admission requeue (issue #2, commit `5f487c14`) and the bounded front-door queue with 429 +
`Retry-After` (issue #3, commit `7c35f3e5`). The fork these were first built on (`hostcache/rc4`, the
production candidate the report measures; `hostcache/rc6`) is retired. One later fix to the cache's RAM
eviction order is in this repository's `patches/0002` (see the top-level README).

| File | What it is |
|---|---|
| `scripts/hc-rotate.py` | Rotating concurrent-session load generator with host-cache accounting: R1–R5 steady rotations, the B4 ramps, the B5 agentic loop (`--sessions 1`, `--turn-gap-secs`), the B3 recovery segment; treats HTTP 503/429 as backpressure (jittered retries, `Retry-After` honoured). Every request record carries TTFT, decode tok/s, usage hit/miss tokens and the `/v1/stats` bracket. |
| `scripts/hc-ladder.py` | Cold / reuse / evict-restore / decode prompt ladders (the B1 no-overhead cell, the 1M rung, the A/B/A passes). |
| `scripts/hc-equiv.py` | Cold-versus-restored output equivalence at temperature 0 (exit 3 on divergence) — the first test to port. |
| `scripts/hc-matrix.sh` | Resumable driver for the whole matrix: `hc-matrix.sh <off|on> <cell...>` with per-point bar checks written into the cell JSONL. Cells: b1-*, b2-r1…r5, b3-recovery, b4-sessions, b4-context, b5-agentic. |
| `scripts/hc-build-corpus.py` | Deterministic prose and code corpora from real text (the reference kit's prompt set tiles to nine strings and is unrealistic for the drafter and the n-gram tables). |
| `scripts/hc-report.py` | Reduces rotation JSONL cells to the standard markdown tables (per-segment TTFT/decode/hit share, counter deltas, verdicts). |
| `scripts/hc-ladder-report.py` | Reduces ladder cells (cold rungs OFF vs ON with ratios, reuse/after-evict restores, decode rungs). |
| `scripts/hc-final-report.py` | Assembles the internal report from a draft plus the cell JSONLs (B1–B5 tables, the 1M rung). |
| `scripts/hc-mock-server.py` | Offline mock of the coordinator API (SSE, usage accounting, `/v1/stats`, every-N 503/429 refusals with `Retry-After`) so the harness has its own tests with zero fleet contact. |
| `scripts/test-hc-rotate.sh` | The harness's own suite (125 checks on 2026-09-15) against the mock: run it once at a time, it is timing-sensitive under load. |
| `PLAN.md` | The bench plan as it was run: goals, decisions, cell definitions, bars, choreography and the honesty notes. An internal planning document, published as-is apart from the address scrub. |

## Running it

```bash
# corpora once (real prose + a pinned code tree), then the cells against a coordinator
python3 scripts/hc-build-corpus.py --prompts-json <reference-kit>/bench/prompts-v1.json \
        --code-tree <ds41rt-checkout> --out-dir <corpus-dir> --min-chars 16000000
export CORPUS_DIR=<corpus-dir> TPC_PROSE=0.31 BASE=http://<coordinator>:8000 OUT=<results-dir>
scripts/hc-matrix.sh off b1 ; scripts/hc-matrix.sh on b1           # no-overhead ladders + decode rungs
scripts/hc-matrix.sh off b2-r3 ; scripts/hc-matrix.sh on b2-r3     # 12 x 300k prose, 6 users (R1..R5 likewise)
scripts/hc-matrix.sh off b5-agentic ; scripts/hc-matrix.sh on b5-agentic   # K = 8,16,32,48 agent loops
python3 scripts/hc-equiv.py --base $BASE --corpus <corpus-dir>/prose.txt --sizes 67742,274194,1044000 --fillers 26 --max-tokens 48 --tag equiv --out <results-dir>/equiv.jsonl
python3 scripts/hc-report.py <results-dir>/b2-r3-off.jsonl <results-dir>/b2-r3-on.jsonl
bash scripts/test-hc-rotate.sh                                     # the harness's own suite, offline
```

The "off" arm is the same coordinator image launched with the host quota unset (or `DS41RT_HOST_CACHE_BYTES=0`);
the "on" arm sets `DS41RT_HOST_CACHE_BYTES=25769803776` (24 GiB pinned) and `DS41RT_HOST_CACHE_COPY_BUDGET_MS=1000`.
Measurement conventions (in every reducer's output): temperature 0, streaming with usage; TTFT = the client-observed
first content delta; decode tok/s = completion tokens ÷ (wall − TTFT); hit share = prompt_cache_hit_tokens ÷
prompt_tokens from the engine's usage object; `/v1/stats` counters bracket every segment.

MIT, like the rest of this repository. Sydney timestamps throughout.
