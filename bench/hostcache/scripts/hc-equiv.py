#!/usr/bin/env python3
"""hc-equiv.py — cold-vs-restored output equivalence check for the DS41RT host-cache smoke.

A wrong byte in a batched device<->host KV snapshot copy lands silently as wrong tokens, so
before trusting the host cache we prove that a request served from a restored snapshot emits
exactly the same tokens as the same request served cold. For each --sizes entry (CHARACTERS):

  cold      the salted prompt of SIZE chars, --max-tokens, temperature 0, thinking off
  fill      --fillers distinct ~4 KB prompts (hc-ladder.py's evict-restore filler generator),
            so the 24-entry device banks evict the cold snapshot
  restored  the identical prompt and parameters again
  compare   equal = cold.text == restored.text; first_divergence = index of the first differing
            character (null when equal); hit_ok = restored.hit_tokens == restored.prompt_tokens
            (a full restore, not a partial one)

One JSON line per size (kind "equiv", or "error" when a request fails) plus a summary line.
Exit 0 when every size is equal and hit_ok, 3 otherwise.

Methodology (v41bench): temperature 0, thinking off (reasoning_effort "none"), usage from
stream_options.include_usage, TTFT = arrival of the first content/reasoning delta. Prompt
bodies are hc-ladder.py's salted header plus a deterministic corpus slice, so cold and
restored send byte-identical prompts. /v1/stats host_cache counters are recorded before and
after the restored request (restores, restore_failures, pages_copied, copy_submissions when
the build exposes it).

--mock-divergence is TEST-ONLY: it perturbs the restored text before comparison so
test-hc-equiv.sh can exercise the exit-3 / first_divergence path against the deterministic mock.
"""
import argparse
import importlib.util
import json
import os
import sys
import urllib.request
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    """Import a sibling harness module whose filename is not a valid identifier (hyphen)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc_ladder = _load("hc_ladder", "hc-ladder.py")  # prompt builder, stats, filler request helper
hc_rotate = _load("hc_rotate", "hc-rotate.py")  # chat() returns the generated text


def _measure(base, text, max_tokens, timeout):
    """One cold/restored request: the fields the equivalence check compares, plus the text.

    hc-ladder's _chat_raw/chat do not return the generated text, so this reuses hc-rotate.chat
    (same conventions: temperature 0, reasoning_effort none, usage via
    stream_options.include_usage, TTFT = first delta) which returns (fields, assistant_text).
    Minimal refactor to unify: have hc-ladder._chat_raw also return the concatenated content.
    """
    try:
        fields, reply = hc_rotate.chat(base, [{"role": "user", "content": text}], max_tokens,
                                       timeout, thinking=False)
    except Exception as e:  # noqa: BLE001 — an errored request is a record, not an abort
        return {"error": f"{type(e).__name__}: {e}"}
    return {"ttft_s": fields["ttft_s"], "wall_s": fields["wall_s"],
            "prompt_tokens": fields["prompt_tokens"], "hit_tokens": fields["hit_tokens"],
            "completion_tokens": fields["out_tokens"], "text": reply}


def _first_divergence(a, b):
    """Index of the first differing character; the shorter length when one is a prefix."""
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None if len(a) == len(b) else min(len(a), len(b))


def _emit_error(size, cold, restored, stats_before, stats_after, tag):
    """A failed cold/restored request: kind "error", counted as not equal by the summary."""
    line = {"kind": "error", "size": size, "cold": cold, "restored": restored,
            "equal": False, "hit_ok": False, "first_divergence": None,
            "stats_before": stats_before, "stats_after": stats_after, "thinking": "off"}
    if tag:
        line["tag"] = tag
    print(json.dumps(line), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8000")
    ap.add_argument("--corpus", required=True, help="text file for prompt bodies (deterministic salted slices)")
    ap.add_argument("--sizes", default="67742,274194", help="comma list of prompt sizes in CHARACTERS")
    ap.add_argument("--fillers", type=int, default=26, help="distinct ~4 KB prompts between cold and restored")
    ap.add_argument("--max-tokens", type=int, default=48)
    ap.add_argument("--tag", default=None, help="run tag recorded on every line (default none)")
    ap.add_argument("--timeout", type=float, default=3600.0)
    ap.add_argument("--mock-divergence", action="store_true",
                    help="TEST-ONLY: perturb the restored text before comparison (exercises exit 3)")
    a = ap.parse_args()
    try:
        sizes = [int(s) for s in a.sizes.split(",") if s]
    except ValueError:
        print(f"bad --sizes {a.sizes!r}", file=sys.stderr)
        return 2
    if not sizes or a.fillers < 0 or a.max_tokens < 1:
        print("--sizes must be non-empty, --fillers >= 0, --max-tokens >= 1", file=sys.stderr)
        return 2
    base = a.base.rstrip("/")
    try:
        with urllib.request.urlopen(f"{base}/health", timeout=8) as r:
            r.read(64)
    except Exception as e:  # noqa: BLE001
        print(f"server unreachable at {a.base}: {e}", file=sys.stderr)
        return 1
    try:
        corpus = hc_ladder.Corpus(a.corpus)
    except (OSError, ValueError) as e:
        print(f"corpus: {e}", file=sys.stderr)
        return 2

    n_equal = n_hit_ok = 0
    for size in sizes:
        salt = uuid.uuid4().hex[:8]
        text = hc_ladder.prompt_text(size, salt, corpus)
        cold = _measure(base, text, a.max_tokens, a.timeout)
        if "error" in cold:
            _emit_error(size, cold, None, None, None, a.tag)
            continue
        # evict the cold snapshot from the device banks exactly as hc-ladder's evict-restore mode
        for i in range(a.fillers):
            hc_ladder.chat(base, hc_ladder.prompt_text(4096, f"{salt}-fill{i}", corpus), 8, False, a.timeout)
        stats_before = hc_ladder.stats(base).get("host_cache")
        restored = _measure(base, text, a.max_tokens, a.timeout)
        stats_after = hc_ladder.stats(base).get("host_cache")
        if "error" in restored:
            _emit_error(size, cold, restored, stats_before, stats_after, a.tag)
            continue
        if a.mock_divergence and restored["text"]:  # TEST-ONLY
            i = len(restored["text"]) // 2
            restored["text"] = (restored["text"][:i]
                                + ("Z" if restored["text"][i] != "Z" else "Q")
                                + restored["text"][i + 1:])
        equal = cold["text"] == restored["text"]
        first_div = None if equal else _first_divergence(cold["text"], restored["text"])
        hit_ok = restored["hit_tokens"] is not None and restored["hit_tokens"] == restored["prompt_tokens"]
        n_equal += int(equal)
        n_hit_ok += int(hit_ok)
        line = {"kind": "equiv", "size": size, "cold": cold, "restored": restored,
                "equal": equal, "hit_ok": hit_ok, "first_divergence": first_div,
                "stats_before": stats_before, "stats_after": stats_after, "thinking": "off"}
        if a.tag:
            line["tag"] = a.tag
        print(json.dumps(line), flush=True)
    print(json.dumps({"kind": "summary", "sizes": len(sizes), "equal": n_equal, "hit_ok": n_hit_ok}),
          flush=True)
    return 0 if (n_equal == len(sizes) and n_hit_ok == len(sizes)) else 3


if __name__ == "__main__":
    sys.exit(main())
