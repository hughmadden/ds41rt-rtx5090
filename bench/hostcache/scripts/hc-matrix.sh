#!/usr/bin/env bash
# hc-matrix.sh — resumable driver for the DS41RT host-cache full matrix (bench plan §6).
#
# Usage:
#   hc-matrix.sh [--base URL] [--out DIR] [--corpus-dir DIR] [--dry-run] [--force] <off|on> <cell...>
#
# Cells (plan §6 names): b1-nopressure, b1-ladder-prose, b1-ladder-code, b1-decode-prose,
# b1-decode-code, b2-r1..b2-r5, b3-recovery, b4-sessions, b4-context, b5-agentic.
# One JSONL per cell under $OUT (default <engram-dir>/bench/hostcache-20260915/, overridable
# with the OUT env var) plus a matrix.log line per cell (AEST + UTC timestamps). A cell whose
# output is complete (last record a rotate footer, a RUN-DONE / LADDER-DONE line, or a
# cell-done record) is skipped unless --force.
#
# The driver never launches or stops the coordinator. It checks /health before each cell and
# refuses an ON cell when /v1/stats reports quota_bytes == 0 (cache not up), and an OFF cell
# when quota_bytes is non-zero (cache still on). --dry-run prints every command with its
# parameters (gating still applied when the endpoint answers; ungated with a note when it
# does not) and exits 0.
#
# B4 ramps run each ramp point as one tagged rotate run inside the cell JSONL (--run-id fixed
# per cell so later points revisit the earlier clients' sessions — the host cache retains
# them, plan §6 B4). After each point the bar check (plan §1.2: decode >= 20 tok/s per
# client, p95 revisit TTFT <= 10 s, zero restore timeouts/failures) is computed FROM the
# JSONL, printed, appended as a bar-check record, and the ramp stops at the first failing
# point; the cell-done record carries the outcome.
#
# B5 (agentic ramp, plan §6 B5) is the same ramp shape at S=1 with --turn-gap-secs 5,30 (the
# tool gap; idle agents hold no request slot) and its own bar (bar_check_b5: p95 revisit
# TTFT <= BAR_TTFT, zero non-503 request errors — a 503 is coordinator backpressure, retried
# by hc-rotate with backoff; one that exhausted its retries still counts — zero restore
# timeouts/failures — no decode bar).
#
# Char targets derive from the plan's token targets via tok/char ratios: the pilot measures
# the real ratios; override TPC_PROSE / TPC_CODE (defaults 0.28 / 0.32, plan §2 caveat)
# once calibrated. Sizes sent to the harnesses stay in characters; measured tokens are
# recorded per line by the harnesses.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENGRAM_DIR=$(dirname "$SCRIPT_DIR")

DRY=0
FORCE=0
BASE=${BASE:-http://127.0.0.1:8000}
OUT=${OUT:-$ENGRAM_DIR/bench/hostcache-20260915}
CORPUS_DIR=${CORPUS_DIR:-$ENGRAM_DIR/bench-corpus}
TPC_PROSE=${TPC_PROSE:-0.28}   # tok/char; pilot calibration may override (plan §2)
TPC_CODE=${TPC_CODE:-0.32}
STEADY_ON=${STEADY_ON:-600}    # plan §6 B2: steady 600 s ON / 300 s OFF
STEADY_OFF=${STEADY_OFF:-300}
RAMP_STEADY=${RAMP_STEADY:-240} # plan §6 B4/B5: 240 s steady per ramp point
B5_POINTS=${B5_POINTS:-"8 16 32 48"} # plan §6 B5 agentic ramp: K agents per point
BAR_TTFT=${BAR_TTFT:-10}        # plan §6 B5 bar: revisit TTFT p95 <= 10 s (no decode bar)
PROSE=$CORPUS_DIR/prose.txt
CODE=$CORPUS_DIR/code.txt
EXIT=0

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
  echo "cells: b1-nopressure b1-ladder-prose b1-ladder-code b1-decode-prose b1-decode-code b2-r1 b2-r2 b2-r3 b2-r4 b2-r5 b3-recovery b4-sessions b4-context b5-agentic"
}

