#!/usr/bin/env python3
"""hc-report.py — reduce hc-rotate.py JSONL runs to the standard markdown report.

Bench plan §8: every table carries concurrency, prefill, decode and prose/code axes; counter
deltas per segment; purity and invariant checks; pass/fail vs Hugh's bar (decode >= 20 tok/s per
client, p95 revisit TTFT <= 10 s, zero restore timeouts/failures — bench plan §1.2). Tolerates
pre-HC-7 runs (device_evictions / store_latency_* reported ABSENT) and cache-off runs
(host_cache null -> counters ABSENT, request tables still produced). Each run header restates
the thinking mode and the TTFT/decode definitions from the JSONL header.

  python3 hc-report.py pilot-off.jsonl pilot-on.jsonl --out pilot-report.md
"""
import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

AEST = timezone(timedelta(hours=10))
BUCKET_LABELS = ["<=1ms", "<=5ms", "<=10ms", "<=50ms", "<=100ms", "<=500ms", "<=1s", ">1s"]
COUNTER_FIELDS = [
    "stores_issued", "stores_completed", "stores_replaced", "stores_failed", "store_drain_timeouts",
    "stores_skipped", "store_bytes", "pages_copied", "pages_shared", "lookups", "host_hits",
    "restores", "restore_bytes", "restore_timeouts", "restore_failures", "restore_latency_sum_ns",
    "evict_waits", "evict_wait_ns", "evict_drops_uncached", "host_evictions", "host_evicted_bytes",
    "resident_snapshots", "bytes_used", "quota_bytes",
    "device_evictions", "store_latency_sum_ns",  # HC-7 additions; ABSENT before it lands
]


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1)))))
    return xs[k]


def fmt(x, nd=2):
    if x is None:
        return "—"
    if isinstance(x, float):
        return f"{x:.{nd}f}"
    return str(x)


def load(path):
    recs = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                recs.append(json.loads(line))
    return recs


class Run:
    def __init__(self, path, recs):
        self.path = path
        self.recs = recs
        self.header = next((r for r in recs if r["kind"] == "header"), {})
        self.footer = next((r for r in recs if r["kind"] == "footer"), {})
        self.tag = self.header.get("tag") or path
        self.cfg = self.header.get("config") or {}
        self.segments = {}
        for r in recs:
            if r["kind"] == "segment":
                self.segments[r["segment"]] = r
        # The arm: the first quota the run observed. The header's stats_start is null for the
        # first second after a boot (the daemon publishes stats once a second), so also look at
        # every segment bracket, stats sample and the footer before concluding "cache off".
        self.quota = self._first_quota(recs)
        self.cache_on = self.quota > 0

    @staticmethod
    def _first_quota(recs):
        def q(d):
            return (d or {}).get("quota_bytes") or 0 if isinstance(d, dict) else 0
        for r in recs:
            k = r.get("kind")
            if k == "header":
                v = q(r.get("stats_start"))
            elif k == "segment":
                v = q(r.get("stats_before")) or q(r.get("stats_after"))
            elif k == "stats":
                v = q(r.get("host_cache"))
            elif k == "footer":
                v = q(r.get("stats_end"))
            else:
                v = 0
            if v:
                return v
        return 0

    def reqs(self, segment):
        return [r for r in self.recs if r["kind"] == "req" and r.get("segment") == segment]

    def errs(self, segment=None):
        return [r for r in self.recs if r["kind"] == "error"
                and (segment is None or r.get("segment") == segment)]

    def stats_samples(self, segment=None):
        return [r for r in self.recs if r["kind"] == "stats"
                and (segment is None or r.get("segment") == segment)]

    def delta(self, segment, field):
        seg = self.segments.get(segment)
        if not seg:
            return None
        b, a = seg.get("stats_before"), seg.get("stats_after")
        if not isinstance(b, dict) or not isinstance(a, dict):
            return None
        if field not in b or field not in a:
            return "ABSENT"
        return a[field] - b[field]

    def gauge(self, segment, field, which="after"):
        seg = self.segments.get(segment)
        if not seg:
            return None
        st = seg.get("stats_after" if which == "after" else "stats_before")
        return (st or {}).get(field) if isinstance(st, dict) else None


