#!/usr/bin/env python3
"""hc-mock-server.py — offline mock of the DS41RT coordinator API for harness validation.

Emulates just enough of /health, /v1/chat/completions (SSE + usage) and /v1/stats
({"host_cache": ...}) to exercise hc-rotate.py and hc-report.py end to end on a bench host with zero fleet
contact. Cache emulation: a 24-key device LRU + an unbounded host store keyed by the session's
first user message (the salt), so warmup misses, steady-state host-hit restores, device_evictions
and the recovery passes all produce plausible counter motion. Timing is synthetic and fast.

  --legacy-metrics  drop the HC-7 fields (device_evictions, store_latency_*) to test ABSENT paths
  --stats-404       /v1/stats returns 404 (emulates the v2 image with no stats route)
  --quota-bytes N   report this host-cache quota (default 24 GiB; 0 emulates the cache-OFF arm
                    so hc-matrix.sh arm gating can be tested offline)
  --reasoning-first N  stream N reasoning_content deltas before the content deltas, with a
                    0.5 s gap between the last reasoning delta and the first content delta so a
                    client that (wrongly) takes TTFT from the first content delta is >0.5 s late.
                    Every request is also checked server-side for a top-level reasoning_effort
                    field; the counts req_seen / req_missing_reasoning_effort land in /v1/stats.
  --mock-503-every N  refuse every Nth /v1/chat/completions request with HTTP 503 (the
                    coordinator's concurrency-limit backpressure); the refused count lands in
                    /v1/stats as req_503 so a test can check retry conservation. HB-8: the
                    refusal status is selectable with --mock-status (default 503, the rc6
                    front door's refusal is 429) and --mock-retry-after S adds a
                    Retry-After: S header to refused responses (rc6 queue-wait hint).
Not a correctness model of the engine — plumbing only.
"""
import argparse
import hashlib
import json
import threading
import time
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BUCKETS = 8
LOCK = threading.Lock()
STATE = {
    "device": OrderedDict(),          # key -> tokens (LRU, max 24)
    "host": {},                       # key -> tokens
    "c": {k: 0 for k in (
        "stores_issued", "stores_completed", "stores_replaced", "stores_failed", "store_drain_timeouts",
        "stores_skipped", "store_bytes", "pages_copied", "pages_shared", "lookups", "host_hits",
        "restores", "restore_bytes", "restore_timeouts", "restore_failures", "evict_waits",
        "evict_wait_ns", "evict_drops_uncached", "host_evictions", "host_evicted_bytes",
        "device_evictions", "req_seen", "req_missing_reasoning_effort", "req_503")},
    "restore_latency_buckets": [0] * BUCKETS,
    "store_latency_buckets": [0] * BUCKETS,
    "restore_latency_sum_ns": 0,
    "store_latency_sum_ns": 0,
    "bytes_used": 0,
    "quota_bytes": 25769803776,
}
OPTS = {"legacy": False, "stats404": False, "reasoning_first": 0, "quota_bytes": 25769803776,
        "mock_503_every": 0, "mock_status": 503, "mock_retry_after": None}


def bump_bucket(buckets, sum_key, ns, state):
    for i, bound in enumerate([1e6, 5e6, 1e7, 5e7, 1e8, 5e8, 1e9]):
        if ns <= bound:
            buckets[i] += 1
            break
    else:
        buckets[-1] += 1
    state[sum_key] += ns


def stats_payload():
    with LOCK:
        s = STATE
        snap = dict(s["c"])
        snap["restore_latency_buckets"] = list(s["restore_latency_buckets"])
        snap["restore_latency_sum_ns"] = s["restore_latency_sum_ns"]
        snap["resident_snapshots"] = len(s["host"])
        snap["bytes_used"] = s["bytes_used"]
        snap["quota_bytes"] = OPTS["quota_bytes"]
        if OPTS["legacy"]:
            snap.pop("device_evictions", None)
        else:
            snap["store_latency_sum_ns"] = s["store_latency_sum_ns"]
            snap["store_latency_buckets"] = list(s["store_latency_buckets"])
        return {"host_cache": snap}


