#!/usr/bin/env python3
"""hc-rotate.py — rotating concurrent-session harness for the DS41RT host-cache benchmarks.

Design: research/afd-hostcache-bench-plan.md. C client threads x S sessions each, round-robin.
Each visit appends a fresh user turn (and the verbatim previous assistant reply) so the prompt is
an exact descendant of the session's retained snapshot: with the host cache on and enough sessions
to thrash the 24-entry device banks, every revisit is an evict/restore pair with no cold prefill.
--corpus takes a comma list to mix corpora across clients round-robin (plan R5 prose+code);
--run-id fixes the session salt prefix so a later run revisits the same sessions (B4 ramps).
--turn-gap-secs MIN,MAX (B5 agentic ramp, plan §6 B5): after each steady-phase visit a client
sleeps a uniform-random tool gap in [MIN, MAX] s drawn from its own RNG, seeded
sha256(run_id + client index) so the same run id reproduces the same gaps across processes.
Each visit's req record carries the drawn gap as turn_gap_s (the gap BEFORE the client's next
visit; 0,0 = no gap, the field is omitted and output is byte-identical to pre-B5 runs). With
--sessions 1 a client IS an agent loop: each visit revisits its single session, which grows by
the new user chunk plus the verbatim previous assistant reply (record_reply).

Segments (each bracketed by /v1/stats scrapes, each request one JSONL record):
  nopressure  small fixed request count, banks near-empty — ONLY valid right after a fresh launch
              (verifies the no-eviction claim from counters, never assumes it)
  warmup      one cold visit per session (excluded from measurement)
  steady      time-bounded rotation; optional passive decode probe + periodic stats sampler
  recovery    idle -> sequential revisit of R sessions -> optional observe -> second pass
              (first pass expects host hits, second expects device hits)

Decode numerator is usage.completion_tokens (never SSE delta counting — dSpark packs several
tokens per chunk; v41bench methodology) over the wall time after the first delta. TTFT = the
client-observed arrival of the first delta carrying content OR reasoning_content (the
coordinator streams reasoning deltas first when thinking is on; v41bench methodology) —
recorded per request as first_delta_kind. Thinking is OFF by default: every request sends
"reasoning_effort": "none"; --thinking omits it (header records the mode). TTFT includes any
prefill-lane queueing — stated in every report.

HTTP 503 or 429 = backpressure, not an error (HB-7; extended to 429 by HB-8): the coordinator
caps in-flight requests (C16), and an agentic ramp bursts above it — on rc4 as an immediate
503, on the rc6 front door as a 429 after a bounded 30 s queue wait. A real agent client
waits and retries, so on a 503 or 429 the visit is retried after a jittered backoff drawn
from a seeded per-client RNG: 0.5 s x 2^attempt +/- 25 %, capped at 8 s, up to
--max-503-retries attempts (default 20; 0 = the refusal is recorded as an error, the
pre-HB-7 behaviour). A 429's Retry-After header, when present and parsing as a non-negative
number of seconds, sets the MINIMUM sleep for that retry (a malformed header is ignored;
one Retry-After is never honoured for more than 60 s): the sleep is
max(jittered backoff, Retry-After). A retried visit's req record gains retries_503 (count of
BOTH 503s and 429s — one shared budget), backoff_s (total seconds slept between attempts,
including the Retry-After sleeps), retries_429 (how many of the retries were 429s) and
retry_after_s_sum (total seconds the server asked for; 0 when no Retry-After was sent);
ttft_s stays the FINAL attempt's send-to-first-delta time and turn_latency_s (first attempt's
send to last delta — what the agent experiences) is added. Exhausting the budget records
kind "error" with the last status, carrying retries_503 so reducers can tell exhausted
backpressure (a request error) from a declined one (backpressure, not counted by
bar_check_b5).

Exit codes: 0 ok; 1 server unreachable at startup; 2 bad arguments.
"""
import argparse
import hashlib
import json
import random
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

AEST = timezone(timedelta(hours=10))  # Sep: AEST=UTC+10 (AEDT from Oct; adjust if re-used then)
MODEL = "deepseek-ai/DeepSeek-V4.1-Flash"


def now_iso():
    return datetime.now(AEST).isoformat(timespec="seconds")