def req_table(run, segments, out):
    out.append("| segment | n | err | TTFT p50 | p95 | p99 (s) | decode p50 (tok/s) | "
               "prompt p50 (tok) | hit frac | miss frac | cold tok/s (est†) |")
    out.append("|---|---:|---:|---|---|---|---|---|---|---|---|")
    for s in segments:
        rs = run.reqs(s)
        if not rs and not run.errs(s):
            continue
        ttft = [r["ttft_s"] for r in rs if r.get("ttft_s") is not None]
        dec = [r["decode_tok_s"] for r in rs if r.get("decode_tok_s")]
        prom = [r["prompt_tokens"] for r in rs if r.get("prompt_tokens")]
        hit = sum(r.get("hit_tokens") or 0 for r in rs)
        miss = sum(r.get("miss_tokens") or 0 for r in rs)
        tot = sum(prom) or None
        cold = None
        cm = [(r.get("miss_tokens") or 0, r.get("ttft_s") or 0) for r in rs if (r.get("miss_tokens") or 0) > 0]
        if cm and sum(t for _, t in cm) > 0:
            cold = sum(m for m, _ in cm) / sum(t for _, t in cm)
        out.append(f"| {s} | {len(rs)} | {len(run.errs(s))} | {fmt(pct(ttft,50),3)} | {fmt(pct(ttft,95),3)} | "
                   f"{fmt(pct(ttft,99),3)} | {fmt(pct(dec,50),1)} | {fmt(pct(prom,50),0)} | "
                   f"{fmt(hit/tot,3) if tot else '—'} | {fmt(miss/tot,4) if tot else '—'} | {fmt(cold,0)} |")
    out.append("")
    out.append("† estimate: Σ miss_tokens / Σ TTFT over requests with misses; TTFT is client-observed "
               "and includes prefill-lane queueing (bench plan §9). Decode numerator = usage "
               "completion_tokens, never SSE deltas.")
    out.append("")


def counter_deltas(run, segment, out):
    seg = run.segments.get(segment)
    if not seg:
        return
    b, a = seg.get("stats_before"), seg.get("stats_after")
    if not isinstance(b, dict) or not isinstance(a, dict):
        out.append(f"_{segment}: host_cache counters ABSENT (cache off or pre-binding stats)_")
        out.append("")
        return
    rows = []
    for f in COUNTER_FIELDS:
        if f.endswith("_ns") or f in ("bytes_used", "quota_bytes", "resident_snapshots", "store_bytes",
                                      "restore_bytes", "host_evicted_bytes"):
            continue
        if f in b and f in a and a[f] - b[f] != 0:
            rows.append((f, b[f], a[f], a[f] - b[f]))
    out.append(f"**{segment} counter deltas** (non-zero; gauges as before→after):")
    out.append("")
    out.append("| counter | before | after | Δ |")
    out.append("|---|---:|---:|---:|")
    for f, x, y, d in rows:
        out.append(f"| {f} | {x} | {y} | {d:+d} |")
    for g in ("bytes_used", "resident_snapshots", "quota_bytes"):
        if g in b and g in a:
            out.append(f"| {g} (gauge) | {b[g]} | {a[g]} | — |")
    out.append("")
    # derived per-op numbers
    der = []
    rl, rs = run.delta(segment, "restore_latency_sum_ns"), run.delta(segment, "restores")
    if isinstance(rl, int) and isinstance(rs, int) and rs > 0:
        der.append(f"restore mean {rl/rs/1e6:.1f} ms over {rs} restores")
    rb = None
    if isinstance(seg.get("stats_before"), dict) and "restore_latency_buckets" in b:
        rb = [y - x for x, y in zip(b["restore_latency_buckets"], a["restore_latency_buckets"])]
        if any(rb):
            der.append("restore buckets Δ " + ", ".join(f"{lab}:{n}" for lab, n in zip(BUCKET_LABELS, rb) if n))
    ew, ewn = run.delta(segment, "evict_waits"), run.delta(segment, "evict_wait_ns")
    if isinstance(ew, int) and isinstance(ewn, int) and ew > 0:
        der.append(f"evict wait mean {ewn/ew/1e6:.2f} ms over {ew} waits")
    sl, sc = run.delta(segment, "store_latency_sum_ns"), run.delta(segment, "stores_completed")
    if sl == "ABSENT":
        der.append("store latency ABSENT (pre-HC-7)")
    elif isinstance(sl, int) and isinstance(sc, int) and sc > 0:
        der.append(f"store copy mean {sl/sc/1e6:.2f} ms over {sc} completed stores")
    de = run.delta(segment, "device_evictions")
    if de == "ABSENT":
        der.append("device_evictions ABSENT (pre-HC-7)")
    lk, hh = run.delta(segment, "lookups"), run.delta(segment, "host_hits")
    if isinstance(lk, int) and isinstance(hh, int) and lk > 0:
        der.append(f"host_hit_rate {hh/lk:.3f}; cold misses {lk-hh}")
    n = len(run.reqs(segment))
    if isinstance(lk, int) and n:
        der.append(f"device hits ≈ {n-lk} of {n} requests (lookups fire only on device miss)")
    if der:
        out.append("; ".join(der) + ".")
        out.append("")


