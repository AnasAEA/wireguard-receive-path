#!/bin/bash
# Re-bootstrap a FRESH CloudLab instantiation (blank UBUNTU22 image) into a working
# WireGuard receive-path testbed: packages, module build, tunnel + N peers.
# Run from the repo on the Mac. Override hosts if the lease changed:
#   DUT=anasait@<dut>.cloudlab.us GEN=anasait@<gen>.cloudlab.us bash bootstrap_testbed.sh [N]
#
# What a fresh instantiation loses (and this restores): iperf3/wireguard-tools/linux-source
# packages, the built wireguard_trigger.ko, all ~/scripts, the dut key, gen namespaces,
# wg0 + peers. The 10G experiment NIC (enp6s0f0, 192.168.1.1 dut / .2 gen) and node-to-node
# root SSH come pre-configured by the profile.
set -euo pipefail
DUT=${DUT:-anasait@c220g2-011319.wisc.cloudlab.us}
GEN=${GEN:-anasait@c220g2-011315.wisc.cloudlab.us}
N=${1:-8}
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SSH="ssh -o StrictHostKeyChecking=no"

echo ">> Using DUT=$DUT"
echo ">>       GEN=$GEN"
echo ">> A fresh CloudLab instantiation gets NEW node IDs — if these are wrong, re-run as:"
echo ">>   DUT=anasait@<dut>.cloudlab.us GEN=anasait@<gen>.cloudlab.us bash $0 ${1:-8}"
sleep 2

echo "== [1/6] install packages =="
$SSH "$DUT" 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iperf3 wireguard-tools linux-source-5.15.0 netperf sockperf >/tmp/apt.log 2>&1; echo dut: iperf3=$(which iperf3) netperf=$(which netserver) sockperf=$(which sockperf) src=$(ls /usr/src/linux-source-*/*.tar.bz2 2>/dev/null)'
$SSH "$GEN" 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iperf3 wireguard-tools netperf sockperf >/tmp/apt.log 2>&1; echo gen: iperf3=$(which iperf3) netperf=$(which netperf) sockperf=$(which sockperf) wg=$(which wg)'

echo "== [2/6] push scripts =="
DUT="$DUT" GEN="$GEN" bash "$HERE/sync_to_dut.sh"

echo "== [3/6] push module source + build wireguard_trigger.ko (pristine 5.15 + our 5 files) =="
$SSH "$DUT" 'mkdir -p ~/wg515-trigger'
scp -o StrictHostKeyChecking=no "$REPO"/build/wg515-trigger/{main.c,peer.c,peer.h,queueing.h,receive.c} "$DUT:~/wg515-trigger/"
$SSH "$DUT" 'set -e
  rm -rf ~/wg_trigger && mkdir -p ~/wg_trigger && cd ~/wg_trigger
  tar xjf /usr/src/linux-source-5.15.0/linux-source-5.15.0.tar.bz2 --strip-components=1 \
      linux-source-5.15.0/drivers/net/wireguard
  cp ~/wg515-trigger/{main.c,peer.c,peer.h,queueing.h,receive.c} drivers/net/wireguard/
  make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/net/wireguard modules 2>&1 | tail -2
  cp drivers/net/wireguard/wireguard.ko ~/wireguard_trigger.ko
  echo "built srcversion=$(modinfo -F srcversion ~/wireguard_trigger.ko)"'

echo "== [4/6] dut key + load module (modprobe pulls deps, then swap in ours) =="
DUT_PUB=$($SSH "$DUT" 'set -e
  sudo mkdir -p /etc/wireguard
  [ -f /etc/wireguard/dut.key ] || { wg genkey | sudo tee /etc/wireguard/dut.key >/dev/null; sudo chmod 600 /etc/wireguard/dut.key; }
  sudo ip link del wg0 2>/dev/null || true
  sudo modprobe wireguard; sudo rmmod wireguard; sudo insmod ~/wireguard_trigger.ko
  sudo cat /etc/wireguard/dut.key | wg pubkey')
echo "DUT_PUB=$DUT_PUB"

echo "== [5/6] gen client namespaces ($N) + dut peers =="
$SSH "$GEN" "chmod +x ~/setup_gen_clients.sh; sudo bash ~/setup_gen_clients.sh $N $DUT_PUB 192.168.1.1" | tail -2
$SSH "$DUT" "sudo REFRESH=1 bash ~/setup_dut_peers.sh $N" | tail -2

echo "== [6/6] verify handshakes (want $N) =="
$SSH "$GEN" "for i in \$(seq 0 $((N-1))); do sudo ip netns exec ns_c\$i ping -c1 -W2 10.0.0.1 >/dev/null 2>&1 & done; wait"
HS=$($SSH "$DUT" 'sudo wg show wg0 | grep -c "latest handshake"')
echo "handshakes=$HS  (testbed ready; run measure_*.sh on dut)"
