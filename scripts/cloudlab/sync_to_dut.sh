#!/bin/bash
# Push all cloudlab scripts from the repo to the testbed.
#   dut-side (measure_*, run_sweep, analyze, setup_dut_peers, ...) -> dut:~/
#   gen-side (genload*, setup_gen_clients)                          -> gen:/tmp + gen:~/
# Run from the repo (on the Mac). Override hosts via env if the lease changes:
#   DUT=anasait@<dut>.cloudlab.us GEN=anasait@<gen>.cloudlab.us bash sync_to_dut.sh
set -euo pipefail
DUT=${DUT:-anasait@c220g2-010630.wisc.cloudlab.us}
GEN=${GEN:-anasait@c220g2-010628.wisc.cloudlab.us}
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "[sync] dut-side scripts -> $DUT:~/"
scp -o StrictHostKeyChecking=accept-new \
    measure_*.sh run_sweep.sh analyze_sweep.py setup_dut_peers.sh genload*.sh "$DUT:~/"
ssh "$DUT" 'chmod +x ~/*.sh 2>/dev/null; echo "[dut] scripts ready"'

echo "[sync] gen-side load -> $GEN:/tmp/  (genload_json may be root-owned; routing via dut if so)"
scp genload.sh genload_json.sh "$GEN:/tmp/" 2>/dev/null || \
    ssh "$DUT" 'for f in genload.sh genload_json.sh; do sudo ssh -o StrictHostKeyChecking=no gen "cat > /tmp/$f" < ~/$f; done; echo "[gen] genload*.sh pushed via dut"'
scp setup_gen_clients.sh "$GEN:~/" 2>/dev/null || true
echo "[sync] done"
