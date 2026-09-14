# Runbook: build, stage, preflight, launch, verify, roll back

Every launcher is dry-run by default and prints the exact `docker run` it would execute.
Nothing here writes into the model directory. The only destructive step is the optional
Engram-tier script, which formats a device and refuses if that device has partitions or mounts.

## 0. Build the coordinator on the 5090 host

```sh
git clone --recursive https://github.com/tpurtell/ds41rt
REPO=$PWD/ds41rt scripts/afd-build-coordinator.sh
```

Three steps, mirroring upstream `build.sh`: dev image, GPU-enabled artifact compile (the AOT
export reads this GPU's SM count here), release image. Expect the log to print
`physical_sms = 170`. Output: `ds41rt-coordinator-rtx5090:v1`. Confirm parity with the published
image on every label except the SM count:

```sh
docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' ds41rt-coordinator-rtx5090:v1
docker run --rm --entrypoint python3 ds41rt-coordinator-rtx5090:v1 -c \
  'import json;print(json.load(open("/opt/ds41rt/share/V41_FP8_AOT.json"))["physical_sms"])'
```

## 1. Prove the memory plan and readiness with no Sparks

```sh
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-plan-probe.sh p1 80 1 on "" 97%
MODEL_DIR=/path/to/DeepSeek-V4.1-Flash scripts/afd-ready-probe.sh     # READY in ~4 s
```

Both use loopback peers; no expert is contacted (the RoCE client connects lazily).

## 2. Stage the Sparks

On each Spark: `docker pull ghcr.io/tpurtell/ds41rt-spark-expert:v1`, and make the full
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

Expert ranks take 5 to 6 minutes to load (40 layers, about 0.7 s per layer plus I/O); the
coordinator about 25 s. Then `curl http://<coordinator>:8000/v1/models`.

## 5. Verify before you benchmark

A one-word coherence prompt, then a 1k and an 8k completion, then a 32k and a 131k prompt with
unique content at temperature 0. The response `usage` block reports prompt cache hits and
misses, and `system_fingerprint` should read `ds41rt-native-fp4-kv-dspark`. Only then run the
ladder and the bench.

## 6. Roll back

All containers run with `--restart no`. `docker rm -f` on the coordinator and each rank returns
every host to its prior state. The Engram-tier staging, if used, is additive and reversible
(unmount, remove the fstab line).
