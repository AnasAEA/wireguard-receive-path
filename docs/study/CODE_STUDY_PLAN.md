# Code Study Plan — WireGuard + io-wq Source Analysis
# Anas Ait El Hadj · Full-time phase · May 2026

> Goal: go from "I read the paper" to "I can point at the exact lines."
> Every claim in the report and presentation needs a source location in the kernel.

---

## Repos to clone

```bash
# WireGuard kernel module — standalone repo, much smaller than full kernel
git clone https://github.com/WireGuard/wireguard-linux.git

# wireguard-go — for Phase 3 comparison
git clone https://github.com/WireGuard/wireguard-go.git

# Linux kernel — sparse checkout for io_uring/ and kernel/workqueue.c only
# (avoid cloning the full 4GB tree)
git clone --depth=1 --filter=blob:none --sparse \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-source
cd linux-source
git sparse-checkout set io_uring kernel/workqueue.c include/linux/workqueue.h
cd ..
```

---

## Part 1 — WireGuard Reception Pipeline

**Directory:** `wireguard-linux/src/`

### Files to read, in this order

| File | Why |
|------|-----|
| `device.h` | Data structures: `wg_device`, workqueue declarations, NAPI setup |
| `device.c` | Initialization: how the RX workqueue and NAPI are set up at boot |
| `receive.c` | **The core file.** The entire RX pipeline lives here. |
| `noise.c` | Decryption logic called by the workqueue worker |
| `peer.c` | Per-peer workqueue association |

### Questions to answer in `receive.c`

1. **Where is `spin_unlock_bh` called?**
   - Find the exact function and line.
   - Confirm it is in the decryption worker path (Stage 2), not in Stage 1 or Stage 3.
   - Note what lock is held and why BH must be re-enabled at that point.

2. **Where is `napi_schedule()` called?**
   - Find every call site in `receive.c`.
   - For each: what triggers it? What CPU context is it running in?
   - Confirm the "stale pointer" claim: does `napi_schedule()` pin to current CPU or use a stored value?

3. **What is the workqueue worker function?**
   - Find `wg_packet_rx_worker()` or equivalent.
   - Trace the call chain: worker entry → decrypt → `spin_unlock_bh` → where does GRO fire?

4. **How is the NAPI poll function registered?**
   - Find `netif_napi_add()` call in `device.c`.
   - What function is registered as the NAPI poll handler?
   - Note whether it's the standard NAPI path or something WireGuard-specific.

5. **What workqueue is used for decryption?**
   - Find `alloc_workqueue()` or `system_wq` usage in `device.c`.
   - Is it a dedicated WireGuard workqueue or the system shared workqueue?
   - What flags are set (WQ_UNBOUND? WQ_CPU_INTENSIVE?)?

### Questions to answer about the patch (from paper)

6. **What does the workqueue fix add?**
   - The paper describes wrapping `napi_struct` inside a `work_struct`.
   - Find `netif_napi_add_wq()` — does it exist in v6.14? If so, what does it do?
   - If not, that means the patch hasn't been merged upstream — note this.

7. **What is the patch size / scope?**
   - Paper says 136 LoC for NAPI + 55 LoC for WireGuard.
   - Try to locate whether any of this is visible in `net/core/dev.c` or `net/core/gro.c`.

---

## Part 2 — Kernel Workqueue Subsystem

**File:** `linux-source/kernel/workqueue.c (sparse checkout)`

This is the infrastructure both WireGuard and io-wq build on.

### Questions to answer

1. **How does `queue_work_on()` enqueue a work item?**
   - Trace from `queue_work_on(cpu, wq, work)` to where the work lands in a per-CPU queue.
   - What data structure holds the pending work?

2. **How does a worker thread pick up work?**
   - Find the worker thread function (something like `worker_thread()`).
   - How does it select which work_struct to execute next?
   - Is there any priority or ordering within a single CPU queue?

3. **How does CPU affinity work?**
   - When `queue_work_on(cpu, ...)` is called with a specific CPU, is the work guaranteed to run on that CPU?
   - What happens if that CPU is overloaded?

