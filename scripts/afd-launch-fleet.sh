#!/usr/bin/env bash
# afd-launch-fleet.sh -- production-candidate bring-up: experts 3,2,1,0 then
# the coordinator. Usage:
#   RANK_HOSTS="hostA hostB hostC hostD" RANK_IPS="ip0 ip1 ip2 ip3" RDMA_DEVICE=<dev> \
#   PEERS=... DEVICE_MAP=... MODEL_DIR=... afd-launch-fleet.sh [--apply]   (dry-run default)
# RANK_HOSTS are ssh targets in rank order; RANK_IPS their fabric addresses in the same
# order (and the same order as the coordinator's PEERS). RDMA_DEVICE is the expert-side
# RDMA device carrying the fabric address (assumed identical across the four Sparks).
set -euo pipefail
apply=0; [[ "${1:-}" == "--apply" ]] && apply=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
read -r -a HOSTS <<<"${RANK_HOSTS:?set RANK_HOSTS (four ssh targets, rank order)}"
read -r -a IPS <<<"${RANK_IPS:?set RANK_IPS (four fabric addresses, rank order)}"
: "${RDMA_DEVICE:?set RDMA_DEVICE (expert-side RDMA device carrying the fabric address)}"
[[ ${#HOSTS[@]} -eq 4 && ${#IPS[@]} -eq 4 ]] || { echo "RANK_HOSTS and RANK_IPS need four entries each" >&2; exit 2; }
rank_ip() { echo "${IPS[$1]}"; }
rank_host() { echo "${HOSTS[$1]}"; }
export RDMA_DEVICE
for r in 3 2 1 0; do
  echo "== rank $r on $(rank_host $r) ($(rank_ip $r))"
  if [[ $apply -eq 1 ]]; then
    ssh -o BatchMode=yes "$(rank_host $r)" "FABRIC_IP=$(rank_ip $r) RDMA_DEVICE=$RDMA_DEVICE bash -s -- $r --apply" \
      < "$SCRIPT_DIR/afd-launch-experts.sh" | tail -1
  else
    FABRIC_IP="$(rank_ip $r)" bash "$SCRIPT_DIR/afd-launch-experts.sh" "$r" | tail -2
  fi
done
echo "== coordinator on this host"
if [[ $apply -eq 1 ]]; then
  bash "$SCRIPT_DIR/afd-launch-coordinator.sh" --apply | tail -2
else
  bash "$SCRIPT_DIR/afd-launch-coordinator.sh" | tail -6
fi
