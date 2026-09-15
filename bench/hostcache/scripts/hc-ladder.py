#!/usr/bin/env python3
"""Prompt ladder for the DS41RT coordinator with host-cache accounting.

Modes (one JSON line per measurement, stdout), every line tagged with the thinking mode
("thinking": "off" = reasoning_effort none sent on every request; "on" = model default):
  cold           salted prompt of SIZE characters, max_tokens 1: TTFT and cache hit/miss tokens
  reuse          the same prompt again (device-bank hit expected)
  evict-restore  cold, then FILLERS distinct 4 KB prompts (retire as turns and prompts, flushing
                 both device banks of 24), then the same prompt again: with the host cache on,
                 a full hit restored from RAM; off, a full re-prefill
  decode         one ~8 KB prompt, max_tokens N, reports tok/s
  aggregate      with --concurrency N: one summary line per concurrent cold/decode group —
                 n, TTFT p50/p95 (nearest-rank), and group tok/s
Every line carries the coordinator's /v1/stats host_cache counters before and after.

--corpus FILE builds the prompt from real text: a salted header plus a deterministic
wrapped slice of the corpus of the requested character size; the slice offset is
sha256(salt)[:8] big-endian * 7919 mod corpus chars, identical to hc-rotate.py, so OFF/ON
arms derive the same prompts from the same corpus. Sizes stay in CHARACTERS; the measured
prompt_tokens/miss_tokens from usage are recorded on every line (plan §2 tok/char caveat).
Without --corpus the synthetic greek-word list is kept (runbook §3 smoke unchanged).

--concurrency N runs N simultaneous salted requests for the cold and decode modes (one
line per request, each tagged with "worker" and "concurrency"), then the aggregate line:
  cold   prefill_tok_s = sum(miss_tokens) / elapsed wall of the group (parallel throughput)
  decode decode_tok_s  = sum(completion_tokens) / sum(wall - TTFT) per request (per-stream mean);
         decode_aggregate_tok_s = sum(completion_tokens) / elapsed wall of the group
TTFT percentiles are client-observed and include any prefill-lane queueing.

TTFT = client-observed arrival of the first delta carrying content OR reasoning_content
(v41bench methodology; recorded as first_delta_kind — the coordinator streams reasoning deltas
first when thinking is on). Decode tok/s = usage.completion_tokens / (wall − TTFT).

Exit codes: 0 ok; 1 server unreachable at startup; 2 bad arguments/corpus.
"""
import argparse, hashlib, json, sys, threading, time, urllib.request, uuid

def stats(base):
    """/v1/stats as a dict; a bare JSON null (host cache off on this build) becomes
    {"host_cache": None}; errors become {"error": ...}."""
    try:
        with urllib.request.urlopen(f"{base}/v1/stats", timeout=5) as r:
            payload = json.load(r)
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}
    return payload if isinstance(payload, dict) else {"host_cache": None}