CELLS=()
ARM=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)   DRY=1 ;;
    --force)     FORCE=1 ;;
    --base)      BASE=$2; shift ;;
    --out)       OUT=$2; shift ;;
    --corpus-dir) CORPUS_DIR=$2; PROSE=$CORPUS_DIR/prose.txt; CODE=$CORPUS_DIR/code.txt; shift ;;
    -h|--help)   usage; exit 0 ;;
    off|on)
      [[ -n $ARM ]] && { echo "arm given twice: $1" >&2; exit 2; }
      ARM=$1 ;;
    b1-*|b2-*|b3-*|b4-*|b5-*) CELLS+=("$1") ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done
[[ -z $ARM ]] && { echo "arm required: off|on" >&2; usage; exit 2; }
if [[ ${#CELLS[@]} -eq 0 ]]; then
  echo "at least one cell required" >&2; usage; exit 2
fi

# --- helpers ----------------------------------------------------------------
ts_aest() { TZ=Australia/Sydney date +%Y-%m-%dT%H:%M:%S%z; }
ts_utc()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
logline() { printf '%s %s %s\n' "$(ts_aest)" "$(ts_utc)" "$*" >> "$OUT/matrix.log"; }

chars_for() { # token target, tok/char -> characters (ceil)
  python3 -c 'import math, sys; print(math.ceil(float(sys.argv[1]) / float(sys.argv[2])))' "$1" "$2"
}

complete_p() { # $1 = cell JSONL; last record must be a footer / DONE line / cell-done
  [[ -f $1 ]] || return 1
  tail -n 1 "$1" | grep -qE 'RUN-DONE|LADDER-DONE|"footer"|"kind": ?"cell-done"'
}

quota_now() {
  curl -fsS -m 5 "$BASE/v1/stats" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = None
hc = d.get("host_cache") if isinstance(d, dict) else None
q = (hc or {}).get("quota_bytes", "ABSENT")
print(q if isinstance(q, int) else "ABSENT")'
}

gated() { # $1 cell, $2 reason
  echo "GATED $1-$ARM: $2"
  logline "$1-$ARM gated $2"
  [[ $DRY == 0 ]] && EXIT=1
}

health_gate() { # $1 cell; 0 = may run (already logged when not)
  local cell=$1
  if ! curl -fsS -m 5 "$BASE/health" >/dev/null 2>&1; then
    if [[ $DRY == 1 ]]; then
      echo "[note] /health unreachable at $BASE — dry-run prints commands ungated"
      return 0
    fi
    echo "REFUSE $cell-$ARM: /health failed at $BASE"
    logline "$cell-$ARM refuse health"
    EXIT=1
    return 1
  fi
  local q
  q=$(quota_now)
  if [[ $ARM == on ]]; then
    if [[ ! $q =~ ^[0-9]+$ || $q -eq 0 ]]; then
      gated "$cell" "ON arm but quota_bytes=$q (cache not up)"
      return 1
    fi
  else
    if [[ $q =~ ^[0-9]+$ && $q -ne 0 ]]; then
      gated "$cell" "OFF arm but quota_bytes=$q (cache still on)"
      return 1
    fi
  fi
  return 0
}

cell_corpora() { # corpus vars a cell needs (for the existence check)
  case $1 in
    b1-ladder-code|b1-decode-code|b5-agentic) echo CODE ;;
    b2-r5)                         echo "PROSE CODE" ;;
    *)                             echo PROSE ;;
  esac
}

