# CloudLab Experiments — Plan / Runbook

> **Living document.** This is the *operational* plan: the ordered list of
> experiments we actually run on CloudLab, each with exact commands, expected
> output, and a status. We keep adding experiments as we go.
>
> - **Strategy / why** lives in `CLOUDLAB_MEASUREMENT_PLAN.md` (the cost model and
>   rationale) and `REUNION_ALAIN_2026-06-15.md` (the spoken brief).
> - **Results / what happened** go in `CLOUDLAB_EXPERIMENTS_LOG.md`. This file says
>   *what we intend to do*; the log says *what we observed*. Keep them separate.
>
> Author: Anas Ait El Hadj · Inria KrakOS (LIG) · supervisors Alain Tchana, André Freyssinet

---

## How to use this document

- Each experiment has an **ID** (`E0.x` provisioning, `E1` EoI repro, `E2…` cost
  model), an **objective**, **depends-on**, **exact commands**, **expected
  output**, and a **status**.
- When you run one: flip its status, and write the numbers + anything surprising in
  the **log** under a dated entry that references the ID (e.g. "E4 — first run").
- Never paste raw results here. This stays a clean, repeatable recipe.
- Status legend: `TODO` · `RUNNING` · `DONE` · `BLOCKED` · `SKIP`.

---

## Testbed conventions (must match `scripts/cloudlab/profile.py`)