def checks(run, args, out):
    out.append("**Checks**")
    out.append("")
    ok_all = True

    def line(name, ok, detail):
        nonlocal ok_all
        mark = {True: "PASS", False: "FAIL", None: "INFO"}[ok]
        if ok is False:
            ok_all = False
        out.append(f"- {mark} — {name}: {detail}")

    # nopressure zero-eviction (G1)
    if "nopressure" in run.segments:
        bad = []
        for f in ("device_evictions", "evict_waits", "evict_drops_uncached", "host_evictions"):
            d = run.delta("nopressure", f)
            if isinstance(d, int) and d != 0:
                bad.append(f"{f}=+{d}")
            elif d == "ABSENT" and f == "device_evictions":
                bad.append("device_evictions ABSENT (pre-HC-7; weaker claim)")
        line("nopressure zero-eviction", not [b for b in bad if "ABSENT" not in b] or None,
             "; ".join(bad) if bad else "all eviction counters Δ=0")
    # steady bars + purity (G2/G3)
    if "steady" in run.segments:
        rs = run.reqs("steady")
        dec = [r["decode_tok_s"] for r in rs if r.get("decode_tok_s")]
        ttft = [r["ttft_s"] for r in rs if r.get("ttft_s") is not None]
        if run.cache_on:
            d50, p95 = pct(dec, 50), pct(ttft, 95)
            to, fl = run.delta("steady", "restore_timeouts"), run.delta("steady", "restore_failures")
            ok = (d50 is not None and d50 >= args.min_decode and p95 is not None and p95 <= args.max_ttft_p95
                  and to == 0 and fl == 0)
            line(f"steady bar (decode>={args.min_decode}, p95TTFT<={args.max_ttft_p95}, 0 timeouts/failures)",
                 ok, f"decode p50 {fmt(d50,1)}, TTFT p95 {fmt(p95,2)} s, timeouts {to}, failures {fl}")
            lk, hh = run.delta("steady", "lookups"), run.delta("steady", "host_hits")
            if isinstance(lk, int) and lk > 0:
                line("steady purity host_hit_rate>=0.95", hh / lk >= 0.95, f"{hh}/{lk} = {hh/lk:.3f}")
            miss = sum(r.get("miss_tokens") or 0 for r in rs)
            prom = sum(r.get("prompt_tokens") or 0 for r in rs)
            if prom:
                line("steady cold fraction <1%", miss / prom < 0.01, f"miss/prompt = {miss/prom:.4f}")
            bu, q = run.gauge("steady", "bytes_used"), run.gauge("steady", "quota_bytes")
            if isinstance(bu, int) and isinstance(q, int) and q:
                line("bytes_used <= quota", bu <= q, f"{bu} / {q}")
        else:
            hit = sum(r.get("hit_tokens") or 0 for r in rs)
            prom = sum(r.get("prompt_tokens") or 0 for r in rs)
            line("steady baseline (cache OFF) near-zero hits", None,
                 f"hit/prompt = {hit/prom:.4f}" if prom else "no requests")
    # recovery (G4)
    if "recovery1" in run.segments and run.cache_on:
        rs = run.reqs("recovery1")
        lk, hh = run.delta("recovery1", "lookups"), run.delta("recovery1", "host_hits")
        if isinstance(lk, int) and lk > 0:
            line("recovery1 all host hits", hh == lk, f"{hh}/{lk}")
        mx = max((r["ttft_s"] for r in rs if r.get("ttft_s") is not None), default=None)
        line(f"recovery1 TTFT max <= {args.max_recovery_ttft} s", (mx is not None and mx <= args.max_recovery_ttft),
             f"max {fmt(mx,3)} s over {len(rs)} sessions")
    if "recovery2" in run.segments and run.cache_on:
        lk = run.delta("recovery2", "lookups")
        line("recovery2 device hits (Δlookups==0)", lk == 0 if isinstance(lk, int) else None,
             f"Δlookups {lk}")
    # observe flatness
    obs = run.stats_samples("observe")
    if obs:
        for g in ("bytes_used", "resident_snapshots"):
            vals = [s["host_cache"].get(g) for s in obs if isinstance(s.get("host_cache"), dict)]
            vals = [v for v in vals if isinstance(v, int)]
            if vals:
                line(f"observe {g} flat", max(vals) - min(vals) <= args.observe_tolerance,
                     f"max−min = {max(vals)-min(vals)} over {len(vals)} samples")
    # errors anywhere
    errs = run.errs()
    line("zero request errors", not errs, f"{len(errs)} error records" + (f" (first: {errs[0].get('error')})" if errs else ""))
    out.append("")
    return ok_all


