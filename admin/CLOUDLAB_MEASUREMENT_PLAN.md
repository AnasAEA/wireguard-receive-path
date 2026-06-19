# CloudLab Measurement Plan — instrument the WireGuard receive path to design a batching-aware trigger

> **Author:** Anas Ait El Hadj · **Draft for the meeting with Alain, Mon June 15, 2026, 14h**
> Inria KrakOS (LIG) · supervisors Alain Tchana, André Freyssinet

---

## 0. Guiding principle (Alain, June 12)

We do **not** rush to benchmark the current six-line fix as if it were the final
solution. The goal of this phase is to **improve** the solution toward a
*batching-aware trigger*. To design that trigger we first need a **cost model of
the receive path** — i.e. we must *measure how long each step takes* and measure
everything we reasonably can. Saturated-NIC throughput benchmarking of the
"final" solution comes **after** the solution is improved, not now.

So the deliverable of this phase is **numbers that explain where time goes on the
receive path**, not a throughput headline.

---

## 1. Why measurement comes before the new trigger

The current fix wakes the NAPI as soon as the *head* of the per-peer ordered
queue is decrypted. That is correct, but not optimal: if only the head is ready
and nothing behind it, we pay a full poll (softirq entry + `napi_complete_done` +
GRO flush + stack traversal) to deliver a **single** packet — no GRO batching
benefit.

A *batching-aware* trigger would instead wake **only when waking pays off** —
when enough packets are (or are about to be) ready that batching amortises the
poll cost. To decide that, we need to know the actual magnitudes of:

| Symbol | Meaning | Why it matters |
|--------|---------|----------------|
| `C_poll` | fixed cost of one poll pass (softirq entry → `napi_complete_done`), independent of packets delivered | the overhead a wake must justify |
| `C_deliver` | marginal cost per packet *inside* the poll (peek, counter-validate, `consume_data_done`, `napi_gro_receive`) | cost of handling one more packet |
| `C_stack` | cost saved per packet by GRO (one stack traversal + copy-to-userspace shared instead of per-packet) | the *benefit* of batching |
| `T_decrypt` | time to decrypt one packet (`decrypt_packet`, ChaCha20-Poly1305) | sets how fast packets become ready |
| `Δ_complete` | inter-completion gap: time between successive decrypt completions for a peer | sets how long we'd wait for the next packet |

The trigger's decision rule will be some form of *"wake when the expected batch
benefit `(k−1)·C_stack` exceeds the cost of waiting (added latency) and the poll
overhead `C_poll` is amortised over `k` packets."* **We cannot pick the threshold
without these numbers.** Hence: measure first.

---

## 2. The receive path we are instrumenting

Data-packet path (post-handshake), with source locations in the curated tree
(`linux-source/drivers/net/wireguard/`):

| # | Step | Function / site | File:line |
|---|------|-----------------|-----------|
| 1 | UDP datagram enters WG, dispatched by type | `wg_packet_receive` | `receive.c:542` |
| 2 | Keypair lookup + **two-phase enqueue**: per-peer ordered queue **and** per-device decrypt queue, dispatched `queue_work_on(cpu, packet_crypt_wq)` | `wg_packet_consume_data` → `wg_queue_enqueue_per_device_and_peer` | `receive.c:509`, `:526` |
| 3 | **Decrypt** (ChaCha20-Poly1305) in per-CPU worker; on completion sets state + wakes NAPI | `wg_packet_decrypt_worker` → `decrypt_packet` → `wg_queue_enqueue_per_peer_rx` | `receive.c:493`, `:501`, `:503` |
| 4 | **The trigger** — unconditional today, conditional in our fix | `napi_schedule(&peer->napi)` | `queueing.h:196` |
| 5 | **Poll** drains the ordered queue head-first; stops at first `UNCRYPTED`; returns `work_done` | `wg_packet_rx_poll` | `receive.c:438` (head check `:451-453`, `napi_complete_done` `:488`) |
| 6 | **GRO #2** — staple decrypted packets | `napi_gro_receive` | `receive.c:411` |
| 7 | Flush GRO → up the stack → copy to userspace / forward | `napi_complete_done` → `gro_flush_normal` | (core) |

The decrypt workqueue is `packet_crypt_wq`, `WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM |
WQ_PERCPU` (`device.c:346`) — one worker per core, which is why completions are
out of order.

---

## 3. CloudLab environment (to build from scratch)

### 3.1 Project & access
- **Project:** Alain's CloudLab project **"WG"**. (Teo's previous experiment is
  no longer accessible — we provision our own.)
- **My account:** approved. I can create experiments under the WG project.
- No profile/experiment exists yet → **we create a profile** (RSpec) and
  instantiate it.

### 3.2 Node selection (decision for Monday)
We need: a **real multi-queue NIC** (10–40 GbE), **many cores** (to reproduce the
parallel-decrypt EoI), and **bare metal** (not a VM — we load a patched kernel
module and run kprobes/perf).