class Writer:
    """Lock-protected JSONL sink; every record carries tag + AEST timestamp."""

    def __init__(self, path, tag):
        self.fh = open(path, "a")
        self.lock = threading.Lock()
        self.tag = tag

    def emit(self, kind, **fields):
        rec = {"kind": kind, "tag": self.tag, "ts": now_iso(), **fields}
        line = json.dumps(rec)
        with self.lock:
            self.fh.write(line + "\n")
            self.fh.flush()
        return rec


def get_stats(base, timeout=5):
    """The coordinator's /v1/stats as a dict. With the host cache off this build returns a bare
    JSON null (Option<Snapshot> serialised), so a non-object payload is normalised to
    {"host_cache": None} and the reports mark the counters ABSENT; an unreachable or
    non-JSON endpoint becomes {"error": ...}."""
    try:
        with urllib.request.urlopen(f"{base}/v1/stats", timeout=timeout) as r:
            payload = json.load(r)
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}
    if isinstance(payload, dict):
        return payload
    return {"host_cache": None, "stats_payload": "null" if payload is None else type(payload).__name__}


def chat(base, messages, max_tokens, timeout, thinking=False):
    """One streaming chat request. Returns (record_fields, assistant_text).

    TTFT = arrival of the first delta carrying content or reasoning_content (v41bench
    methodology); which kind fired is recorded as first_delta_kind. Unless --thinking,
    the body carries "reasoning_effort": "none" so the coordinator skips reasoning and
    the first delta is content.
    """
    body_obj = {"model": MODEL, "stream": True, "temperature": 0, "max_tokens": max_tokens,
                "stream_options": {"include_usage": True}, "messages": messages}
    if not thinking:
        body_obj["reasoning_effort"] = "none"
    body = json.dumps(body_obj).encode()
    req = urllib.request.Request(f"{base}/v1/chat/completions", data=body,
                                 headers={"content-type": "application/json"})
    t0 = time.monotonic()
    first = None
    first_kind = None
    usage = None
    parts = []
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
                    parts.append(d["content"])
                    kind = "content"
                elif d.get("reasoning_content"):
                    kind = "reasoning_content"
                else:
                    continue
                if first is None:
                    first = time.monotonic() - t0
                    first_kind = kind
    wall = time.monotonic() - t0
    ttft = first
    gen = (wall - first) if first is not None else None
    out_tok = (usage or {}).get("completion_tokens")
    return {
        "wall_s": round(wall, 3),
        "ttft_s": None if ttft is None else round(ttft, 3),
        "first_delta_kind": first_kind,
        "gen_s": None if gen is None else round(gen, 3),
        "out_tokens": out_tok,
        "prompt_tokens": (usage or {}).get("prompt_tokens"),
        "hit_tokens": (usage or {}).get("prompt_cache_hit_tokens"),
        "miss_tokens": (usage or {}).get("prompt_cache_miss_tokens"),
        "decode_tok_s": round(out_tok / gen, 1) if (out_tok and gen and gen > 0) else None,
    }, "".join(parts)


class Corpus:
    """Deterministic wrapped slices of one text file."""

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


class Session:
    """One rotating conversation: fixed initial context + a new user chunk per visit.

    Corpus offset derivation is deterministic across processes: sha256(sid) first 8 bytes
    big-endian × 7919 mod corpus chars (Python's hash() is salted per process, so OFF/ON
    arms must not use it). Recorded in the JSONL header.
    """

    def __init__(self, corpus, salt, sid, ctx_chars, new_chars):
        off = (int.from_bytes(hashlib.sha256(sid.encode("utf-8")).digest()[:8], "big")
               * 7919 % max(1, len(corpus.text)))
        self.sid = sid
        self.corpus = corpus
        self.base_off = off
        self.ctx_chars = ctx_chars
        self.new_chars = new_chars
        self.cursor = ctx_chars  # continuation point for new turns
        self.visits = 0
        self.failures = 0
        self.messages = [{"role": "user", "content": f"session {salt}. " + corpus.slice(off, ctx_chars)}]

    def next_user(self):
        chunk = self.corpus.slice(self.base_off + self.cursor, self.new_chars)
        self.cursor += self.new_chars
        self.messages.append({"role": "user", "content": chunk})
        return self.messages

    def pop_user(self):
        """Undo the user turn appended by next_user() after a failed request, so the
        transcript never carries two consecutive user turns."""
        if self.messages and self.messages[-1]["role"] == "user":
            self.messages.pop()

    def record_reply(self, text):
        if text:
            self.messages.append({"role": "assistant", "content": text})
        self.visits += 1


