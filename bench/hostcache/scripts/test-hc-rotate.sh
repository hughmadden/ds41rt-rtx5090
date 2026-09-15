#!/usr/bin/env bash
# test-hc-rotate.sh — offline validation of the host-cache bench harness on a bench host, zero fleet contact.
# Exercises: hc-build-corpus.py (happy path + fail-closed), hc-rotate.py against hc-mock-server.py
# (all segments, bank-thrash eviction/restore motion), hc-report.py (checks + comparison + ABSENT
# tolerance for pre-HC-7 metrics and a stats-404 "v2-style" run), hc-ladder.py (--corpus slices,
# --concurrency aggregates), hc-matrix.sh (--dry-run cells + arm gating against the mock's quota).
set -u
cd "$(dirname "$0")"
TMP=$(mktemp -d /tmp/hc-test.XXXXXX)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
chk()  { if [[ "$1" == 0 ]]; then ok "$2"; else bad "$2"; fi; }

# Mock ports: several packet worktrees on the bench host run this suite concurrently; the base port is
# random per run (override BASE_PORT for a fixed value) so concurrent runs never share mocks.
BASE_PORT=${BASE_PORT:-$((8791 + RANDOM % 500))}
P_MAIN=$BASE_PORT                  # cache-ON style mock
P_LEGACY=$((BASE_PORT + 1))        # pre-HC-7 metrics
P_V2=$((BASE_PORT + 2))            # no /v1/stats
P_REASON=$((BASE_PORT + 3))        # reasoning-first
P_QZERO=$((BASE_PORT + 4))         # quota-bytes 0 (OFF-arm gating)
P_QZERO2=$((BASE_PORT + 5))        # quota-bytes 0, second (b5 OFF dry-run)
P_ZEROA=$((BASE_PORT + 6))         # B5 0,0 equivalence, mock A
P_ZEROB=$((BASE_PORT + 7))         # B5 0,0 equivalence, mock B
P_503=$((BASE_PORT + 8))           # 503 every 3rd request (backpressure)
P_429=$((BASE_PORT + 9))           # 429 every 3rd request, Retry-After 1 (rc6 front door)
P_429NA=$((BASE_PORT + 10))        # 429 every 3rd request, no Retry-After
P_429BAR=$((BASE_PORT + 11))       # 429 every 3rd, Retry-After 1 (dedicated b5 bar cell)
echo "mock base port: $BASE_PORT"

# --- fixtures -------------------------------------------------------------
python3 - "$TMP" <<'EOF'
import json, os, random, sys
tmp = sys.argv[1]
random.seed(7)
words = "the quick brown fox jumps over lazy dog while agents rotate sessions evict restore".split()
with open(os.path.join(tmp, "corpus.txt"), "w") as fh:
    fh.write(" ".join(random.choice(words) for _ in range(60000)) + " ")
json.dump({"categories": [
    {"name": "c1", "prompts": [{"text": "x" * 60 + " category one prose sample " + "y" * 60}]},
    {"name": "c2", "prompts": [{"text": "z" * 60 + " category two prose sample " + "w" * 60}]}]},
    open(os.path.join(tmp, "prompts.json"), "w"))
os.makedirs(os.path.join(tmp, "tree", "src"))
open(os.path.join(tmp, "tree", "src", "a.rs"), "w").write("fn main() {}\n" * 20)
open(os.path.join(tmp, "tree", "src", "b.py"), "w").write("print('hi')\n" * 20)
open(os.path.join(tmp, "broken.json"), "w").write("{not json")
EOF

# --- corpus builder -------------------------------------------------------
python3 hc-build-corpus.py --prompts-json "$TMP/prompts.json" --code-tree "$TMP/tree" \
  --out-dir "$TMP/corpus" --min-chars 20000 >/dev/null 2>&1
chk $? "corpus builder happy path exit 0"
[[ -s "$TMP/corpus/prose.txt" && -s "$TMP/corpus/code.txt" && -s "$TMP/corpus/prose.txt.meta.json" ]]
chk $? "corpus outputs + meta exist"
python3 -c "import json,sys; m=json.load(open('$TMP/corpus/prose.txt.meta.json')); assert m['source_sha256'] and m['output_sha256'] and m['tiles']>=1" 2>/dev/null
chk $? "corpus meta carries source+output sha256 and tiling factor"
python3 hc-build-corpus.py --prompts-json "$TMP/broken.json" --code-tree "$TMP/tree" \
  --out-dir "$TMP/corpus2" --min-chars 1000 >/dev/null 2>&1
[[ $? -ne 0 ]]; chk $? "corpus builder fail-closed on unparseable JSON"

# --- mock runs ------------------------------------------------------------
python3 hc-mock-server.py --port $P_MAIN >"$TMP/mock.log" 2>&1 &
MOCK1=$!
python3 hc-mock-server.py --port $P_LEGACY --legacy-metrics >"$TMP/mock2.log" 2>&1 &
MOCK2=$!
python3 hc-mock-server.py --port $P_V2 --stats-404 >"$TMP/mock3.log" 2>&1 &
MOCK3=$!
for p in $P_MAIN $P_LEGACY $P_V2; do
  for _ in $(seq 1 40); do curl -fsS -m 1 "http://127.0.0.1:$p/health" >/dev/null 2>&1 && break; sleep 0.25; done
done
curl -fsS -m 2 http://127.0.0.1:$P_MAIN/health >/dev/null; chk $? "mock servers up"

# cache-ON style run: 3x10 = 30 sessions > 24-entry device LRU -> evict/restore motion.
# ctx/new-chars ratio mirrors the pilot (new turn ~0.5% of prompt) so the <1% cold-fraction
# purity check is exercised at a realistic scale.
python3 hc-rotate.py --base http://127.0.0.1:$P_MAIN --tag mock-on --out "$TMP/on.jsonl" \
  --corpus "$TMP/corpus.txt" --clients 3 --sessions 10 --ctx-chars 40000 --new-chars 200 --decode 8 \
  --np-clients 2 --np-sessions 2 --np-rounds 2 --np-ctx-chars 2000 \
  --steady-secs 8 --probe --probe-every 3 --probe-ctx 1500 --probe-decode 10 --stats-every 2 \
  --recovery-sessions 12 --idle-secs 1 --observe-secs 3 --timeout 30 >"$TMP/rot.log" 2>&1
chk $? "hc-rotate full run exit 0"
grep -q 'RUN-DONE mock-on' "$TMP/rot.log"; chk $? "hc-rotate printed RUN-DONE"

python3 - "$TMP/on.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
kinds = {r["kind"] for r in recs}
segs = {r["segment"] for r in recs if r["kind"] == "segment"}
need_kinds = {"header", "segment", "stats", "req", "footer"}
need_segs = {"nopressure", "warmup", "steady", "recovery1", "recovery2"}
assert need_kinds <= kinds, f"missing kinds: {need_kinds - kinds}"
assert need_segs <= segs, f"missing segments: {need_segs - segs}"
assert any(r.get("segment") == "probe" for r in recs if r["kind"] == "req"), "no probe requests"
hdr = next(r for r in recs if r["kind"] == "header")
assert hdr["corpus"]["sha256_16"] and hdr["run_id"], "header missing corpus sha / run_id"
for r in recs:
    if r["kind"] == "segment":
        assert isinstance(r.get("stats_before"), dict) and "quota_bytes" in r["stats_before"], \
            f"segment {r['segment']} stats_before not a host_cache dict"
    if r["kind"] == "req":
        assert r.get("prompt_tokens") and r.get("out_tokens") is not None, "req record missing usage"
print("STRUCT-OK", len(recs), "records")
EOF
chk $? "JSONL structure: header/segments/stats/probe/footer + usage on every request"

