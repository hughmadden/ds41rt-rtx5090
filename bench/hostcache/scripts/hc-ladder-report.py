#!/usr/bin/env python3
"""hc-ladder-report.py — reduce hc-ladder.py JSONL cells to markdown tables (bench plan §8).

Groups ladder records by corpus (prose/code/synthetic, from the run tag and the presence of
`corpus_sha256_16`) and by arm (tag suffix -off/-on), then renders, per corpus:

  cold rungs        one row per prompt size: measured prompt tokens (canonical; sizes are chars,
                    plan §2 tok/char caveat), TTFT s, prefill tok/s = miss_tokens/TTFT, hit tokens.
                    OFF and ON of the same rung sit side by side with the ON/OFF ratio when both
                    exist (B1's no-overhead claim is TTFT and prefill both within 1% -> ratio ≈ 1.00).
  reuse/after-evict one row per measurement: TTFT, hit fraction (hit_tokens/prompt_tokens), and the
                    restore counter deltas (Δrestores, Δrestore_bytes, restore mean ms) from
                    stats_before/stats_after when the host cache exported counters.
  decode            one row per concurrency: per-stream mean decode tok/s (Σ out tokens / Σ(wall −
                    TTFT)) and the group's aggregate throughput. Aggregate is the record's
                    `decode_aggregate_tok_s` when present; else recomputed from the per-request
                    lines as Σ out_tokens / (max end − min start), where end = the record's `ts`
                    (parsed as AEST when it carries no offset) and start = end − wall_s; when the
                    pre-fix lines carry no `ts` at all, the aggregate line's own `elapsed_s` is the
                    group's wall span (identical definition: the harness measured it with the same
                    monotonic clock that bounded the requests).
  errors            one row per record carrying an `error` field (mode, size, error head), plus a
                    missing-rungs note for rung sizes an arm did not record (a crashed run from
                    before the error-record fix simply stops emitting lines, so absence is the
                    failure shape; mid-matrix ON cells are pending, not errors).

TTFT is the client-observed arrival of the first delta carrying content or reasoning_content;
decode tok/s uses usage completion_tokens, never SSE delta counting (v41bench methodology).

  python3 hc-ladder-report.py b1-ladder-prose-off.jsonl b1-ladder-prose-on.jsonl --out b1-prose.md
"""
import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone

AEST = timezone(timedelta(hours=10))


def fmt(x, nd=2):
    if x is None:
        return "—"
    if isinstance(x, float):
        return f"{x:.{nd}f}"
    return str(x)


def ratio(a, b):
    """a/b when both numbers exist and b != 0, else None."""
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and b:
        return a / b
    return None


def load(path):
    """JSON ladder lines; 'LADDER-DONE' tails and blank lines are dropped."""
    recs = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            recs.append(json.loads(line))
    return recs


def classify(rec):
    """(corpus, arm) for one ladder record.

    corpus: 'prose'/'code' from the tag, else 'sha-<12>' when a corpus sha is recorded but the tag
    carries no corpus name, else 'synthetic' (no corpus -> greek-word list). arm: 'off'/'on' from
    the tag suffix after stripping -cN concurrency and -reuse decorations; None when untagged.
    """
    tag = rec.get("tag") or ""
    base = re.sub(r"-c\d+$", "", tag)
    base = re.sub(r"-reuse$", "", base)
    arm = None
    for suf in ("-off", "-on"):
        if base.endswith(suf):
            arm = suf[1:]
            base = base[: -len(suf)]
            break
    if "prose" in base:
        corpus = "prose"
    elif "code" in base:
        corpus = "code"
    elif rec.get("corpus_sha256_16"):
        corpus = "sha-" + rec["corpus_sha256_16"][:12]
    else:
        corpus = "synthetic"
    return corpus, arm


def stat_delta(rec, field):
    """stats_after − stats_before for one counter, or None when either side is absent."""
    b, a = rec.get("stats_before"), rec.get("stats_after")
    if not isinstance(b, dict) or not isinstance(a, dict):
        return None
    if field not in b or field not in a:
        return None
    return a[field] - b[field]


def parse_ts(ts):
    """A ladder record ts; naive values are read as AEST (hc-ladder runs are Sydney-local)."""
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=AEST)
    return dt