class Corpus:
    """Deterministic wrapped slices of one text file (same derivation as hc-rotate.py)."""
    def __init__(self, path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            self.text = fh.read()
        self.sha = hashlib.sha256(self.text.encode()).hexdigest()[:16]
        if len(self.text) < 4096:
            raise ValueError(f"corpus too small: {len(self.text)} chars")

    def slice(self, start, n):
        t, L = self.text, len(self.text)
        start %= L
        if start + n <= L:
            return t[start:start + n]
        return t[start:] + t[:(start + n) % L]

def prompt_text(size, salt, corpus=None):
    """Salted header plus the prompt body: a deterministic corpus slice, or the synthetic
    greek-word list when no corpus is given. Exactly SIZE characters."""
    header = f"session {salt}. "
    body = size - len(header)
    if corpus is None:
        words = ("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho "
                 "sigma tau upsilon phi chi psi omega ").split()
        out = [header]
        n = 0
        while n < body:
            w = words[n % len(words)] + " "
            out.append(w); n += len(w)
        return "".join(out)[:size]
    off = (int.from_bytes(hashlib.sha256(salt.encode("utf-8")).digest()[:8], "big")
           * 7919 % len(corpus.text))
    return (header + corpus.slice(off, body))[:size]

def _chat_raw(base, text, max_tokens, thinking, timeout=3600):
    """One streaming chat request; TTFT = first delta with content or reasoning_content."""
    body_obj = {"model": "deepseek-ai/DeepSeek-V4.1-Flash", "stream": True, "temperature": 0,
                "max_tokens": max_tokens, "stream_options": {"include_usage": True},
                "messages": [{"role": "user", "content": text}]}
    if not thinking:
        body_obj["reasoning_effort"] = "none"
    body = json.dumps(body_obj).encode()
    req = urllib.request.Request(f"{base}/v1/chat/completions", data=body, headers={"content-type": "application/json"})
    t0 = time.monotonic(); first = None; first_kind = None; usage = None; tokens = 0
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            ev = json.loads(line[5:])
            if ev.get("usage"):
                usage = ev["usage"]
            for c in ev.get("choices", []):
                d = c.get("delta", {})
                if d.get("content"):
                    tokens += 1
                    kind = "content"
                elif d.get("reasoning_content"):
                    kind = "reasoning_content"
                else:
                    continue
                if first is None:
                    first = time.monotonic() - t0
                    first_kind = kind
    wall = time.monotonic() - t0
    return {"wall_s": round(wall, 3), "ttft_s": None if first is None else round(first, 3),
            "first_delta_kind": first_kind, "out_tokens": tokens,
            "prompt_tokens": (usage or {}).get("prompt_tokens"),
            "hit_tokens": (usage or {}).get("prompt_cache_hit_tokens"),
            "miss_tokens": (usage or {}).get("prompt_cache_miss_tokens")}

def chat(base, text, max_tokens, thinking, timeout=3600.0):
    """_chat_raw with errors as records: an HTTP error (the coordinator rejects some prompts with
    400) or a transport failure returns a line-shaped dict carrying "error" (status + body head)
    and None measurements, so a ladder run continues and the report sees the failure."""
    t0 = time.monotonic()
    try:
        return _chat_raw(base, text, max_tokens, thinking, timeout)
    except urllib.error.HTTPError as e:
        body = e.read(300).decode("utf-8", "replace") if hasattr(e, "read") else ""
        err = f"HTTP {e.code}: {body}"
    except Exception as e:  # noqa: BLE001
        err = f"{type(e).__name__}: {e}"
    return {"wall_s": round(time.monotonic() - t0, 3), "ttft_s": None, "first_delta_kind": None,
            "out_tokens": 0, "prompt_tokens": None, "hit_tokens": None, "miss_tokens": None, "error": err}

def emit(mode, size, result, before, after, thinking, extra=None, tag=None):
    line = {"mode": mode, "size": size, "thinking": "on" if thinking else "off", **result,
            "stats_before": before.get("host_cache"), "stats_after": after.get("host_cache")}
    if tag:
        line["tag"] = tag
    if extra: line.update(extra)
    print(json.dumps(line), flush=True)

def percentile(sorted_vals, q):
    """Nearest-rank percentile: q in percent, vals sorted ascending."""
    if not sorted_vals:
        return None
    k = -(-len(sorted_vals) * q // 100)  # ceil(q/100 * n)
    return sorted_vals[max(0, min(len(sorted_vals) - 1, k - 1))]

def run_concurrent(base, mode, size, max_tokens, n, thinking, timeout, corpus, tag=None):
    """N simultaneous salted requests; one line per request plus one aggregate line."""
    results = [None] * n
    lock = threading.Lock()
    def worker(i):
        salt = f"{uuid.uuid4().hex[:8]}-w{i}"
        text = prompt_text(size, salt, corpus)
        before = stats(base)
        try:
            r = chat(base, text, max_tokens, thinking, timeout)
        except Exception as e:  # noqa: BLE001 — an errored request is a line, not an abort
            r = {"error": f"{type(e).__name__}: {e}"}
        extra = {"salt": salt, "worker": i, "concurrency": n}
        if corpus:
            extra["corpus_sha256_16"] = corpus.sha
        with lock:
            results[i] = r
            emit(mode, size, r, before, stats(base), thinking, extra, tag=tag)
    t_start = time.monotonic()
    threads = [threading.Thread(target=worker, daemon=True, args=(i,)) for i in range(n)]
    for t in threads: t.start()
    for t in threads: t.join()
    elapsed = time.monotonic() - t_start
    ok = [r for r in results if r is not None and "error" not in r]
    ttfts = sorted(r["ttft_s"] for r in ok if r.get("ttft_s") is not None)
    line = {"mode": "aggregate", "size": size, "n": len(ok), "concurrency": n,
            "errors": n - len(ok), "elapsed_s": round(elapsed, 3),
            "ttft_p50_s": percentile(ttfts, 50), "ttft_p95_s": percentile(ttfts, 95),
            "thinking": "on" if thinking else "off"}
    if tag:
        line["tag"] = tag
    if corpus:
        line["corpus_sha256_16"] = corpus.sha
    if mode == "decode":
        tok = sum(r.get("out_tokens") or 0 for r in ok)
        gen = sum(r["wall_s"] - (r["ttft_s"] or 0) for r in ok if r.get("ttft_s") is not None)
        # per-stream mean (sum of tokens over the sum of each request's generation time) and the
        # group's aggregate throughput (sum of tokens over the group's wall-clock span)
        line["decode_tok_s"] = round(tok / gen, 1) if gen > 0 else None
        line["decode_aggregate_tok_s"] = round(tok / elapsed, 1) if elapsed > 0 else None
    else:  # cold: parallel prefill throughput over the group's wall clock
        miss = sum(r.get("miss_tokens") or 0 for r in ok)
        line["prefill_tok_s"] = round(miss / elapsed, 1) if elapsed > 0 else None
    print(json.dumps(line), flush=True)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8000")
    ap.add_argument("--tag", default=None, help="run tag recorded on every line (default none)")
    ap.add_argument("--sizes", default="32768,131072,262144")
    ap.add_argument("--mode", default="cold,reuse", help="comma list of cold,reuse,evict-restore,decode")
    ap.add_argument("--fillers", type=int, default=26)
    ap.add_argument("--decode", type=int, default=200, help="output tokens for the decode mode")
    ap.add_argument("--decode-ctx-chars", type=int, default=8192, help="prompt size for the decode mode")
    ap.add_argument("--corpus", default=None, help="text file for prompt bodies (deterministic salted slices); default synthetic greek words")
    ap.add_argument("--concurrency", type=int, default=1, help="N simultaneous salted requests for cold/decode modes")
    ap.add_argument("--timeout", type=float, default=3600.0)
    ap.add_argument("--thinking", action="store_true",
                    help="leave the model's default thinking on (omit reasoning_effort); default off = reasoning_effort none")
    a = ap.parse_args()
    if a.concurrency < 1:
        print("--concurrency must be >= 1", file=sys.stderr)
        return 2
    try:
        with urllib.request.urlopen(f"{a.base.rstrip('/')}/health", timeout=8) as r:
            r.read(64)
    except Exception as e:  # noqa: BLE001
        print(f"server unreachable at {a.base}: {e}", file=sys.stderr)
        return 1
    corpus = None
    if a.corpus:
        try:
            corpus = Corpus(a.corpus)
        except (OSError, ValueError) as e:
            print(f"corpus: {e}", file=sys.stderr)
            return 2
    sizes = [int(s) for s in a.sizes.split(",") if s]
    modes = a.mode.split(",")
    base = a.base.rstrip("/")
    csha = {"corpus_sha256_16": corpus.sha} if corpus else {}
    for size in sizes:
        salt = uuid.uuid4().hex[:8]
        text = prompt_text(size, salt, corpus)
        if "cold" in modes or "evict-restore" in modes:
            if a.concurrency > 1:
                run_concurrent(base, "cold", size, 1, a.concurrency, a.thinking, a.timeout, corpus, tag=a.tag)
            else:
                b = stats(base); r = chat(base, text, 1, a.thinking, a.timeout)
                emit("cold", size, r, b, stats(base), a.thinking, {"salt": salt, **csha}, tag=a.tag)
        if "reuse" in modes:
            b = stats(base); r = chat(base, text, 1, a.thinking, a.timeout)
            emit("reuse", size, r, b, stats(base), a.thinking, {"salt": salt, **csha}, tag=a.tag)
        if "evict-restore" in modes:
            t0 = time.monotonic()
            for i in range(a.fillers):
                chat(base, prompt_text(4096, f"{salt}-fill{i}", corpus), 8, a.thinking, a.timeout)
            fill_s = round(time.monotonic() - t0, 1)
            b = stats(base); r = chat(base, text, 1, a.thinking, a.timeout)
            emit("after-evict", size, r, b, stats(base), a.thinking,
                 {"salt": salt, "fillers": a.fillers, "fill_s": fill_s, **csha}, tag=a.tag)
    if "decode" in modes:
        if a.concurrency > 1:
            run_concurrent(base, "decode", a.decode_ctx_chars, a.decode, a.concurrency,
                           a.thinking, a.timeout, corpus, tag=a.tag)
        else:
            b = stats(base); r = chat(base, prompt_text(a.decode_ctx_chars, uuid.uuid4().hex[:8], corpus), a.decode, a.thinking, a.timeout)
            gen_s = r["wall_s"] - (r["ttft_s"] or 0)
            emit("decode", a.decode_ctx_chars, r, b, stats(base), a.thinking,
                 {"decode_tok_s": round(r["out_tokens"] / gen_s, 1) if gen_s > 0 else None, **csha}, tag=a.tag)
    print("LADDER-DONE", flush=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