- **Candidate:** `c220g2` (Wisconsin) — 2× Intel Xeon E5-2660 v3 (10c/20t each,
  20c/40t total), 160 GB RAM, Intel X520 dual-port 10 GbE + Mellanox ConnectX-3
  FDR. This matches what Teo used and is well-suited.
- **Alternatives to confirm by availability:** `c6525-25g` / `c6525-100g` (Utah,
  more cores, 25/100 GbE), `xl170` (Utah, 10c, 25 GbE), `d6515` (Clemson, 32-core
  AMD, 100 GbE — good for an x86 high-core check).
- **ARM cross-check (optional):** `m400`/`r320` or an Ampere node if we want to
  confirm the ARM↔x86 question from the report on server hardware.

> **Ask Alain:** which cluster/node has the best availability and whether he wants
> the x86 high-core node and/or an ARM node for the architecture comparison.

### 3.3 Topology
```
 client-0 ──┐
            ├── (10/25 GbE link) ──► server (DUT: WireGuard receiver, instrumented)
 client-1 ──┘
```
- **Server = Device Under Test.** All instrumentation runs here; this is where the
  receive-path EoI lives.
- **2 client nodes** as traffic sources. To reach the many-peer regime (up to
  ~1,000 peers) we use **network namespaces** on the clients — each namespace is
  one WireGuard peer with its own keypair and allowed-IPs (the approach from
  Teo's onboarding). The server routes/dispatches per peer.
- Start small (1, 4, 8, 16, 32 peers) to mirror the M1 study and validate, then
  scale up toward 1,000.

### 3.4 OS / kernel / module
- **Image:** a CloudLab bare-metal Ubuntu (e.g. 22.04 / 24.04) with a **6.x
  kernel**, kernel **headers**, and **BTF** enabled (`/sys/kernel/btf/vmlinux`
  present) so bpftrace kprobes work without manual DWARF.
- **WireGuard:** in-kernel since 5.6 — present, but we need **our patched
  module**. Plan: build the WireGuard module out-of-tree against the running
  kernel (the `wireguard-linux-compat` style build or rebuilding the in-tree
  module), apply our `receive.c` / `queueing.h` change, `insmod` the patched
  `.ko`. Keep stock and patched `.ko` side by side for A/B.
- Confirm we can also run an **uninstrumented stock** module for baseline.

### 3.5 Profile creation (RSpec) — outline
- Build a small **geni-lib python profile** (or the portal's "raw PC" form) that
  requests: 1 server + 2 clients of the chosen type, a LAN linking them, the
  Ubuntu image, and a **post-boot setup script** that installs tooling and builds
  the modules.
- Parameterise node type and peer count so we can re-instantiate easily.
- Store the profile + setup scripts in the repo (`scripts/cloudlab/`).

### 3.6 Software setup (post-boot script)
- `bpftrace`, `bpfcc-tools`, `linux-tools-$(uname -r)` (perf), `iperf3`,
  `wireguard-tools`, build-essential, kernel headers.
- Our measurement harness from `scripts/` (the v2 multipeer scripts), adapted
  from loopback/namespaces to the client→server real-NIC topology.

---

## 4. Instrumentation plan — measuring per-step cost

The core of this phase. For each cost in §1 we attach a probe on the server.

| Cost | How to measure | Tool / probe |
|------|----------------|--------------|
| `T_decrypt` (per-packet decrypt) | duration of `decrypt_packet` (or the worker body around it) | `bpftrace` kprobe/kretprobe on `decrypt_packet`; histogram of latency |
| `Δ_complete` (inter-completion gap) | time between successive `wg_queue_enqueue_per_peer_rx` (or `napi_schedule`) per peer | `bpftrace` kprobe timestamps keyed by peer |
| `C_poll` (fixed poll overhead) | duration of `wg_packet_rx_poll` **when `work_done == 0`** (pure overhead, the wasted-poll case) | `bpftrace` k/kretprobe on `wg_packet_rx_poll`; correlate retval with duration |
| `C_deliver` (per-packet in poll) | slope of poll duration vs `work_done` (regress duration on retval) | `bpftrace` 2-D: lhist of duration bucketed by `work_done` |
| `C_stack` (GRO benefit) | cost of `napi_gro_receive` + the flush/stack path; compare batched vs unbatched | `bpftrace` on `napi_gro_receive` and `napi_complete_done`/`gro_flush_normal`; `perf` for stack traversal |
| Wasted-poll rate (the EoI signature) | histogram of `wg_packet_rx_poll` return value (`work_done`); spike at 0 = waste | `bpftrace` `kretprobe:wg_packet_rx_poll { @=lhist(retval,0,64,8) }` |
| GRO batch size distribution | how many packets per useful poll / per GRO flush | `bpftrace` on `napi_gro_receive` count per `napi_complete_done` |
| CPU utilisation per core | confirm single-core saturation, where cycles go | `perf stat`, `mpstat`, `perf record/report` (flame graph of the softirq) |
| Queue op cost (optional) | `ptr_ring_consume_bh` / enqueue overhead | `bpftrace` on the ring ops |

**Method notes**
- All probes on the **server** only.
- Prefer **in-kernel aggregation** (bpftrace maps/histograms) over per-event dumps
  to avoid probe overhead skewing the very timings we measure — and always run a
  **probe-overhead control** (measure with probes attached but idle vs detached).
- Pin/measure per-core to see the saturated core explicitly.
- Capture both **stock** and **patched** modules for every measurement.

---

## 5. From the cost model to the trigger

Once §4 yields `C_poll`, `C_deliver`, `C_stack`, `T_decrypt`, `Δ_complete`, we can:
1. **Quantify the residual waste** of the current fix (how many one-packet polls
   it still issues, and what they cost).
2. **Derive a threshold/policy** for the batching-aware trigger, e.g. "delay the
   wake until `k` packets are ready (or a bounded time `τ` elapses), where `k` and
   `τ` are chosen so `(k−1)·C_stack > C_poll + acceptable added latency`."
3. **Bound the latency cost** using `Δ_complete` (how long waiting for the next
   packet actually takes) so we never trade throughput for unacceptable tail
   latency.
4. Prototype the trigger, then **re-measure** the same costs to confirm the
   improvement — iterate.

This is the loop: **measure → model → improve trigger → re-measure.**

---

## 6. Configurations & methodology

- **Modules:** (a) stock WireGuard, (b) our conditional fix. *(Paper's dedicated
  `gro_wq` and the combined variant come later, once the trigger is improved.)*
- **Peer counts:** 1, 4, 8, 16, 32 → then scale to 128, 512, ~1,000.
- **Load:** `iperf3` (and/or a UDP flood) from client namespaces, sized to push
  the server's receive path toward saturation on the real NIC.
- **Repeats & variance:** ≥5 runs per config, report median + spread; reuse the
  variance-control approach from the M1 v2 harness.
- **Primary outputs (this phase):** the per-step cost table, wasted-poll
  histograms, GRO batch-size distributions, per-core CPU. **Throughput is a
  secondary sanity check here, not the headline.**

---

## 7. Phased timeline (through July)

| Phase | Goal | Output |
|-------|------|--------|
| **A. Provision** | Create WG profile, instantiate server+2 clients, build stock + patched modules | working testbed, scripts in `scripts/cloudlab/` |
| **B. Validate** | Reproduce the EoI signature on real NIC (wasted-poll spike), small peer counts | confirmation it reproduces off-loopback |
| **C. Instrument** | Attach all §4 probes, gather per-step costs (stock + patched) | the cost-model dataset |
| **D. Model** | Turn costs into the trigger threshold/policy | written cost model + trigger design |
| **E. Improve** | Prototype the batching-aware trigger, re-measure | improved module + before/after numbers |
| **F. (Later) Benchmark** | Real-NIC throughput of the improved solution; combine with paper's fix; ARM↔x86 | final performance numbers |

We are aiming to get through **A–C** first; **D–E** is the heart; **F** is the
deferred benchmarking Alain explicitly de-prioritised for now.

---

## 8. Open questions for Alain (Monday June 15)

1. **Node/cluster:** which node type and cluster (availability)? Include an x86
   high-core node? An ARM node for the architecture comparison?
2. **Kernel/image:** is there a preferred kernel version to match the study, or do
   we take the cluster's stock 6.x and rebuild the module against it?
3. **Peer-generation:** namespaces on 2 clients (Teo's approach) vs more client
   nodes — how far toward 1,000 peers do we need for the *measurement* (vs the
   later benchmark)?
4. **Cost-model scope:** is the §1 set of costs the right set, or does he want
   additional steps instrumented (e.g. handshake path, encrypt/TX side)?
5. **Trigger policy shape:** count-threshold `k`, time-bound `τ`, or adaptive — any
   prior preference before we let the data decide?
6. **Probe methodology:** acceptable to rely on bpftrace/BTF, or does he want
   `perf`-based or even in-module counters for the hot path?

---

## 9. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Probe overhead skews the timings we measure | in-kernel aggregation; probe-overhead control runs; cross-check hot spots with `perf` |
| Loopback EoI doesn't fully reproduce on real NIC | Phase B explicitly validates the wasted-poll signature before investing in the full cost model |
| Building/loading the patched module on CloudLab's kernel fails | pick an image with headers+BTF; keep the out-of-tree compat build path; test on a fresh node early |
| Reaching 1,000 peers is hard with 2 clients | namespaces scale peers without more nodes; for *measurement* a moderate peer count may suffice — confirm scope with Alain |
| CloudLab node time limits / availability | parameterised profile for quick re-instantiation; keep setup scripted and idempotent |

---

## 10. Next actions (pre/post Monday)
- [ ] Before Monday: this plan reviewed; node-type shortlist ready.
- [ ] Monday 14h: align with Alain on §8 decisions.
- [ ] Then: create the WG profile + setup scripts (`scripts/cloudlab/`), instantiate, build modules (Phase A).