# header must record the thinking mode + deterministic session-offset derivation
python3 - "$TMP/on.jsonl" <<'EOF'
import json, sys
hdr = next(json.loads(l) for l in open(sys.argv[1]) if l.strip()
           and json.loads(l)["kind"] == "header")
assert hdr["config"].get("thinking") is False, "header config must record thinking=False"
assert "sha256" in hdr.get("session_offset", ""), "header must record session-offset derivation"
print("HDR-OK thinking=off, session_offset derivation recorded")
EOF
chk $? "header records thinking mode + sha256 session-offset derivation"

# --- reasoning-first mock: the coordinator streams reasoning_content before content.
# TTFT must land on the FIRST reasoning delta; the mock asserts server-side that every
# request carried reasoning_effort (hc-rotate default: thinking off).
python3 hc-mock-server.py --port $P_REASON --reasoning-first 3 >"$TMP/mock4.log" 2>&1 &
MOCK4=$!
for _ in $(seq 1 40); do curl -fsS -m 1 http://127.0.0.1:$P_REASON/health >/dev/null 2>&1 && break; sleep 0.25; done
python3 hc-rotate.py --base http://127.0.0.1:$P_REASON --tag mock-think --out "$TMP/think.jsonl" \
  --corpus "$TMP/corpus.txt" --clients 1 --sessions 2 --ctx-chars 2000 --new-chars 300 --decode 6 \
  --segments warmup --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate against reasoning-first mock exit 0"
python3 - "$TMP/think.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
reqs = [r for r in recs if r["kind"] == "req"]
assert reqs, "no req records"
for r in reqs:
    assert r.get("first_delta_kind") == "reasoning_content", f"first_delta_kind={r.get('first_delta_kind')}"
    # mock sends content >= 0.5 s after the first reasoning delta; a correct TTFT is well under that
    assert r.get("ttft_s") is not None and r["ttft_s"] < 0.4, f"ttft_s={r.get('ttft_s')}"
print("TTFT-OK", len(reqs), "requests took TTFT at the first reasoning delta")
EOF
chk $? "TTFT taken at the first reasoning delta (content arrives >=0.5 s later)"
python3 - "$P_REASON" <<'EOF'
import json, sys, urllib.request
st = json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/stats", timeout=5))["host_cache"]
assert st["req_seen"] > 0, "mock saw no requests"
assert st["req_missing_reasoning_effort"] == 0, \
    f"{st['req_missing_reasoning_effort']} of {st['req_seen']} requests lacked reasoning_effort"
print(f"EFFORT-OK all {st['req_seen']} requests carried reasoning_effort (server-side assert)")
EOF
chk $? "every request the mock received carried reasoning_effort (server-side assert)"

# --thinking omits reasoning_effort: mock must flag every request as missing it
python3 hc-rotate.py --base http://127.0.0.1:$P_REASON --tag mock-think-on --out "$TMP/thinkon.jsonl" \
  --corpus "$TMP/corpus.txt" --clients 1 --sessions 1 --ctx-chars 2000 --new-chars 300 --decode 6 \
  --segments warmup --thinking --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate --thinking exit 0"
python3 - "$TMP/thinkon.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hdr = next(r for r in recs if r["kind"] == "header")
assert hdr["config"]["thinking"] is True, "--thinking must be recorded in the header"
print("THINKING-ON-OK header records thinking=True")
EOF
chk $? "--thinking recorded in header"
python3 - "$P_REASON" <<'EOF'
import json, sys, urllib.request
st = json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/stats", timeout=5))["host_cache"]
assert st["req_missing_reasoning_effort"] == 1, \
    f"expected exactly 1 request without reasoning_effort (the --thinking warmup), got {st['req_missing_reasoning_effort']}"
print("EFFORT-OFF-OK --thinking runs sent no reasoning_effort (mock counted them)")
EOF
chk $? "--thinking omits reasoning_effort (server-side count)"

# pre-HC-7 mock (no device_evictions/store_latency): harness must not care, report says ABSENT
python3 hc-rotate.py --base http://127.0.0.1:$P_LEGACY --tag mock-legacy --out "$TMP/legacy.jsonl" \
  --corpus "$TMP/corpus.txt" --clients 3 --sessions 10 --ctx-chars 40000 --new-chars 200 --decode 8 \
  --segments warmup,steady --steady-secs 5 --stats-every 2 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate against legacy-metrics mock exit 0"

# v2-style (no /v1/stats route): stats are error records, run still completes
python3 hc-rotate.py --base http://127.0.0.1:$P_V2 --tag mock-v2 --out "$TMP/v2.jsonl" \
  --corpus "$TMP/corpus.txt" --clients 2 --sessions 3 --ctx-chars 2000 --new-chars 300 --decode 6 \
  --segments warmup,steady --steady-secs 4 --stats-every 2 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate against stats-404 mock exit 0 (v2-style baseline)"

# --- B5 agentic ramp: turn gaps (HB-6, plan §6 B5) -----------------------------
# --turn-gap-secs 1,1: every steady req carries turn_gap_s=1.0 and visits per
# client are spaced >= 1 s (the tool gap); S=1 makes each client an agent loop.
python3 hc-rotate.py --base http://127.0.0.1:$P_MAIN --tag mock-b5 --out "$TMP/b5.jsonl" \
  --corpus "$TMP/corpus.txt" --segments warmup,steady --clients 2 --sessions 1 \
  --ctx-chars 2000 --new-chars 300 --decode 6 --turn-gap-secs 1,1 \
  --steady-secs 6 --stats-every 30 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate --turn-gap-secs 1,1 exit 0"
python3 - "$TMP/b5.jsonl" <<'EOF'
import json, sys
from datetime import datetime
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
steady = [r for r in recs if r.get("kind") == "req" and r.get("segment") == "steady"]
assert len(steady) >= 4, f"too few steady reqs: {len(steady)}"
assert all(r.get("turn_gap_s") == 1.0 for r in steady), \
    [r.get("turn_gap_s") for r in steady]
for c in {r["client"] for r in steady}:
    mine = [r for r in steady if r["client"] == c]
    ts = [datetime.fromisoformat(r["ts"]) for r in mine]
    gaps = [(b - a).total_seconds() for a, b in zip(ts, ts[1:])]
    assert all(g >= 1 for g in gaps), f"client {c} visits not spaced >=1s: {gaps}"
    # S=1 agent loop: prompt grows by the new chunk AND the model's reply each visit
    pt = [r["prompt_tokens"] for r in mine]
    assert all(b > a for a, b in zip(pt, pt[1:])), f"session not growing: {pt}"
print("B5-GAP-OK every steady req carries turn_gap_s=1.0; visits spaced >=1s; session grows")
EOF
chk $? "--turn-gap-secs 1,1: turn_gap_s=1.0 on every steady req, >=1s spacing, growing session"

# gap draws are deterministic per run id + client index (seeded like corpus offsets)
for i in 1 2; do
  python3 hc-rotate.py --base http://127.0.0.1:$P_MAIN --tag mock-b5-det --run-id DETRUN \
    --out "$TMP/b5-det$i.jsonl" --corpus "$TMP/corpus.txt" --segments steady \
    --clients 2 --sessions 1 --ctx-chars 2000 --new-chars 300 --decode 6 \
    --turn-gap-secs 0,2 --steady-secs 5 --stats-every 30 --timeout 30 >/dev/null 2>&1
done
python3 - "$TMP/b5-det1.jsonl" "$TMP/b5-det2.jsonl" <<'EOF'
import json, sys
def per_client(p):
    out = {}
    for l in open(p):
        r = json.loads(l)
        if r.get("kind") == "req" and r.get("segment") == "steady":
            out.setdefault(r["client"], []).append(r.get("turn_gap_s"))
    return out