def compare(runs, args, out):
    if len(runs) < 2:
        return
    out.append("## Comparison (steady segment)")
    out.append("")
    out.append("| tag | cache | n | TTFT p50 | TTFT p95 (s) | decode p50 (tok/s) | probe decode p50 | "
               "host_hit_rate | restore mean (ms) | Δdevice_evictions | verdict |")
    out.append("|---|---|---:|---|---|---|---|---|---|---|---|")
    for run in runs:
        rs = run.reqs("steady")
        pr = run.reqs("probe")
        ttft = [r["ttft_s"] for r in rs if r.get("ttft_s") is not None]
        dec = [r["decode_tok_s"] for r in rs if r.get("decode_tok_s")]
        pdec = [r["decode_tok_s"] for r in pr if r.get("decode_tok_s")]
        lk, hh = run.delta("steady", "lookups"), run.delta("steady", "host_hits")
        hhr = f"{hh/lk:.3f}" if isinstance(lk, int) and lk > 0 and isinstance(hh, int) else "—"
        rl, rc = run.delta("steady", "restore_latency_sum_ns"), run.delta("steady", "restores")
        rm = f"{rl/rc/1e6:.1f}" if isinstance(rl, int) and isinstance(rc, int) and rc > 0 else "—"
        de = run.delta("steady", "device_evictions")
        de = str(de) if isinstance(de, int) else "ABSENT"
        verdict = "—"
        if run.cache_on:
            d50, p95 = pct(dec, 50), pct(ttft, 95)
            to, fl = run.delta("steady", "restore_timeouts"), run.delta("steady", "restore_failures")
            verdict = ("PASS" if (d50 or 0) >= args.min_decode and (p95 or 1e9) <= args.max_ttft_p95
                       and to == 0 and fl == 0 else "FAIL")
        out.append(f"| {run.tag} | {'on' if run.cache_on else 'off'} | {len(rs)} | {fmt(pct(ttft,50),3)} | "
                   f"{fmt(pct(ttft,95),3)} | {fmt(pct(dec,50),1)} | {fmt(pct(pdec,50),1)} | {hhr} | {rm} | "
                   f"{de} | {verdict} |")
    out.append("")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out")
    ap.add_argument("--min-decode", type=float, default=20.0)
    ap.add_argument("--max-ttft-p95", type=float, default=10.0)
    ap.add_argument("--max-recovery-ttft", type=float, default=1.0)
    ap.add_argument("--observe-tolerance", type=int, default=0)
    args = ap.parse_args()

    out = [f"# Host-cache bench report — {datetime.now(AEST).strftime('%Y-%m-%d %H:%M AEST')}", ""]
    runs = []
    for p in args.runs:
        try:
            runs.append(Run(p, load(p)))
        except (OSError, json.JSONDecodeError, StopIteration) as e:
            print(f"skip {p}: {e}", file=sys.stderr)
    if not runs:
        print("no usable runs", file=sys.stderr)
        return 1

    all_ok = True
    for run in runs:
        h = run.header
        cfg = run.cfg
        out.append(f"## Run {run.tag} — `{run.path}`")
        out.append("")
        out.append(f"- run_id {h.get('run_id','?')}, base {h.get('base','?')}, "
                   f"corpus {((h.get('corpus') or {}).get('path','?'))} sha {((h.get('corpus') or {}).get('sha256_16','?'))}")
        out.append(f"- shape: C{cfg.get('clients')} × S{cfg.get('sessions')} × {cfg.get('ctx_chars')} chars "
                   f"(+{cfg.get('new_chars')}/visit), decode {cfg.get('decode')}, steady {cfg.get('steady_secs')} s, "
                   f"segments {h.get('segments')}")
        out.append(f"- cache: {'ON, quota ' + str(run.quota) if run.cache_on else 'OFF (quota 0/absent)'}")
        think = cfg.get("thinking")
        think_s = {True: "ON (model default; no reasoning_effort sent)",
                   False: "OFF (reasoning_effort=none on every request)"}.get(
                       think, f"unknown (header predates the --thinking flag; argv: {h.get('argv', '?')})")
        out.append(f"- thinking: {think_s}")
        out.append("- TTFT: client-observed arrival of the first delta carrying content or "
                   "reasoning_content; decode tok/s = usage.completion_tokens / (wall − TTFT).")
        if h.get("session_offset"):
            out.append(f"- session corpus offset: {h['session_offset']}")
        if h.get("stats_error"):
            out.append(f"- stats note: {h['stats_error']}")
        out.append("")
        segs = list(run.segments.keys())
        order = ["nopressure", "warmup", "steady", "probe", "recovery1", "recovery2"]
        segs = [s for s in order if s in segs] + [s for s in segs if s not in order]
        req_table(run, [s for s in segs if s != "probe"] + (["probe"] if "probe" in segs else []), out)
        for s in segs:
            counter_deltas(run, s, out)
        all_ok &= checks(run, args, out)
    compare(runs, args, out)
    text = "\n".join(out)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"report -> {args.out}")
    else:
        print(text)
    return 0 if all_ok else 3


if __name__ == "__main__":
    sys.exit(main())
