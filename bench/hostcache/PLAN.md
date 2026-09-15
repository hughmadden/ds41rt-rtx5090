# DS41RT host snapshot cache — fleet benchmark plan

2026-09-15 00:10 AEST (14:10 UTC). Companion to `afd-hostcache-design.md` (v3) and
`afd-hostcache-cutover-runbook.md`; **extends and supersedes runbook §4** (the ≤20-min
cutover-night matrix becomes the pilot below). Designed with Hugh in-thread on
2026-09-14/15 AEST; his decisions are recorded in §1.2 and bind this plan.

## 1. Objectives and decisions

### 1.1 Hugh's goals (five in-thread 2026-09-14 ~23:35 AEST; G6 added 2026-09-15 with the B5 brief)

- **G1** No performance overhead with the cache ON when there is **no KV pressure (no evictions)**.
- **G2** Under cache pressure: **how long evict and load (restore) each take**, and what that does
  to prefill and decode — ideally a set of **rotating concurrent clients causing basically
  continuous evict+load but no fresh cold prefills**; engine behaviour under **extreme paging pressure**.
- **G3** The same pressure **with the cache OFF** (baseline: evictions cause large cold prefills).
- **G4** With the cache ON: **clean recovery when the pressure stops**.
- **G5** The number of large concurrent sessions that is **simply too much** — not practical to support.
- **G6** (Hugh, 2026-09-15, the B5 brief): **how many concurrent tool-using agents** the fleet
  supports before their revisits go cold, **OFF vs ON** — the coding-agent loop shape (K growing
  conversations, short tool-call decodes, idle tool gaps), not just resident sessions.

Standing reporting axes (every results table): **concurrency, prefill, decode, prose vs code**.
Context-size and concurrency sweeps are wanted generally, but low concurrency can't pressure the
KV cache, so the pressure phases start where the arithmetic of §2 says pressure exists.

### 1.2 Hugh's decisions (same thread)

| Topic | Decision |
|---|---|
| G5 practicality bar | **decode ≥ 20 tok/s per client AND p95 revisit TTFT ≤ 10 s**, plus zero `restore_timeouts`/`restore_failures` |
| Endpoint | **Coordinator direct** (`http://127.0.0.1:8000` on the coordinator host, or `http://<coordinator-ip>:8000` from the bench host) — matches the v2 receipt methodology; no front-door matrix |
| Instrumentation | **Land the evict/store instrumentation addition (HC-7, §4) before cutover** so even the pilot has per-operation numbers |
| Windowing | **Pilot first: 15 min baseline (cache OFF), then the same 15 min on the release candidate (cache ON)** — validates harness + methodology and yields early numbers; **initial report delivered; then launch the full matrix** |
| Over-system-RAM (over-quota) testing | **Excluded this round** ("not relevant for this round") — no small-quota excursion, no >24 GiB working sets as a test axis (B4 crosses the quota only as a recorded observation) |
| Corpora | **Reference kit `prompts-v1.json` categories (prose) + a pinned repo snapshot (code)** — `tony-ref/bench/prompts-v1.json` and the `ds41rt` tree on the coordinator host |
| Authority (2026-09-15 00:40 AEST) | **Helm runs the pilot and matrix without a sign-off** (Hugh AFK; full control over coordinator-host and the Sparks); POs at each milestone; stop-fix-rerun on any bug |
| Prose corpus | **`bench-corpus/prose-docs.txt`** (26.1M chars of real markdown prose from the recipes and turq-canon repos, fenced code stripped). The reference kit's `prompts-v1.json` yields only 9 strings / 2,763 chars tiled 5,791x, unrealistic for the drafter and Engram; `code.txt` (590 engine-tree files, untiled) is the code corpus |
| Thinking | **Off on every request** (`reasoning_effort: "none"`, the only spelling this build honours besides `thinking: {type: disabled}`); TTFT = first delta carrying content or reasoning_content (HB-1, recipes 3997b485) |