def retry_rng(run_id, client):
    """Per-client RNG for the 503/429 backoff jitter, deterministic across processes: seeded from
    sha256("<run_id>-retry-c<client>") like the turn-gap draws, so a re-run with the same
    --run-id reproduces the same backoff schedule (OFF/ON arms compare like for like)."""
    seed = int.from_bytes(hashlib.sha256(f"{run_id}-retry-c{client}".encode()).digest()[:8], "big")
    return random.Random(seed)


def visit(w, base, sess, seg, client, max_tokens, timeout, thinking=False, extra=None,
          turn_gap=None, max_503_retries=0, rng=None):
    rec = {"segment": seg, "client": client, "session": sess.sid, "visit": sess.visits}
    if turn_gap is not None:
        rec["turn_gap_s"] = turn_gap  # B5 tool gap BEFORE this client's next visit
    if extra:
        rec.update(extra)
    retries = 0
    retries_429 = 0
    retry_after_sum = 0.0
    backoff = 0.0
    t_send0 = None
    try:
        messages = sess.next_user()  # one user turn per visit, however many backpressure retries
        while True:
            if t_send0 is None:
                t_send0 = time.monotonic()  # the agent-experienced latency anchor
            try:
                fields, reply = chat(base, messages, max_tokens, timeout, thinking=thinking)
                break
            except urllib.error.HTTPError as e:
                # 503/429 only: coordinator backpressure — wait and retry (HB-7/HB-8)
                if e.code not in (503, 429) or retries >= max_503_retries:
                    raise
                retries += 1
                delay = min(8.0, 0.5 * 2 ** (retries - 1)
                            * (rng.uniform(0.75, 1.25) if rng is not None else 1.0))
                if e.code == 429:
                    retries_429 += 1
                    # rc6 front door: honour Retry-After as the MINIMUM sleep for this retry.
                    # A malformed header is ignored; one Retry-After is never honoured > 60 s.
                    try:
                        ask = float(e.headers.get("Retry-After", ""))
                    except (TypeError, ValueError):
                        ask = -1.0  # missing/malformed header: jittered backoff only
                    if ask >= 0:
                        ask = min(60.0, ask)
                        delay = max(delay, ask)
                        retry_after_sum += ask
                backoff += delay
                time.sleep(delay)
        sess.record_reply(reply)
        if retries:
            rec["retries_503"] = retries  # 503s AND 429s absorbed as backpressure (HB-7/HB-8;
            rec["retries_429"] = retries_429  # one shared budget counted as retries_503)
            rec["retry_after_s_sum"] = round(retry_after_sum, 3)  # seconds the server asked for
            rec["backoff_s"] = round(backoff, 3)  # total wall slept (incl. Retry-After sleeps)
            rec["turn_latency_s"] = round(time.monotonic() - t_send0, 3)  # first send -> last delta
        w.emit("req", **rec, **fields)
        return fields
    except Exception as e:  # noqa: BLE001 — errors are records, not aborts (B4 needs the shape)
        sess.pop_user()  # never leave two consecutive user turns in the transcript
        sess.failures += 1
        if retries:
            rec["retries_503"] = retries  # exhausted backpressure: still a request error,
            rec["retries_429"] = retries_429  # but distinguishable from a declined 503/429
            rec["retry_after_s_sum"] = round(retry_after_sum, 3)
            rec["backoff_s"] = round(backoff, 3)  # (bar_check_b5 counts only exhausted refusals)
        w.emit("error", **rec, failures=sess.failures, error=f"{type(e).__name__}: {e}")
        return None


def bracket(w, name, fn, base):
    before = get_stats(base)
    t0 = time.monotonic()
    result = fn()
    t1 = time.monotonic()
    after = get_stats(base)
    w.emit("segment", segment=name, t0=round(t0, 1), t1=round(t1, 1),
           stats_before=before.get("host_cache"), stats_after=after.get("host_cache"),
           stats_error=before.get("error") or after.get("error"))
    return result


def gap_rng(run_id, client):
    """Per-client RNG for --turn-gap-secs draws, deterministic across processes: seeded from
    sha256("<run_id>-gap-c<client>") like the session corpus offsets, so the OFF/ON arms and a
    re-run with the same --run-id draw identical gap sequences."""
    seed = int.from_bytes(hashlib.sha256(f"{run_id}-gap-c{client}".encode()).digest()[:8], "big")
    return random.Random(seed)


