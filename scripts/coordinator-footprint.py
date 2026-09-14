#!/usr/bin/env python3
"""Derive the AFD coordinator-resident weight footprint of DeepSeek-V4.1-Flash.

Why this exists: the DS41RT AFD topology keeps only the *non-routed-expert*
weights on the coordinator GPU (attention/CED, embeddings, head, routers,
shared experts, vision, dSpark drafter) and sends the backbone routed experts
to the Sparks. A 32 GB RTX 5090 coordinator is therefore gated by this
footprint. This script computes it from the real safetensors headers, not from
prose.

Two numbers are reported per category:
  * `native`   - bytes as stored in the checkpoint (mixed fp8/bf16/f32 dtypes)
  * `bf16_equiv` - bytes if every floating tensor were materialised in bf16,
                   which is what loaders that dequantise fp8 at load do
                   (measured precedent: glmrt, see PORT-5090.md section 1.2).

Classification is by tensor name only and is deliberately conservative: it
prints the top name patterns so the mapping can be audited rather than
trusted.

Usage: python3 coordinator-footprint.py /path/to/DeepSeek-V4.1-Flash
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections import defaultdict

DTYPE_BYTES = {
    "F64": 8,
    "I64": 8,
    "F32": 4,
    "I32": 4,
    "F16": 2,
    "BF16": 2,
    "F8_E4M3": 1,
    "F8_E5M2": 1,
    "F8_E8M0": 1,
    "I8": 1,
    "U8": 1,
    "I4": 0.5,
    "U4": 0.5,
    "F4": 0.5,
}


def read_header(path: str) -> dict:
    with open(path, "rb") as f:
        n = int.from_bytes(f.read(8), "little")
        return json.loads(f.read(n))


def classify(name: str) -> str:
    n = name.lower()
    pre = "draft " if n.startswith("mtp.") else ""
    if "engram" in n and ".embed." in n:
        return "engram tables (host-mapped, NOT coordinator VRAM)"
    if "experts" in n and "shared" not in n:
        return "draft routed experts (coordinator)" if pre else "routed experts (Spark-side)"
    if "engram" in n:
        return pre + "engram projection (coordinator)"
    if "vision" in n or "spatial" in n or "image" in n or n.startswith("aligner."):
        return pre + "vision tower"
    if "shared_expert" in n or "shared_experts" in n:
        return pre + "shared experts"
    if "router" in n or re.search(r"\.gate(\.|$)", n):
        return pre + "routers/gates"
    if "embed" in n:
        return pre + "embedding"
    if "lm_head" in n or "head" in n:
        return pre + "lm_head/head"
    if "norm" in n:
        return pre + "norms"
    if "attn" in n or "attention" in n or "indexer" in n or "compressor" in n:
        return pre + "attention/indexer"
    if "mlp" in n or "ffn" in n or "proj" in n:
        return pre + "dense mlp / other"
    return pre + "other"


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/models/deepseek-ai/DeepSeek-V4.1-Flash"
    )
    with open(os.path.join(root, "model.safetensors.index.json")) as f:
        index = json.load(f)
    weight_map = index["weight_map"]

    headers: dict[str, dict] = {}
    totals: dict[str, dict] = defaultdict(lambda: {"native": 0, "bf16_equiv": 0, "n": 0})
    patterns: dict[str, dict] = defaultdict(lambda: {"native": 0, "n": 0})
    dtype_bytes: dict[str, int] = defaultdict(int)
    dtype_count: dict[str, int] = defaultdict(int)

    for name, shard in weight_map.items():
        if shard not in headers:
            headers[shard] = read_header(os.path.join(root, shard))
        meta = headers[shard].get(name)
        if meta is None:
            print(f"WARN: {name} absent from {shard} header", file=sys.stderr)
            continue
        dt = meta["dtype"]
        nbytes = meta["data_offsets"][1] - meta["data_offsets"][0]
        nelem = nbytes / DTYPE_BYTES[dt]
        bf16 = int(nelem * 2)
        cat = classify(name)
        totals[cat]["native"] += nbytes
        totals[cat]["bf16_equiv"] += bf16
        totals[cat]["n"] += 1
        dtype_bytes[dt] += nbytes
        dtype_count[dt] += 1
        key = re.sub(r"\d+", "#", name)
        patterns[key]["native"] += nbytes
        patterns[key]["n"] += 1

    gib = 1024 ** 3
    print(f"root: {root}")
    print(f"index total_size: {index.get('metadata', {}).get('total_size', 0) / gib:,.2f} GiB")
    print(f"tensors: {len(weight_map)}\n")

    print("== by category ==")
    order = sorted(totals, key=lambda c: -totals[c]["native"])
    for cat in order:
        t = totals[cat]
        print(
            f"{cat:<46} n={t['n']:<4} native={t['native']/gib:8.2f} GiB  bf16={t['bf16_equiv']/gib:8.2f} GiB"
        )

    coord = [
        c
        for c in totals
        if c
        not in (
            "routed experts (Spark-side)",
            "engram tables (host-mapped, NOT coordinator VRAM)",
        )
    ]
    c_native = sum(totals[c]["native"] for c in coord)
    c_bf16 = sum(totals[c]["bf16_equiv"] for c in coord)
    print(
        f"\ncoordinator-resident weights (excl. Spark routed experts, excl. Engram tables):\n"
        f"  native    = {c_native/gib:.2f} GiB ({c_native/1e9:.2f} GB)\n"
        f"  bf16-equiv= {c_bf16/gib:.2f} GiB ({c_bf16/1e9:.2f} GB)  <-- UNDERSTATES packed FP4:\n"
        f"     I8 expert tensors hold 2 FP4 values/byte, so their true bf16 equivalent is 4x\n"
        f"     their stored bytes, not the 2x used above. Treat bf16-equiv as a lower bound."
    )
    routed = sum(totals[c]["native"] for c in totals if c.startswith("routed"))
    print(f"routed experts (Spark-side) = {routed/gib:.2f} GiB")
    eng = sum(totals[c]["native"] for c in totals if c.startswith("engram"))
    print(f"engram tables (host-mapped)  = {eng/gib:.2f} GiB")
    draft = sum(
        v["native"]
        for k, v in patterns.items()
        if k.lower().startswith("mtp.")
    )
    print(f"  of which dSpark draft/mtp   = {draft/gib:.2f} GiB (native)")

    print("\n== by dtype ==")
    for dt in sorted(dtype_bytes, key=lambda d: -dtype_bytes[d]):
        print(f"{dt:<10} n={dtype_count[dt]:<4} {dtype_bytes[dt]/gib:8.2f} GiB")

    print("\n== top coordinator name patterns (audit the classifier) ==")
    ranked = sorted(
        ((k, v) for k, v in patterns.items() if classify(k) not in ("routed experts (Spark-side)",) and not k.lower().startswith("engram")),
        key=lambda kv: -kv[1]["native"],
    )
    for k, v in ranked[:35]:
        print(f"{v['n']:>4}x {k:<70} {v['native']/gib:8.3f} GiB -> {classify(k)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