g1, g2 = per_client(sys.argv[1]), per_client(sys.argv[2])
assert g1 == g2 and any(0 < g < 2 for gs in g1.values() for g in gs), (g1, g2)
print("B5-DET-OK per-client gap sequences reproduce across runs with the same run id")
EOF
chk $? "gap draws deterministic per run id + client index (seeded RNG)"

# --turn-gap-secs 0,0 is byte-equivalent to no flag: no gap fields anywhere,
# header config omits turn_gap_secs, records identical modulo ts/argv/out/stats/timing.
# Two fresh mocks so both runs see identical server-side cache state.
python3 hc-mock-server.py --port $P_ZEROA >"$TMP/mock7a.log" 2>&1 &
MOCK7A=$!
python3 hc-mock-server.py --port $P_ZEROB >"$TMP/mock7b.log" 2>&1 &
MOCK7B=$!
for p in $P_ZEROA $P_ZEROB; do
  for _ in $(seq 1 40); do curl -fsS -m 1 "http://127.0.0.1:$p/health" >/dev/null 2>&1 && break; sleep 0.25; done
done
python3 hc-rotate.py --base http://127.0.0.1:$P_ZEROA --tag mock-b5-zero --run-id ZRUN \
  --out "$TMP/b5-zero-a.jsonl" --corpus "$TMP/corpus.txt" --segments steady \
  --clients 2 --sessions 1 --ctx-chars 2000 --new-chars 300 --decode 6 \
  --steady-secs 3 --stats-every 30 --timeout 30 >/dev/null 2>&1
python3 hc-rotate.py --base http://127.0.0.1:$P_ZEROB --tag mock-b5-zero --run-id ZRUN \
  --out "$TMP/b5-zero-b.jsonl" --corpus "$TMP/corpus.txt" --segments steady \
  --clients 2 --sessions 1 --ctx-chars 2000 --new-chars 300 --decode 6 \
  --turn-gap-secs 0,0 --steady-secs 3 --stats-every 30 --timeout 30 >/dev/null 2>&1
python3 - "$TMP/b5-zero-a.jsonl" "$TMP/b5-zero-b.jsonl" <<'EOF'
import json, sys
TIMING = {"wall_s", "gen_s", "ttft_s", "decode_tok_s"}  # ms jitter between any two runs
def norm(p):
    recs = []
    reqs = []  # client interleave order is thread-scheduling jitter: compare per client
    for l in open(p):
        r = json.loads(l)
        r.pop("ts", None)
        if r.get("kind") == "header":
            r.pop("argv", None); r.pop("base", None)
            r["config"].pop("out", None); r["config"].pop("base", None)
            r.pop("stats_start", None); r.pop("stats_error", None)
        if r.get("kind") == "segment":
            r.pop("stats_before", None); r.pop("stats_after", None); r.pop("stats_error", None)
            r.pop("t0", None); r.pop("t1", None)  # monotonic wall anchors, run-dependent
        if r.get("kind") == "req":
            for k in TIMING:
                r.pop(k, None)
            reqs.append(r)
            continue
        recs.append(r)
    recs[1:1] = sorted(reqs, key=lambda r: (r.get("client"), r.get("session"), r.get("visit")))
    return recs
za, zb = norm(sys.argv[1]), norm(sys.argv[2])
assert za == zb, "0,0 run differs from the no-flag run"
assert not any("turn_gap" in json.dumps(r) for r in zb)
hdr = next(r for r in zb if r["kind"] == "header")
assert "turn_gap_secs" not in hdr["config"], "default must stay out of the header config"
print("B5-ZERO-OK 0,0 = no gap: no turn_gap fields, config omits the default")
EOF
chk $? "--turn-gap-secs 0,0 byte-equivalent to no flag (no gap fields, config omits default)"

# bad gap arguments exit 2
python3 hc-rotate.py --base http://127.0.0.1:$P_MAIN --tag x --out "$TMP/x.jsonl" \
  --corpus "$TMP/corpus.txt" --segments steady --turn-gap-secs 3,1 >/dev/null 2>&1
[[ $? -eq 2 ]]; chk $? "--turn-gap-secs 3,1 (MIN>MAX) exits 2"

# --- 503 backpressure (HB-7) ---------------------------------------------------
# The coordinator caps in-flight requests (C16); an agentic ramp bursts above it and
# gets HTTP 503s. A real agent client waits and retries: every 3rd mock request is
# refused 503, and the harness must absorb each one with a jittered backoff retry
# (retries_503/backoff_s/turn_latency_s on the req), never an error record.
P_503=$((BASE_PORT + 8))
python3 hc-mock-server.py --port $P_503 --mock-503-every 3 >"$TMP/mock8.log" 2>&1 &
MOCK8=$!
for _ in $(seq 1 40); do curl -fsS -m 1 http://127.0.0.1:$P_503/health >/dev/null 2>&1 && break; sleep 0.25; done
python3 hc-rotate.py --base http://127.0.0.1:$P_503 --tag mock-503 --out "$TMP/r503.jsonl" \
  --corpus "$TMP/corpus.txt" --segments steady --clients 2 --sessions 1 \
  --ctx-chars 2000 --new-chars 300 --decode 6 --turn-gap-secs 0,0 \
  --steady-secs 6 --stats-every 30 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate against 503-every-3 mock exit 0 (default --max-503-retries 20)"
python3 - "$TMP/r503.jsonl" "$P_503" <<'EOF'
import json, sys, urllib.request
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
steady = [r for r in recs if r.get("kind") == "req" and r.get("segment") == "steady"]
retried = [r for r in steady if r.get("retries_503")]
assert steady, "no steady reqs"
assert retried, "no visit retried a 503 (mock refuses every 3rd)"
assert not [r for r in recs if r["kind"] == "error"], "503s must be absorbed, not error records"
for r in retried:
    assert r["retries_503"] >= 1 and r["backoff_s"] > 0, r
    # ttft_s is the FINAL attempt's send -> first delta; turn_latency_s is the whole
    # visit (first send -> last delta), so it must cover ttft_s, wall_s and the backoff
    assert r["turn_latency_s"] >= r["ttft_s"], r
    assert r["turn_latency_s"] >= r["wall_s"] - 1e-9, r
    assert r["backoff_s"] <= r["turn_latency_s"] - r["wall_s"] + 0.05, r
assert not any("turn_latency_s" in r for r in steady if not r.get("retries_503")), \
    "turn_latency_s only where retries happened"
st = json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[2]}/v1/stats", timeout=5))["host_cache"]
absorbed = sum(r.get("retries_503", 0) for r in steady)
assert st["req_503"] == absorbed, f"mock served {st['req_503']} 503s, harness absorbed {absorbed}"
print(f"503-OK {st['req_503']} 503s absorbed as backpressure; turn_latency_s >= ttft_s + backoff")
EOF
chk $? "503 = backpressure: retries_503>=1, backoff_s>0, turn_latency_s>=ttft_s, zero errors, conservation"

# --max-503-retries 0 = pre-HB-7 behaviour: the 503 is recorded as an error
python3 hc-rotate.py --base http://127.0.0.1:$P_503 --tag mock-503-off --out "$TMP/r503off.jsonl" \
  --corpus "$TMP/corpus.txt" --segments steady --clients 2 --sessions 1 \
  --ctx-chars 2000 --new-chars 300 --decode 6 --max-503-retries 0 \
  --steady-secs 3 --stats-every 30 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate --max-503-retries 0 exit 0"
python3 - "$TMP/r503off.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
errs = [r for r in recs if r["kind"] == "error"]
assert errs, "with retries disabled every 3rd request must error"
assert all("503" in r["error"] for r in errs), [r["error"] for r in errs]
assert not any("retries_503" in r for r in recs), "retries disabled must record no retry fields"
print(f"503-OFF-OK {len(errs)} 503s recorded as errors (pre-HB-7 behaviour)")
EOF
chk $? "--max-503-retries 0: 503 recorded as error, no retry fields"