def client_loop(w, base, sessions, stop, seg, client, decode, timeout, thinking, deadline=None,
                rng=None, gap_range=(0.0, 0.0), max_503_retries=0, rng503=None):
    i = 0
    while not stop.is_set() and (deadline is None or time.monotonic() < deadline):
        s = sessions[i % len(sessions)]
        gap = round(rng.uniform(*gap_range), 3) if rng is not None else None
        visit(w, base, s, seg, client, decode, timeout, thinking=thinking, turn_gap=gap,
              max_503_retries=max_503_retries, rng=rng503)
        i += 1
        if gap and not stop.is_set():
            # idle agents hold no request slot (B5): sleep the tool gap, bounded by the deadline
            rem = None if deadline is None else max(0.0, deadline - time.monotonic())
            stop.wait(gap if rem is None else min(gap, rem))


def steady_phase(w, base, a, clients_sessions, stop):
    threads = []
    deadline = time.monotonic() + a.steady_secs
    gap_on = a._turn_gap[1] > 0
    for ci, sessions in enumerate(clients_sessions):
        t = threading.Thread(target=client_loop, daemon=True,
                             args=(w, base, sessions, stop, "steady", ci, a.decode, a.timeout, a.thinking, deadline),
                             kwargs={"rng": gap_rng(a.run_id, ci) if gap_on else None,
                                     "gap_range": a._turn_gap,
                                     "max_503_retries": a.max_503_retries,
                                     "rng503": retry_rng(a.run_id, ci)})
        t.start()
        threads.append(t)
    sampler = threading.Thread(target=stats_sampler, daemon=True,
                               args=(w, base, stop, a.stats_every, "steady"))
    sampler.start()
    probe_t = None
    if a.probe:
        probe_stop = threading.Event()
        probe_t = threading.Thread(target=probe_loop, daemon=True,
                                   args=(w, base, a, probe_stop, deadline))
        probe_t.start()
    for t in threads:
        t.join()
    stop.set()
    if probe_t:
        probe_t.join(timeout=a.timeout)
    sampler.join(timeout=10)


def stats_sampler(w, base, stop, every, seg):
    while not stop.wait(every):
        st = get_stats(base)
        w.emit("stats", segment=seg, host_cache=st.get("host_cache"), error=st.get("error"))


def probe_loop(w, base, a, stop, deadline):
    """Passive decode probe: a lone small cold context + long-ish decode, every a.probe_every s."""
    corpus = a._probe_corpus
    n = 0
    while time.monotonic() < deadline and not stop.is_set():
        salt = f"probe-{a.run_id}-{n}"
        s = Session(corpus, salt, salt, a.probe_ctx, 0)
        visit(w, base, s, "probe", -1, a.probe_decode, a.timeout, thinking=a.thinking,
              extra={"probe": n}, max_503_retries=a.max_503_retries, rng=retry_rng(a.run_id, -1))
        n += 1
        stop.wait(max(0.0, a.probe_every - 1))