begin_cell() { # $1 = cell name; 0 = proceed (sets TAG/F/LOG/CELL_T0), 1 = skip/refuse (logged)
  local cell=$1 v path
  TAG=$cell-$ARM
  F=$OUT/$TAG.jsonl
  LOG=$OUT/$TAG.log
  mkdir -p "$OUT"
  if [[ $FORCE == 0 ]] && complete_p "$F"; then
    echo "SKIP $TAG (complete)"
    logline "$TAG skip complete"
    return 1
  fi
  if [[ $FORCE == 1 && $DRY == 0 ]]; then
    rm -f "$F" "$LOG"
  fi
  health_gate "$cell" || return 1
  if [[ $DRY == 0 ]]; then
    for v in $(cell_corpora "$cell"); do
      path=${!v}
      if [[ ! -s $path ]]; then
        echo "REFUSE $TAG: corpus missing: $path"
        logline "$TAG refuse corpus-missing $path"
        EXIT=1
        return 1
      fi
    done
  fi
  CELL_T0=$(date +%s)
  return 0
}

end_cell() { # $1 rc, $2 detail
  local rc=$1 detail=${2:-}
  if [[ $rc == 0 ]]; then
    logline "$TAG ok $(($(date +%s) - CELL_T0))s $detail"
  else
    logline "$TAG FAIL rc=$rc $(($(date +%s) - CELL_T0))s $detail"
    EXIT=1
  fi
}

rot() { # hc-rotate against $F/$LOG; all args passed through
  local cmd=(python3 "$SCRIPT_DIR/hc-rotate.py" --base "$BASE" "$@" --out "$F")
  if [[ $DRY == 1 ]]; then
    echo "+ ${cmd[*]}"
    return 0
  fi
  "${cmd[@]}" >>"$LOG" 2>&1
}

lad() { # hc-ladder; JSONL records go to $F (stdout), stderr to $LOG
  local cmd=(python3 "$SCRIPT_DIR/hc-ladder.py" --base "$BASE" "$@")
  if [[ $DRY == 1 ]]; then
    echo "+ ${cmd[*]} >> $F"
    return 0
  fi
  "${cmd[@]}" >>"$F" 2>>"$LOG"
}