# live bar_check_b5 against the 503 mock: a shrunken b5 cell (B5_POINTS/RAMP_STEADY
# overridden) must PASS — 503s are backpressure, not request errors — and the
# bar-check record must carry the HB-7 fields (retries_503_sum/p95, turn_latency_p95_s).
out=$(B5_POINTS="2" RAMP_STEADY=3 bash hc-matrix.sh --base http://127.0.0.1:$P_503 \
  --out "$TMP/mx-b5-503" --corpus-dir "$TMP/corpus" on b5-agentic 2>&1)
rc=$?
chk $rc "hc-matrix live b5 cell against the 503 mock exit 0 (bar must pass)"
python3 - "$TMP/mx-b5-503/b5-agentic-on.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
bc = [r for r in recs if r.get("kind") == "bar-check"]
assert len(bc) == 1 and bc[0]["result"] == "pass", bc
b = bc[0]
assert b["request_errors"] == 0, b
assert b["retries_503_sum"] > 0 and b["retries_503_p95_per_turn"] >= 1, b
assert isinstance(b["turn_latency_p95_s"], (int, float)), b
assert b["steady_requests"] > 0
print(f"BAR503-OK bar passes with {b['retries_503_sum']} absorbed 503s; "
      f"retries/turn p95={b['retries_503_p95_per_turn']}, "
      f"turn latency p95={b['turn_latency_p95_s']}s")
EOF
chk $? "bar_check_b5: 503s not request errors; record carries retries_503_sum/p95 + turn_latency_p95_s"

# --- 429 + Retry-After backpressure (HB-8, rc6 front door) ---------------------
# The rc6 front door queues over-capacity bursts up to 30 s, then refuses 429 with a
# Retry-After hint; the harness must absorb it exactly like a 503 (same retry loop and
# --max-503-retries budget), but sleep max(jittered backoff, Retry-After) per retry.
python3 hc-mock-server.py --port $P_429 --mock-503-every 3 --mock-status 429 \
  --mock-retry-after 1 >"$TMP/mock9.log" 2>&1 &
MOCK9=$!
for _ in $(seq 1 40); do curl -fsS -m 1 http://127.0.0.1:$P_429/health >/dev/null 2>&1 && break; sleep 0.25; done
curl -fsS -m 2 http://127.0.0.1:$P_429/health >/dev/null; chk $? "429 mock up"
python3 hc-rotate.py --base http://127.0.0.1:$P_429 --tag mock-429 --out "$TMP/r429.jsonl" \
  --corpus "$TMP/corpus.txt" --segments steady --clients 2 --sessions 1 \
  --ctx-chars 2000 --new-chars 300 --decode 6 --turn-gap-secs 0,0 \
  --steady-secs 8 --stats-every 30 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate against 429+Retry-After mock exit 0"
python3 - "$TMP/r429.jsonl" "$P_429" <<'EOF'
import json, sys, urllib.request
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
steady = [r for r in recs if r.get("kind") == "req" and r.get("segment") == "steady"]
retried = [r for r in steady if r.get("retries_503")]
assert steady, "no steady reqs"
assert retried, "no visit retried a 429 (mock refuses every 3rd)"
assert not [r for r in recs if r["kind"] == "error"], "429s must be absorbed, not error records"
for r in retried:
    assert r["retries_503"] >= 1 and r["retries_429"] >= 1, r  # shared budget + 429 split
    assert r["retry_after_s_sum"] >= 1, r  # the server's ask was seen
    assert r["backoff_s"] >= r["retry_after_s_sum"], r  # and honoured (min sleep per retry)
    assert r["turn_latency_s"] >= r["backoff_s"], r
assert all("turn_latency_s" in r for r in steady if r.get("retries_503")), \
    "turn_latency_s missing on a retried visit"
st = json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[2]}/v1/stats", timeout=5))["host_cache"]
absorbed = sum(r.get("retries_429", 0) for r in steady)
assert st["req_503"] == absorbed, f"mock served {st['req_503']} 429s, harness counted {absorbed}"
print(f"429-OK {absorbed} 429s absorbed; Retry-After honoured (backoff_s>=ask), conservation exact")
EOF
chk $? "429 = backpressure: retries_503/429 split, backoff_s>=retry_after_s_sum, zero errors, conservation"

# --max-503-retries 0: the 429 is recorded as an error, no retry fields (pre-HB-7 rule)
python3 hc-rotate.py --base http://127.0.0.1:$P_429 --tag mock-429-off --out "$TMP/r429off.jsonl" \
  --corpus "$TMP/corpus.txt" --segments steady --clients 2 --sessions 1 \
  --ctx-chars 2000 --new-chars 300 --decode 6 --max-503-retries 0 \
  --steady-secs 3 --stats-every 30 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate --max-503-retries 0 against 429 mock exit 0"
python3 - "$TMP/r429off.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
errs = [r for r in recs if r["kind"] == "error"]
assert errs, "with retries disabled every 3rd request must error"
assert all("HTTP Error 429" in r["error"] for r in errs), [r["error"] for r in errs]
assert not any("retries_503" in r or "retries_429" in r or "retry_after_s_sum" in r
               for r in recs), "retries disabled must record no retry fields"
print(f"429-OFF-OK {len(errs)} 429s recorded as errors (pre-HB-7 behaviour)")
EOF
chk $? "--max-503-retries 0: 429 recorded as error, no retry fields"

# a 429 WITHOUT Retry-After behaves exactly like a 503: jittered backoff only
python3 hc-mock-server.py --port $P_429NA --mock-503-every 3 --mock-status 429 \
  >"$TMP/mock10.log" 2>&1 &
MOCK10=$!
for _ in $(seq 1 40); do curl -fsS -m 1 http://127.0.0.1:$P_429NA/health >/dev/null 2>&1 && break; sleep 0.25; done
python3 hc-rotate.py --base http://127.0.0.1:$P_429NA --tag mock-429na --out "$TMP/r429na.jsonl" \
  --corpus "$TMP/corpus.txt" --segments steady --clients 2 --sessions 1 \
  --ctx-chars 2000 --new-chars 300 --decode 6 \
  --steady-secs 6 --stats-every 30 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate against 429-no-Retry-After mock exit 0"
python3 - "$TMP/r429na.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
steady = [r for r in recs if r.get("kind") == "req" and r.get("segment") == "steady"]
retried = [r for r in steady if r.get("retries_503")]
assert retried, "no visit retried a 429 (mock refuses every 3rd)"
assert not [r for r in recs if r["kind"] == "error"], "429s must be absorbed, not error records"
for r in retried:
    assert r["retries_429"] >= 1, r
    assert r["retry_after_s_sum"] == 0, r  # no header: jittered backoff only
    assert r["backoff_s"] > 0, r
print("429-NA-OK headerless 429 = 503 rule: retry_after_s_sum 0, jittered backoff only")
EOF
chk $? "429 without Retry-After: behaves like a 503 (retry_after_s_sum 0, backoff jitter only)"

# live bar_check_b5 against a 429 mock: a shrunken b5 cell must PASS — 429s (and the
# Retry-After sleeps) are backpressure, not request errors. Dedicated fresh mock so the
# every-3rd refusal is guaranteed to land inside the cell's requests.
python3 hc-mock-server.py --port $P_429BAR --mock-503-every 3 --mock-status 429 \
  --mock-retry-after 1 >"$TMP/mock11.log" 2>&1 &
MOCK11=$!
for _ in $(seq 1 40); do curl -fsS -m 1 http://127.0.0.1:$P_429BAR/health >/dev/null 2>&1 && break; sleep 0.25; done
out=$(B5_POINTS="2" RAMP_STEADY=4 bash hc-matrix.sh --base http://127.0.0.1:$P_429BAR \
  --out "$TMP/mx-b5-429" --corpus-dir "$TMP/corpus" on b5-agentic 2>&1)