def parse_turn_gap(s):
    """--turn-gap-secs MIN,MAX -> (min, max) floats; 0 <= MIN <= MAX (exit 2 otherwise)."""
    try:
        lo, hi = (float(x) for x in s.split(","))
    except (ValueError, TypeError):
        raise argparse.ArgumentTypeError(f"expected MIN,MAX seconds, got {s!r}")
    if lo < 0 or hi < lo:
        raise argparse.ArgumentTypeError(f"expected 0 <= MIN <= MAX, got {s!r}")
    return lo, hi


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8000")
    ap.add_argument("--tag", required=True, help="run tag, e.g. pilot-on / pilot-off / R3-on")
    ap.add_argument("--run-id", default=None,
                    help="salt prefix / run id (default: random uuid8); fixed ids let a later run "
                         "revisit the same sessions, e.g. the B4 ramps grow the client set per point")
    ap.add_argument("--out", required=True, help="JSONL output (appended)")
    ap.add_argument("--corpus", required=True,
                    help="text file(s) for session bodies; a comma list mixes corpora across "
                         "clients round-robin (client c uses corpus[c mod n])")
    ap.add_argument("--segments", default="nopressure,warmup,steady,recovery")
    # rotation shape
    ap.add_argument("--clients", type=int, default=6)
    ap.add_argument("--sessions", type=int, default=8, help="sessions per client")
    ap.add_argument("--ctx-chars", type=int, default=30000)
    ap.add_argument("--new-chars", type=int, default=2000, help="fresh user text per visit (~500 tok prose)")
    ap.add_argument("--decode", type=int, default=100)
    ap.add_argument("--turn-gap-secs", default="0,0", metavar="MIN,MAX",
                    help="B5 agentic tool gap: after each steady visit a client sleeps a "
                         "uniform-random [MIN, MAX] s drawn from its per-client seeded RNG "
                         "(seed = sha256(run_id + client index)); recorded on the visit's req "
                         "record as turn_gap_s; default 0,0 = no gap, field omitted")
    # nopressure
    ap.add_argument("--np-clients", type=int, default=3)
    ap.add_argument("--np-sessions", type=int, default=2)
    ap.add_argument("--np-rounds", type=int, default=3)
    ap.add_argument("--np-ctx-chars", type=int, default=30000)
    # phases
    ap.add_argument("--steady-secs", type=int, default=480)
    ap.add_argument("--recovery-sessions", type=int, default=12)
    ap.add_argument("--recovery-decode", type=int, default=16)
    ap.add_argument("--idle-secs", type=int, default=60)
    ap.add_argument("--observe-secs", type=int, default=0)
    # probe / stats
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--probe-every", type=int, default=60)
    ap.add_argument("--probe-ctx", type=int, default=8192)
    ap.add_argument("--probe-decode", type=int, default=200)
    ap.add_argument("--stats-every", type=int, default=15)
    ap.add_argument("--timeout", type=float, default=3600.0)
    ap.add_argument("--max-503-retries", type=int, default=20, metavar="N",
                    help="HTTP 503 or 429 = coordinator backpressure: retry the visit after a "
                         "jittered backoff (0.5 s x 2^attempt +/- 25 %, capped 8 s, seeded "
                         "per-client RNG), honouring a 429's Retry-After as the minimum sleep "
                         "(max one Retry-After per retry, malformed ignored), up to N times; "
                         "0 = record the refusal as an error (pre-HB-7 behaviour)")
    ap.add_argument("--thinking", action="store_true",
                    help="leave the model's default thinking on (omit reasoning_effort); default off = reasoning_effort none")
    a = ap.parse_args()
    if a.max_503_retries < 0:
        print("--max-503-retries must be >= 0", file=sys.stderr)
        return 2
    try:
        a._turn_gap = parse_turn_gap(a.turn_gap_secs)  # parsed (MIN, MAX) for the rotation
    except argparse.ArgumentTypeError as e:
        print(f"--turn-gap-secs: {e}", file=sys.stderr)
        return 2

    segs = [s.strip() for s in a.segments.split(",") if s.strip()]
    known = {"nopressure", "warmup", "steady", "recovery"}
    if not segs or not set(segs) <= known:
        print(f"bad --segments {segs}; subset of {sorted(known)}", file=sys.stderr)
        return 2
    corpus_paths = [p.strip() for p in a.corpus.split(",") if p.strip()]
    try:
        corpora = [Corpus(p) for p in corpus_paths]
    except (OSError, ValueError) as e:
        print(f"corpus: {e}", file=sys.stderr)
        return 2
    corpus = corpora[0]
    a._probe_corpus = corpus

    try:
        with urllib.request.urlopen(f"{a.base.rstrip('/')}/health", timeout=8) as r:
            r.read(64)
    except Exception as e:  # noqa: BLE001
        print(f"server unreachable at {a.base}: {e}", file=sys.stderr)
        return 1

    a.run_id = a.run_id or uuid.uuid4().hex[:8]
    w = Writer(a.out, a.tag)
    base = a.base.rstrip("/")
    st0 = get_stats(base)
    corpus_hdr = ({"path": corpus_paths[0], "sha256_16": corpus.sha, "chars": len(corpus.text)}
                  if len(corpora) == 1 else
                  {"paths": corpus_paths, "sha256_16": [c.sha for c in corpora],
                   "chars": [len(c.text) for c in corpora],
                   "assignment": "client c uses corpus[c mod n] round-robin"})
    w.emit("header", run_id=a.run_id, base=base, argv=sys.argv[1:], segments=segs,
           corpus=corpus_hdr,
           session_offset="sha256(sid)[:8] big-endian * 7919 mod corpus_chars (deterministic across processes)",
           thinking="on" if a.thinking else "off (reasoning_effort=none on every request)",
           config={k: v for k, v in vars(a).items() if not k.startswith("_") and k != "run_id"
                   and not (k == "turn_gap_secs" and v == "0,0")  # defaults omitted: pre-B5 headers byte-identical
                   and not (k == "max_503_retries" and v == 20)},  # same rule for the HB-7 default
           stats_start=st0.get("host_cache"), stats_error=st0.get("error"))
    if a.turn_gap_secs != "0,0":  # B5 runs only: default output stays byte-identical to pre-B5
        w.emit("turn-gap", segments=segs,
               mode=f"uniform [{a._turn_gap[0]}, {a._turn_gap[1]}] s per client, drawn per visit "
                    f"from the client RNG (seed sha256(run_id + client index)), slept before the "
                    f"client's next steady visit; recorded on each visit's req as turn_gap_s")

    # -- nopressure: fixed small request count; only meaningful on a fresh launch (plan §5).
    # One concurrent request per client per round; np_clients * np_sessions * np_rounds must stay
    # under the bank caps (24+24) for the zero-eviction claim to be checkable.
    if "nopressure" in segs:
        def np_run():
            sessions = [[Session(corpora[c % len(corpora)], f"{a.run_id}-np{c}-{s}", f"np{c}-{s}", a.np_ctx_chars, a.new_chars)
                         for s in range(a.np_sessions)] for c in range(a.np_clients)]
            for rnd in range(a.np_rounds):
                threads = []
                for ci, ss in enumerate(sessions):
                    t = threading.Thread(target=visit, daemon=True,
                                         args=(w, base, ss[rnd % len(ss)], "nopressure", ci, a.decode,
                                               a.timeout, a.thinking),
                                         kwargs={"extra": {"round": rnd},
                                                 "max_503_retries": a.max_503_retries,
                                                 "rng": retry_rng(a.run_id, ci)})
                    t.start()
                    threads.append(t)
                for t in threads:
                    t.join()
        bracket(w, "nopressure", np_run, base)

    # -- rotation sessions (warmup + steady share them so the transcripts grow).
    clients_sessions = [[Session(corpora[c % len(corpora)], f"{a.run_id}-c{c}s{s}", f"c{c}s{s}", a.ctx_chars, a.new_chars)
                         for s in range(a.sessions)] for c in range(a.clients)]
    flat = [s for ss in clients_sessions for s in ss]

    if "warmup" in segs:
        def warm():
            # one cold visit per session, per-client threads (excluded from measurement)
            def one_pass(ci, ss):
                for si, s in enumerate(ss):
                    visit(w, base, s, "warmup", ci, a.decode, a.timeout, thinking=a.thinking,
                          extra={"warm": si}, max_503_retries=a.max_503_retries,
                          rng=retry_rng(a.run_id, ci))

            threads = [threading.Thread(target=one_pass, daemon=True, args=(ci, ss))
                       for ci, ss in enumerate(clients_sessions)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        bracket(w, "warmup", warm, base)

    if "steady" in segs:
        bracket(w, "steady", lambda: steady_phase(w, base, a, clients_sessions, threading.Event()), base)

    if "recovery" in segs:
        r_sessions = flat[:a.recovery_sessions]

        def rec(pass_name, decode):
            for i, s in enumerate(r_sessions):
                visit(w, base, s, pass_name, -1, decode, a.timeout, thinking=a.thinking,
                      extra={"seq": i}, max_503_retries=a.max_503_retries,
                      rng=retry_rng(a.run_id, -1))

        w.emit("idle", segment="recovery", idle_secs=a.idle_secs, stats_before=get_stats(base).get("host_cache"))
        time.sleep(a.idle_secs)
        bracket(w, "recovery1", lambda: rec("recovery1", a.recovery_decode), base)
        if a.observe_secs > 0:
            stop = threading.Event()
            sampler = threading.Thread(target=stats_sampler, daemon=True, args=(w, base, stop, 30, "observe"))
            sampler.start()
            stop.wait(a.observe_secs)
            stop.set()
            sampler.join(timeout=10)
        bracket(w, "recovery2", lambda: rec("recovery2", a.recovery_decode), base)

    st1 = get_stats(base)
    w.emit("footer", stats_end=st1.get("host_cache"), stats_error=st1.get("error"))
    print(f"RUN-DONE {a.tag} -> {a.out}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