4. **What are `WQ_UNBOUND` workqueues?**
   - How do they differ from per-CPU workqueues?
   - Which type does WireGuard use for decryption?

---

## Part 3 — io_uring Worker Pool (io-wq)

**Directory:** `linux-source/io_uring/ (sparse checkout)`

### Files to read

| File | Why |
|------|-----|
| `io-wq.h` | Data structures: `io_wq`, `io_wq_work`, worker types |
| `io-wq.c` | The worker pool implementation |
| `io_uring.c` | Where Path 2 (IOSQE_ASYNC) is triggered |

### Questions to answer

1. **How does io-wq dispatch a work_struct?**
   - Find `io_wq_enqueue()`.
   - Trace the path to `queue_work_on()`. Confirm it uses the same kernel workqueue subsystem call.

2. **What is the difference between bounded and unbounded workers in io-wq?**
   - Find where bounded vs unbounded is decided.
   - For socket I/O: which type is used and why?

3. **Where does IOSQE_ASYNC force the io-wq path?**
   - Find where `IOSQE_ASYNC` is checked in `io_uring.c`.
   - What does it skip that the normal socket path would do (the non-blocking attempt)?

4. **How does IORING_FEAT_NO_IOWAIT change the file read path?**
   - Find where this feature flag is set.
   - What condition routes file reads to Path 1 (inline) instead of Path 2?

5. **The proxy claim — verify it:**
   - Does io-wq call `queue_work_on()` from `kernel/workqueue.c`?
   - Or does it use its own dispatch mechanism?
   - This is the key question: if io-wq uses a different dispatch path than `queue_work_on`, the proxy argument needs to be qualified.

---

## Part 4 — wireguard-go

**Directory:** `wireguard-go/`

### Files to read

| File | Why |
|------|-----|
| `device/device.go` | Device setup, goroutine pool initialization |
| `device/receive.go` | RX pipeline — goroutine-based equivalent of WireGuard's receive.c |
| `device/peer.go` | Per-peer goroutine management |
| `tun/tun.go` | TUN device interface — the user/kernel boundary (Phase 3 caveat) |

### Questions to answer

1. **How does wireguard-go structure the RX pipeline?**
   - Are there goroutines equivalent to each of WireGuard's three stages?
   - How is decryption parallelized? One goroutine per peer? A pool?

2. **Where would EoI be impossible by construction?**
   - Goroutines are scheduled by the Go runtime in user space.
   - Confirm there is no mechanism by which a downstream goroutine could preempt an upstream one mid-execution in the same way softirq preempts workqueue.

3. **What is the TUN boundary overhead?**
   - How does wireguard-go move packets between kernel network stack and user space?
   - How many syscalls per packet (approximately)?
   - This quantifies the Phase 3 caveat: the gap measured vs kernel WireGuard is a lower bound on workqueue overhead because of this boundary.

4. **What does a realistic throughput comparison look like?**
   - Does wireguard-go have any published benchmarks at scale (1,000 clients, 25 Gbps)?
   - If not, note that as a gap.

---

## Study Order

```
Day 1 (today):   device.h + device.c — understand the WireGuard data structures and workqueue setup
Day 2:           receive.c — find spin_unlock_bh, napi_schedule, worker function
Day 3:           kernel/workqueue.c — understand queue_work_on dispatch
Day 4:           io_uring/io-wq.c + io-wq.h — verify the proxy claim at source level
Day 5:           wireguard-go/device/receive.go — understand the Go pipeline
```

---

## Output: What This Study Should Produce

By the end of this week, you should be able to:

1. Point at the exact line in `receive.c` where EoI is triggered.
2. Confirm (or qualify) that io-wq and WireGuard's workqueue use the same kernel dispatch primitives.
3. Describe the wireguard-go RX pipeline at a level that makes the Phase 3 comparison concrete.
4. Have a list of tracepoints with the exact kernel functions they instrument.

This feeds directly into:
- The Alain presentation (slides 3–5)
- The Phase 2 measurement setup (which functions to trace)
- The final report (§2.1 can be upgraded from "paper says X" to "source confirms X at line Y")
