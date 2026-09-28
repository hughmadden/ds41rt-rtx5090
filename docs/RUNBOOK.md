# Runbook: build, stage, preflight, launch, verify, roll back

Every launcher is dry-run by default and prints the exact `docker run` it would execute.
Nothing here writes into the model directory. The only destructive step is the optional
Engram-tier script, which formats a device and refuses if that device has partitions or mounts.

## 0. Build the coordinator on the 5090 host

```sh
git clone https://github.com/tpurtell/ds41rt       # no --recursive: the script initialises the pinned submodules
REPO=$PWD/ds41rt scripts/afd-build-coordinator.sh  # PATCHES=none for upstream v15 unchanged
```

Three steps, mirroring upstream `build.sh`: dev image, GPU-enabled artifact compile (the AOT
export reads this GPU's SM count here), release image. The GPU must be free for step 2. Before
step 1 the script checks out v15 (`bd06bec`), applies `patches/` (HEAD must become `51b85c8b`; `27ff8c73` before release 2.1.0),
and verifies the SparkInfer (`7fcc094e`) and XGrammar sources. Expect the log to print
`physical_sms = 170` for both AOT manifests. Output: `ds41rt-coordinator-rtx5090:v15`.

```sh
docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' ds41rt-coordinator-rtx5090:v15
docker run --rm --entrypoint python3 ds41rt-coordinator-rtx5090:v15 -c \
  'import json;print(json.load(open("/opt/ds41rt/share/V41_FP8_AOT.json"))["physical_sms"])'
```

On our 5090 host the dev image built in under a minute from a cached v3 dev image (upstream's
`Dockerfile.dev` did not change between v3 and v15), and the export plus release image took 3.5
minutes.

## 1. Prove the memory plan and readiness with no Sparks

```sh
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-plan-probe.sh p1 80 1 on "" 97%
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-ready-probe.sh     # READY in ~4 s
```

Both use loopback peers; no expert is contacted (the RoCE client connects lazily). Verified on v1;
not re-run on v15.

## 2. Stage the Sparks

On each Spark: `docker pull ghcr.io/tpurtell/ds41rt-spark-expert:v15`. If the pull stalls (for us
three of four Sparks stalled on GHCR with layers "Waiting" and "Retrying"), copy the image from a
Spark that has it over the fabric, `docker save ghcr.io/tpurtell/ds41rt-spark-expert:v15 | ssh
<other spark> docker load` (about two minutes each; the image ID must read `sha256:0a6c0fae…`).
Make the full
48-shard checkpoint reachable at a local path (`MODEL_DIR`, default `/models/DeepSeek-V4.1-Flash`).
Every rank reads its routed slices out of all 48 shards, so all must exist, though each rank
reads only about 80 GB. Upstream's own route is one copy on a head node exported read-only over
NFS; a local copy per Spark also works. Each Spark needs about 100 GiB of free unified memory at
launch: if something else is running, stop it and wait for memory to recover.

## 3. Preflight, read-only

```sh
SPARK_HOSTS="hostA hostB hostC hostD" MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-preflight.sh
```

Checks the coordinator image's revision parity and AOT SM count, the GPU, the model snapshot,
the optional Engram tier, the API port, and per Spark: the expert image, the 48 shards, port
19441, memory headroom, stale containers. Prints GO or NO-GO with the exact prep commands.

## 4. Launch, worker-first

Per Spark, ranks 3, 2, 1, 0:

```sh
FABRIC_IP=<this Spark's fabric address> RDMA_DEVICE=<its RDMA device> \
  scripts/afd-launch-experts.sh <rank>            # dry run
  scripts/afd-launch-experts.sh <rank> --apply    # start
```

Then the coordinator:

```sh
PEERS=<ip0>:19441,<ip1>:19441,<ip2>:19441,<ip3>:19441 \
DEVICE_MAP=<coordinator fabric ip>=<coordinator rdma device> \
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-launch-coordinator.sh --apply
```

`scripts/afd-launch-fleet.sh` does both from the coordinator host over ssh, given
`RANK_HOSTS`, `RANK_IPS`, `RDMA_DEVICE`, `PEERS`, `DEVICE_MAP`, `MODEL_DIR`.

On v15 each expert rank listened on 19441 after 30-34 s and the coordinator answered `/health`
10 s after starting (v1: 5 to 6 minutes per rank with a cold page cache, about 25 s for the
coordinator). Then `curl http://<coordinator>:8000/v1/models`.

If the coordinator's RoCE link is an LACP bond, check the port balance before measuring anything
(`GATES.md` §5) and restart the coordinator until the port-0 share is 42-58%.

## 5. Verify before you benchmark

A one-word coherence prompt, then a 1k and an 8k completion, then a 32k and a 131k prompt with
unique content at temperature 0. The response `usage` block reports prompt cache hits and
misses, and `system_fingerprint` should read `ds41rt-native-fp4-kv-dspark`. Then the v15 rows:
- a streamed request with `stream_options.include_usage`, sent twice: the last chunk before
  `[DONE]` has `choices: []` and, on the repeat, `usage.prompt_tokens_details.cached_tokens` equal
  to the prompt (`patches/0001`);
- `temperature 0.7` with a `seed`, sent twice: identical text, and a different seed differs;
- the model thinks by default; `reasoning_effort: "none"` answers directly.

Only then run the ladder and the bench.

## 6. Roll back

All containers run with `--restart no`. `docker rm -f` on the coordinator and each rank returns
every host to its prior state. To keep a previous version for rollback, stop its containers and
launch the new ones under other names (`NAME=...`); the launchers replace a container of the same
name only with `--apply` (the coordinator launcher before this release removed it on a dry run). The Engram-tier staging, if used, is additive and reversible
(unmount, remove the fstab line).