rc=$?
chk $rc "hc-matrix live b5 cell against the 429 mock exit 0 (bar must pass)"
python3 - "$TMP/mx-b5-429/b5-agentic-on.jsonl" <<'EOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
bc = [r for r in recs if r.get("kind") == "bar-check"]
assert len(bc) == 1 and bc[0]["result"] == "pass", bc
assert bc[0]["request_errors"] == 0, bc
assert bc[0]["retries_503_sum"] > 0, bc  # 429s share the retries_503 budget
print(f"BAR429-OK bar passes with {bc[0]['retries_503_sum']} absorbed 429s; zero request errors")
EOF
chk $? "bar_check_b5 against 429s: backpressure not request errors, bar passes"

# --- report ---------------------------------------------------------------
python3 hc-report.py "$TMP/on.jsonl" --out "$TMP/report-on.md" >/dev/null 2>&1
rc=$?; chk $rc "hc-report on-run exit 0 (all checks PASS)"
grep -q 'steady bar' "$TMP/report-on.md"; chk $? "report contains steady bar verdict"
grep -q 'nopressure zero-eviction' "$TMP/report-on.md"; chk $? "report contains nopressure zero-eviction check"
grep -q 'host_hit_rate' "$TMP/report-on.md"; chk $? "report contains host_hit_rate"
grep -Eq 'PASS — recovery2 device hits' "$TMP/report-on.md"; chk $? "recovery2 device-hit check PASS on mock"
grep -q 'recovery1 all host hits' "$TMP/report-on.md"; chk $? "recovery1 host-hit check exercised (LRU evictions)"
python3 hc-report.py "$TMP/legacy.jsonl" --out "$TMP/report-legacy.md" >/dev/null 2>&1
rc=$?; [[ $rc -eq 0 || $rc -eq 3 ]]; chk $? "hc-report legacy run exits 0/3 (verdict-coded, no crash)"
grep -q 'ABSENT' "$TMP/report-legacy.md"; chk $? "legacy report marks HC-7 fields ABSENT"
python3 hc-report.py "$TMP/v2.jsonl" --out "$TMP/report-v2.md" >/dev/null 2>&1
chk $? "hc-report stats-404 run does not crash"
grep -q 'ABSENT' "$TMP/report-v2.md"; chk $? "v2-style report marks counters ABSENT"
python3 hc-report.py "$TMP/v2.jsonl" "$TMP/on.jsonl" --out "$TMP/report-cmp.md" >/dev/null 2>&1
chk $? "hc-report multi-run exit"
grep -q '## Comparison' "$TMP/report-cmp.md"; chk $? "comparison table rendered for 2 runs"

# --- ladder corpus + concurrency (HB-3) --------------------------------------
python3 hc-ladder.py --base http://127.0.0.1:$P_MAIN --sizes 1024 --mode cold --timeout 30 \
  >"$TMP/ladder-greek.jsonl" 2>"$TMP/ladder-greek.err"
chk $? "hc-ladder default greek corpus smoke exit 0"
tail -n 1 "$TMP/ladder-greek.jsonl" | grep -q LADDER-DONE; chk $? "greek smoke prints LADDER-DONE"
! grep -q corpus_sha256_16 "$TMP/ladder-greek.jsonl"; chk $? "greek lines carry no corpus sha (default unchanged)"

python3 hc-ladder.py --base http://127.0.0.1:$P_MAIN --corpus "$TMP/corpus.txt" --sizes 2000,4000 \
  --mode cold,reuse --timeout 30 >"$TMP/ladder-corpus.jsonl" 2>"$TMP/ladder-corpus.err"
chk $? "hc-ladder --corpus cold,reuse exit 0"
python3 - "$TMP/ladder-corpus.jsonl" <<'EOF'
import json, sys
raw = open(sys.argv[1]).read().splitlines()
assert raw[-1] == "LADDER-DONE", raw[-1]
lines = [json.loads(l) for l in raw[:-1]]
# per size: cold then reuse (reuse re-sends the same prompt while it is hot)
assert [l["mode"] for l in lines] == ["cold", "reuse", "cold", "reuse"], [l["mode"] for l in lines]
assert [l["size"] for l in lines] == [2000, 2000, 4000, 4000], [l["size"] for l in lines]
for l in lines:
    assert l.get("corpus_sha256_16"), "corpus sha not recorded"
    assert l.get("prompt_tokens"), "measured prompt_tokens missing (tok/char caveat)"
print("LADDER-CORPUS-OK salted slices, sizes in chars, measured tokens recorded")
EOF
chk $? "ladder --corpus: salted corpus lines, char sizes, measured prompt_tokens"

python3 hc-ladder.py --base http://127.0.0.1:$P_MAIN --corpus "$TMP/corpus.txt" --sizes 3000 \
  --mode cold --concurrency 3 --timeout 30 >"$TMP/ladder-cc.jsonl" 2>&1
chk $? "hc-ladder cold --concurrency 3 exit 0"
python3 - "$TMP/ladder-cc.jsonl" <<'EOF'
import json, sys
raw = open(sys.argv[1]).read().splitlines()
assert raw[-1] == "LADDER-DONE"
lines = [json.loads(l) for l in raw[:-1]]
reqs = [l for l in lines if l["mode"] == "cold"]
agg = [l for l in lines if l["mode"] == "aggregate"]
assert len(reqs) == 3 and all(r["concurrency"] == 3 and "worker" in r for r in reqs)
assert len({r["salt"] for r in reqs}) == 3, "concurrent requests must be distinctly salted"
assert len(agg) == 1 and agg[0]["n"] == 3 and agg[0]["errors"] == 0
assert agg[0]["ttft_p50_s"] is not None and agg[0]["ttft_p95_s"] is not None
assert agg[0]["prefill_tok_s"] and agg[0]["prefill_tok_s"] > 0
print("LADDER-CC-OK 3 salted request lines + aggregate p50/p95 + prefill tok/s")
EOF
chk $? "ladder cold --concurrency: N request lines + aggregate line (tok/s, TTFT p50/p95)"

python3 hc-ladder.py --base http://127.0.0.1:$P_MAIN --corpus "$TMP/corpus.txt" --mode decode \
  --decode 8 --concurrency 3 --timeout 30 >"$TMP/ladder-dc.jsonl" 2>&1
chk $? "hc-ladder decode --concurrency 3 exit 0"
python3 - "$TMP/ladder-dc.jsonl" <<'EOF'
import json, sys
raw = open(sys.argv[1]).read().splitlines()
assert raw[-1] == "LADDER-DONE"
lines = [json.loads(l) for l in raw[:-1]]
reqs = [l for l in lines if l["mode"] == "decode"]
agg = [l for l in lines if l["mode"] == "aggregate"]
assert len(reqs) == 3 and all(r["out_tokens"] == 8 for r in reqs)
assert len(agg) == 1 and agg[0]["n"] == 3
assert agg[0]["decode_tok_s"] and agg[0]["decode_tok_s"] > 0
print("LADDER-DECODE-CC-OK aggregate decode_tok_s", agg[0]["decode_tok_s"])
EOF
chk $? "ladder decode --concurrency: per-request lines + aggregate decode tok/s"

# --- rotate mixed corpus (HB-3, plan R5 prose+code) ---------------------------
python3 hc-rotate.py --base http://127.0.0.1:$P_MAIN --tag mock-mix --out "$TMP/mix.jsonl" \
  --corpus "$TMP/corpus/prose.txt,$TMP/corpus/code.txt" --segments warmup \
  --clients 2 --sessions 2 --ctx-chars 2000 --new-chars 300 --decode 6 --timeout 30 >/dev/null 2>&1
