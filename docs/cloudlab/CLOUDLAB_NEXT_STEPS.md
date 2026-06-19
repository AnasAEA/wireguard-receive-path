# CloudLab — What To Do Right Now

> Hands-on walkthrough for the live testbed. Copy blocks from here.
> Recipe: `CLOUDLAB_EXPERIMENTS_PLAN.md`. Results: `CLOUDLAB_EXPERIMENTS_LOG.md`.

**Live nodes (instantiation #1, lease extended 2026-06-17):**

| Role | Node | SSH |
|------|------|-----|
| `dut` (instrumented receiver) | c220g2-011308 (Wisc) | `ssh anasait@c220g2-011308.wisc.cloudlab.us` |
| `gen` (load generator) | c220g2-011310 (Wisc) | `ssh anasait@c220g2-011310.wisc.cloudlab.us` |

**Done:** E0.1 instantiate · E0.2 verify HW/NIC/BTF · E0.6 symbols · E0.4 tunnel ·
E0.3 build stock+patched modules · E1 stock pre-check (EoI reproduced, 35.8% wasted
@1peer) · E1 1-peer A/B (no effect at 1 peer, as expected) · E0.5 multi-peer up
(8/8 peers handshake).

**Multi-peer A/B done + DIAGNOSED.** Stock 33.0% vs patched 33.2% wasted @8 (null).
Counter build: fix fires (skips 9.4% of wakes) but `napi_schedule` is ~63% no-op
under load → gating it can't help on a real NIC. **KEY RESULT** (see log).
**Now: pivot to the cost model (Phase C)** to design a poll/delivery-level trigger.
See the Phase C section below; the diagnostic section is kept for reference.

Facts: experiment NIC `enp6s0f1` (192.168.1.1 dut / 192.168.1.2 gen). Kernel
5.15.0-177. Modules: `~/wireguard_stock.ko` (`81233F6…`), `~/wireguard_patched.ko`
(`069999A…`). A/B swap: `wg-quick down wg0; rmmod wireguard; insmod ~/wireguard_<v>.ko`.
DUT pub `8+ROmIIc9bFQ74dzb9nmENZ/7vxW3RUcmv5tOOIA2j8=`.

---

# ▶ DIAGNOSTIC — does the fix actually fire? (run now)

Rebuild patched with two counters: `wg_dbg_sched` (wake taken) and `wg_dbg_skip`
(wake skipped because head not ready), exposed as module params.
**skip ≈ 0 → fix is a no-op here; skip ≫ 0 → fires but doesn't cut wasted polls.**

## Step 1 — inject counters (on dut, in the source tree)
```bash
cd ~/linux-source-5.15.0
python3 - <<'PY'
b="drivers/net/wireguard"
q=open(b+"/queueing.h").read()
assert q.count("napi_schedule(&peer->napi);")==1, "queueing.h not in patched state"
q=q.replace(
  "static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb, enum packet_state state)",
  "extern unsigned long wg_dbg_sched, wg_dbg_skip;\nstatic inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb, enum packet_state state)",1)
q=q.replace(
  "napi_schedule(&peer->napi);",
  "{ wg_dbg_sched++; napi_schedule(&peer->napi); } else wg_dbg_skip++;",1)
open(b+"/queueing.h","w").write(q)
m=open(b+"/main.c").read()
assert "wg_dbg_sched" not in m, "main.c already edited"
inj=("unsigned long wg_dbg_sched, wg_dbg_skip;\n"
     "module_param(wg_dbg_sched, ulong, 0644);\n"
     "module_param(wg_dbg_skip, ulong, 0644);\n\n")
m=m.replace("static int __init", inj+"static int __init",1)
open(b+"/main.c","w").write(m)
print("diag counters injected")
PY
```

## Step 2 — build the diag module (on dut)
```bash
make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/net/wireguard modules 2>&1 | tail -4
cp drivers/net/wireguard/wireguard.ko ~/wireguard_diag.ko
modinfo ~/wireguard_diag.ko | grep -E 'srcversion|parm'
```

## Step 3 — run at 8 peers and read counters (on dut)
```bash
sudo bash ~/measure_one.sh diag 8
echo "sched=$(cat /sys/module/wireguard/parameters/wg_dbg_sched)"
echo "skip=$(cat /sys/module/wireguard/parameters/wg_dbg_skip)"
```

Report: the `modinfo` parm lines, `WASTED/USEFUL`, and `sched=`/`skip=`.
(Counters are plain `unsigned long`, raced across cores → slight undercount; fine for
"~0" vs "millions".)

**RESULT (2026-06-19):** sched=6,778,058 skip=701,460 → fix skips 9.4% of wakes
(fires!), but wasted polls unchanged because napi_schedule is ~63% no-op under load
(7.48M wake-attempts → 2.73M actual polls). Gating napi_schedule is the wrong lever
on a real NIC. → pivot to Phase C.

---

# ▶ Phase C — Cost model (run now)

Goal: quantify what a poll costs so the batching-aware trigger can act at the
poll/delivery level. `measure_cost.sh` captures `T_decrypt` (E2) and the poll
duration vs work_done → `C_poll`/`C_deliver` (E4) in one run.

## Create the cost probe (on dut)
```bash
cat > ~/measure_cost.sh <<'EOF'
#!/bin/bash
set -uo pipefail
MOD=${1:?usage: measure_cost.sh stock|patched|diag N [DUR] [STREAMS] [GEN]}
N=${2:?need N}
DUR=${3:-20}
STREAMS=${4:-4}
GEN=${5:-gen}
KO="$HOME/wireguard_${MOD}.ko"
ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null
sleep 1
for i in $(seq 0 $((N-1))); do
    iperf3 -s -p $((5201+i)) -D
done
ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload.sh $N $DUR $STREAMS" &
LOAD=$!
DURP=$((DUR+3))
bpftrace -e '
kprobe:decrypt_packet      { @ds[tid] = nsecs; }
kretprobe:decrypt_packet /@ds[tid]/ {
    @T_decrypt_ns = hist(nsecs - @ds[tid]);
    delete(@ds[tid]);
}
kprobe:wg_packet_rx_poll   { @ps[tid] = nsecs; }
kretprobe:wg_packet_rx_poll /@ps[tid]/ {
    $d = nsecs - @ps[tid];
    @poll_avg_ns[retval] = avg($d);
    @poll_cnt[retval]    = count();
    delete(@ps[tid]);
}
interval:s:'"$DURP"' {
    print(@T_decrypt_ns);
    print(@poll_avg_ns);
    print(@poll_cnt);
    exit();
}'
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT cost module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
EOF
```

## Run baseline cost model (on dut)
```bash
sudo bash ~/measure_cost.sh stock 8
```

Read-out:
- `@T_decrypt_ns` → median decrypt time (E2).
- `@poll_avg_ns[0]` = **C_poll** (cost of a wasted poll). × 922k wasted polls = CPU
  time the EoI burns.
- `@poll_avg_ns[k]` rising with k → slope = **C_deliver** (per-packet in-poll cost).
- `@poll_cnt[k]` = weighting (how many polls delivered k).

Repo copy: `scripts/cloudlab/measure_cost.sh`.

**RESULT (stock @8, 2026-06-19):** T_decrypt ~5–6µs; C_poll ~1.0µs; delivery setup
~3.6µs; C_deliver ~1.66µs; batches bottom-heavy (most polls deliver 0–4). See log.

---

# ▶ Phase C finishers — clean C_poll + C_stack + Δ_complete

Two more runs to complete the cost model (kept separate so probe overhead doesn't
inflate the poll timings).

## Create both probes (on dut)
```bash
cat > ~/measure_pollcost.sh <<'EOF'
#!/bin/bash
set -uo pipefail
MOD=${1:?}; N=${2:?}; DUR=${3:-20}; STREAMS=${4:-4}; GEN=${5:-gen}
KO="$HOME/wireguard_${MOD}.ko"
ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null
sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload.sh $N $DUR $STREAMS" &
LOAD=$!
DURP=$((DUR+3))
bpftrace -e '
kprobe:wg_packet_rx_poll   { @ps[tid] = nsecs; }
kretprobe:wg_packet_rx_poll /@ps[tid]/ {
    $d = nsecs - @ps[tid];
    @poll_avg_ns[retval] = avg($d);
    @poll_cnt[retval]    = count();
    delete(@ps[tid]);
}
interval:s:'"$DURP"' { print(@poll_avg_ns); print(@poll_cnt); exit(); }'
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT pollcost module=$MOD src=$SRC N=$N"
EOF

cat > ~/measure_gro.sh <<'EOF'
#!/bin/bash
set -uo pipefail
MOD=${1:?}; N=${2:?}; DUR=${3:-20}; STREAMS=${4:-4}; GEN=${5:-gen}
KO="$HOME/wireguard_${MOD}.ko"
ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null
sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload.sh $N $DUR $STREAMS" &
LOAD=$!
DURP=$((DUR+3))
bpftrace -e '
kprobe:napi_gro_receive   { @gs[tid] = nsecs; }
kretprobe:napi_gro_receive /@gs[tid]/ { @gro_ns = hist(nsecs - @gs[tid]); delete(@gs[tid]); }
kretprobe:decrypt_packet {
    if (@dl[cpu]) { @delta_ns = hist(nsecs - @dl[cpu]); }
    @dl[cpu] = nsecs;
}
interval:s:'"$DURP"' { print(@gro_ns); print(@delta_ns); clear(@dl); exit(); }'
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT gro module=$MOD src=$SRC N=$N"
EOF
```

## Run both (on dut)
```bash
sudo bash ~/measure_pollcost.sh stock 8
sudo bash ~/measure_gro.sh stock 8
```

Read-out:
- `measure_pollcost`: clean `@poll_avg_ns[0]` = **C_poll**, slope = **C_deliver**
  (no decrypt-probe inflation).
- `measure_gro`: `@gro_ns` = per-packet GRO/stack cost (**C_stack** component);
  `@delta_ns` = per-core gap between decrypt completions (decrypt cadence → bounds the
  delay a trigger could afford).

Repo copies: `scripts/cloudlab/measure_pollcost.sh`, `measure_gro.sh`.

---

# ▶ E0.5 — Multi-peer bring-up (verify at N=8)

## Step 1 — node-to-node SSH (already verified ✓)
```bash
# on dut:
sudo ssh -o StrictHostKeyChecking=no gen hostname     # should print gen's hostname
```

## Step 2 — on GEN: create N client namespaces
```bash
cat > ~/setup_gen_clients.sh <<'EOF'
#!/bin/bash
set -euo pipefail
N=${1:?usage: setup_gen_clients.sh N [DUT_PUB] [DUT_LINK_IP]}
DUT_PUB=${2:-8+ROmIIc9bFQ74dzb9nmENZ/7vxW3RUcmv5tOOIA2j8=}
DUT_IP=${3:-192.168.1.1}
PORT=51820
KEYS=/tmp/wg_clients
mkdir -p "$KEYS"
echo "[gen] setting up $N client namespaces -> DUT $DUT_IP:$PORT"
for ns in $(ip netns list 2>/dev/null | awk '/^ns_c[0-9]/{print $1}'); do ip netns del "$ns" 2>/dev/null || true; done
: > "$KEYS/client_pubs.txt"
for i in $(seq 0 $((N-1))); do
    [ -f "$KEYS/c${i}.key" ] || wg genkey > "$KEYS/c${i}.key"
    PUB=$(wg pubkey < "$KEYS/c${i}.key")
    echo "$i $PUB 10.0.$((i+1)).1" >> "$KEYS/client_pubs.txt"
    ns=ns_c${i}; ifc=wgc${i}
    ip netns add "$ns"
    ip link add "$ifc" type wireguard
    ip link set "$ifc" netns "$ns"
    ip netns exec "$ns" wg set "$ifc" private-key "$KEYS/c${i}.key" peer "$DUT_PUB" allowed-ips 10.0.0.0/16 endpoint "$DUT_IP:$PORT"
    ip netns exec "$ns" ip addr add 10.0.$((i+1)).1/16 dev "$ifc"
    ip netns exec "$ns" ip link set "$ifc" up
    ip netns exec "$ns" ip link set lo up
done
echo "[gen] created $N clients. Pubkeys -> $KEYS/client_pubs.txt"
EOF
sudo bash ~/setup_gen_clients.sh 8
```

## Step 3 — on DUT: build wg0 with N peers
```bash
cat > ~/setup_dut_peers.sh <<'EOF'
#!/bin/bash
set -euo pipefail
N=${1:?usage: setup_dut_peers.sh N [GEN_HOST]}
GEN_HOST=${2:-gen}
PUBS=/tmp/client_pubs.txt
PORT=51820
if [ ! -f "$PUBS" ] || [ "${REFRESH:-0}" = "1" ]; then
    scp -o StrictHostKeyChecking=no "$GEN_HOST":/tmp/wg_clients/client_pubs.txt "$PUBS"
fi
echo "[dut] (re)building wg0 with $N peers"
ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
wg set wg0 listen-port "$PORT" private-key /etc/wireguard/dut.key
ip addr add 10.0.0.1/16 dev wg0
ip link set wg0 up
while read -r i pub ip; do [ -n "${pub:-}" ] || continue; wg set wg0 peer "$pub" allowed-ips "${ip}/32"; done < <(head -n "$N" "$PUBS")
echo "[dut] wg0 up with $(wg show wg0 peers | wc -l) peers; module srcversion $(cat /sys/module/wireguard/srcversion)"
EOF
sudo bash ~/setup_dut_peers.sh 8
```

## Step 4 — verify all 8 peers handshake
```bash
# on gen: poke each tunnel
for i in $(seq 0 7); do sudo ip netns exec ns_c$i ping -c1 -W1 10.0.0.1 >/dev/null & done; wait; echo done
# on dut: count handshakes (want 8)
sudo wg show wg0 | grep -c "latest handshake"
```

**Report:** the `[gen] created 8 clients` line, the `[dut] wg0 up with N peers` line,
and the handshake count (want 8). If 8 → multi-peer works → I write `measure_ab.sh`.

---

# ▶ Multi-peer A/B at N=8 (script-based — run now)

Metric = **wasted-poll fraction = WASTED / (WASTED + USEFUL)**. We use small script
files (short lines) instead of long pasted one-liners — long one-liners get wrapped
by the terminal and break (split strings / split `-c` from its arg).

> Note: the load runs on `gen`; the measure script drives it over ssh, so you run
> everything from the `dut` terminal. Namespaces on `gen` persist across DUT module
> swaps; clients re-handshake on first traffic.

## One-time setup

On **gen** — create the load driver:
```bash
cat > /tmp/genload.sh <<'EOF'
#!/bin/bash
N=$1; DUR=$2; STREAMS=$3
for i in $(seq 0 $((N-1))); do
    ip netns exec "ns_c$i" iperf3 -c 10.0.0.1 \
        -p $((5201+i)) -t "$DUR" -P "$STREAMS" >/dev/null 2>&1 &
done
wait
EOF
```

On **dut** — create the measure script:
```bash
cat > ~/measure_one.sh <<'EOF'
#!/bin/bash
set -uo pipefail
MOD=${1:?usage: measure_one.sh stock|patched N [DUR] [STREAMS] [GEN]}
N=${2:?need N}
DUR=${3:-20}
STREAMS=${4:-4}
GEN=${5:-gen}
KO="$HOME/wireguard_${MOD}.ko"
ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null
sleep 1
for i in $(seq 0 $((N-1))); do
    iperf3 -s -p $((5201+i)) -D
done
ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload.sh $N $DUR $STREAMS" &
LOAD=$!
DURP=$((DUR+3))
bpftrace -e '
kretprobe:wg_packet_rx_poll /retval==0/ { @w += 1; }
kretprobe:wg_packet_rx_poll /retval>0/  { @u += 1; @batch = lhist(retval,0,64,4); }
interval:s:'"$DURP"' {
    printf("WASTED %lld USEFUL %lld\n", @w, @u);
    print(@batch);
    exit();
}'
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
EOF
```

## Run the A/B (on dut)
```bash
sudo bash ~/measure_one.sh stock 8
```
then
```bash
sudo bash ~/measure_one.sh patched 8
```

Each prints `WASTED … USEFUL …`, the `@batch` histogram, and a `RESULT …` line
(confirms which module ran: `81233F6…`=stock, `069999A…`=patched). Paste both.
Expect patched < stock here (M1 saw −21.9% at 8 peers).

Repo copies: `scripts/cloudlab/genload.sh`, `scripts/cloudlab/measure_one.sh`.

---

# Later: the automated sweep

`measure_ab.sh` (run on `dut`) will loop `measure_one.sh` over module ∈
{stock,patched} × peers ∈ {1,4,8,16,32,64,128} × ≥5 repeats, plus the richer probe
(NET_RX softirq time) and a CSV + analyzer for medians.

## A/B module swap reference
```bash
sudo wg-quick down wg0 2>/dev/null; sudo ip link del wg0 2>/dev/null
sudo rmmod wireguard
sudo insmod ~/wireguard_<stock|patched>.ko
sudo bash ~/setup_dut_peers.sh <N>            # rebuilds wg0 + peers on the new module
cat /sys/module/wireguard/srcversion           # 81233F6…=stock, 069999A…=patched
```

## Open items
- E3 `Δ_complete`: `wg_queue_enqueue_per_peer_rx` inlined → probe decrypt completion +
  derive peer from skb.
- Confirm Alain's June 15 decisions; lock the assumptions block in the plan.
- `work_done=8` mode in the histograms — understand the quantum later.
