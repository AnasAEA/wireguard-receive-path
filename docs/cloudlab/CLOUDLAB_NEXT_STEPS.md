# CloudLab — What To Do Right Now

> Hands-on walkthrough for the live testbed. Copy blocks from here.
> Recipe: `CLOUDLAB_EXPERIMENTS_PLAN.md`. Results: `CLOUDLAB_EXPERIMENTS_LOG.md`.

**Live nodes (instantiation #6, re-instantiated 2026-07-02):**

| Role | Node | SSH |
|------|------|-----|
| `dut` (instrumented receiver) | c220g2-011118 (Wisc) | `ssh anasait@c220g2-011118.wisc.cloudlab.us` |
| `gen` (load generator) | c220g2-011131 (Wisc) | `ssh anasait@c220g2-011131.wisc.cloudlab.us` |

> **Experiment 10G NIC is now `enp6s0f0`** (was `enp6s0f1` in instantiation #1), already
> up with dut `192.168.1.1` / gen `192.168.1.2`. Node-to-node SSH works only as **root**
> (`sudo ssh gen`). A fresh instantiation is a blank UBUNTU22 image: re-bootstrap with
> `scripts/cloudlab/bootstrap_testbed.sh` (installs iperf3/wireguard-tools/linux-source,
> pushes scripts, builds `wireguard_trigger.ko`, brings up wg0 + 8 peers). A fresh
> instantiation regenerates the DUT key — the bootstrap reads the new pub and passes it to
> `setup_gen_clients.sh` automatically. DUT pub for instantiation #3:
> `z2HDdaydsU4sgYL5zMnL4dk3nJ8kWvyvDbDScnb35xo=`.

---

# ▶ RUN NOW — three experiments × peer-count sweep (Alain 2026-06-25)

All on `dut`. Module `~/wireguard_trigger.ko` (srcversion `EA06EE82…`) has the two-sided
fix composable (`wg_supp` + `wg_headwake`) and the decrypt-cost knob (`wg_decrypt_delay_ns`).
Gen has 64 client namespaces pre-created, so any `N ≤ 64` works. Each script rebuilds dut
peers for `N`, uses the sdfn spread, and reverts the NIC hash to `sd` at the end.

```bash
# 1) TWO-SIDED FIX A/B — wasted-poll reduction (stock / move / root / both). DONE + clean.
#    'both' = wg_supp=1 wg_headwake=1 (producer gate + consumer suppress).
#    NOTE: measure_missed.sh now warms up the tunnels before the loop — without it the FIRST
#    condition (stock) was measured cold and reported a bogus polls=1 / 0% wasted.
for N in 8 16 32 64; do sudo bash ~/measure_missed.sh "$N" 12; done
#    Result (2026-06-26, data/cloudlab/twosided_peersweep_20260626.csv, fig_twosided_peers.png):
#    stock ~27% -> move ~25% -> root ~15% -> both ~14% wasted polls, ~FLAT from 8 to 64 peers.
#    'both' halves wasted polls; the fresh-wake regeneration drops from ~6% (move) to ~1% (both).
#    The M1 "grows with peers" effect does NOT reproduce here.

# 2) TAIL LATENCY at sub-saturation — NOISY, NOT YET RELIABLE.
for N in 8 16 32 64; do sudo bash ~/measure_taillat.sh "$N" 2000 20; done
#    off/both trade places run-to-run, 10-12ms outliers both sides, and 'off' loses ping
#    samples (769-795 vs 2000) => percentiles untrustworthy. TODO before believing any number:
#    more samples, a latency tunnel isolated from the load, fix the off-side sample loss.

# 3) DECRYPT-COST SWEEP — knob works, METHODOLOGY BREAKS at high delay.  [SUPERSEDED]
#    The 2026-06-26 run used uncapped load + two disjoint windows; past ~10-20us/packet the
#    busy-wait collapsed the pipeline (gbps -> 0.000/NA, wasted% meaningless). Direction was
#    right (stock wasted ~28% -> ~44% as decrypt slows). Script REWRITTEN 2026-07-02 to the
#    measure_subsat.sh design — see "RUN NEXT — Phase B" below.
```

---

# ▶ RUN NEXT — Phase B decrypt-cost sweep (rewritten script, 2026-07-02)

`measure_decrypt_sweep.sh` now implements `CLOUDLAB_PLAN_phase2.md` Phase B properly:
capped bulk load on peers 1..N-1 (default 2 Gb/s total, below the decrypt knee), sockperf
latency on dedicated peer 0, and per run ONE window measuring latency + CPU CE + verified
actual throughput + wasted polls together. Pipeline collapse is recorded as
`status=collapse` and the row is KEPT (it locates the knee). Latency numbers are
probe-perturbed (bpftrace runs in-window) — fair off-vs-both, NOT comparable to Phase A
absolutes.

```bash
# 0) fresh instantiation: bootstrap from the Mac (sync_to_dut.sh pushes all measure scripts),
#    then verify the REWRITTEN sweep landed on dut. Instantiation #6 (2026-07-02):
#    dut c220g2-011118 / gen c220g2-011131. DONE for #6 (srcversion EA06EE82, 8/8 handshakes).
DUT=anasait@c220g2-011118.wisc.cloudlab.us GEN=anasait@c220g2-011131.wisc.cloudlab.us \
  bash scripts/cloudlab/bootstrap_testbed.sh 8
ssh anasait@c220g2-011118.wisc.cloudlab.us \
  'grep -q "REWRITTEN 2026-07-02" ~/measure_decrypt_sweep.sh && echo SCRIPT_OK || echo STALE_SCRIPT'

# 1) the sweep — delays 0/1/2/5/10us, off vs both, 5 reps, 30s windows (~35 min), ON DUT.
#    nohup so an ssh drop doesn't kill the run mid-campaign (trap cleanup would fire):
ssh anasait@c220g2-011118.wisc.cloudlab.us
sudo -v && nohup sudo bash ~/measure_decrypt_sweep.sh 8 > ~/decsweep_run.log 2>&1 &
tail -f ~/decsweep_run.log        # progress: one line per run; watch for [COLLAPSE]

# extend upward only if the knee hasn't appeared by 10us:
sudo bash ~/measure_decrypt_sweep.sh 8 "0 2000 5000 10000 20000" 30

# 2) fetch results (CSV + placement sidecar) back to the repo, from the Mac
scp "anasait@c220g2-011118.wisc.cloudlab.us:~/decsweep_*.csv" \
    "anasait@c220g2-011118.wisc.cloudlab.us:~/decsweep_*.placement.txt" data/cloudlab/
```

Read the result with the plan's knee framing: safe / transition / collapse regions; only
`status=ok` rows are evidence. The question the sweep answers: at what decrypt:poll ratio
(if any) does `both` start saving CPU CE or tail latency vs `off`?

> **DONE 2026-07-06** (`data/cloudlab/decsweep_20260706_0321.csv`): dose-responsive
> mechanism (waste removal 56%→89% as delay 0→10 µs), CPU/latency payoff still null.
> Follow-up below: confirm the cost model is a *measured* null, not a derived one.

---

# ▶ RUN NOW — instantiation #8 (2026-07-09): E11-C classified stalls + Phase C soak

Nodes: `dut` c220g2-010631 / `gen` c220g2-010625. The module now carries the
**E11 stall classifier** (per-episode empty-queue vs UNCRYPTED-head accounting,
`build/wg515-trigger/`, gated on `wg_diag`) — a NEW srcversion, recorded per CSV row
as always. The two last experiments before the write-up:

```bash
# 0) bootstrap (builds the classifier module) — done for #8 if handshakes=8 printed
DUT=anasait@c220g2-010631.wisc.cloudlab.us GEN=anasait@c220g2-010625.wisc.cloudlab.us \
  bash scripts/cloudlab/bootstrap_testbed.sh 8

# 1) E11-C — classified stall episodes (~6 min: delays 0/5/10us x 3 reps x 30s), ON DUT
ssh anasait@c220g2-010631.wisc.cloudlab.us
sudo -v && nohup sudo bash ~/measure_stall_class.sh 8 > ~/stallclass_run.log 2>&1 &
tail -f ~/stallclass_run.log
#    Read it with the decision rule: the UNCRYPT class is the steering prize.
#    mean_us - decrypt floor in 5-20us => future work only; 100+us => go design.
#    The EMPTY class should hold the ms tail (inter-burst idle) — if it doesn't,
#    the bpftrace E11 interpretation needs revisiting.

# 2) Phase C — headwake soak (~32 min: 2 stages x 15 min), ON DUT, after E11-C
sudo -v && nohup sudo bash ~/measure_soak.sh 8 > ~/soak_run.log 2>&1 &
tail -f ~/soak_run.log
#    Ends with VERDICT: PASS/FAIL. PASS = recommend `both` in the report.
#    FAIL = the fallback wording is ready in RECEIVE_PATH_FINDINGS (consumer-side
#    suppress is safe; producer gate needs memory-ordering hardening).

# 3) fetch BOTH artifacts immediately (the #6 lesson), from the Mac
scp "anasait@c220g2-010631.wisc.cloudlab.us:~/stallclass_*.csv" \
    "anasait@c220g2-010631.wisc.cloudlab.us:~/soak_*.csv" data/cloudlab/
```

# ▶ RUN NEXT — E10/E11: cost-model confirmation + steering bound (2026-07-06)

Two bounds to measure before designing anything further (agreed with Alain's framing):
**cost bound** (E10 — are the wasted polls really too cheap to matter?) and **latency
bound** (E11 — how much delivery time is lost to a blocked UNCRYPTED head? = the ceiling
any head-priority/decrypt-steering scheme could recover).

One orchestrator runs both: `scripts/cloudlab/measure_cost_accounting.sh` (on dut, ~10 min).
E10 runs off vs both at delay 0 and 10 µs, same capped 2 Gb/s load as Phase B, with
**separate probe windows** (perf and bpftrace never run together — they'd perturb each
other): E10a = perf cycle attribution on all cores (`wg_packet_rx_poll`,
`napi_complete_done`, `__napi_schedule`, decrypt symbols); E10b = bpftrace duration *sums*
for polls returning 0 → wasted CPU-time in seconds/CE, not counts. E11 = stall-episode
gaps under `off` at delays 0/2/5/10 µs: first `retval==0` poll after a productive poll
starts an episode; the next productive poll on the same NAPI ends it.

```bash
# 0) perf is NOT in the bootstrap package set — install once per instantiation:
ssh anasait@c220g2-011118.wisc.cloudlab.us 'sudo apt-get install -y -qq linux-tools-$(uname -r) linux-tools-generic >/dev/null; perf --version'

# 1) push + run the orchestrator (from the Mac)
scp scripts/cloudlab/measure_cost_accounting.sh anasait@c220g2-011118.wisc.cloudlab.us:~/
ssh anasait@c220g2-011118.wisc.cloudlab.us 'nohup sudo bash ~/measure_cost_accounting.sh > ~/costacct_run.log 2>&1 & tail -f ~/costacct_run.log'

# 2) fetch the whole artifact dir IMMEDIATELY (lesson from instantiation #6)
scp -r "anasait@c220g2-011118.wisc.cloudlab.us:~/costacct_*" data/cloudlab/
```

**How to read E11 (wording agreed — do not overclaim):**
```text
raw stall gap                                = upper bound on delivery-blocked time
× UNCRYPTED-head fraction (~54%, wg_diag)    = upper bound on relevant head stalls
− decrypt floor (T_decrypt_effective)        = conservative estimate of the recoverable
                                               steering excess (conservative because the
                                               failed poll may land mid-decrypt, so the
                                               true recoverable part may be larger)
```
**Decision rule:** corrected excess p99 ≈ 5–20 µs → head-priority/decrypt-order steering
is future-work only, not worth implementing this internship. 100+ µs and growing with
decrypt delay → real next-stage direction with evidence behind it.

**E10 expected result** (if the cost model is right): wasted-poll symbol/time share drops
hard off→both, but is <1% of total busy cycles in both conditions → the CPU null becomes
*measured*, not just explained. If it doesn't match, we found the hidden cost.

> **DONE 2026-07-06** (`data/cloudlab/costacct_20260706_{0539,0613}`, two runs, combined
> coverage complete). **E10: cost model CONFIRMED** — C_poll 1.14–1.36 µs, reclaimable
> ≈ 0.02 CE vs ±2 CE noise (100× below), perf: poll machinery < 0.7 % of busy cycles.
> **E11: steering bound PROMISING** — median stall ~50–100 µs ≈ 10–20× T_decrypt and
> delay-insensitive (the head waits on worker scheduling, not on decrypt); conservative
> excess typical ~30–90 µs, tail 200–800 µs. Above the drop band, tail beyond the go
> threshold, but head-vs-empty classification unresolved. **Next concrete step: the
> ~20-line wg_diag per-episode classifier (head-state + duration), NOT steering itself.**
> Full numbers: `CLOUDLAB_EXPERIMENTS_LOG.md` E10/E11 entry.

# ▶ OPTIONAL — E12: hardware as a parameter space (not a contradiction of the null)

Phrase the c220g2 result as: *the fix matters when `wasted_poll_rate × C_poll` becomes
non-negligible relative to total receive-path CPU / latency noise.* Phase B swept the
decrypt axis; the poll/wakeup-cost axis is untested. Candidates where the ratio shifts:
VMs (expensive wakeups/IPIs), no-SIMD crypto, in-order embedded cores. Note the
invariance hypothesis: *uniformly* slower hardware scales C_poll and per-packet costs
together, so the waste share may be invariant — the free test on this dut:

```bash
# clamp all cores to the E5-2660v3 floor (1.2 GHz), re-run E10b + measure_missed.sh 8,
# then restore. If the waste share is invariant under uniform slowdown, the parametric
# claim holds; asymmetric platforms remain the interesting axis.
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 1200000 | sudo tee $c >/dev/null; done
# ... measure ...
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do cat ${c%max_freq}cpuinfo_max_freq | sudo tee $c >/dev/null; done
```

To repeat a single cell for variance, just rerun that one line (e.g. `sudo bash
~/measure_taillat.sh 32 2000 20`). CSVs land in `~` (`taillat_*.csv`, `decsweep_*.csv`);
`measure_missed.sh` prints to stdout. Knob check while loaded: `cat
/sys/module/wireguard/parameters/{wg_supp,wg_headwake,wg_decrypt_delay_ns}`.

---

**Done:** E0.1 instantiate · E0.2 verify HW/NIC/BTF · E0.6 symbols · E0.4 tunnel ·
E0.3 build stock+patched modules · E1 stock pre-check (EoI reproduced, 35.8% wasted
@1peer) · E1 1-peer A/B (no effect at 1 peer, as expected) · E0.5 multi-peer up
(8/8 peers handshake).

**Status:** A/B null + diagnosed (napi_schedule ~63% no-op); cost model complete
(C_poll~1µs, C_deliver~1.64µs, C_stack~3.7µs, Δ_complete~5/100µs); mechanism PROVEN
(Phase D trace: `wasted_after_resched/wasted=99.7%`); re-poll gap MEASURED (median
~1.6µs, ≈49% wasted — coin flip, ~3× premature vs `T_decrypt`); low-variance sweep
CONFIRMS the 6-line fix is null (CV<2%, dGbps −0.3%, ~33% wasted both modules);
saturation CONFIRMED single-core CPU-bound (Design A locked). **Trigger BUILT + TESTED.**
**CONCLUDED (see `RECEIVE_PATH_FINDINGS.md`):** on real 10G the receive path is bound by
**per-packet delivery softirq on one core**, NOT polls. Three measurements agree —
`wg_supp=1` cuts wasted polls −25% (throughput flat), `wg_trig_k=8` batches −22% useful
polls (throughput flat/−0.9%), and the hot core stays 100%/97% softirq at both. EoI
wasted polls are real + suppressible but second-order; hrtimer coalescing self-defeats on
the saturated core. Throughput-on-Design-A is the wrong metric for this fix. Candidate
future work: Design B (multi-core spread → CPU-per-byte) or latency. The Phase E/E0
run sections below remain for reproduction.

Facts: experiment NIC `enp6s0f1` (192.168.1.1 dut / 192.168.1.2 gen). Kernel
5.15.0-177. Modules: `~/wireguard_stock.ko` (`81233F6…`), `~/wireguard_patched.ko`
(`069999A…`), `~/wireguard_diag.ko` (`5E90522…`), `~/wireguard_trigger.ko`
(`3076ED3…`, built from PRISTINE 5.15 source via clean-room, k=0 ⇒ stock). A/B swap:
`wg-quick down wg0; rmmod wireguard; insmod ~/wireguard_<v>.ko`. DUT pub
`8+ROmIIc9bFQ74dzb9nmENZ/7vxW3RUcmv5tOOIA2j8=`.

---

# ▶ Phase E0 — SIMPLEST FIX: suppress the wasted MISSED re-poll (run THIS first)

The targeted version of the original idea, moved to the right place. The first fix gated
`napi_schedule` (the producer/bell-ring) and was null: under a real NIC the bell is
already-ringing ~63% of the time, and at ring-time you can't know if the head will be
ready. This instead acts at the **poll-completion site** (consumer side), where the head
state is authoritative: if the head is still UNCRYPTED, clear `NAPI_STATE_MISSED` so the
kernel **parks the NAPI instead of firing the re-poll** that Phase D proved is wasted
99.7% of the time. The head's own decrypt completion re-wakes a fresh, productive poll —
so nothing is lost under continuous load. Same binary `~/wireguard_trigger.ko`, isolated
by `wg_supp` (coalescer held off). **All commands on `dut`.**

```bash
# dut — A/B at 8 peers: wg_supp=0 (stock) vs wg_supp=1 (suppress), 7 shuffled runs.
bash ~/measure_supp.sh 8 7
# prints per-mode median GBPS + wasted_frac + CV%, then dGbps / dWastedFrac (supp1-supp0).
```

Expected (the hypothesis): `wasted_frac` drops well below ~33% (we kill the wasted
re-polls but keep the 44% productive ones), and on the CPU-bound core GBPS rises. **Watch
for stalls:** if GBPS collapses at supp=1, the lost-wakeup corner case (traffic idling in
the clear-MISSED window) bit us → we add a small hrtimer backstop and re-test. Under
continuous iperf load it should self-heal, but confirm the number isn't 0.

```bash
# dut — does it generalize across load?
for N in 8 16 32; do bash ~/measure_supp.sh "$N" 5; done
```

If a result looks off, confirm the knob is live: `cat
/sys/module/wireguard/parameters/wg_supp` (only valid while loaded). Rebuild recipe at the
bottom of this file ("Rebuild the trigger module").

---

# ▶ Phase E DIAGNOSTIC — why is throughput flat? per-core CPU at k0 vs k8 (run now)

Both levers reduced polls (wg_supp −25% wasted; wg_trig_k=8 −22% useful, real batching)
yet throughput stayed flat/slightly down. The decisive question: did batching actually
free the hot core, or did the hrtimer overhead eat the saving? This samples per-core
busy%/softirq% under load at each k. **On `dut`.**

```bash
# dut — per-core busy%/softirq% at k=0 vs k=8, 30s load each.
bash ~/measure_cpu_trigger.sh 8 "0 8"
```

Read it:
- **Hot core still ~100% busy at k=8** + throughput flat ⇒ batching did NOT free it (timer
  overhead landed on the same softirq core, or it's per-packet-delivery bound). Poll
  reduction is moot for throughput here → the value is latency or the multi-core regime.
- **Hot core drops below 100% at k=8** + throughput flat ⇒ CPU was freed but the bottleneck
  MOVED (gen-side encrypt? padata decrypt?) → confirm gen isn't the cap, then Design B.

---

# ▶ Phase E — TRIGGER A/B (the fuller version, if E0 leaves headroom)

The trigger is **one binary**, `~/wireguard_trigger.ko`: `wg_trig_k=0` is byte-identical
stock behaviour, `wg_trig_k=8` enables count-or-timeout RX coalescing (τ from
`wg_trig_tau_ns`, default 5000 ns). So the A/B toggles a runtime knob on the *same*
loaded module — no base divergence, no reload variance. **All commands run on `dut`.**

```bash
# dut — quick A/B at 8 peers: k=0 (stock) vs k=8 (trigger), 7 repeats, shuffled.
# Loads trigger.ko once, brings up peers+iperf servers once, sweeps the knob.
bash ~/measure_trigger.sh 8 "0 8" 7
# prints per-k median GBPS + wasted_frac + CV%, then dGbps / dWastedFrac vs k0.
```

Expected (the hypothesis): `wasted_frac` DROPS at k=8 (we stop waking into uncrypted
heads), the poll batch grows, and on the CPU-bound core that frees cycles → **GBPS
rises** — the number the 6-line fix left flat. Paste the summary table.

```bash
# dut — τ sweep (find the knee): hold k=8, vary the coalesce window.
for TAU in 4000 6000 8000 12000; do bash ~/measure_trigger.sh 8 "8" 5 "$TAU"; done
# dut — K sweep at the chosen τ:
bash ~/measure_trigger.sh 8 "0 4 8 16" 5
# dut — does it generalize across load? repeat the k=0/8 A/B at more peers:
for N in 8 16 32; do bash ~/measure_trigger.sh "$N" "0 8" 5; done
```

If a result looks off, confirm the knob is live: `cat
/sys/module/wireguard/parameters/wg_trig_k` and `…/wg_trig_tau_ns` (only valid while the
module is loaded). To rebuild the module after a source change, see "Rebuild the trigger
module" at the bottom of this file.

---

# ▶ SATURATION DIAGNOSIS — why ~4 Gb/s on a 10G NIC? (run first)

Every throughput claim depends on knowing the bottleneck. Single-peer tops out ~4 Gb/s
(1 peer = 1 NAPI = 1 core). At 8 peers we still see ~4 Gb/s → suspect the NIC funnels
all tunnels onto **one RX queue/core** (all peers share dst port 51820 + gen's src IP;
only the src UDP port varies, so an IP-only flow hash collapses them). Confirm before
trusting any throughput number.

> **FINDING (2026-06-22):** `/proc/softirqs` NET_RX over 3 s → **CPU3 = 84.9%** of all
> NET_RX, every other CPU ≤ 1.8%. The receive softirq is **funneled to a single core** —
> confirmed. Adding peers has NOT been buying cores; that is the 4 Gb/s ceiling.
> (Absolute count was low, +287/3 s — load likely idle during that snapshot; the
> *distribution* is the signal. Re-confirm under live load with the combined check below.)

## Decisive follow-up — is that core actually SATURATED at 4 Gb/s?
Confirms the funnel under live load AND answers the crux: is the bottleneck core ~100%
busy (⇒ cleanly CPU-bound ⇒ the trigger's CPU saving converts to throughput)?

> **RUN EVERYTHING ON `dut`.** You never log into gen — the `sudo ssh gen "…"` lines
> execute *from dut* and run the quoted part remotely on gen. The `/proc/stat` sampler
> reads dut's own cores (the receiver = what we care about).
```bash
# NOTE: node-to-node ssh works only as ROOT here -> drive the load with `sudo ssh`
# (plain `ssh gen` as user anasait => "Permission denied (publickey)" and NO load runs,
#  which silently makes the busy% read 0% everywhere).
# ONE-TIME: create genload_json.sh ON GEN (the nodes have no git repo; create over ssh):
sudo ssh -o StrictHostKeyChecking=no gen 'cat > /tmp/genload_json.sh' <<'EOF'
#!/bin/bash
N=$1; DUR=$2; STREAMS=$3
rm -f /tmp/ipf_*.json
for i in $(seq 0 $((N-1))); do
    ip netns exec "ns_c$i" iperf3 -c 10.0.0.1 -p $((5201+i)) -t "$DUR" -P "$STREAMS" -J > "/tmp/ipf_$i.json" 2>/dev/null &
done
wait
python3 - <<'PY'
import json,glob
tot=0.0
for f in glob.glob('/tmp/ipf_*.json'):
    try: d=json.load(open(f)); tot+=d['end']['sum_received']['bits_per_second']
    except Exception: pass
print("GBPS %.3f"%(tot/1e9))
PY
EOF

# SETUP (required, or you get GBPS 0.000): genload_json only runs iperf CLIENTS, so dut
# must have the module loaded, wg0 + 8 peers up, AND the iperf SERVERS listening.
sudo ip link del wg0 2>/dev/null; sudo rmmod wireguard 2>/dev/null
sudo insmod ~/wireguard_stock.ko
sudo bash ~/setup_dut_peers.sh 8
pkill -f 'iperf3 -s' 2>/dev/null
for i in $(seq 0 7); do iperf3 -s -p $((5201+i)) -D; done

# 30s load that also reports aggregate throughput
sudo ssh -o StrictHostKeyChecking=no gen "bash /tmp/genload_json.sh 8 30 4" &
sleep 1
# per-core busy% + softirq% over 10s WHILE the load runs
python3 - <<'PY'
import time
def snap():
    c={}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3:4].isdigit():
            p=l.split(); t=sum(map(int,p[1:])); idle=int(p[4])+int(p[5]); soft=int(p[7])
            c[p[0]]=(t,idle,soft)
    return c
a=snap(); time.sleep(10); b=snap()
rows=[]
for k in a:
    dt=b[k][0]-a[k][0]
    if dt>0: rows.append((k,100*(1-(b[k][1]-a[k][1])/dt),100*(b[k][2]-a[k][2])/dt))
rows.sort(key=lambda x:-x[1])
for k,busy,soft in rows[:12]: print(f"{k:6} busy={busy:5.1f}%  softirq={soft:5.1f}%")
PY
wait   # prints "GBPS <n>"
```

**Decision from this output:**
- **Top core ~100% busy (mostly softirq)** → cleanly **CPU-bound on one core**. This is the
  *ideal trigger testbed*, not a defect to fix → take **Design A** (below). Proceed to the
  low-variance sweep, then implement the trigger.
- **No core saturated** → 4 Gb/s is capped elsewhere (single-flow latency, or `gen`
  encrypt-bound — check gen the same way) → spread RX + add streams (Design B) to find the
  real ceiling first.

**Recommendation (decided 2026-06-22): embrace the single-core bottleneck — do NOT chase
10G line rate.** The funneled regime is exactly where the trigger should pay off: wasted
polls burn the *bottleneck* core's cycles, so reclaiming them is pure throughput. And it
reframes the peer sweep — more peers add **parallel-decrypt disorder on the same core**
(the condition that creates wasted polls), not more cores. Design B (spread to 10G) is a
*later* "it generalizes" run, not the contribution, and must not block the trigger.

## Run a 60 s load, then watch where the work lands
```bash
# dut: start a sustained load on gen
ssh -o StrictHostKeyChecking=no gen "bash /tmp/genload.sh 8 60 4" &

# (1) which CPUs take NET_RX softirq, and how concentrated?  -> the decisive check.
#     install-free (mpstat needs `sudo apt-get install -y sysstat`; you have sudo).
python3 - <<'PY'
import time
def snap():
    for l in open('/proc/softirqs'):
        if l.strip().startswith('NET_RX:'):
            return list(map(int, l.split()[1:]))
a=snap(); time.sleep(3); b=snap()
d=sorted(((i,b[i]-a[i]) for i in range(len(a))), key=lambda x:-x[1])
tot=sum(v for _,v in d) or 1
for i,v in d[:12]:
    print(f"CPU{i:<3} NET_RX +{v:<10} {100*v/tot:5.1f}%")
PY
# top CPU ~90-100% => funneled to one core (the 4 Gb/s ceiling). Spread across many => not the cap.

# (2) corroborate: are packets landing on one RX queue or many?
ethtool -S enp6s0f1 | grep -E 'rx.*packets' | awk '$2+0>0' | sort -t_ -k3 -n | tail -20

# (3) does the NIC hash L4 ports? need 'sd fn' (src/dst IP+port) to spread tunnels
ethtool -n enp6s0f1 rx-flow-hash udp4

# (4) check the GENERATOR isn't the cap (gen must encrypt 8 tunnels) — same NET_RX check on gen
ssh gen "python3 - <<'PY'
import time
def snap():
    for l in open('/proc/softirqs'):
        if l.strip().startswith('NET_RX:'): return list(map(int,l.split()[1:]))
a=snap(); time.sleep(3); b=snap()
d=sorted(((i,b[i]-a[i]) for i in range(len(a))),key=lambda x:-x[1]); t=sum(v for _,v in d) or 1
[print(f'CPU{i} +{v} {100*v/t:.1f}%') for i,v in d[:8]]
PY"
```

## If funneled to one queue/core — spread it, then re-measure throughput
```bash
# hash on L4 ports so the 8 tunnels' distinct src ports fan out across RX queues
sudo ethtool -N enp6s0f1 rx-flow-hash udp4 sdfn

# spread NIC IRQs across cores (vendor script if present, else RPS fallback below)
( ls /usr/*/set_irq_affinity* 2>/dev/null && sudo $(ls /usr/*/set_irq_affinity*|head -1) enp6s0f1 ) || \
for q in /sys/class/net/enp6s0f1/queues/rx-*/rps_cpus; do
    printf 'ffffffff,ffffffff' | sudo tee "$q" >/dev/null
done

# re-run an 8-peer throughput run and recheck mpstat: cores should now share %soft
sudo bash ~/measure_run.sh stock 8
```

**Two experimental designs (pick per what the diagnosis shows):**
- **A — clean single-core CPU-bound test (decisive for the trigger).** Keep the work on
  one core (1 peer, or pin IRQ+RPS to a single CPU). The core is the bottleneck, so the
  trigger's CPU-per-poll saving converts *directly* into higher single-core Gb/s. This
  is the cleanest proof and needs no RSS fiddling — **run this first.**
- **B — scaled realistic (spread).** After spreading RX, push 8/16/32 peers toward 10G
  and show the trigger either raises aggregate Gb/s or lowers CPU at fixed Gb/s. The
  bottleneck may move to the 10G line; then the metric becomes CPU headroom, not Gb/s.

---

# ▶ LOW-VARIANCE SWEEP — repeats + throughput + wasted-frac (replaces single runs)

Stop drawing conclusions from single N=8 runs. This captures **throughput AND
wasted-poll fraction in the same run**, repeats each cell, randomizes module order to
decorrelate drift, and reports median / IQR / CV. CV < ~5% ⇒ enough runs; else add more.

## One-time: create the throughput-capturing load + the harness
On **gen** — throughput-capturing load driver:
```bash
cat > /tmp/genload_json.sh <<'EOF'
#!/bin/bash
N=$1; DUR=$2; STREAMS=$3
rm -f /tmp/ipf_*.json
for i in $(seq 0 $((N-1))); do
    ip netns exec "ns_c$i" iperf3 -c 10.0.0.1 -p $((5201+i)) \
        -t "$DUR" -P "$STREAMS" -J > "/tmp/ipf_$i.json" 2>/dev/null &
done
wait
python3 - <<'PY'
import json, glob
tot = 0.0
for f in glob.glob('/tmp/ipf_*.json'):
    try:
        d = json.load(open(f)); tot += d['end']['sum_received']['bits_per_second']
    except Exception: pass
print("GBPS %.3f" % (tot / 1e9))
PY
EOF
```
On **dut** — copy `measure_run.sh`, `run_sweep.sh`, `analyze_sweep.py` from
`scripts/cloudlab/` (heredocs there). Then:

## Run the sweep (≥7 repeats per cell)
```bash
# peers, modules, repeats, dur, streams
bash ~/run_sweep.sh "1 8 16 32" "stock patched" 7 20 4
```
Prints a CSV (`~/sweep_<ts>.csv`) and a summary table: per (module,peers) median Gb/s
and wasted-frac with **CV%** (the variance you were worried about), plus
`median(patched) − median(stock)` per peer count. Paste the summary table.

**Read-out:** if `gbps_cv%` and `wfrac_cv%` are < ~5%, 7 runs suffice; the
patched−stock deltas are now trustworthy (with error bars), unlike the single-run A/B.

---

# ▶ Phase D+ — measure the RE-POLL GAP (run now)

Goal: put a number on the claim *"the MISSED re-poll fires sub-µs after the head was
proven UNCRYPTED, while `T_decrypt`≈5µs → structurally too early."* We never measured
it. And the trace build says **44% of reschedules are productive** — impossible if the
gap were a flat sub-µs (flat-hazard predicts `useful ≈ gap/T_decrypt`; 44% ⇒ a useful
gap near **~2.2 µs**, not sub-µs). So measure the distribution and split it.

**What's measured:** for each peer NAPI, `gap = entry(poll N+1) − return(poll N)`, keyed
by the napi pointer (polls serialize per-NAPI). Split three ways:
- `@gap_all_ns` — every inter-poll gap (will be **bimodal**: a tight re-poll spike + a
  long idle tail = fresh schedules ~Δ_complete).
- `@missed_repoll_WASTED_ns` — gap for re-polls that followed a MISSED reschedule **and**
  came back wasted (head still UNCRYPTED). **This is the "too early" number.**
- `@missed_repoll_useful_ns` — same but the re-poll delivered ≥1 (head crypted in the
  gap). **Where this mass sits = how long you'd have had to wait = τ.**

`napi_complete_done` is `EXPORT_SYMBOL` on 5.15 → directly kretprobe-able; `retval==0`
is the MISSED reschedule. Run on **stock** (gap timing only, no decrypt probe to
inflate it — we already have `T_decrypt≈5µs`).

## Step 1 — create the probe (on dut)
```bash
cat > ~/measure_repoll_gap.sh <<'EOF'
#!/bin/bash
set -uo pipefail
MOD=${1:?usage: measure_repoll_gap.sh stock N [DUR] [STREAMS] [GEN]}
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
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload.sh $N $DUR $STREAMS" &
LOAD=$!
DURP=$((DUR+3))
bpftrace -e '
kprobe:wg_packet_rx_poll {
    $n = arg0;
    @napi[tid] = $n;
    @resched_seen[tid] = 0;
    if (@last_end[$n]) {
        @gap[tid] = nsecs - @last_end[$n];
        @was_repoll[tid] = @prev_resched[$n];
    } else {
        @gap[tid] = 0;
        @was_repoll[tid] = 0;
    }
}
kretprobe:napi_complete_done /@napi[tid]/ {
    @resched_seen[tid] = (retval == 0);
}
kretprobe:wg_packet_rx_poll {
    $n = @napi[tid];
    if (@gap[tid]) {
        @gap_all_ns = hist(@gap[tid]);
        if (@was_repoll[tid]) {
            if (retval == 0) { @missed_repoll_WASTED_ns = hist(@gap[tid]); }
            else             { @missed_repoll_useful_ns = hist(@gap[tid]); }
        }
    }
    @prev_resched[$n] = @resched_seen[tid];
    @last_end[$n] = nsecs;
    delete(@napi[tid]); delete(@gap[tid]);
    delete(@was_repoll[tid]); delete(@resched_seen[tid]);
}
interval:s:'"$DURP"' {
    print(@gap_all_ns);
    print(@missed_repoll_WASTED_ns);
    print(@missed_repoll_useful_ns);
    clear(@last_end); clear(@prev_resched);
    exit();
}'
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT repoll_gap module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
EOF
```

## Step 2 — run at 8 peers (on dut)
```bash
sudo bash ~/measure_repoll_gap.sh stock 8
```

Read-out / what to look for:
- **`@missed_repoll_WASTED_ns` mode** — if it sits in `[256,512)`–`[512,1024)` ns, the
  "sub-µs, nothing can change" claim is confirmed for the wasted population. The ratio
  `T_decrypt / median(WASTED_gap)` = **"how many times too early"** the re-poll is.
- **`@missed_repoll_useful_ns` mode** — expect it shifted *right* (µs-scale). The gap
  where WASTED mass ends and useful mass begins ≈ the **break-even τ**: wait that long
  and most wasted re-polls would have found a crypted head. This is the direct,
  data-driven setting for `TRIGGER_DESIGN`'s τ (currently a guessed 20 µs).
- **Sanity:** count under `@missed_repoll_WASTED_ns` should ≈ `wasted_after_resched`
  (897,901 from the trace build).
- `@gap_all_ns` bimodality: tight spike = MISSED re-polls; long tail (~Δ_complete
  ~100 µs) = genuine fresh schedules. The spike is the population the trigger removes.

Repo copy: `scripts/cloudlab/measure_repoll_gap.sh`.

---

# ▶ Phase D confirmation — trace build (run now)

Goal: prove wasted polls are `MISSED`-driven re-polls. Counters in `wg_packet_rx_poll`:
`polls`, `wasted` (work_done==0), `resched` (napi_complete_done returned false →
MISSED forced a reschedule), `wasted_after_resched` (wasted poll whose previous poll
on the same napi rescheduled). Built from **stock** (restore `queueing.h.orig`).

## Step 1 — restore stock + inject counters (on dut)
```bash
cd ~/linux-source-5.15.0
cp drivers/net/wireguard/queueing.h.orig drivers/net/wireguard/queueing.h
python3 - <<'PY'
b="drivers/net/wireguard"
r=open(b+"/receive.c").read()
assert r.count("return work_done;")==1
assert r.count("napi_complete_done(napi, work_done);")==1
assert "wg_trace_polls" not in r
r=r.replace("int wg_packet_rx_poll(struct napi_struct *napi, int budget)",
  "extern unsigned long wg_trace_polls, wg_trace_wasted, wg_trace_resched, wg_trace_wasted_after_resched;\nint wg_packet_rx_poll(struct napi_struct *napi, int budget)",1)
r=r.replace("int work_done = 0;","int work_done = 0; int dbg_resched = 0;",1)
r=r.replace("napi_complete_done(napi, work_done);","dbg_resched = !napi_complete_done(napi, work_done);",1)
r=r.replace("return work_done;",
  "wg_trace_polls++; if (work_done == 0) { wg_trace_wasted++; if (peer->dbg_prev_resched) wg_trace_wasted_after_resched++; } wg_trace_resched += dbg_resched; peer->dbg_prev_resched = dbg_resched; return work_done;",1)
open(b+"/receive.c","w").write(r)
p=open(b+"/peer.h").read()
assert "dbg_prev_resched" not in p
assert p.count("struct napi_struct napi;")==1
p=p.replace("struct napi_struct napi;","struct napi_struct napi;\n\tint dbg_prev_resched;",1)
open(b+"/peer.h","w").write(p)
m=open(b+"/main.c").read()
if "wg_trace_polls" not in m:
    inj=("unsigned long wg_trace_polls, wg_trace_wasted, wg_trace_resched, wg_trace_wasted_after_resched;\n"
         "module_param(wg_trace_polls, ulong, 0444);\n"
         "module_param(wg_trace_wasted, ulong, 0444);\n"
         "module_param(wg_trace_resched, ulong, 0444);\n"
         "module_param(wg_trace_wasted_after_resched, ulong, 0444);\n\n")
    m=m.replace("static int __init", inj+"static int __init",1)
    open(b+"/main.c","w").write(m)
print("trace counters injected")
PY
```

## Step 2 — build (on dut)
```bash
make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/net/wireguard modules 2>&1 | tail -4
cp drivers/net/wireguard/wireguard.ko ~/wireguard_trace.ko
modinfo ~/wireguard_trace.ko | grep -E 'srcversion|parm'
```

## Step 3 — run at 8 peers + read counters (on dut)
```bash
sudo bash ~/measure_one.sh trace 8
echo "polls=$(cat /sys/module/wireguard/parameters/wg_trace_polls)"
echo "wasted=$(cat /sys/module/wireguard/parameters/wg_trace_wasted)"
echo "resched=$(cat /sys/module/wireguard/parameters/wg_trace_resched)"
echo "wasted_after_resched=$(cat /sys/module/wireguard/parameters/wg_trace_wasted_after_resched)"
```

**Confirms the model:** `wasted` ≈ measure_one's `WASTED` (sanity); `resched` large;
**`wasted_after_resched` ≈ `wasted`** → wasted polls are MISSED-driven re-polls. If
not, rethink before designing.

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

---

# ▶ Rebuild the trigger module (clean-room, on dut)

`~/wireguard_trigger.ko` is built from a **pristine** 5.15 tree, NOT the contaminated
`~/linux-source-5.15.0` (that one has stale `wg_trace`/`wg_dbg` edits in receive.c/main.c
and no backups). The trigger patch lives in the repo at `build/wg515-trigger/` (5 files:
`peer.h peer.c queueing.h receive.c main.c`). The build matters because a rigorous A/B
needs trigger and its own k=0 baseline to share ONE binary.

```bash
# dut — (1) extract a fresh pristine tree from the Ubuntu source tarball
rm -rf ~/wg_build && mkdir ~/wg_build && cd ~/wg_build
tar xjf /usr/src/linux-source-5.15.0/linux-source-5.15.0.tar.bz2 \
    --strip-components=1 linux-source-5.15.0/drivers/net/wireguard
# (2) make a trigger tree and drop in the 5 modified files (push them from the Mac repo:
#     scp build/wg515-trigger/{peer.h,peer.c,queueing.h,receive.c,main.c} \
#         anasait@<dut>:~/wg_trigger/drivers/net/wireguard/   — see scripts/cloudlab/)
cp -R ~/wg_build ~/wg_trigger
# (3) build + stage
cd ~/wg_trigger
make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/net/wireguard modules
cp drivers/net/wireguard/wireguard.ko ~/wireguard_trigger.ko
modinfo ~/wireguard_trigger.ko | grep -E '^parm|^srcversion'   # expect wg_trig_k, wg_trig_tau_ns
```

From the Mac, the whole push+build is one step via `scripts/cloudlab/` (the same flow
that produced the current `3076ED3…` build). Default `wg_trig_k=0` ⇒ the module is
stock; set `8` to enable the trigger.
