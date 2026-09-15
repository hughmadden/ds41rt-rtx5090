#!/usr/bin/env python3
"""hc-build-corpus.py — deterministic prose/code corpora for the host-cache benchmarks.

Hugh's corpus decision (2026-09-14, bench plan §1.2): prose = the reference kit's
prompts-v1.json categories; code = a pinned repo snapshot. Runs on the coordinator host:

  python3 hc-build-corpus.py \
    --prompts-json /path/to/reference-kit/bench/prompts-v1.json \
    --code-tree /path/to/ds41rt \
    --out-dir /path/to/bench-corpus --min-chars 16000000

Outputs prose.txt, code.txt and *.meta.json (sha256 of every input and output, git REV,
tiling factor — recorded because tiled text inflates Engram n-gram hit rates; bench plan §9).
Fail-closed: unparseable JSON, zero collected strings or a missing tree exit non-zero rather
than emitting a silent fallback. Corpus bytes are not committed; the meta files are.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

AEST = timezone(timedelta(hours=10))
CODE_EXT = {".rs", ".py", ".c", ".cc", ".cpp", ".h", ".hpp", ".sh", ".toml", ".cu", ".cuh"}
MAX_FILE = 2 * 1024 * 1024


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode()).hexdigest()


def collect_strings(node, out):
    """Recursive, insertion-order walk collecting string values >= 40 chars."""
    if isinstance(node, str):
        if len(node) >= 40:
            out.append(node)
    elif isinstance(node, dict):
        for k in sorted(node):
            collect_strings(node[k], out)
    elif isinstance(node, list):
        for v in node:
            collect_strings(v, out)


def build_prose(prompts_json, min_chars):
    with open(prompts_json, encoding="utf-8") as fh:
        data = json.load(fh)
    strings = []
    collect_strings(data, strings)
    if not strings:
        raise SystemExit(f"REFUSED: no strings >= 40 chars found in {prompts_json}")
    unit = "\n\n".join(strings)
    tiles = max(1, -(-min_chars // len(unit)))
    text = (unit + "\n\n") * tiles
    return text[:max(min_chars, len(unit))], {
        "source": prompts_json, "source_sha256": sha256(prompts_json),
        "strings": len(strings), "unit_chars": len(unit), "tiles": tiles,
    }


def file_list(tree):
    try:
        out = subprocess.run(["git", "-C", tree, "ls-files"], capture_output=True, text=True, check=True)
        return [os.path.join(tree, p) for p in out.stdout.splitlines()], out.stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        files = []
        for root, dirs, names in os.walk(tree):
            dirs[:] = sorted(d for d in dirs if d not in {".git", "target", "node_modules", "__pycache__"})
            for n in sorted(names):
                files.append(os.path.join(root, n))
        return files, None


def build_code(tree, min_chars):
    if not os.path.isdir(tree):
        raise SystemExit(f"REFUSED: code tree missing: {tree}")
    rev = None
    try:
        rev = subprocess.run(["git", "-C", tree, "rev-parse", "HEAD"],
                             capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    files, _ = file_list(tree)
    files = sorted(f for f in files if os.path.splitext(f)[1] in CODE_EXT
                   and os.path.isfile(f) and os.path.getsize(f) <= MAX_FILE)
    if not files:
        raise SystemExit(f"REFUSED: no code files under {tree}")
    parts, used = [], 0
    for f in files:
        rel = os.path.relpath(f, tree)
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except OSError:
            continue
        parts.append(f"\n==== {rel} ====\n{body}")
        used += len(body)
        if used >= min_chars:
            break
    unit = "".join(parts)
    tiles = max(1, -(-min_chars // len(unit)))
    text = (unit + "\n") * tiles
    return text[:max(min_chars, len(unit))], {
        "tree": tree, "git_rev": rev, "files_used": len(parts), "unit_chars": len(unit), "tiles": tiles,
    }


def write(out_dir, name, text, meta):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    meta = {**meta, "output": path, "output_sha256": sha256_text(text), "chars": len(text),
            "built_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "built_aest": datetime.now(AEST).isoformat(timespec="seconds")}
    mpath = os.path.join(out_dir, name + ".meta.json")
    with open(mpath, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=1)
    print(f"{path}  {len(text)} chars  sha256={meta['output_sha256'][:16]}  tiles={meta['tiles']}")
    return mpath


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prompts-json", required=True)
    ap.add_argument("--code-tree", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--min-chars", type=int, default=16_000_000)
    a = ap.parse_args()
    text, meta = build_prose(a.prompts_json, a.min_chars)
    write(a.out_dir, "prose.txt", text, meta)
    text, meta = build_code(a.code_tree, a.min_chars)
    write(a.out_dir, "code.txt", text, meta)
    return 0


if __name__ == "__main__":
    sys.exit(main())