## 2. Design basis (measured facts, with sources)

| Fact | Value | Source |
|---|---|---|
| Device KV pool @ capacity 1024, resv 97% | ~1.84 GiB ≈ **2.2M tokens** (890 B/token), shared by active requests + retained snapshots + restore reservations | `receipts/AFD-V2-CUTOVER-20260914.md` (pool 1.84 GiB); design §3 (890 B/token) |
| Retention banks | **24 prompt + 24 turn** snapshots (`--prefix-cache-entries 24`) | design §1, §6 |
| Admission concurrency cap | **16** (measured; prefill lane serializes) | `receipts/AFD-CONCURRENCY-AND-BENCH-20260914.md` |
| Host cache quota (planned) | 24 GiB pinned ≈ **~26M tokens** (~12× device) | cutover runbook §2; design §7 (~110M tok/100 GB) |
| Prefill / decode / 1M cold | 5,377–5,717 tok/s / 76.7 tok/s / 165.3 s | `receipts/AFD-V2-CUTOVER-20260914.md` |
| Restore (stub model, ~25 GB/s) | 6.4 ms @100k, 69.7 ms @1M | HC-5-fix packet report (`~/dev/ds41rt-hostcache-wt/logs/hc-5-fix.out`) |
| `/v1/stats` payload | `{"host_cache": {...counters...}}`, exported whether or not the cache is on | fork `ds41rt-api/src/native_v41.rs:77`, `ds41rt-daemon/.../scheduler.rs:103`, `ds41rt-hostcache/src/metrics.rs` |

**Two orthogonal pressure knobs** (this shapes every cell):

- **Bank thrash** — more than 24 distinct sessions: every rotation evicts and every revisit
  restores, even at tiny contexts. Cheap; produces high-rate per-operation samples.
- **Pool thrash** — Σ(active contexts) + retained snapshots ≈/> 2.2M tokens: `make_room`
  evictions during prefill; the realistic big-context regime, and where restore reservations
  race the pool (extreme cells).

A cell is *pressure-free* only if distinct sessions ≤ ~12 (bank headroom for prompt+turn) **and**
Σcontexts ≪ 2.2M — and G1 cells **verify** it from counters (`device_evictions` Δ = 0 after HC-7;
until then `evict_waits` Δ = 0, `evict_drops_uncached` Δ = 0, `host_evictions` Δ = 0), never assume it.

**Counter semantics for attribution** (design §4.3): the `lookups` hook fires only on a *device*
miss, so `device_hits ≈ visits − Δlookups`, `host_hit_rate = Δhost_hits / Δlookups`,
`cold_misses = Δlookups − Δhost_hits`. Per-request `usage.prompt_cache_hit_tokens` cannot
distinguish device from host hits — the counters can. Usage `completion_tokens` (never delta
counting) is the decode numerator: dSpark packs several tokens per SSE chunk (v41bench methodology,
`tony-ref/bench/v41bench.py` docstring).

**Sizing caveat:** `--ctx-chars` is characters; tokens are corpus-dependent (the synthetic ladder
corpus ran ~0.65 tok/char; real prose ~0.25–0.3, code ~0.3–0.35). Cells below are specified in
**target tokens**; the pilot measures the actual tok/char of each corpus and the full matrix
uses the calibrated char counts (recorded in the corpus meta and the run header).

## 3. Harness

All under `scripts/`, driven from a bench host against `http://<coordinator-ip>:8000` (or copied to
`<coordinator-host>:/path/to/ds41rt-run/` and driven locally — same file, `--base` differs):