bar_check() { # $1 file, $2 tag, $3 point label, $4 arm; appends a bar-check record; 0 pass / 1 fail
  if [[ $DRY == 1 ]]; then
    echo "+ bar-check $2 ($3) >> $1"
    return 0
  fi
  local rec rc
  rec=$(python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, os, sys
path, tag, point, arm = sys.argv[1:5]
runs = []
for line in open(path):
    try:
        r = json.loads(line)
    except ValueError:
        continue  # RUN-DONE / LADDER-DONE text lines
    if isinstance(r, dict) and r.get("tag") == tag:
        runs.append(r)
steady = [r for r in runs if r.get("kind") == "req" and r.get("segment") == "steady"
          and r.get("decode_tok_s")]
by_client, ttfts = {}, []
for r in steady:
    by_client.setdefault(r["client"], []).append(r["decode_tok_s"])
    if r.get("ttft_s") is not None:
        ttfts.append(r["ttft_s"])
def pct(v, q):
    v = sorted(v)
    return v[max(0, min(len(v) - 1, -(-len(v) * q // 100) - 1))] if v else None
decode_min = min((sum(v) / len(v) for v in by_client.values()), default=None)
ttft_p95 = pct(ttfts, 95)
d_to = d_rf = 0
for r in runs:
    if r.get("kind") == "segment":
        b, a = r.get("stats_before") or {}, r.get("stats_after") or {}
        d_to += (a.get("restore_timeouts") or 0) - (b.get("restore_timeouts") or 0)
        d_rf += (a.get("restore_failures") or 0) - (b.get("restore_failures") or 0)
# plan §1.2 bars; BAR_DECODE / BAR_TTFT (env) override them for exploratory ramps (the record
# carries the thresholds used)
bar_decode = float(os.environ.get("BAR_DECODE", "20"))
bar_ttft = float(os.environ.get("BAR_TTFT", "10"))
fails = []
if decode_min is None:
    fails.append("no steady decode samples")
elif decode_min < bar_decode:
    fails.append(f"client decode {decode_min:.1f} tok/s < {bar_decode:g} bar")
if ttft_p95 is None:
    fails.append("no steady ttft samples")
elif ttft_p95 > bar_ttft:
    fails.append(f"revisit TTFT p95 {ttft_p95:.2f}s > {bar_ttft:g}s bar")
if d_to or d_rf:
    fails.append(f"restore_timeouts +{d_to}, restore_failures +{d_rf}")
out = {"kind": "bar-check", "cell": tag, "point": point, "arm": arm,
       "result": "fail" if fails else "pass",
       "min_client_decode_tok_s": None if decode_min is None else round(decode_min, 1),
       "ttft_p95_s": ttft_p95,
       "restore_timeouts_delta": d_to, "restore_failures_delta": d_rf,
       "steady_requests": len(steady), "bar_decode_tok_s": bar_decode, "bar_ttft_p95_s": bar_ttft,
       "detail": "; ".join(fails) or f"within bar (decode>={bar_decode:g} tok/s/client, revisit TTFT p95<={bar_ttft:g}s, zero restore timeouts/failures)"}
print(json.dumps(out))
sys.exit(1 if fails else 0)
PYEOF
)
  rc=$?
  echo "$rec" >> "$1"
  echo "BAR $2 ($3): $rec"
  return $rc
}

bar_check_b5() { # $1 file, $2 tag, $3 point label, $4 arm, $5 ttft bar (s); appends a bar-check
  # record; 0 pass / 1 fail. B5 (plan §6 B5) has NO decode bar: agents are latency-bound, not
  # throughput-bound. Bar: revisit TTFT p95 <= BAR_TTFT s, zero NON-BACKPRESSURE request
  # errors, zero restore timeouts/failures (both thresholds recorded on the record).
  # HB-7/HB-8: an HTTP 503 or 429 is coordinator backpressure (rc4 immediate 503 / rc6
  # queued-then-429 with Retry-After), not a request error — a terminal 503/429 error
  # record that carries retries_503 (the shared 503+429 retry budget) exhausted its retry
  # budget and STILL counts; a bare 503/429 (retries disabled) does not. The record also
  # carries retries_503_sum, retries_503_p95_per_turn and turn_latency_p95_s
  # (informational; the bar stays on ttft_s).
  if [[ $DRY == 1 ]]; then
    echo "+ bar-check $2 ($3) >> $1"
    return 0
  fi
  local rec rc
  rec=$(python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import json, sys
path, tag, point, arm, bar_ttft = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
runs = []
for line in open(path):
    try:
        r = json.loads(line)
    except ValueError:
        continue  # RUN-DONE text lines
    if isinstance(r, dict) and r.get("tag") == tag:
        runs.append(r)
steady = [r for r in runs if r.get("kind") == "req" and r.get("segment") == "steady"]
ttfts = [r["ttft_s"] for r in steady if r.get("ttft_s") is not None]
turn_lat = [r["turn_latency_s"] for r in steady if isinstance(r.get("turn_latency_s"), (int, float))]
retries = [r.get("retries_503") or 0 for r in steady]
# HB-7/HB-8: 503/429 = backpressure, not a request error; only a 503/429 that EXHAUSTED
# its retry budget (error record carrying retries_503) still counts, as does every
# non-backpressure terminal error.
errs = [r for r in runs if r.get("kind") == "error"
        and not (any(s in (r.get("error") or "") for s in ("503", "429"))
                 and not r.get("retries_503"))]
def pct(v, q):
    v = sorted(v)
    return v[max(0, min(len(v) - 1, -(-len(v) * q // 100) - 1))] if v else None
ttft_p95 = pct(ttfts, 95)
tlat_p95 = pct(turn_lat, 95)
d_to = d_rf = 0
for r in runs:
    if r.get("kind") == "segment":
        b, a = r.get("stats_before") or {}, r.get("stats_after") or {}
        d_to += (a.get("restore_timeouts") or 0) - (b.get("restore_timeouts") or 0)
        d_rf += (a.get("restore_failures") or 0) - (b.get("restore_failures") or 0)
fails = []
if ttft_p95 is None:
    fails.append("no steady ttft samples")
elif ttft_p95 > bar_ttft:
    fails.append(f"revisit TTFT p95 {ttft_p95:.2f}s > {bar_ttft:g}s bar")
if errs:
    fails.append(f"{len(errs)} request errors")
if d_to or d_rf:
    fails.append(f"restore_timeouts +{d_to}, restore_failures +{d_rf}")
out = {"kind": "bar-check", "cell": tag, "point": point, "arm": arm,
       "result": "fail" if fails else "pass",
       "bar_ttft_s": bar_ttft, "ttft_p95_s": ttft_p95,
       "turn_latency_p95_s": tlat_p95,
       "request_errors": len(errs),
       "retries_503_sum": sum(retries),
       "retries_503_p95_per_turn": pct(retries, 95),
       "restore_timeouts_delta": d_to, "restore_failures_delta": d_rf,
       "steady_requests": len(steady),
       "detail": "; ".join(fails) or f"within bar (revisit TTFT p95<={bar_ttft:g}s, "
                                      "zero non-backpressure request errors — 503s/429s are "
                                      "coordinator backpressure, absorbed with backoff and "
                                      "counted in "
                                      "retries_503 — zero restore timeouts/failures; "
                                      "no decode bar — latency-bound)"}
print(json.dumps(out))
sys.exit(1 if fails else 0)
PYEOF
)
  rc=$?
  echo "$rec" >> "$1"
  echo "BAR $2 ($3): $rec"
  return $rc
}

bc_state() { # $1 file, $2 point, $3 result; 0 if that bar-check record exists (ramp resume)
  [[ -f $1 ]] || return 1
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
try:
    lines = open(sys.argv[1])
except OSError:
    sys.exit(1)
for line in lines:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if (isinstance(r, dict) and r.get("kind") == "bar-check"
            and r.get("point") == sys.argv[2] and r.get("result") == sys.argv[3]):
        sys.exit(0)
sys.exit(1)
PYEOF
}

# --- cells ------------------------------------------------------------------
cell_b1_nopressure() {
  begin_cell b1-nopressure || return 0
  # plan §6 B1: nopressure rotation C3 x S2 x 3 rounds (18 requests), ~8k tok/session
  # (30k chars prose at 0.28 tok/char); only valid immediately post-launch
  rot --tag "$TAG" --corpus "$PROSE" --segments nopressure \
      --clients 3 --sessions 2 --ctx-chars 30000 --new-chars 2000 --decode 100 \
      --np-clients 3 --np-sessions 2 --np-rounds 3 --np-ctx-chars 30000 --stats-every 15 --timeout 3600
  end_cell $?
}

cell_b1_ladder() { # $1 = prose|code
  local kind=$1 corpus tpc c21 c85 c170 c679 rc1 rc2
  begin_cell "b1-ladder-$kind" || return 0
  corpus=$PROSE; tpc=$TPC_PROSE
  if [[ $kind == code ]]; then corpus=$CODE; tpc=$TPC_CODE; fi
  c21=$(chars_for 21000 "$tpc");  c85=$(chars_for 85000 "$tpc")
  c170=$(chars_for 170000 "$tpc"); c679=$(chars_for 679000 "$tpc")
  # plan §6 B1: cold ladder 21k/85k/170k/679k target tokens + reuse (device hit) at 170k, C1
  lad --tag "$TAG" --corpus "$corpus" --sizes "$c21,$c85,$c170,$c679" --mode cold --timeout 3600
  rc1=$?
  lad --tag "$TAG-reuse" --corpus "$corpus" --sizes "$c170" --mode cold,reuse --timeout 3600  # cold+reuse in one run: the reuse rung must share the cold rung salt (HB-3 split them; fixed by the helm)
  rc2=$?
  end_cell $((rc1 + rc2)) "chars $c21/$c85/$c170/$c679 reuse@$c170"
}

cell_b1_decode() { # $1 = prose|code
  local kind=$1 corpus=$PROSE rc=0 C
  begin_cell "b1-decode-$kind" || return 0
  [[ $kind == code ]] && corpus=$CODE
  # plan §6 B1: decode 200 at C1, C3, C6
  for C in 1 3 6; do
    lad --tag "$TAG-c$C" --corpus "$corpus" --mode decode --decode 200 \
        --concurrency "$C" --timeout 3600
    rc=$((rc + $?))
  done
  end_cell $rc
}

b2_shape() { # $1 = r1..r5 -> "C S ctx_chars mix"; L from plan §6 B2, prose at TPC_PROSE
  case $1 in
    r1) echo "6 8 30000 prose" ;;                                     # 8k tok
    r2) echo "3 4 $(chars_for 170000 "$TPC_PROSE") prose" ;;          # 2.0M tok W
    r3) echo "6 2 $(chars_for 300000 "$TPC_PROSE") prose" ;;          # 3.6M tok W
    r4) echo "3 2 $(chars_for 679000 "$TPC_PROSE") prose" ;;          # 4.1M tok W, extreme
    r5) echo "6 4 $(chars_for 300000 "$TPC_PROSE") mix" ;;            # 7.2M tok W, prose+code
  esac
}

cell_b2() { # $1 = b2-rN
  local n=${1#b2-} C S cx mix corpus steady
  begin_cell "$1" || return 0
  read -r C S cx mix <<< "$(b2_shape "$n")"
  corpus=$PROSE
  [[ $mix == mix ]] && corpus="$PROSE,$CODE"
  steady=$STEADY_ON
  [[ $ARM == off ]] && steady=$STEADY_OFF
  rot --tag "$TAG" --corpus "$corpus" --segments warmup,steady \
      --clients "$C" --sessions "$S" --ctx-chars "$cx" --new-chars 2000 --decode 100 \
      --steady-secs "$steady" --probe --stats-every 15 --timeout 3600
  end_cell $? "C=$C S=$S ctx=$cx mix=$mix steady=${steady}s"
}

cell_b3() {
  begin_cell b3-recovery || return 0
  # plan §6 B3: recovery only, 12 sessions, 60 s idle, 600 s observe; runs immediately
  # after the harshest ON pressure cell so revisits hit the host cache.
  # Shape rule (HB-9): with B3_RUN_ID set the cell revisits the primed cell's sessions, so
  # it must rerun the PRIMED cell's shape, not a hardcoded one — B3_CLIENTS/B3_SESSIONS
  # default to 6 x 2 = R3's shape (the 2026-09-15 rerun used 3 x 4 against R3's run id:
  # six revisits were never-primed sessions, cold 51-65 s — a harness shape mismatch,
  # not a cache result). B3_RUN_ID unset = today's 3 x 4 with 12 fresh sessions. Either
  # way --recovery-sessions stays 12, so clients x sessions must equal 12; a mismatch
  # fails the cell (rc != 0) instead of quietly measuring the wrong session set.
  local C S shape rc
  if [[ -n ${B3_RUN_ID:-} ]]; then
    C=${B3_CLIENTS:-6}; S=${B3_SESSIONS:-2}
  else
    C=${B3_CLIENTS:-3}; S=${B3_SESSIONS:-4}
  fi
  if (( C * S != 12 )); then
    echo "FAIL $TAG: B3 shape ${C}x${S} (product $((C*S)) != 12 recovery sessions); set B3_CLIENTS x B3_SESSIONS = 12" >&2
    logline "$TAG FAIL b3-shape ${C}x${S} product=$((C*S))!=12"
    EXIT=1
    return 1
  fi
  shape=${C}x${S}
  rot --tag "$TAG" ${B3_RUN_ID:+--run-id "$B3_RUN_ID"} --corpus "$PROSE" --segments recovery \
      --clients "$C" --sessions "$S" --ctx-chars "$(chars_for 300000 "$TPC_PROSE")" \
      --new-chars 2000 --decode 16 \
      --recovery-sessions 12 --idle-secs 60 --observe-secs 600 --stats-every 30 --timeout 3600
  rc=$?
  if [[ $DRY == 0 && $rc == 0 ]]; then
    printf '{"kind": "cell-done", "cell": "b3-recovery", "arm": "%s", "b3_shape": "%s", "b3_run_id": "%s"}\n' \
      "$ARM" "$shape" "${B3_RUN_ID:-}" >> "$F"
  fi
  end_cell $rc "shape=$shape run_id=${B3_RUN_ID:-fresh}"
}

ramp_point() { # $1 cell, $2 run-id, $3 label, $4 C, $5 ctx_chars; tag = <cell>-<arm>-<label>
  rot --tag "$1-$ARM-$3" --run-id "$2" --corpus "$PROSE" --segments warmup,steady \
      --clients "$4" --sessions 2 --ctx-chars "$5" --new-chars 2000 --decode 100 \
      --steady-secs "$RAMP_STEADY" --stats-every 15 --timeout 3600
}

cell_b4_sessions() {
  local C cx result=pass stop_at="" rc
  begin_cell b4-sessions || return 0
  cx=$(chars_for 300000 "$TPC_PROSE")
  # plan §6 B4 sessions axis: L=300k, S=2/client, C = 6 -> 8 -> 12 -> 16, 240 s per point,
  # fixed run-id so later points revisit the earlier clients' retained sessions
  for C in 6 8 12 16; do
    if bc_state "$F" "c$C" pass; then echo "RESUME $TAG c$C (bar passed)"; continue; fi
    if bc_state "$F" "c$C" fail; then result=fail stop_at=c$C; break; fi
    ramp_point b4-sessions "$TAG" "c$C" "$C" "$cx"
    rc=$?
    if [[ $rc != 0 ]]; then result="error rc=$rc"; break; fi
    if ! bar_check "$F" "$TAG-c$C" "c$C" "$ARM"; then result=fail stop_at=c$C; break; fi
  done
  if [[ $DRY == 0 ]]; then
    printf '{"kind": "cell-done", "cell": "%s", "arm": "%s", "result": "%s", "stop_at": "%s"}\n' \
      "b4-sessions" "$ARM" "$result" "${stop_at:-none}" >> "$F"
  fi
  [[ $result == pass ]]; rc=$?
  end_cell $rc "ramp result=$result stop_at=${stop_at:-none}"
}

cell_b4_context() {
  local L C cx result=pass stop_at="" rc sub cs
  begin_cell b4-context || return 0
  # plan §6 B4 context axis: 679k at C = 2 -> 3 -> 4, then 1M at C = 1 -> 2 -> 3;
  # active contexts alone reach/exceed the ~2.2M-token pool near C=3-4 (pool cliff)
  for sub in 679k 1m; do
    L=679000; cs="2 3 4"
    if [[ $sub == 1m ]]; then L=1000000; cs="1 2 3"; fi
    cx=$(chars_for "$L" "$TPC_PROSE")
    for C in $cs; do
      if bc_state "$F" "$sub-c$C" pass; then echo "RESUME $TAG $sub-c$C (bar passed)"; continue; fi
      if bc_state "$F" "$sub-c$C" fail; then result=fail stop_at=$sub-c$C; break 2; fi
      ramp_point b4-context "$TAG-$sub" "$sub-c$C" "$C" "$cx"
      rc=$?
      if [[ $rc != 0 ]]; then result="error rc=$rc"; break 2; fi
      if ! bar_check "$F" "$TAG-$sub-c$C" "$sub-c$C" "$ARM"; then result=fail stop_at=$sub-c$C; break 2; fi
    done
  done
  if [[ $DRY == 0 ]]; then
    printf '{"kind": "cell-done", "cell": "%s", "arm": "%s", "result": "%s", "stop_at": "%s"}\n' \
      "b4-context" "$ARM" "$result" "${stop_at:-none}" >> "$F"
  fi
  [[ $result == pass ]]; rc=$?
  end_cell $rc "ramp result=$result stop_at=${stop_at:-none}"
}

cell_b5_agentic() {
  local K cx result=pass stop_at="" rc point
  begin_cell b5-agentic || return 0
  cx=$(chars_for 30000 "$TPC_CODE")
  # plan §6 B5 agentic ramp (G6): K agent loops (C=K, S=1, --turn-gap-secs 5,30 = the tool gap),
  # code corpus at 30k tok, fixed run-id per cell so later points revisit the earlier agents'
  # sessions; bar per point = revisit TTFT p95 <= BAR_TTFT s, zero NON-503 request errors (503s
  # are coordinator backpressure: hc-rotate retries them with jittered backoff, --max-503-retries
  # default 20; the bar-check record carries retries_503_sum / retries_503_p95_per_turn /
  # turn_latency_p95_s as informational fields), zero restore timeouts/failures (no decode bar).
  # K=32/48 exceed the engine's concurrency 16 on purpose: idle agents hold no request slot
  # during their gaps. The OFF arm is expected to fail its TTFT bar early — that is the result,
  # not a bug.
  for K in $B5_POINTS; do
    point=k$K
    if bc_state "$F" "$point" pass; then echo "RESUME $TAG $point (bar passed)"; continue; fi
    if bc_state "$F" "$point" fail; then result=fail stop_at=$point; break; fi
    rot --tag "$TAG-$point" --run-id "$TAG" --corpus "$CODE" --segments warmup,steady \
        --clients "$K" --sessions 1 --ctx-chars "$cx" --new-chars 5000 --decode 96 \
        --turn-gap-secs 5,30 --steady-secs "$RAMP_STEADY" --stats-every 15 --timeout 3600
    rc=$?
    if [[ $rc != 0 ]]; then result="error rc=$rc"; break; fi
    if ! bar_check_b5 "$F" "$TAG-$point" "$point" "$ARM" "$BAR_TTFT"; then result=fail stop_at=$point; break; fi
  done
  if [[ $DRY == 0 ]]; then
    printf '{"kind": "cell-done", "cell": "%s", "arm": "%s", "result": "%s", "stop_at": "%s"}\n' \
      "b5-agentic" "$ARM" "$result" "${stop_at:-none}" >> "$F"
  fi
  [[ $result == pass ]]; rc=$?
  end_cell $rc "ramp result=$result stop_at=${stop_at:-none}"
}

# --- dispatch ----------------------------------------------------------------
for cell in "${CELLS[@]}"; do
  case $cell in
    b1-nopressure)     cell_b1_nopressure ;;
    b1-ladder-prose)   cell_b1_ladder prose ;;
    b1-ladder-code)    cell_b1_ladder code ;;
    b1-decode-prose)   cell_b1_decode prose ;;
    b1-decode-code)    cell_b1_decode code ;;
    b2-r1|b2-r2|b2-r3|b2-r4|b2-r5) cell_b2 "$cell" ;;
    b3-recovery)       cell_b3 ;;
    b4-sessions)       cell_b4_sessions ;;
    b4-context)        cell_b4_context ;;
    b5-agentic)        cell_b5_agentic ;;
    *) echo "unknown cell: $cell" >&2; usage; exit 2 ;;
  esac
done
exit $EXIT