def handle_chat(body):
    """Returns (prompt_tokens, hit_tokens, miss_tokens, ttft_delay_s)."""
    msgs = body.get("messages") or []
    texts = [m.get("content", "") for m in msgs]
    prompt_chars = sum(len(t) for t in texts)
    prompt_tokens = max(1, prompt_chars // 4)
    key = hashlib.sha1(texts[0][:200].encode()).hexdigest() if texts else "?"
    with LOCK:
        s = STATE
        dev, host, c = s["device"], s["host"], s["c"]
        if key in dev:
            dev.move_to_end(key)
            hit = min(dev[key], prompt_tokens)
            miss = prompt_tokens - hit
        else:
            c["lookups"] += 1
            if key in host:
                c["host_hits"] += 1
                c["restores"] += 1
                hit = min(host[key], prompt_tokens)
                miss = prompt_tokens - hit
                c["restore_bytes"] += hit * 890
                bump_bucket(s["restore_latency_buckets"], "restore_latency_sum_ns", 8_000_000, s)
                dev[key] = prompt_tokens
            else:
                hit = 0
                miss = prompt_tokens
                dev[key] = prompt_tokens
        while len(dev) > 24:
            dev.popitem(last=False)
            c["device_evictions"] += 1
        # write-behind store of the completed turn (on-retain)
        host[key] = prompt_tokens
        c["stores_issued"] += 1
        c["stores_completed"] += 1
        c["store_bytes"] += miss * 890
        c["pages_copied"] += 1
        bump_bucket(s["store_latency_buckets"], "store_latency_sum_ns", 4_000_000, s)
        add = miss * 890
        s["bytes_used"] += add
        while s["bytes_used"] > s["quota_bytes"] and host:
            k0 = next(iter(host))
            host.pop(k0)
            s["bytes_used"] = max(0, s["bytes_used"] - add)
            c["host_evictions"] += 1
            c["host_evicted_bytes"] += add
    return prompt_tokens, hit, miss, 0.02 + miss * 2e-5


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, payload, ctype="application/json", retry_after=None):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(data)))
        if retry_after is not None:
            self.send_header("Retry-After", str(retry_after))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, b"ok", "text/plain")
        elif self.path == "/v1/stats":
            if OPTS["stats404"]:
                self._send(404, {"error": "not found"})
            else:
                self._send(200, stats_payload())
        elif self.path == "/v1/models":
            self._send(200, {"data": [{"id": "deepseek-ai/DeepSeek-V4.1-Flash"}]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            return self._send(404, {"error": "not found"})
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        with LOCK:
            STATE["c"]["req_seen"] += 1
            if "reasoning_effort" not in body:
                STATE["c"]["req_missing_reasoning_effort"] += 1
            # HB-7/HB-8: every Nth request is refused (503 on rc4, 429 on the rc6 front
            # door), emulating the coordinator's concurrency backpressure; refused requests
            # skip cache emulation. req_503 keeps its historical key name but counts
            # refusals of either status (conservation: served refusals == counted retries).
            refuse = (OPTS["mock_503_every"] > 0
                      and STATE["c"]["req_seen"] % OPTS["mock_503_every"] == 0)
            if refuse:
                STATE["c"]["req_503"] += 1
        if refuse:
            return self._send(OPTS["mock_status"],
                              {"error": f"backpressure (mock {OPTS['mock_status']})"},
                              retry_after=OPTS["mock_retry_after"])
        prompt_tokens, hit, miss, delay = handle_chat(body)
        max_tokens = int(body.get("max_tokens") or 8)
        time.sleep(delay)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()

        def chunk(obj):
            data = f"data: {json.dumps(obj)}\n\n".encode()
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.flush()

        try:
            rf = OPTS["reasoning_first"]
            if rf:
                # reasoning deltas stream immediately after the prefill delay; the 0.5 s gap
                # before content makes a first-content-delta TTFT measurably wrong.
                for i in range(rf):
                    chunk({"choices": [{"delta": {"reasoning_content": f"think{i} "}, "index": 0}]})
                time.sleep(0.5)
            for i in range(max_tokens):
                chunk({"choices": [{"delta": {"content": f"tok{i} "}, "index": 0}]})
                time.sleep(0.004)
            chunk({"choices": [], "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": max_tokens,
                                            "prompt_cache_hit_tokens": hit, "prompt_cache_miss_tokens": miss}})
            done = b"data: [DONE]\n\n"
            self.wfile.write(f"{len(done):x}\r\n".encode() + done + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8791)
    ap.add_argument("--legacy-metrics", action="store_true")
    ap.add_argument("--stats-404", action="store_true")
    ap.add_argument("--reasoning-first", type=int, default=0,
                    help="stream N reasoning_content deltas before content (with a 0.5 s gap)")
    ap.add_argument("--quota-bytes", type=int, default=25769803776,
                    help="host-cache quota to report in /v1/stats (0 emulates the cache-OFF arm)")
    ap.add_argument("--mock-503-every", type=int, default=0, metavar="N",
                    help="refuse every Nth chat request with backpressure (default status 503)")
    ap.add_argument("--mock-status", type=int, default=503, metavar="CODE",
                    help="status for the --mock-503-every refusal (503 or 429; default 503)")
    ap.add_argument("--mock-retry-after", type=int, default=None, metavar="S",
                    help="add Retry-After: S to refused responses (rc6 queue-wait hint)")
    a = ap.parse_args()
    OPTS["legacy"] = a.legacy_metrics
    OPTS["stats404"] = a.stats_404
    OPTS["reasoning_first"] = a.reasoning_first
    OPTS["quota_bytes"] = a.quota_bytes
    OPTS["mock_503_every"] = max(0, a.mock_503_every)
    if a.mock_status not in (503, 429):
        ap.error("--mock-status must be 503 or 429")
    OPTS["mock_status"] = a.mock_status
    OPTS["mock_retry_after"] = a.mock_retry_after
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"mock listening on 127.0.0.1:{a.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