- **`hc-rotate.py`** — the rotating-clients harness. C client threads × S sessions each,
  round-robin. Each visit appends a fresh ~500-token user turn to the session transcript
  (including the verbatim assistant reply from the previous visit, so the prompt is an exact
  descendant of the retained snapshot) and requests D output tokens. Segments, each bracketed by
  `/v1/stats` scrapes: `nopressure` (small fixed request count, banks near-empty — **only valid
  immediately after a fresh launch**), `warmup` (one cold visit per session, excluded from
  measurement), `steady` (time- or visit-bounded rotation; periodic stats every 15 s; optional
  **passive decode probe** — a lone 8k/200-token stream every 60 s that isolates decode-under-paging
  from the rotating clients' own numbers), `recovery` (idle → sequential revisit of R sessions →
  optional observe window → second pass expecting device hits). Every request emits one JSONL
  record (segment, tag, client, session, visit, wall, ttft, usage tokens incl. hit/miss, decode
  tok/s); errors are records, not aborts (B4 needs the failure shape). Run header carries the
  full config, corpus sha256, image/config from `/v1/stats`, AEST+UTC timestamps.
- **`hc-build-corpus.py`** — builds `prose.txt` (prompts-v1.json text fields, deterministic
  category order, tiled to `--min-chars`) and `code.txt` (pinned `git ls-files` order of the
  `ds41rt` tree, code extensions, path headers) + `.meta.json` with sha256 of every input/output,
  the git REV, and the tiling factor. Fail-closed on an unparseable JSON shape. Run on the coordinator host;
  corpus files live at `/path/to/bench-corpus/` (not committed; meta is).
- **`hc-report.py`** — reduces one or more JSONL runs to the standard markdown report: per-segment
  request tables (n, TTFT p50/p95/p99, decode tok/s, estimated cold-prefill tok/s, incremental
  tok/s), counter delta tables (every `host_cache` field, before→after→Δ), restore latency bucket
  distribution + mean, purity checks (§5), probe decode vs baseline decode, pass/fail vs the bars.
- **`hc-mock-server.py`** + **`test-hc-rotate.sh`** — offline plumbing validation on a bench host (mock SSE
  endpoint + emulated `host_cache` counters); no fleet contact. Receipt:
  `receipts/hc-rotate-mock-validated-20260915.md`.
- `hc-ladder.py` (exists) — singleton cold/reuse/evict-restore/decode; still the runbook §3 smoke.
  `--corpus FILE` builds prompts from real corpora (salted header + deterministic sha256-offset
  slice, same derivation as hc-rotate), `--concurrency N` runs N simultaneous salted requests for
  cold/decode with one line per request plus an aggregate line (tok/s + TTFT p50/p95) — the B1
  ladder/decode cells.