class Group:
    """All records of one (corpus, arm)."""

    def __init__(self):
        self.recs = []

    def by_mode(self, mode):
        return [r for r in self.recs if r.get("mode") == mode]

    def aggregates(self):
        return [r for r in self.recs if r.get("mode") == "aggregate"]


def cold_row(group, size):
    """One cold rung: (prompt_tokens, ttft_s, prefill_tok_s, hit_tokens).

    C1 rungs have a single line; concurrent cold groups reduce through their aggregate line
    (prefill_tok_s = Σ miss / group wall, TTFT p50) when it exists, else line means.
    """
    lines = [r for r in group.by_mode("cold") if r.get("size") == size]
    agg = next((a for a in group.aggregates() if a.get("size") == size), None)
    if agg and agg.get("prefill_tok_s"):
        ttfts = sorted(r["ttft_s"] for r in lines
                       if r.get("ttft_s") is not None)
        mid = ttfts[len(ttfts) // 2] if ttfts else None
        prompt = sum(r.get("prompt_tokens") or 0 for r in lines) or None
        return prompt, mid, agg["prefill_tok_s"], None
    if not lines:
        return None, None, None, None
    r0 = lines[0]
    ttfts = sorted(x["ttft_s"] for x in lines if x.get("ttft_s") is not None)
    ttft = ttfts[len(ttfts) // 2] if ttfts else None
    prompt = r0.get("prompt_tokens")
    prefill = None
    if isinstance(r0.get("miss_tokens"), (int, float)) and isinstance(ttft, (int, float)) and ttft > 0:
        prefill = r0["miss_tokens"] / ttft
    return prompt, ttft, prefill, r0.get("hit_tokens")


def hit_row(rec):
    """(prompt_tokens, ttft_s, hit_fraction) for a reuse/after-evict line."""
    prompt = rec.get("prompt_tokens")
    hit = rec.get("hit_tokens")
    frac = (hit / prompt) if isinstance(hit, (int, float)) and isinstance(prompt, (int, float)) \
        and prompt else None
    return prompt, rec.get("ttft_s"), frac


def decode_row(group, conc):
    """(per-stream mean tok/s, aggregate tok/s, n, errors) for one concurrency group.

    per-stream mean: the aggregate line's decode_tok_s (Σ out / Σ(wall − TTFT)) when present,
    else recomputed from the per-request lines. Aggregate: decode_aggregate_tok_s when present,
    else Σ out / group wall span from the per-request ts/wall_s, else Σ out / the aggregate
    line's elapsed_s (pre-ts, pre-aggregate field shape).
    """
    lines = [r for r in group.by_mode("decode") if (r.get("concurrency") or 1) == conc]
    agg = next((a for a in group.aggregates()
                if (a.get("concurrency") or 1) == conc), None)
    ok = [r for r in lines if "error" not in r]
    errs = len(lines) - len(ok)
    per_stream = agg.get("decode_tok_s") if agg else None
    if per_stream is None:
        gen = sum(r["wall_s"] - (r["ttft_s"] or 0) for r in ok
                  if isinstance(r.get("wall_s"), (int, float)) and r.get("ttft_s") is not None)
        tok = sum(r.get("out_tokens") or 0 for r in ok)
        per_stream = tok / gen if gen > 0 else None
    aggregate = agg.get("decode_aggregate_tok_s") if agg else None
    if aggregate is None:
        tok = sum(r.get("out_tokens") or 0 for r in ok)
        span = None
        ends = []
        for r in ok:
            if r.get("ts") and isinstance(r.get("wall_s"), (int, float)):
                ends.append((parse_ts(r["ts"]), r["wall_s"]))
        if len(ends) >= 2:
            span = (max(e for e, _ in ends) - min(e - timedelta(seconds=w) for e, w in ends)) \
                .total_seconds()
        elif agg and isinstance(agg.get("elapsed_s"), (int, float)) and agg["elapsed_s"] > 0:
            span = agg["elapsed_s"]
        aggregate = tok / span if span and span > 0 else None
    n = (agg or {}).get("n", len(ok))
    return per_stream, aggregate, n, errs


def render_corpus(name, arms, out):
    """All tables for one corpus; arms is {arm: Group} with arm None meaning single-arm."""
    out.append(f"## Corpus: {name}")
    out.append("")
    arm_names = list(arms.keys())
    side_by_side = len(arm_names) > 1

    def cell(arm, val, nd=2):
        return fmt(val, nd) if arm in arms else "—"

    # --- cold rungs ----------------------------------------------------------
    cold_sizes = sorted({r["size"] for g in arms.values() for r in g.by_mode("cold")},
                        key=lambda s: s or 0)
    if cold_sizes:
        out.append("### Cold rungs (C1)")
        out.append("")
        out.append("| rung (chars) | prompt tok | TTFT off (s) | TTFT on (s) | TTFT on/off | "
                   "prefill tok/s off | prefill tok/s on | prefill on/off | hit tok off | hit tok on |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for size in cold_sizes:
            row = {a: cold_row(g, size) for a, g in arms.items()}
            p_off = row.get("off") or row.get(None) or (None,) * 4
            p_on = row.get("on") or (None,) * 4
            out.append(f"| {size} | {fmt(p_off[0] or p_on[0], 0)} | {fmt(p_off[1], 3)} | "
                       f"{fmt(p_on[1], 3)} | {fmt(ratio(p_on[1], p_off[1]), 4)} | "
                       f"{fmt(p_off[2], 0)} | {fmt(p_on[2], 0)} | {fmt(ratio(p_on[2], p_off[2]), 4)} | "
                       f"{fmt(p_off[3], 0)} | {fmt(p_on[3], 0)} |")
        out.append("")
        out.append("prompt tok = measured usage tokens for the char-sized rung (canonical; plan §2 "
                   "tok/char caveat). prefill tok/s = miss_tokens/TTFT for C1 (client-observed TTFT "
                   "includes prefill-lane queueing); a concurrent cold group uses its aggregate "
                   "prefill_tok_s (Σ miss / group wall). hit tok = usage prompt_cache_hit_tokens.")
        out.append("")

    # --- reuse / after-evict -------------------------------------------------
    reuse_recs = []
    for a, g in arms.items():
        for r in g.by_mode("reuse") + g.by_mode("after-evict"):
            reuse_recs.append((a, r))
    if reuse_recs:
        out.append("### Reuse / after-evict")
        out.append("")
        out.append("| mode | size (chars) | prompt tok | TTFT off (s) | TTFT on (s) | on/off | "
                   "hit frac off | hit frac on | Δrestores | restore mean (ms) | Δrestore_bytes |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        seen = set()
        for a, r in sorted(reuse_recs, key=lambda t: (t[1].get("mode") != "reuse",
                                                      t[1].get("size") or 0)):
            key = (r.get("mode"), r.get("size"))
            if key in seen:
                continue
            seen.add(key)
            off = hit_row(r) if a != "on" else (None,) * 3
            on = hit_row(r) if a == "on" else (None,) * 3
            # counters come from whichever arm recorded the line (host cache is ON-only anyway)
            dr = stat_delta(r, "restores")
            dbytes = stat_delta(r, "restore_bytes")
            dlat = stat_delta(r, "restore_latency_sum_ns")
            mean = dlat / dr / 1e6 if isinstance(dlat, (int, float)) and isinstance(dr, (int, float)) \
                and dr > 0 else None
            out.append(f"| {r['mode']} | {r.get('size')} | {fmt(off[0] or on[0], 0)} | "
                       f"{fmt(off[1], 3)} | {fmt(on[1], 3)} | {fmt(ratio(on[1], off[1]), 3)} | "
                       f"{fmt(off[2], 3)} | {fmt(on[2], 3)} | "
                       f"{dr if dr is not None else '—'} | {fmt(mean, 2)} | "
                       f"{dbytes if dbytes is not None else '—'} |")
        out.append("")
        out.append("hit frac = usage prompt_cache_hit_tokens / prompt_tokens. Δ counters = "
                   "stats_after − stats_before on the record (host-cache counters; '—' = counters "
                   "absent, e.g. cache OFF or pre-binding stats). after-evict = the same prompt "
                   "again after filler prompts flushed the device banks.")
        out.append("")

    # --- decode --------------------------------------------------------------
    concs = sorted({(r.get("concurrency") or 1) for g in arms.values()
                    for r in g.by_mode("decode")})
    if concs:
        out.append("### Decode")
        out.append("")
        out.append("| C | per-stream off (tok/s) | per-stream on | aggregate off | aggregate on | "
                   "aggregate on/off | n off | n on | err |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        for conc in concs:
            ro = decode_row(arms["off"], conc) if "off" in arms else (None,) * 4
            rn = decode_row(arms["on"], conc) if "on" in arms else (None,) * 4
            out.append(f"| C{conc} | {fmt(ro[0], 1)} | {fmt(rn[0], 1)} | {fmt(ro[1], 1)} | "
                       f"{fmt(rn[1], 1)} | {fmt(ratio(rn[1], ro[1]), 3)} | "
                       f"{ro[2] if ro[2] is not None else '—'} | "
                       f"{rn[2] if rn[2] is not None else '—'} | {(ro[3] or 0) + (rn[3] or 0)} |")
        out.append("")
        out.append("per-stream = Σ out tokens / Σ(wall − TTFT) over the group's requests; aggregate "
                   "= Σ out tokens / group wall span (decode_aggregate_tok_s when the harness "
                   "recorded it, else recomputed from per-request ts/wall_s, else Σ out / the "
                   "aggregate line's elapsed_s). Decode numerator = usage completion_tokens, never "
                   "SSE deltas.")
        out.append("")


def render_errors(groups, out):
    """errors table + missing-rung notes across all (corpus, arm) groups."""
    out.append("## Errors")
    out.append("")
    rows = []
    for (corpus, arm), g in sorted(groups.items()):
        for r in g.recs:
            if "error" in r:
                head = str(r["error"]).replace("|", "/")[:100]
                rows.append((corpus, arm or "?", r.get("mode"), r.get("size"), head))
    if rows:
        out.append("| corpus | arm | mode | size | error (head) |")
        out.append("|---|---|---|---:|---|")
        for corpus, arm, mode, size, head in rows:
            out.append(f"| {corpus} | {arm} | {mode} | {size} | {head} |")
    else:
        out.append("_no error records in any input file_")
    out.append("")
    # missing rungs: a cold size recorded by one arm of a corpus but not the other
    notes = []
    corpora = {}
    for (corpus, arm), g in groups.items():
        corpora.setdefault(corpus, {})[arm] = g
    for corpus, arm_map in sorted(corpora.items()):
        if len(arm_map) < 2:
            continue
        sizes = {a: {r["size"] for r in g.by_mode("cold")} for a, g in arm_map.items()}
        for a, have in sizes.items():
            for s in sorted(set().union(*sizes.values()) - have):
                other = next(x for x in sizes if x != a)
                notes.append(f"- corpus {corpus}: rung {s} chars missing from the {a} arm "
                             f"(recorded on {other}) — pending or crashed before the error-record fix")
    if notes:
        out.append("### Missing rungs (present in one arm only)")
        out.append("")
        out.extend(notes)
        out.append("")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out")
    args = ap.parse_args()

    groups = {}
    for path in dict.fromkeys(args.files):  # dedupe, keep order
        try:
            recs = load(path)
        except (OSError, json.JSONDecodeError) as e:
            print(f"skip {path}: {e}", file=sys.stderr)
            continue
        for r in recs:
            corpus, arm = classify(r)
            groups.setdefault((corpus, arm), Group()).recs.append(r)
    if not groups:
        print("no usable ladder records", file=sys.stderr)
        return 1

    now = datetime.now(AEST).strftime("%Y-%m-%d %H:%M AEST")
    out = [f"# Ladder report — {now}", ""]
    out.append("Grouped by corpus and arm (-off/-on tag suffix). TTFT = client-observed arrival of "
               "the first delta carrying content or reasoning_content; decode tok/s = usage "
               "completion_tokens / (wall − TTFT); thinking mode as recorded per line.")
    out.append("")
    corpora = {}
    for (corpus, arm), g in sorted(groups.items()):
        corpora.setdefault(corpus, {})[arm] = g
    for name in corpora:
        arms = corpora[name]
        ordered = {}
        for a in (None, "off", "on"):
            if a in arms:
                ordered[a] = arms[a]
        render_corpus(name, ordered, out)
    render_errors(groups, out)

    text = "\n".join(out)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"report -> {args.out}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