| Item | Value |
|------|-------|
| Profile | `wg-recv-measure` (project **WG**) |
| Nodes | `dut` (Device Under Test, instrumented receiver) · `gen` (load generator) |
| Private LAN | `recvlan`, 10 GbE, `192.168.1.0/24` |
| Experiment NIC (instance #1) | **`enp6s0f1`** — the OS names it this, *not* `eth1`; `enp1s0f0` is the public/control net |
| `dut` link IP | `192.168.1.1` on `enp6s0f1` |
| `gen` link IP | `192.168.1.2` on `enp6s0f1` |
| Default HW | `c220g2` (Wisconsin) — 2× E5-2660 v3, 20c/40t, Intel X520 10 GbE |
| Image | Ubuntu 22.04 STD (`UBUNTU22-64-STD`), kernel **5.15.0-177-generic** (LTS GA) |
| Modules | `wireguard_stock.ko` and `wireguard_patched.ko`, side by side, A/B per run |

> **Working assumptions pending Alain's June 15 outcome** (confirm, then lock here):
> node type `c220g2`; peer scale 1→32 then 128 for the *measurement* phase (1,000
> deferred to the later benchmark); five-quantity cost model as in the plan;
> bpftrace/BTF as the primary probe method. Update this block once decided.

---

## Status dashboard

| ID | Experiment | Phase | Status | Log entry |
|----|------------|-------|--------|-----------|
| E0.1 | Instantiate profile, get nodes | A Provision | DONE | 2026-06-17 |
| E0.2 | Verify HW / NIC / kernel / BTF | A Provision | DONE | 2026-06-17 |
| E0.3 | Build stock + patched modules | A Provision | DONE | 2026-06-18 |
| E0.4 | Bring up WireGuard tunnel gen↔dut | A Provision | DONE | 2026-06-18 |
| E0.5 | Multi-peer namespaces on `gen` | A Provision | DONE | 2026-06-18 (8/8 peers handshake) |
| E0.6 | bpftrace symbol check on `dut` | A Provision | DONE | 2026-06-17 |
| E1   | Reproduce EoI + stock/patched A/B | B Validate | DONE | 2026-06-19 — EoI reproduced (33% wasted @8p); fix fires (skips 9.4%) but **null on real NIC** (napi_schedule ~63% no-op under load) |
| E2   | `T_decrypt` — per-packet decrypt time | C Cost model | DONE | 2026-06-19 (~5–6µs @8p) |
| E3   | `Δ_complete` — inter-completion gap per peer | C Cost model | TODO | — |
| E4   | `C_poll` + `C_deliver` — poll duration vs work_done | C Cost model | DONE* | 2026-06-19 (C_poll~1µs, C_deliver~1.66µs; *re-run poll-only for clean nums) |
| E5   | `C_stack` + GRO batch-size distribution | C Cost model | TODO | — |
| E6   | System view — perf / mpstat (core saturation) | C Cost model | TODO | — |

---

# Phase A — Provision & build

### E0.1 — Instantiate the profile

**Objective.** A live two-node testbed.

**Steps.**
1. CloudLab → Experiments → *Start Experiment* → choose profile `wg-recv-measure`.
2. If `c220g2` is unavailable, edit `HW_TYPE` in `scripts/cloudlab/profile.py`
   (alternatives: `c6525-25g`/`c6525-100g` Utah, `xl170` Utah, `d6515` Clemson)
   and re-create the profile, or override the `hwtype` parameter at instantiate.
3. Wait until both nodes are "ready"; grab the SSH commands from the listview.

**Expected.** SSH into `dut` and `gen` succeeds.

**Record in log:** cluster, exact node IDs, allocation time, lease expiry.

---

### E0.2 — Verify hardware, NIC, kernel, BTF

**Objective.** Confirm the node is what we asked for and supports our tooling
*before* investing time.

**Commands (on `dut`).**
```bash
uname -r                                            # kernel version (want 6.x)
lscpu | grep -E 'Model name|^CPU\(s\)|Socket|Core'  # core/socket count
ip -br link                                         # find the 10G iface (eth1)
ethtool eth1 | grep -i speed                        # confirm 10000Mb/s
ethtool -l eth1                                      # NIC queue count (multi-queue?)
ls /sys/kernel/btf/vmlinux                           # BTF present → bpftrace kprobes work
dpkg -l | grep -E "linux-headers-$(uname -r)|bpftrace|linux-tools" # toolchain installed?
ping -c2 192.168.1.2                                 # reach gen over the private LAN
```

**Expected.** 6.x kernel, ~20c/40t, `eth1` at 10000Mb/s with multiple RX queues,
`/sys/kernel/btf/vmlinux` exists, headers + bpftrace + perf present, `gen` pingable.

**If BTF missing or headers absent:** the profile's `Execute` service may have
failed — re-run the apt install by hand (see `profile.py`), and consider a
different image.

---

### E0.3 — Build stock + patched modules

**Objective.** Two loadable modules differing only by the 6-line trigger fix.

**Approach.** Build the WireGuard module out-of-tree against the running kernel
(the in-tree `drivers/net/wireguard/` sources, or `wireguard-linux-compat`). Keep
both `.ko` files for A/B.

**Sketch (on `dut`).**
```bash
# 1. obtain matching WireGuard module sources for the running kernel
# 2. build the stock module
make -C /lib/modules/$(uname -r)/build M=$PWD modules
cp wireguard.ko ~/wireguard_stock.ko
# 3. apply the 6-line trigger fix (receive.c head-readiness check before napi_schedule),
#    rebuild, save as wireguard_patched.ko
cp wireguard.ko ~/wireguard_patched.ko
```

The fix (canonical):
```c
tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);     // otherwise: skip the wake
```

**A/B load helpers** (port from `scripts/load_stock.sh` / `scripts/load_patched.sh`):
```bash
sudo rmmod wireguard 2>/dev/null; sudo insmod ~/wireguard_stock.ko    # baseline
sudo rmmod wireguard 2>/dev/null; sudo insmod ~/wireguard_patched.ko  # fix
modinfo ~/wireguard_patched.ko | head                                  # sanity
```

**Expected.** Both modules `insmod` cleanly; `dmesg` shows the WireGuard init line;
`modinfo` reports the expected version.

**Open item:** if `decrypt_packet` must be probed directly and is inlined, build a
third "measurement" module with `noinline` on it (see E0.6 / E2).

---

### E0.4 — Bring up the WireGuard tunnel gen↔dut

**Objective.** A working encrypted tunnel so the `dut` receive path actually runs.

**Concrete commands (single peer, instance #1).** Tunnel net `10.0.0.0/24`; link
endpoints are the `enp6s0f1` IPs (`192.168.1.1` dut, `192.168.1.2` gen); port 51820.

On **dut** (tunnel 10.0.0.1):
```bash
sudo mkdir -p /etc/wireguard
wg genkey | sudo tee /etc/wireguard/dut.key >/dev/null
sudo sh -c 'wg pubkey < /etc/wireguard/dut.key > /etc/wireguard/dut.pub'
sudo ip link add wg0 type wireguard
sudo wg set wg0 listen-port 51820 private-key /etc/wireguard/dut.key
sudo ip addr add 10.0.0.1/24 dev wg0
sudo ip link set wg0 up
echo "DUT_PUB = $(sudo cat /etc/wireguard/dut.pub)"
```
On **gen** (tunnel 10.0.0.2): same as above with `gen.key`/`gen.pub`, `10.0.0.2/24`.

Then wire the peers (substitute the printed pubkeys):
```bash
# on dut:
sudo wg set wg0 peer <GEN_PUB> allowed-ips 10.0.0.2/32 endpoint 192.168.1.2:51820
# on gen:
sudo wg set wg0 peer <DUT_PUB> allowed-ips 10.0.0.1/32 endpoint 192.168.1.1:51820
```

**Expected.**
```bash
sudo wg show          # latest handshake present, both ends
ping -c3 10.0.0.1     # from gen: tunnel carries traffic
```

**Note:** load `modprobe wireguard` first if `wg0` add fails — the module isn't
auto-loaded until a wg iface is created (it was on first use here).

**Record in log:** the exact `wg` config used (reusable for every run).

---

### E0.5 — Multi-peer via network namespaces on `gen`

**Objective.** N WireGuard peers without N physical clients — the M1 method ported
to the real link.

**Approach.** On `gen`, create N namespaces, each its own keypair + allowed-ips, all
targeting the single receiver tunnel on `dut`. Port `scripts/setup_multipeer.sh`
from loopback to the `192.168.1.0/24` link.

**Peer ladder:** 1, 4, 8, 16, 32 (mirror M1) → then 128 (→ 512/1000 only if Alain
wants it for measurement; otherwise deferred to the benchmark phase).

**Expected.** `sudo wg show` on `dut` lists N peers, each with a handshake; load can
be driven from each namespace independently.

---

### E0.6 — bpftrace symbol check on `dut`

**Objective.** Know which probe points exist before writing probe scripts.

**Commands.**
```bash
sudo bpftrace -l 'kprobe:*wg_packet*'
sudo bpftrace -l 'kprobe:*decrypt*'
sudo bpftrace -l 'kprobe:*rx_poll*'
grep -E 'wg_packet_rx_poll|decrypt_packet|wg_packet_decrypt_worker|napi_gro_receive' /proc/kallsyms
```

**Expected & decision.**
- `wg_packet_rx_poll` (receive.c:438) and `napi_gro_receive` (receive.c:411) should
  be probeable directly.
- If `decrypt_packet` (receive.c:501) is **inlined** (no symbol): probe the worker
  boundary `wg_packet_decrypt_worker` (receive.c:493) instead, and/or rebuild with
  `noinline` (E0.3 measurement module). **Record which path we took** — it changes
  how E2 is interpreted.
- Confirm the argument index for `peer` on `wg_queue_enqueue_per_peer_rx`
  (receive.c:503) needed by E3 (`arg0` assumed).

---

# Phase B — Validate (reproduce the EoI off loopback)

### E1 — Wasted-poll spike, stock vs patched

**Objective.** Confirm the EoI signature appears on real server hardware: a spike of
`wg_packet_rx_poll` returns at `work_done == 0` under stock, shrinking under the
fix. This is the **go/no-go** before the full cost model.

**Probe (`dut`).**
```c
// wasted_poll.bt
kretprobe:wg_packet_rx_poll {
    @workdone = lhist(retval, 0, 64, 4);   // distribution of work_done; bucket 0 = wasted poll
    @total = count();
}
```

**Run.** For each module (stock, then patched), for each peer count {1,4,8,16,32},
≥5 runs:
```bash
sudo bpftrace wasted_poll.bt -o e1_<module>_<peers>_run<k>.txt &
# drive load from gen namespaces for a fixed duration (e.g. 30s)
# stop bpftrace, save output
```

**Expected.** Stock: heavy bucket-0 mass. Patched: bucket-0 mass drops, distribution
shifts toward >1 — matching M1's −9 % to −22 % wasted-poll reduction and the GRO
batch-size rise. Reduction should **grow with peer count**.

**Decision.** If the spike does **not** reproduce on the real NIC, stop and discuss
with Alain before building the cost model — the EoI premise needs the real path.

**Record in log:** bucket-0 fraction stock vs patched per peer count; compare to M1.

---

# Phase C — Cost model (per-step costs)

> All probes on `dut`, in-kernel aggregation only (no per-event `printf` on the hot
> path), ≥5 runs, median + spread, **both modules**. See methodology section below.

### E2 — `T_decrypt` (per-packet decrypt time)

```c
kprobe:decrypt_packet        { @start[tid] = nsecs; }            // or wg_packet_decrypt_worker if inlined
kretprobe:decrypt_packet /@start[tid]/ {
    @T_decrypt = hist(nsecs - @start[tid]);
    delete(@start[tid]);
}
```
**Output:** median of `@T_decrypt`. **Note in log** whether probed at `decrypt_packet`
or worker boundary (changes what's included).

### E3 — `Δ_complete` (inter-completion gap, per peer)

```c
kprobe:wg_queue_enqueue_per_peer_rx {
    $peer = arg0;                                                // confirm arg index (E0.6)
    if (@last[$peer]) { @delta_complete = hist(nsecs - @last[$peer]); }
    @last[$peer] = nsecs;
}
```
**Output:** median gap per peer. Sets how long a batching trigger could afford to
wait for the next packet.

### E4 — `C_poll` + `C_deliver` (the central probe)

```c
kprobe:wg_packet_rx_poll  { @s[tid] = nsecs; }
kretprobe:wg_packet_rx_poll /@s[tid]/ {
    $dur = nsecs - @s[tid];
    @workdone = lhist(retval, 0, 64, 4);   // (also covers E1 signature)
    @poll_dur[retval] = hist($dur);        // duration histogram per work_done
    @sum_dur[retval]  = sum($dur);         // for the regression
    @cnt[retval]      = count();
    delete(@s[tid]);
}
```
**Derive:** `C_poll` = `@poll_dur[0]` (duration of a poll that delivers nothing).
`C_deliver` = slope of mean duration (`@sum_dur[k]/@cnt[k]`) vs `k`; intercept should
cross-check `C_poll`.

### E5 — `C_stack` + GRO batch size

```c
kprobe:napi_gro_receive   { @g[tid] = nsecs; }
kretprobe:napi_gro_receive /@g[tid]/ { @gro_cost = hist(nsecs - @g[tid]); delete(@g[tid]); }
// batch size: napi_gro_receive calls between two napi_complete_done
kprobe:napi_gro_receive    { @gro_in_batch = count(); }
kprobe:napi_complete_done  { @batch = hist(@gro_in_batch); @gro_in_batch = 0; }
```
**Derive:** `C_stack` ≈ per-packet cost of the stack-traversal segment at batch=1
(the part batching amortises); cross-check with the perf flamegraph (E6). Also yields
the GRO batch-size distribution to compare against M1 (3.1→3.3, 8.7→9.6, 7.7→8.9).

### E6 — System view (perf / mpstat)

```bash
mpstat -P ALL 1                                                     # find THE saturated softirq core
sudo perf stat -a -C <core> -e cycles,instructions,cache-misses -- sleep 10
sudo perf record -a -g -C <core> -- sleep 10 && sudo perf report   # softirq flamegraph
```
**Output:** confirm single-core `NET_RX_SOFTIRQ` saturation; attribute cycles
(decrypt vs poll vs stack); cross-check `C_poll`/`C_stack`.

---

## Methodology & rigor (applies to every Phase-C run)

- **In-kernel aggregation** (maps/histograms) only on the hot path; never per-event
  output.
- **Probe-overhead control:** run identical load with probes attached to a *cold*
  function vs detached → quantify the bias the probes themselves add.
- **Pin & read per-core** to isolate the saturated softirq core.
- **Both modules every time** — stock and patched at iso-conditions.
- **≥5 runs**, report median + spread (reuse the M1 v2 variance approach).
- **Fixed load profile** per run (same duration, same packet size, same peer set) so
  runs are comparable.

---

## From data → trigger (what Phase C feeds)

Once E2–E6 give `C_poll, C_deliver, C_stack, T_decrypt, Δ_complete`:
1. Quantify residual waste of the current fix (count + cost of its 1-packet polls).
2. Derive the trigger rule: wake when expected batch benefit `(k−1)·C_stack` exceeds
   `C_poll` + acceptable added latency; bound the wait with `Δ_complete`.
3. Prototype the batching-aware trigger; **re-measure E1–E6** to confirm. Iterate.

---

## Backlog / parking lot (not scheduled yet)

- Queue-op cost (`ptr_ring_consume_bh` / enqueue) — optional micro-cost.
- Encrypt/TX-side instrumentation — only if Alain wants the cost model to cover it.
- Handshake-path cost — out of scope for the data-packet trigger.
- Scale to 512 / ~1,000 peers — deferred to the benchmark phase (F) unless requested.
- ARM cross-check node — pending the x86↔ARM decision.
- Combine with the paper's dedicated `gro_wq` variant — phase F.

---

## Change log (of this plan)

- **2026-06-17** — Created. Phases A–C laid out with exact probes/commands;
  working assumptions noted pending Alain's June 15 decisions.
