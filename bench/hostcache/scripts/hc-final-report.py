#!/usr/bin/env python3
"""hc-final-report.py — assemble the host-cache fleet benchmark report (bench plan §8).

  python3 hc-final-report.py --draft report-draft.md --pilot pilot-report.md \
      --out report.md [--cells DIR]

Assembly: the draft's sections pass through verbatim, except —
  §3 (Pilot)   replaced by the pilot report body (hc-report.py output), minus its H1 title so the
               pilot does not carry a duplicate document heading.
  §4 (matrix)  filled in from the cell JSONLs under --cells (default
               <repo>/bench/hostcache-20260915):
               - B1 tables from hc-ladder-report.py: cold/reuse ladder (prose, code) and the
                 decode C1/C3/C6 rungs (prose, code), OFF vs ON side by side;
               - the B1 nopressure rotation and the B2 (R1–R5), B3 (recovery), B4 (sessions,
                 context) cells from hc-report.py, OFF and ON of one cell in a single call so its
                 comparison table renders;
               - §4.5 B5 (agentic ramp, G6): one table row per (K, arm) reduced with hc-report.py's
                 Run class (imported, not copied); OFF and ON rows for the same K adjacent;
               - the 1M rung table from oneM-true-*.jsonl (cold vs after-evict restore).
A cell whose ON (or OFF) JSONL is absent renders as a pending note, never an error, so the
assembler runs mid-matrix. hc-report.py's verdict-coded exit (3 = a bar failed) is not an
assembler failure; its output is embedded either way.

Every embedded table already carries the methodology restated per run: TTFT = client-observed
arrival of the first delta carrying content or reasoning_content; decode tok/s = usage
completion_tokens / (wall − TTFT); counters from /v1/stats brackets around each segment.
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

AEST = timezone(timedelta(hours=10))
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CELLS = os.path.normpath(os.path.join(HERE, "..", "bench", "hostcache-20260915"))
HC_REPORT = os.path.join(HERE, "hc-report.py")
HC_LADDER_REPORT = os.path.join(HERE, "hc-ladder-report.py")

# hc-report.py's reduction, imported (not copied): Run/pct/load reduce a tagged rotate run.
_spec = importlib.util.spec_from_file_location("hc_report", HC_REPORT)
hc_report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hc_report)

# canonical matrix cells (hc-matrix.sh header), in report order
B2_CELLS = ["b2-r1", "b2-r2", "b2-r3", "b2-r4", "b2-r5"]
B4_CELLS = ["b4-sessions", "b4-context"]
B5_CELL = "b5-agentic"


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def split_sections(md):
    """Draft -> (preamble, {section number: (heading line, body text)})."""
    parts = re.split(r"(?m)^(?=## )", md)
    preamble = parts[0]
    sections = {}
    for part in parts[1:]:
        heading, _, body = part.partition("\n")
        m = re.match(r"##\s+(\d+)", heading)
        if not m:
            preamble += part
            continue
        sections[int(m.group(1))] = (heading, body)
    return preamble, sections


def demote(md):
    """Drop embedded headings one level (## -> ###) so reducer bodies nest under the draft's
    section hierarchy instead of colliding with it."""
    return re.sub(r"(?m)^(#+)", r"#\1", md)


def strip_h1(md):
    """Drop a leading '# ...' title line (and the blank line under it) — embedded reports keep
    their own section headings but must not reintroduce the document title."""
    lines = md.splitlines()
    while lines and not lines[0].startswith("# "):
        lines.pop(0)
    if lines:
        lines.pop(0)
    while lines and not lines[0].strip():
        lines.pop(0)
    return "\n".join(lines)


def run_reducer(script, files):
    """Markdown from one of the reducer scripts; empty string when nothing usable rendered."""
    proc = subprocess.run([sys.executable, script, *files],
                          capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
    return proc.stdout.strip() if proc.stdout.strip() else ""


def cell_pair(cells, cell):
    """(off_path|None, on_path|None) for one matrix cell."""
    off = os.path.join(cells, f"{cell}-off.jsonl")
    on = os.path.join(cells, f"{cell}-on.jsonl")
    return (off if os.path.exists(off) else None,
            on if os.path.exists(on) else None)


def embed_cell(cells, cell, out):
    """hc-report.py over both arms of one cell; missing arms render as pending notes."""
    off, on = cell_pair(cells, cell)
    out.append(f"#### {cell}")
    out.append("")
    if not off and not on:
        out.append(f"_{cell}: pending — neither `{cell}-off.jsonl` nor `{cell}-on.jsonl` present "
                   f"in the cells dir (matrix not reached)._")
        out.append("")
        return
    files = [p for p in (off, on) if p]
    md = run_reducer(HC_REPORT, files)
    if md:
        out.append(demote(strip_h1(md)))
    for arm, path in (("ON", on), ("OFF", off)):
        if path is None:
            out.append(f"_{cell} {arm} arm pending — `{cell}-{arm.lower()}.jsonl` not present in "
                       f"the cells dir (matrix incomplete)._")
    out.append("")


def embed_ladder(cells, kind, out):
    """hc-ladder-report.py over the OFF+ON files of one B1 ladder/decode cell."""
    off, on = cell_pair(cells, f"b1-{kind}")
    if not off and not on:
        out.append(f"#### B1 {kind}")
        out.append("")
        out.append(f"_b1-{kind}: pending — no JSONL in the cells dir._")
        out.append("")
        return
    files = [p for p in (off, on) if p]
    md = run_reducer(HC_LADDER_REPORT, files)
    if md:
        out.append(demote(strip_h1(md)))
    for arm, path in (("ON", on), ("OFF", off)):
        if path is None:
            out.append(f"_b1-{kind} {arm} arm pending — `b1-{kind}-{arm.lower()}.jsonl` not "
                       f"present in the cells dir (matrix incomplete)._")
    out.append("")


def stat_delta(rec, field):
    b, a = rec.get("stats_before"), rec.get("stats_after")
    if isinstance(b, dict) and isinstance(a, dict) and field in b and field in a:
        return a[field] - b[field]
    return None


def b5_section(cells, out):
    """§4.5 B5 agentic ramp: one row per (K, arm), OFF and ON adjacent for the same K, reduced
    with hc-report.py's Run class (imported). Pending note when a cell file is absent."""
    out.append("### 4.5 B5 — agentic ramp (G6)")
    out.append("")
    arms = []
    for arm in ("off", "on"):
        path = os.path.join(cells, f"{B5_CELL}-{arm}.jsonl")
        if os.path.exists(path):
            arms.append((arm.upper(), path))
    if not arms:
        out.append(f"_{B5_CELL}: pending — neither `{B5_CELL}-off.jsonl` nor `{B5_CELL}-on.jsonl` "
                   f"present in the cells dir (matrix not reached)._")
        out.append("")
        return
    rows = {}  # K -> {ARM: (run, bar_rec)}
    for arm, path in arms:
        recs = hc_report.load(path)
        bars = {r.get("point"): r for r in recs if r.get("kind") == "bar-check"}
        points = []  # (K, point tag) per ramp point, header order
        for r in recs:
            if r.get("kind") != "header":
                continue
            m = re.search(r"-k(\d+)$", r.get("tag") or "")
            if m and (int(m.group(1)), r["tag"]) not in points:
                points.append((int(m.group(1)), r["tag"]))
        for K, tag in points:
            run = hc_report.Run(path, [r for r in recs if r.get("tag") == tag])
            rows.setdefault(K, {})[arm] = (run, bars.get(f"k{K}"))
    out.append("| K | arm | steady turns | turns/agent-min | TTFT p50 (s) | TTFT p95 (s) | "
               "hit frac | decode p50 (tok/s) | retries/turn p95 | turn latency p95 (s) | "
               "errors | bar |")
    out.append("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    for K in sorted(rows):
        for arm in ("OFF", "ON"):  # adjacent rows for the same K
            if arm not in rows[K]:
                continue
            run, bar = rows[K][arm]
            rs = run.reqs("steady")
            ttft = [r["ttft_s"] for r in rs if r.get("ttft_s") is not None]
            dec = [r["decode_tok_s"] for r in rs if r.get("decode_tok_s")]
            hit = sum(r.get("hit_tokens") or 0 for r in rs)
            prom = sum(r.get("prompt_tokens") or 0 for r in rs)
            retries = [r.get("retries_503") or 0 for r in rs]
            tlat = [r["turn_latency_s"] for r in rs
                    if isinstance(r.get("turn_latency_s"), (int, float))]
            # HB-7/HB-8: 503/429 = coordinator backpressure, not a request error; a terminal
            # 503/429 that carries retries_503 exhausted its retry budget and still counts.
            errs = [e for e in run.errs("steady")
                    if not (any(s in (e.get("error") or "") for s in ("503", "429"))
                            and not e.get("retries_503"))]
            seg = run.segments.get("steady") or {}
            mins = (seg.get("t1") - seg.get("t0")) / 60 \
                if isinstance(seg.get("t0"), (int, float)) and isinstance(seg.get("t1"), (int, float)) else None
            tpam = f"{len(rs) / (K * mins):.2f}" if mins and mins > 0 else "—"
            out.append(f"| {K} | {arm} | {len(rs)} | {tpam} | "
                       f"{hc_report.fmt(hc_report.pct(ttft, 50), 3)} | "
                       f"{hc_report.fmt(hc_report.pct(ttft, 95), 3)} | "
                       f"{hc_report.fmt(hit / prom, 3) if prom else '—'} | "
                       f"{hc_report.fmt(hc_report.pct(dec, 50), 1)} | "
                       f"{hc_report.fmt(hc_report.pct(retries, 95))} | "
                       f"{hc_report.fmt(hc_report.pct(tlat, 95), 3)} | "
                       f"{len(errs)} | "
                       f"{(bar or {}).get('result', '—')} |")
    out.append("")
    out.append("K concurrent agent loops (S=1, code corpus at 30k tok); between turns each agent "
               "idles a seeded uniform 5–30 s tool gap (`--turn-gap-secs 5,30`), so agents in "
               "their gap hold no request slot and K exceeds the engine's concurrency. One agent "
               "loop = one client revisiting its single growing session. steady turns = steady-segment "
               "request records; turns/agent-min = steady turns ÷ (K × steady wall minutes from the "
               "segment bracket); hit frac = Σ prompt_cache_hit_tokens / Σ prompt_tokens; decode "
               "p50 = usage completion_tokens / (wall − TTFT); TTFT = client-observed first delta of "
               "the final attempt. retries/turn p95 = p95 of per-visit backpressure retry counts (503s "
               "and 429s together) and turn "
               "latency p95 = p95 of turn_latency_s (wall from the first attempt's send to the last "
               "delta, including backoff sleeps — what the agent experiences; recorded only on "
               "visits that retried backpressure); both are informational, the bar stays on ttft_s. "
               "errors = non-backpressure terminal errors: HTTP 503 or 429 (with Retry-After "
               "honoured) is the coordinator's concurrency backpressure — an rc4 over-capacity burst "
               "gets an immediate 503, the rc6 front door queues up to 30 s then refuses 429 with "
               "Retry-After — which hc-rotate absorbs with seeded jittered-backoff retries "
               "(0.5 s × 2^attempt ± 25 %, capped 8 s, `--max-503-retries` default 20; a 429's "
               "Retry-After sets the minimum sleep, one ask capped at 60 s) and records as "
               "retries_503 (503s and 429s share the budget) plus retries_429/retry_after_s_sum "
               "per visit; only a 503 or 429 that exhausted its retry budget still lands in the "
               "errors column. "
               "Bar (recorded per point on the cell's bar-check record): revisit TTFT p95 ≤ 10 s, "
               "zero non-backpressure request errors, zero restore timeouts/failures — no decode "
               "bar (agents are latency-bound). A missing arm renders as a pending note, never an "
               "error.")
    out.append("")
    for arm in ("ON", "OFF"):
        if arm not in {a for a, _ in arms}:
            out.append(f"_{B5_CELL} {arm} arm pending — `{B5_CELL}-{arm.lower()}.jsonl` not "
                       f"present in the cells dir (matrix incomplete)._")
            out.append("")


def one_m_table(cells, out):
    """The 1M context rung: cold prefill vs after-evict restore from oneM-true-*.jsonl."""
    out.append("### 4.6 1M context rung")
    out.append("")
    paths = sorted(glob.glob(os.path.join(cells, "oneM-true-*.jsonl")))
    if not paths:
        out.append("_1M rung pending — no `oneM-true-*.jsonl` in the cells dir._")
        out.append("")
        return
    for path in paths:
        recs = []
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("{"):
                    recs.append(json.loads(line))
        out.append(f"`{os.path.basename(path)}`")
        out.append("")
        out.append("| rung | chars | prompt tok | miss tok | hit tok | TTFT (s) | prefill tok/s "
                   "| Δrestores | restore mean (ms) | restored (MB) |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for r in recs:
            if r.get("mode") not in ("cold", "after-evict"):
                continue
            ttft = r.get("ttft_s")
            prefill = None
            if isinstance(r.get("miss_tokens"), (int, float)) and isinstance(ttft, (int, float)) \
                    and ttft > 0:
                prefill = r["miss_tokens"] / ttft
            dr = stat_delta(r, "restores")
            dlat = stat_delta(r, "restore_latency_sum_ns")
            mean = dlat / dr / 1e6 if isinstance(dlat, (int, float)) \
                and isinstance(dr, (int, float)) and dr > 0 else None
            dbytes = stat_delta(r, "restore_bytes")
            mb = dbytes / 1e6 if isinstance(dbytes, (int, float)) else None
            out.append(f"| {r['mode']} | {r.get('size')} | {r.get('prompt_tokens')} | "
                       f"{r.get('miss_tokens')} | {r.get('hit_tokens')} | {ttft} | "
                       f"{f'{prefill:.0f}' if prefill else '—'} | {dr if dr is not None else '—'} | "
                       f"{f'{mean:.2f}' if mean else '—'} | {f'{mb:.1f}' if mb else '—'} |")
        out.append("")
        out.append("cold = salted 1M-token prompt after the device banks were filled (full "
                   "re-prefill); after-evict = the same prompt again once the fillers evicted its "
                   "snapshot (host restore). TTFT client-observed; prefill tok/s = miss/TTFT; "
                   "restore counters = stats_after − stats_before on the record.")
        out.append("")


def build_matrix(cells, out):
    out.append("## 4. Full matrix — baseline (cache OFF) vs release candidate (cache ON)")
    out.append("")
    out.append("Every table: thinking off (`reasoning_effort: none`), temperature 0, coordinator "
               "direct; TTFT = client-observed first delta; decode = usage completion_tokens / "
               "(wall − TTFT). B1 cells ran fresh-launch per arm (plan §6, n=3 A/B/A alternating; "
               "the 1% no-overhead bar compares OFF vs ON on the same rung). A missing OFF/ON file "
               "renders as pending, never as an error, so this section assembles mid-matrix.")
    out.append("")
    out.append("### 4.1 B1 — no overhead, no pressure (G1)")
    out.append("")
    out.append("Cold ladder (prose):")
    out.append("")
    embed_ladder(cells, "ladder-prose", out)
    out.append("Cold ladder (code):")
    out.append("")
    embed_ladder(cells, "ladder-code", out)
    out.append("Decode rungs (prose):")
    out.append("")
    embed_ladder(cells, "decode-prose", out)
    out.append("Decode rungs (code):")
    out.append("")
    embed_ladder(cells, "decode-code", out)
    out.append("Nopressure rotation (C3 × S2, immediately post-launch; zero-eviction claim):")
    out.append("")
    embed_cell(cells, "b1-nopressure", out)
    out.append("### 4.2 B2 — steady-state rotation (G2 + G3)")
    out.append("")
    for cell in B2_CELLS:
        embed_cell(cells, cell, out)
    out.append("### 4.3 B3 — recovery (G4)")
    out.append("")
    embed_cell(cells, "b3-recovery", out)
    out.append("### 4.4 B4 — practical ceiling (G5)")
    out.append("")
    for cell in B4_CELLS:
        embed_cell(cells, cell, out)
    b5_section(cells, out)
    one_m_table(cells, out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--draft", required=True)
    ap.add_argument("--pilot", required=True)
    ap.add_argument("--out")
    ap.add_argument("--cells", default=DEFAULT_CELLS,
                    help="cell JSONL dir (default <repo>/bench/hostcache-20260915)")
    args = ap.parse_args()

    try:
        draft = read(args.draft)
        pilot = read(args.pilot)
    except OSError as e:
        print(f"read error: {e}", file=sys.stderr)
        return 1
    preamble, sections = split_sections(draft)
    if not sections:
        print(f"no '## N' sections found in {args.draft}", file=sys.stderr)
        return 1

    out = [preamble.rstrip(), ""]
    nums = sorted(sections)
    for n in nums:
        heading, body = sections[n]
        if n == 3:
            out.append(heading.rstrip())
            out.append("")
            out.append(demote(strip_h1(pilot)))
        elif n == 4:
            build_matrix(args.cells, out)
        else:
            out.append(heading.rstrip())
            out.append("")
            out.append(body.strip())
        out.append("")

    text = "\n".join(out).rstrip() + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"report -> {args.out}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