- `hc-matrix.sh` (HB-3) — resumable driver for the §6 full matrix: `hc-matrix.sh <off|on> <cell...>`,
  one JSONL per cell under `$OUT` plus `matrix.log` (AEST+UTC per cell), skip-if-complete unless
  `--force`, `/health` + `quota_bytes` arm gating before every cell, `--dry-run` prints every
  command and exits 0. B4 ramps run each point as a tagged rotate run inside the cell JSONL
  (fixed `--run-id` so later points revisit the earlier clients' retained sessions) and apply the
  §1.2 bar check from the JSONL after each point, stopping at the first failure.

Session salts are unique per run (`session <uuid8>.` first line), so sessions never cross-hit even
when corpus slices wrap; wrap is a realism caveat (Engram n-gram repetition), recorded via the
corpus meta tiling factor.

## 4. Prerequisite: HC-7 instrumentation packet (before cutover)

Hugh's decision: per-operation evict/store timing lands **first**. From reading
`ds41rt-hostcache/src/metrics.rs` (committed @ 44d3ad9): restore latency already has a full
histogram + sum; evict-path wait has count + total ns (mean only, acceptable — the wait is bounded
by `--host-cache-copy-budget-ms 50`). Missing:

1. **`device_evictions`** (u64) — every `before_device_evict` call, regardless of outcome. Without
   it, G1's "no evictions" can only be asserted indirectly and G2/G3 can't report eviction *rate*
   (only waits/drops).
2. **Store-copy completion latency** — `store_latency_sum_ns` + `store_latency_buckets` (reuse
   `RESTORE_BUCKETS_NS` bounds), recorded at tick when a store completes: issue→completion is the
   per-operation store cost G2 asks for.

Full brief with acceptance criteria: `research/hc7-evict-store-instrumentation-brief.md`. Branch
from the merged head **after HC-6 lands** (HC-6 is in flight in `sim.rs`; HC-7 touches
`metrics.rs`/`cache.rs`/binding — no overlap expected, but sequence the merges). The pilot can run
without HC-7 (report marks the two fields ABSENT), but Hugh's choice is to land it first.

## 5. Pilot — 15 min OFF + 15 min ON (Hugh's windowing decision)

Purpose: validate harness + methodology against the live engine and deliver **early numbers**;
the initial report gates the full matrix. Runs on cutover night inside the same PO'd window,
each arm **immediately after a fresh launch** (banks empty → `nopressure` valid):

1. Cut v2 → `ds41rt-coordinator-5090:hostcache` launched **cache OFF** (env unset).
2. **Pilot-OFF (≈15 min)**, then relaunch **ON, 24 GiB** (`DS41RT_HOST_CACHE_BYTES=25769803776`).
3. **Pilot-ON (≈15 min)**, then runbook §3 smoke (≤15 min) — the gate to leave the cache on.
4. `hc-report.py` over both JSONLs → **initial report** (repo + LAN dashboard) → Hugh reviews →
   full matrix scheduled.

Cell (bank thrash — continuous evict+load, cheap warmup): prose corpus, C=6, S=8 → **48 sessions**
(2× the 24-entry bank), target ~8k tokens/session (~30k chars prose), new turn ~500 tokens,
D=100 decode; warmup ≈ 48×8k ≈ 384k tokens ≈ 70 s cold. Segments: nopressure (3×2×3 rounds,
18 requests) → warmup → **steady 480 s** with probe → recovery (12 sessions, 60 s idle, 0 s observe).

```bash
# from a bench host (or on the coordinator host with --base http://127.0.0.1:8000)
python3 scripts/hc-rotate.py --base http://<coordinator-ip>:8000 --tag pilot-off \
  --corpus bench-corpus/prose.txt --clients 6 --sessions 8 --ctx-chars 30000 \
  --new-chars 2000 --decode 100 --steady-secs 480 --probe --out pilot-off.jsonl
# identical command with --tag pilot-on after the ON relaunch
python3 scripts/hc-report.py pilot-off.jsonl pilot-on.jsonl --out pilot-report.md
```

**Pilot pass criteria (methodology):** all segments complete on both arms; steady-state purity —
ON: `host_hit_rate ≥ 95%` and `Σmiss_tokens/Σprompt_tokens < 1%` in the steady window; OFF:
`hit_tokens ≈ 0` on revisits; counters internally consistent (`stores_issued ≈ stores_completed +
stores_failed + in-flight`; `bytes_used ≤ quota_bytes`; no growth in `restore_failures`); report
renders with every standard axis populated. **Early numbers reported:** steady revisit TTFT
p50/p95 OFF vs ON, restore mean + bucket distribution, per-client and probe decode tok/s OFF vs
ON, eviction rate (HC-7), cold-prefill tok/s (OFF) vs incremental tok/s (ON).

## 6. Full matrix (after pilot sign-off)

Durations are estimates at measured v2 speeds; every cell records C, L (target tokens, measured
tokens), S, working set W, pressure ratio W/pool, corpus mix, cache state.

### B1 — no overhead, no pressure (G1). Fresh launch per arm; n=3 A/B/A alternating arms.

| Cell | Shape | Acceptance |
|---|---|---|
| nopressure rotation | C3 × S2 × ~8k tok, 3 rounds (18 requests) — immediately post-launch | zero-eviction counters Δ=0; per-request TTFT/decode within 1% OFF↔ON |
| prefill ladder cold | 21k / 85k / 170k / 679k tokens, C1, **prose and code** | TTFT + prefill tok/s within **1%** (design R2) |
| reuse (device hit) | 170k, C1 | within 1% |
| decode 200 | C1, C3, C6, **prose and code** | tok/s within 1% of 76.7-class baseline |

If run-to-run variance exceeds 1% at n=3, widen to n=5 for the failing cell and report the
variance honestly rather than claiming the 1% bar on noise. Optional row (time permitting):
`--host-cache-store on-evict` at C1 decode + 170k ladder, to document the config surface.
≈45–55 min per arm.

### B2 — steady-state rotation (G2 + G3). ON and OFF, identical scripts.

| Cell | L (tok) | C | S | Sessions | W (tok) | Regime | Mix |
|---|---|---|---|---|---|---|---|
| R1 | 8k | 6 | 8 | 48 | 0.4M | bank thrash (per-op timings at high rate) | prose |
| R2 | 170k | 3 | 4 | 12 | 2.0M | mild pool pressure | prose |
| R3 | 300k | 6 | 2 | 12 | 3.6M | pool thrash, realistic | prose |
| R4 | 679k | 3 | 2 | 6 | 4.1M | **extreme**: active alone ≈ pool; restore reservations race `make_room` | prose |
| R5 | 300k | 6 | 4 | 24 | 7.2M | extreme + content | **prose and code** |

Steady 600 s ON / 300 s OFF (OFF revisit = full cold prefill ≈ L/5.4k s — 300k ≈ 55 s — so OFF
cells are prefill-bound; 300 s still yields ≥5 visits/client at R3). Warmups: R2 ≈ 6 min,
R3 ≈ 11 min, R4 ≈ 13 min, R5 ≈ 22 min (one cold pass; excluded from measurement). Report per cell:
revisit TTFT p50/p95/p99, restore p50/p95/p99 + mean (histogram), restores/s, evictions/s (HC-7),
store latency mean (HC-7), `evict_waits` + mean wait, `evict_drops_uncached`, `restore_timeouts`
(**expect 0**; any is a finding to chase before continuing), host-hit %, purity, per-client +
aggregate + probe decode tok/s, incremental prefill tok/s (ON) vs cold prefill tok/s (OFF).
ON ≈ 1.6–1.9 h, OFF ≈ 40–50 min.

### B3 — recovery (G4). Immediately after the harshest B2/B4 cell (ON).

All load stops → counters snapshot → 60 s idle → sequential revisit of 12 sessions (expect 100%
host hit; TTFT < 1 s at ≤170k scale — restore is ms-class) → **10 min observe** (stats every 30 s:
`bytes_used`, `resident_snapshots`, coordinator RSS flat; no spontaneous stores) → second
sequential pass (expect device hits: `Δlookups ≈ 0`, `usage hit_tokens == prompt_tokens`).
Invariants over the whole run: `stores = evictions + resident` balance, `restore_failures == 0`,
`bytes_used ≤ quota_bytes`. ≈15 min.

Driver shape rule (hc-matrix.sh `cell_b3`, HB-9): with `B3_RUN_ID` the cell revisits the primed
cell's shape (default 6×2 = R3); the 2026-09-15 rerun used 3×4 and half its first-pass revisits
were never-primed sessions (recorded, not a cache result).

### B4 — practical ceiling (G5). ON only; bar = §1.2 (decode ≥20 tok/s/client, p95 revisit
TTFT ≤10 s, zero restore timeouts/failures). Incremental ramp (host cache retains earlier
clients' sessions, so only new clients pay warmup):

- **Sessions axis**, L=300k, S=2/client: C = 6 → 8 → 12 → 16 (W = 3.6M → 9.6M; +~4 min warmup/step).
- **Context axis**: 679k at C = 2 → 3 → 4 (active 1.4M → 2.7M — expect the pool cliff near C=3–4);
  1M at C = 1 → 2 → 3 (1M cold = 165 s; active alone exceeds pool at C≥3).
- **Quota crossing** (observation only, per Hugh's exclusion of over-RAM testing): if the sessions
  axis approaches ~26M tokens, record `host_evictions` and cold-miss fraction as findings, not as
  a test axis; do not engineer a working set beyond quota.

Per ramp point: 240 s steady, then the bar check. Record the **first** point that fails, the
failure mode (admission queue growth / `restore_timeouts` / pool-exhausted deferrals / decode
collapse / host evictions → cold misses), and the cliff shape (graceful vs abrupt) in prose.
Compare against the v2 no-cache envelope (`receipts/AFD-CONCURRENCY-AND-BENCH-20260914.md`: C16
admission cap, 8×679k filled contexts passed serially) as the OFF reference — no OFF rerun.
≈45–60 min.

### B5 — agentic ramp (G6). ON and OFF.

Coding-agent loops: **K concurrent agents, each ONE growing conversation**. Every turn the
agent's whole context is resent (the client's history), the model emits a short tool call
(decode ~96 tokens), the client appends a tool result (~5,000 chars of code ≈ 1,600 tokens) and,
after an idle **tool gap** while the tool "runs", sends the next turn. Idle agents hold no
request slot, so K runs past the engine's concurrency (C16 admission cap): the idle agents'
turn snapshots are evicted from the 24-entry device banks by the others' traffic, making their
next turn a cold re-prefill with the cache OFF and a host restore with the cache ON; as contexts
grow, the device pool also comes under pressure. The ramp finds how many agents the fleet
supports OFF vs ON.

Harness: `hc-rotate.py --clients K --sessions 1` (a client IS an agent loop: each visit
revisits its single session, which grows by the new user chunk **and** the verbatim previous
assistant reply — `record_reply`) with `--turn-gap-secs 5,30` (uniform-random idle gap drawn
per client from a seeded RNG, recorded per visit as `turn_gap_s`), `--corpus code.txt`,
`--ctx-chars` = 30k tok at TPC_CODE, `--new-chars 5000 --decode 96 --segments warmup,steady
--steady-secs 240 --stats-every 15`. Points **K = 8, 16, 32, 48** (env `B5_POINTS` overrides);
`--run-id` fixed per cell so later points revisit the earlier agents' sessions (as B4). Each
point is one tagged run **`b5-agentic-<arm>-k<K>`** inside the cell file **`b5-agentic-<arm>.jsonl`**.

Bar per point (derived from §1.2, thresholds recorded on the `bar-check` record): **revisit
TTFT p95 ≤ 10 s (`BAR_TTFT`), zero request errors, zero restore timeouts/failures — no decode
bar** (agents are latency-bound, not throughput-bound). The ramp stops at the first failing
point; the `cell-done` record carries `stop_at`. **Both arms run the same points** — the OFF arm
is expected to fail its TTFT bar early (idle agents' snapshots are gone, every revisit is a
full cold re-prefill), and where it fails IS the result. Report per point (§8 axes): K, arm,
steady turns served, turns per agent-minute, TTFT p50/p95, hit fraction, decode p50, errors,
bar result (hc-final-report.py §4.5, OFF/ON rows adjacent per K).

503-as-backpressure rule (HB-7, fleet 2026-09-15: the k32 point showed TTFT p95 64.7 s with
30 `HTTP 503` "request errors" from the coordinator's C16 concurrency cap, zero admission
failures): an HTTP 503 or 429 (with Retry-After honoured) is admission backpressure, not a
request error — `hc-rotate.py` retries a refused visit after a seeded jittered backoff
(0.5 s × 2^attempt ± 25 %, capped 8 s; a 429's Retry-After sets the minimum sleep, one ask
capped at 60 s; up to
`--max-503-retries`, default 20; 0 = record the error as before; the retries_503 budget and
count cover 503s and 429s alike) and records `retries_503`
and `backoff_s` on the visit plus `turn_latency_s` (first attempt's send → last delta, what
the agent experiences; `ttft_s` stays the final attempt's send → first delta); the bar's
`request_errors` counts only non-backpressure terminal errors (a 503 or 429 that exhausted
its retries still
counts), and each point's bar-check record carries the informational per-point fields
`retries_503_sum`, `retries_503_p95_per_turn` and `turn_latency_p95_s` (rendered as §4.5's
retries/turn p95 and turn latency p95 columns; the TTFT bar itself is unchanged).

### Excluded (recorded)

- Over-quota / small-quota excursion — Hugh, 2026-09-14: not relevant this round.
- Front-door matrix — coordinator direct only (Hugh); one front-door confirmation request during
  the pilot is harmless if Hugh wants production-path sanity, but it is not a matrix axis.
- Concurrency 1/3/6 in pressure cells — kept only in B1 (no-overhead) per Hugh's note that low
  concurrency can't pressure the cache; pressure cells run at C3–C16.

## 7. Choreography, POs, costs

- **Cutover night** (one PO, 15-min notice, quiet priority −1 per standing rule): cutover →
  pilot OFF → relaunch ON → pilot ON → runbook §3 smoke → leave ON → initial report. ≈1 h 05.
- **Full window** (separate night(s) after Hugh signs off the initial report): OFF arm first
  (launch OFF fresh → B1-off → B2-off), relaunch ON (→ B1-on → B2-on → B4 → B3), leave ON.
  ≈3–3.5 h total; splittable into two ≤2 h windows at the OFF/ON boundary. Two relaunches ≈3 min each.
- Benches run from a bench host against `<coordinator-ip>:8000` (LAN adds ~0.3 ms — negligible against
  second-scale prefills); JSONL + reports land in `bench/hostcache-<date>/` in this repo.
- Front door stays live during benches unless Hugh says otherwise; the bench is the dominant load.
- Rollback any time: runbook §5 (`IMAGE=ds41rt-coordinator-5090:v2`, ≤2 min).

## 8. Report format

Standard table per cell (Hugh's standing axes in bold): **C** | L target/measured tokens | S |
W | mix (**prose/code**) | cache (on/off) | TTFT p50/p95/p99 | **prefill** tok/s (cold and
incremental, labeled) | **decode** tok/s (per-client, aggregate, probe) | host-hit % | restore
p50/p95/p99 + mean | evictions/s, evict wait mean | store latency mean | timeouts/failures |
verdict vs bar. Counter-delta appendix per segment; JSONL retained as the raw record; report
published to the LAN dashboard (public only on Hugh's call, per standing delivery rule).

## 9. Caveats and honesty notes

- **Queueing confound:** the prefill lane serializes, so revisit TTFT under rotation includes
  queue wait behind other clients' restores/prefills; the probe stream and per-segment counters
  are the attribution tools. TTFT here is client-observed (includes queue), stated in every table.
- **Retokenization boundary:** replaying the assistant's streamed text as history can shift a few
  tokens at turn boundaries vs the retained snapshot's token stream; the 128-token replay window
  (design R3) absorbs this. Purity is measured from counters, not assumed.
- **Corpus realism:** prose tiled from prompts-v1.json repeats (tiling factor recorded in meta);
  Engram n-gram hit rates on tiled text run higher than organic workloads. Code corpus is a pinned
  REV of the ds41rt tree — recorded, reproducible.
- **Char→token calibration** differs per corpus; every cell reports measured tokens as canonical.
- **n=1 legacy:** v2 receipt numbers were n=1; B1's 1% claims use n=3 A/B/A medians and widen on
  variance. Do not compare a pilot n=1 cell against the 1% bar.
- The pool figure (~2.2M tokens) is from the v2 offline probe + cutover receipt; the design doc's
  "~2.5M" is the rounded v1-era number. Cells calibrate pressure from counters, not arithmetic.