chk $? "hc-rotate mixed-corpus exit 0"
python3 - "$TMP/mix.jsonl" <<'EOF'
import json, sys
hdr = next(json.loads(l) for l in open(sys.argv[1]) if l.strip()
           and json.loads(l)["kind"] == "header")
c = hdr["corpus"]
assert len(c["paths"]) == 2 and len(c["sha256_16"]) == 2, c
assert "client c uses" in c["assignment"], c
print("MIX-OK comma corpora recorded with round-robin client assignment")
EOF
chk $? "mixed --corpus records paths + round-robin assignment in header"

# --- matrix driver dry-run (HB-3) --------------------------------------------
python3 hc-mock-server.py --port $P_QZERO --quota-bytes 0 >"$TMP/mock5.log" 2>&1 &
MOCK5=$!
for _ in $(seq 1 40); do curl -fsS -m 1 http://127.0.0.1:$P_QZERO/health >/dev/null 2>&1 && break; sleep 0.25; done

out=$(bash hc-matrix.sh --base http://127.0.0.1:$P_QZERO --out "$TMP/mx-on0" --dry-run on b1-ladder-prose 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run exit 0 (ON arm, quota=0 mock)"
grep -q "GATED b1-ladder-prose-on" <<<"$out"; chk $? "ON arm gated when quota_bytes=0 (cache off)"
grep -q gated "$TMP/mx-on0/matrix.log" 2>/dev/null; chk $? "gating recorded in matrix.log"

out=$(bash hc-matrix.sh --base http://127.0.0.1:$P_QZERO --out "$TMP/mx-off0" --dry-run off b1-ladder-prose 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run exit 0 (OFF arm, quota=0 mock)"
! grep -q GATED <<<"$out"; chk $? "OFF arm not gated when quota_bytes=0"
grep -q "hc-ladder.py" <<<"$out"; chk $? "OFF arm prints the ladder commands"
grep -q -- "--mode cold" <<<"$out"; chk $? "ladder cell prints the cold-rung command"
grep -q -- "--mode cold,reuse" <<<"$out"; chk $? "ladder cell prints the reuse-rung command (170k)"

out=$(bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-on24" --dry-run on b2-r3 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run exit 0 (ON arm, quota=24G mock)"
grep -q "hc-rotate.py" <<<"$out"; chk $? "b2-r3 prints the rotate command"
grep -q -- "--clients 6" <<<"$out"; chk $? "b2-r3 shape C6 (plan R3)"
grep -q -- "--sessions 2" <<<"$out"; chk $? "b2-r3 shape S2 (plan R3)"
grep -q -- "--steady-secs 600" <<<"$out"; chk $? "b2-r3 steady 600 s ON"
grep -q -- "--probe" <<<"$out"; chk $? "b2-r3 probe on"

out=$(bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-all" --dry-run on \
  b1-nopressure b1-ladder-prose b1-ladder-code b1-decode-prose b1-decode-code \
  b2-r1 b2-r2 b2-r3 b2-r4 b2-r5 b3-recovery b4-sessions b4-context 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run all 13 cells exit 0"
n=$(grep -c '^+ ' <<<"$out")
[[ $n -ge 13 ]]; chk $? "every cell printed at least one command ($n commands total)"
for c in b1-nopressure b1-ladder-prose b1-ladder-code b1-decode-prose b1-decode-code \
         b2-r1 b2-r2 b2-r3 b2-r4 b2-r5 b3-recovery b4-sessions b4-context; do
  grep -q "$c" <<<"$out" || bad "cell $c missing from dry-run output"
done
chk 0 "all 13 cell names appear in dry-run output"
n_bc=$(grep -c '^+ bar-check' <<<"$out")
[[ $n_bc -eq 10 ]]; chk $? "b4 ramps print a bar check per ramp point ($n_bc/10)"
grep -q -- "--run-id b4-sessions-on" <<<"$out"; chk $? "b4-sessions ramp reuses one run-id (session retention)"
grep -q -- "--concurrency 6" <<<"$out"; chk $? "b1-decode cells print the C6 rung"

# --- matrix driver: b3-recovery revisit shape (HB-9) --------------------------
# With B3_RUN_ID the cell must rerun the primed cell's shape (default 6x2 = R3, not
# the hardcoded 3x4 that cold-primed six never-primed sessions on 2026-09-15);
# without it today's 3x4 fresh shape; clients x sessions must stay 12.
out=$(B3_RUN_ID=abc bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-b3r3" --dry-run on b3-recovery 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run on b3-recovery exit 0 (B3_RUN_ID set)"
grep -q -- "--clients 6" <<<"$out"; chk $? "B3 revisit default C6 (R3's shape)"
grep -q -- "--sessions 2" <<<"$out"; chk $? "B3 revisit default S2 (R3's shape)"
grep -q -- "--run-id abc" <<<"$out"; chk $? "B3 passes the primed cell's run id"

out=$(B3_RUN_ID=abc B3_CLIENTS=3 B3_SESSIONS=4 bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-b3ov" --dry-run on b3-recovery 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run on b3-recovery exit 0 (B3 shape override 3x4)"
grep -q -- "--clients 3" <<<"$out"; chk $? "B3_CLIENTS override honoured"
grep -q -- "--sessions 4" <<<"$out"; chk $? "B3_SESSIONS override honoured"
grep -q -- "--run-id abc" <<<"$out"; chk $? "B3 shape override keeps the revisit run id"

out=$(bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-b3fr" --dry-run on b3-recovery 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run on b3-recovery exit 0 (no B3_RUN_ID, fresh)"
grep -q -- "--clients 3" <<<"$out"; chk $? "fresh B3 shape C3 (today's cell)"
grep -q -- "--sessions 4" <<<"$out"; chk $? "fresh B3 shape S4 (today's cell)"
! grep -q -- "--run-id" <<<"$out"; chk $? "no --run-id without B3_RUN_ID (fresh sessions)"
grep -q -- "--recovery-sessions 12" <<<"$out"; chk $? "B3 recovers exactly 12 sessions either way"

out=$(B3_CLIENTS=5 B3_SESSIONS=2 bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-b3bad" --dry-run on b3-recovery 2>&1)
rc=$?
[[ $rc -ne 0 ]]; chk $? "B3 shape 5x2 (product 10 != 12) fails the cell non-zero"
grep -q "product 10 != 12" <<<"$out"; chk $? "B3 shape failure names the mismatch"


# --- matrix driver: b5-agentic cell (HB-6, plan §6 B5) ------------------------
out=$(bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-b5" --dry-run on b5-agentic 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run on b5-agentic exit 0"
for K in 8 16 32 48; do
  grep -q -- "--tag b5-agentic-on-k$K" <<<"$out" || bad "b5 dry-run missing point k$K tag"
done
chk 0 "b5-agentic prints all four point tags (k8/k16/k32/k48)"
grep -q -- "--clients 48" <<<"$out"; chk $? "b5 k48 point present (exceeds engine concurrency 16 by design)"
grep -q -- "--sessions 1" <<<"$out"; chk $? "b5 agents own one growing session (S=1)"
grep -q -- "--turn-gap-secs 5,30" <<<"$out"; chk $? "b5 prints the 5,30 s tool gap"
grep -q -- "--new-chars 5000" <<<"$out"; chk $? "b5 tool result ~5,000 chars"
grep -q -- "--decode 96" <<<"$out"; chk $? "b5 tool-call decode 96 tokens"
grep -q -- "--run-id b5-agentic-on" <<<"$out"; chk $? "b5 ramp reuses one run-id (session retention)"
n_bc5=$(grep -c '^+ bar-check' <<<"$out")
[[ $n_bc5 -eq 4 ]]; chk $? "b5 prints a bar check per point ($n_bc5/4)"

python3 hc-mock-server.py --port $P_QZERO2 --quota-bytes 0 >"$TMP/mock6.log" 2>&1 &
MOCK6=$!
for _ in $(seq 1 40); do curl -fsS -m 1 http://127.0.0.1:$P_QZERO2/health >/dev/null 2>&1 && break; sleep 0.25; done
out=$(B5_POINTS="8 16" bash hc-matrix.sh --base http://127.0.0.1:$P_QZERO2 --out "$TMP/mx-b5off" \
  --dry-run off b5-agentic 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run off b5-agentic exit 0 (quota=0 mock)"
grep -q -- "--tag b5-agentic-off-k8" <<<"$out"; chk $? "B5_POINTS override: k8 point present"
grep -q -- "--tag b5-agentic-off-k16" <<<"$out"; chk $? "B5_POINTS override: k16 point present"
! grep -q -- "k32" <<<"$out"; chk $? "B5_POINTS override: k32/k48 omitted"
! grep -q GATED <<<"$out"; chk $? "OFF arm not gated when quota_bytes=0"

out=$(bash hc-matrix.sh --base http://127.0.0.1:$P_MAIN --out "$TMP/mx-b5code" --dry-run on b5-agentic 2>&1)
cx=$(python3 -c 'import math; print(math.ceil(30000/0.32))')
grep -q "code.txt" <<<"$out"; chk $? "b5 uses the code corpus"
grep -q -- "--ctx-chars $cx" <<<"$out"; chk $? "b5 ctx = 30k code tok at TPC_CODE ($cx chars)"

out=$(bash hc-matrix.sh --base http://127.0.0.1:9 --out "$TMP/mx-noh" --dry-run on b1-nopressure 2>&1)
rc=$?
chk $rc "hc-matrix --dry-run exit 0 with unreachable endpoint"
grep -q '^+ .*hc-rotate.py' <<<"$out"; chk $? "unreachable /health in dry-run prints commands ungated (with note)"

out=$(bash hc-matrix.sh --out "$TMP/mx-none" --dry-run on 2>&1)
[[ $? -ne 0 && -n $out ]]; chk $? "missing cell argument exits non-zero"

# unreachable server -> exit 1, no output file
python3 hc-rotate.py --base http://127.0.0.1:9 --tag x --out "$TMP/x.jsonl" \
  --corpus "$TMP/corpus.txt" --segments steady --steady-secs 1 >/dev/null 2>&1
[[ $? -eq 1 ]]; chk $? "unreachable server exits 1"

# --- ladder reducer + final report assembler (HB-4) ---------------------------
# Real fleet fixtures (OFF arm of the 2026-09-15 matrix, copied into the repo's
# bench dir): the code ladder crashed mid-cell before the error-record fix, so
# its JSONL simply stops after 2 of 4 cold rungs — absence is the failure shape.
# The fixture JSONLs are untracked live bench output, so packet worktrees that
# never pulled them across skip these checks (with a note), never fail them.
BENCH=../bench/hostcache-20260915
if [[ -r $BENCH/b1-ladder-prose-off.jsonl && -r $BENCH/b1-ladder-code-off.jsonl \
   && -r $BENCH/b1-decode-prose-off.jsonl && -r $BENCH/b1-decode-code-off.jsonl \
   && -r $BENCH/b2-r1-off.jsonl && -r $BENCH/b2-r4-off.jsonl \
   && -r $BENCH/pilot-report.md ]]; then
python3 hc-ladder-report.py "$BENCH/b1-ladder-prose-off.jsonl" "$BENCH/b1-ladder-code-off.jsonl" \
  "$BENCH/b1-decode-prose-off.jsonl" "$BENCH/b1-decode-code-off.jsonl" \
  --out "$TMP/ladder-report.md" >/dev/null 2>&1
chk $? "hc-ladder-report over the real OFF fixtures exit 0"
python3 - "$TMP/ladder-report.md" <<'EOF'
import re, sys
md = open(sys.argv[1]).read()

def corpus(name):
    m = re.search(rf"^## Corpus: {name}\n(.*?)(?=^## |\Z)", md, re.M | re.S)
    assert m, f"corpus {name} missing"
    return m.group(1)

def cold_rungs(body):
    head = body.split("### Reuse")[0]
    return re.findall(r"^\| \d+ \|", head, re.M)

prose, code = corpus("prose"), corpus("code")
# cold rungs: prose recorded all 4; the code ladder had crashed after 2 when this
# fixture snapshot was taken (lines simply missing) — the live file now records all 4
assert len(cold_rungs(prose)) == 4, cold_rungs(prose)
assert 2 <= len(cold_rungs(code)) <= 4, cold_rungs(code)
# reuse rows: one per corpus (170k-class rung)
assert len(re.findall(r"^\| reuse \|", prose, re.M)) == 1
assert len(re.findall(r"^\| reuse \|", code, re.M)) == 1
# decode rows: C1/C3/C6 per corpus; recomputed aggregate exceeds the per-stream
# mean wherever an aggregate exists (C3/C6 here predate decode_aggregate_tok_s,
# so the reducer recomputes them from the per-request lines' wall span)
for body in (prose, code):
    m = re.search(r"### Decode\n\n(.*?)(?=^### |\Z)", body, re.M | re.S)
    rows = [l for l in m.group(1).splitlines() if re.match(r"^\| C\d+ ", l)]
    assert len(rows) == 3, rows
    for l in rows:
        c = [x.strip() for x in l.split("|")]
        per_stream, agg = float(c[2]), c[4]
        if agg != "—":
            assert float(agg) > per_stream, f"{c[1]}: aggregate {agg} !> per-stream {per_stream}"
print("LADDER-REPORT-OK 4+2 cold rungs, 2 reuse, 3+3 decode rows, aggregates > per-stream")
EOF
chk $? "reducer: expected row counts; recomputed C3/C6 aggregates exceed per-stream means"
grep -q "no error records" "$TMP/ladder-report.md"
chk $? "errors table tolerates the pre-fix crash shape (no error records, rungs simply missing)"

# errors table renders mode/size/error head when a record carries one
printf '%s\n' '{"mode": "cold", "size": 1024, "tag": "synthetic-off", "error": "HTTP 400: prompt too long"}' \
  > "$TMP/ladder-err.jsonl"
python3 hc-ladder-report.py "$TMP/ladder-err.jsonl" --out "$TMP/ladder-err.md" >/dev/null 2>&1
chk $? "hc-ladder-report on an error record exit 0"
grep -q '| synthetic | off | cold | 1024 | HTTP 400: prompt too long |' "$TMP/ladder-err.md"
chk $? "errors table row = corpus, arm, mode, size, error head"

# assembler over an OFF-only copy of the fixtures (the live bench dir may hold ON cells by now):
# ON cells absent -> pending, never errors
mkdir -p "$TMP/cells-off"
cp "$BENCH"/b1-*-off.jsonl "$BENCH"/b2-r1-off.jsonl "$BENCH"/b2-r4-off.jsonl "$BENCH"/oneM-true-*.jsonl "$TMP/cells-off"/ 2>/dev/null
python3 hc-final-report.py --draft ../bench/report-draft.md --pilot "$BENCH/pilot-report.md" \
  --out "$TMP/final-report.md" --cells "$TMP/cells-off" >/dev/null 2>&1
chk $? "hc-final-report assembles with OFF-only cells exit 0"
grep -q "pending" "$TMP/final-report.md"; chk $? "missing ON cells render as pending rows"
python3 - "$TMP/final-report.md" <<'EOF'
import sys
md = open(sys.argv[1]).read()
# §3 replaced by the pilot body (comparison table in, duplicate H1 title out)
assert "\n### Comparison (steady segment)\n" in md, "pilot comparison table missing"
assert "# Host-cache bench report" not in md, "pilot H1 title must be stripped"
# draft sections outside §3/§4 pass through verbatim
assert "\n## 5. Findings\n" in md and "Store-copy completion latency" in md
assert "\n## 2. Method\n" in md
# §4: B1 ladder/decode tables from the OFF arm, B2 tables, 1M rung with restore numbers
assert "### Corpus: prose" in md and "### Corpus: code" in md
assert "### Run b2-r1-off" in md and "### Run b2-r4-off" in md
assert "| after-evict | 4800000 | 1000007 | 0 | 1000007 | 1.089 |" in md
assert "68.16" in md, "1M restore mean missing"
# unreached cells are pending notes, not failures
assert "b3-recovery: pending" in md and "b4-sessions: pending" in md
print("FINAL-REPORT-OK pilot in §3, draft verbatim, B1/B2/1M tables, ON cells pending")
EOF
chk $? "assembled report: §3 pilot body, draft verbatim, B1/B2/1M tables, ON pending"
else
  echo "SKIP real-fixture reducer/assembler checks: no fleet fixture JSONLs under $BENCH"
fi

# assembler §4.5: two-point B5 fixture (HB-6, HB-7 fields) — OFF fails its bar at k16,
# ON passes both; exercises the 503-as-backpressure error classification:
# OFF k8 carries a bare 503 error (retries disabled -> backpressure, NOT counted),
# ON k8 a genuine 500 (counted), OFF k16 a 503 that exhausted its retry budget (counted).
mkdir -p "$TMP/cells-b5"
python3 - "$TMP/cells-b5" <<'EOF'
import json, os, sys
d = sys.argv[1]
for arm, quota in (("off", 0), ("on", 25769803776)):
    lines = []
    for K in (8, 16):
        tag = f"b5-agentic-{arm}-k{K}"
        n = 10 if arm == "off" else 24
        lines.append({"kind": "header", "tag": tag, "run_id": f"b5-agentic-{arm}",
                      "config": {"clients": K, "sessions": 1, "turn_gap_secs": "5,30",
                                 "steady_secs": 240, "decode": 96},
                      "stats_start": {"quota_bytes": quota}})
        lines.append({"kind": "segment", "tag": tag, "segment": "steady",
                      "t0": 1000.0, "t1": 1240.0,
                      "stats_before": {"quota_bytes": quota, "restore_timeouts": 0,
                                       "restore_failures": 0},
                      "stats_after": {"quota_bytes": quota, "restore_timeouts": 0,
                                      "restore_failures": 0}})
        for i in range(n):
            rec = {"kind": "req", "tag": tag, "segment": "steady", "client": i % K,
                   "visit": i // K, "turn_gap_s": 12.5,
                   "ttft_s": 8.0 if arm == "off" else 0.9,
                   "wall_s": 9.0, "gen_s": 1.0, "out_tokens": 96, "decode_tok_s": 96.0,
                   "prompt_tokens": 40000,
                   "hit_tokens": 0 if arm == "off" else 38400,
                   "miss_tokens": 40000 if arm == "off" else 1600}
            if K == 16 and i >= n - 4:  # HB-7: visits that absorbed 503 backpressure
                rec.update({"retries_503": 2, "backoff_s": 1.1,
                            "turn_latency_s": 9.7 if arm == "off" else 2.4})
            lines.append(rec)
        if arm == "off" and K == 8:
            lines.append({"kind": "error", "tag": tag, "segment": "steady", "client": 0,
                          "error": "HTTPError: HTTP Error 503: Service Unavailable"})
        if arm == "on" and K == 8:
            lines.append({"kind": "error", "tag": tag, "segment": "steady", "client": 0,
                          "error": "HTTPError: HTTP Error 500: Internal Server Error"})
        if arm == "off" and K == 16:
            lines.append({"kind": "error", "tag": tag, "segment": "steady", "client": 1,
                          "error": "HTTPError: HTTP Error 503: Service Unavailable",
                          "retries_503": 20, "backoff_s": 42.5})
        lines.append({"kind": "bar-check", "cell": f"b5-agentic-{arm}", "point": f"k{K}",
                      "arm": arm, "result": "fail" if (arm == "off" and K == 16) else "pass",
                      "bar_ttft_s": 10,
                      "ttft_p95_s": 8.4 if arm == "off" else 1.1,
                      "turn_latency_p95_s": (9.7 if arm == "off" else 2.4) if K == 16 else None,
                      "request_errors": (1 if (arm == "off" and K == 16)
                                         else 1 if (arm == "on" and K == 8) else 0),
                      "retries_503_sum": 8 if K == 16 else 0,
                      "retries_503_p95_per_turn": 2 if K == 16 else 0,
                      "restore_timeouts_delta": 0,
                      "restore_failures_delta": 0, "steady_requests": n,
                      "detail": "within bar" if not (arm == "off" and K == 16)
                                else "revisit TTFT p95 8.40s > 10s bar"})
    lines.append({"kind": "cell-done", "cell": "b5-agentic", "arm": arm,
                  "result": "fail" if arm == "off" else "pass",
                  "stop_at": "k16" if arm == "off" else "none"})
    with open(os.path.join(d, f"b5-agentic-{arm}.jsonl"), "w") as fh:
        for l in lines:
            fh.write(json.dumps(l) + "\n")
EOF
python3 hc-final-report.py --draft ../bench/report-draft.md \
  --pilot ../bench/hostcache-20260915/pilot-report.md \
  --out "$TMP/final-b5.md" --cells "$TMP/cells-b5" >/dev/null 2>&1
chk $? "assembler exit 0 over the two-point B5 fixture"
python3 - "$TMP/final-b5.md" <<'EOF'
import re, sys
md = open(sys.argv[1]).read()
assert "\n### 4.5 B5 — agentic ramp (G6)\n" in md, "§4.5 B5 heading missing"
assert "\n### 4.6 1M context rung\n" in md, "1M rung must be renumbered to §4.6"
rows = re.findall(r"^\| (\d+) \| (OFF|ON) \|", md, re.M)
assert rows == [("8", "OFF"), ("8", "ON"), ("16", "OFF"), ("16", "ON")], rows
# HB-7 columns: retries/turn p95, turn latency p95, errors = non-503 terminal errors
# (bare 503 on OFF k8 excluded, exhausted-retry 503 on OFF k16 counted, 500 on ON k8 counted)
assert re.search(r"^\| 8 \| OFF \| 10 \| 0\.31 \| 8\.000 \| 8\.000 \| 0\.000 \| 96\.0 \| 0 \| — \| 0 \| pass \|", md, re.M), \
    "OFF k8 row wrong (bare 503 must not count as an error)"
assert re.search(r"^\| 8 \| ON \| 24 \| 0\.75 \| 0\.900 \| 0\.900 \| 0\.960 \| 96\.0 \| 0 \| — \| 1 \| pass \|", md, re.M), \
    "ON k8 row wrong (the 500 must count)"
assert re.search(r"^\| 16 \| OFF \| 10 \| 0\.16 \| 8\.000 \| 8\.000 \| 0\.000 \| 96\.0 \| 2 \| 9\.700 \| 1 \| fail \|", md, re.M), \
    "OFF k16 row wrong (exhausted-retry 503 must count; retries/turn p95 = 2)"
assert re.search(r"^\| 16 \| ON \| 24 \| 0\.38 \| 0\.900 \| 0\.900 \| 0\.960 \| 96\.0 \| 2 \| 2\.400 \| 0 \| pass \|", md, re.M), \
    "ON k16 row wrong (retries/turn p95 = 2, turn latency p95 = 2.400)"
assert "backpressure" in md, "503-as-backpressure rationale missing"
assert "latency-bound" in md, "no-decode-bar rationale missing"
print("B5-REPORT-OK §4.5 rows adjacent per K, HB-7 columns, 503 error classification, 1M at §4.6")
EOF
chk $? "§4.5 B5 table: (K, arm) rows adjacent, retries/turn + turn latency columns, non-503 errors"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
