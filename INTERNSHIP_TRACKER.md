# 🔬 Internship Tracker: io_uring Performance Research

## 📋 Overview

| Field | Details |
|-------|---------|
| **Organization** | Inria - KrakOS Team (LIG) |
| **Location** | Grenoble, Auvergne-Rhône-Alpes, France |
| **Duration** | January 2026 - Present |
| **Supervisor** | André Freyssinet |
| **Team Lead** | Alain Tchana |
| **Subject** | Performance I/O (io_uring, Linux Kernel) |

---

## 🎯 Research Objectives

### Main Goal
Study and evaluate io_uring performance for transparent file system access, specifically investigating inefficiencies in how io_uring is used in real-world applications.

### Hypothesis
io_uring-based implementations in applications like **WireGuard** are slower than user-level library versions (e.g., Go implementation) due to:
- Inefficient use of **workqueues**
- **Context switches** when kernel threads fetch from workqueues
- **Thread blocking** (not just task blocking)
- Non-optimal queueing/scheduling policies

### Specific Tasks
- [x] Evaluate io_uring performance for transparent file system access in heterogeneous environments — *baseline investigation complete, see IO_URING_REFERENCE.md*
- [x] Understand how io-wq workers are triggered and what changed between kernel versions (`IORING_FEAT_NO_IOWAIT` discovery)
- [ ] Analyze queueing/scheduling bottlenecks related to kernel threads and workqueues in async I/O path — *in progress: tools verified, need network workload next*
- [ ] Reproduce and characterize overhead (latency, context switches, contention, CPU cycles) caused by non-optimal queueing policies
- [ ] Stress test I/O-intensive applications (microbench + application workloads) to highlight performance limits and variability
- [ ] Propose and evaluate scheduling/queue management solutions to reduce overhead (batching, CPU affinity, wakeup reduction, worker tuning)

---

## 🏆 What Success Looks Like

> ⚠️ **Golden Rule:** Reproduction first. Always. If you can't reproduce the slowdown reliably, every explanation will be shaky and every "fix" will look like random luck.

### Definition of Done
- [ ] **Reproduce** WireGuard io_uring slowdown vs Go implementation with <10% variance across multiple runs
- [ ] **Attribute** overhead to at least 2 measurable mechanisms (e.g., worker thread wakeups + CPU migrations)
- [ ] **Show improvement** with a mitigation (batching/affinity/worker tuning) by ≥20% throughput OR ≤30% tail latency reduction
- [ ] **Document** reproducible scripts + configs so someone else can rerun everything in one command

### Milestones
| Phase | Deliverable | Target Date | Status |
|-------|-------------|-------------|--------|
| 0. Setup | Linux environment (Fedora Asahi Remix) on MacBook | **Feb 6-7** | ✅ Done |
| 1. Understand | Reading summaries + knowledge base | Mid-February | ✅ Done — io_uring internals, Cloudflare worker pool, Kernel VPN paper (EoI), DBMS paper all read and noted |
| 2. Reproduce | Clean baseline benchmark with <10% variance | End of February → **April** | 🟡 In Progress — need WireGuard test environment (contact Brice/Teo) |
| 3. Measure | Overhead attribution report (context switches, migrations, etc.) | Mid-March → **May** | ⬜ Not started |
| 4. Mitigate | Tested improvement with one approach | April → **June** | ⬜ Not started |
| 5. Document | Final report + reproducibility pack | End of internship | ⬜ Not started |

---

## 📅 Schedule

### Part-Time Period (January 2026 - End of April 2026)
| Day | Time | Focus |
|-----|------|-------|
| **Wednesday** | Morning | Research & Development |
| **Friday** | Afternoon | Research & Development |

### Full-Time Period (May 2026 onwards)
*TBD*

---

## Metrics & Measurement Strategy

### Core Performance Outputs
| Metric | Tool | Why It Matters |
|--------|------|----------------|
| Throughput (req/s, MB/s) | iperf3, fio, custom bench | Primary performance indicator |
| Latency distribution (p50/p90/p99/p99.9) | histogram tools, bpftrace | **Tail latency is where scheduling sins show up** |
| CPU utilization (user/sys/softirq/irq) | perf stat, mpstat | Shows where time is spent |

### "Prove the Overhead" Metrics
| Metric | Tool | What It Reveals |
|--------|------|------------------|
| Context switches (voluntary/involuntary) | `perf stat`, `/proc/*/status` | **Smoking gun #1** - scheduling overhead |
| CPU migrations | `perf stat` | **Smoking gun #2** - task bouncing between cores |
| Run queue latency / scheduling delay | `perf sched latency`, bpftrace | How long threads wait to run |
| Wakeups per operation | bpftrace, ftrace | Too many wakeups = death by a thousand pokes |
| Lock contention hotspots | `perf lock`, lockstat | Workqueue/shared ring contention |

### io_uring-Specific Signals
| Signal | How to Capture | Why |
|--------|----------------|-----|
| CQE/SQE batching effectiveness | `io_uring` tracepoints | Completions per wakeup |
| Worker thread behavior | ftrace, bpftrace | Wake/sleep frequency, which CPUs |
| Fallback paths | tracepoints | Sync I/O when you expected async |

> 🎯 **If you measure only one thing:** context switches + CPU migrations + p99 latency. These are usually the smoking gun.

---

## 🧪 Experiment Matrix

### Variable Knobs (What You Change)
| Variable | Values to Test | Notes |
|----------|----------------|-------|
| Kernel version | TBD (e.g., 5.15 LTS, 6.1, 6.6) | Document exact version string |
| io_uring flags/features | SQPOLL, polling, registered buffers | One variable at a time |
| Worker settings | Default vs tuned (IORING_SETUP_ATTACH_WQ, etc.) | Workqueue behavior |
| CPU affinity | None / pinned app threads / pinned workers | Isolate migration effects |
| Workload type | Small random reads, sequential, sync-heavy | Match real use case |
| Batch size | 1, 8, 32, 128 | SQE batching impact |

### Fixed Controls (What Stays Constant)
| Control | Setting | Why |
|---------|---------|-----|
| Hardware | Same machine for all tests | Eliminate HW variance |
| Filesystem + mount options | ext4/xfs, specific mount flags | Consistent I/O path |
| CPU governor | `performance` | No frequency scaling noise |
| Background noise | Minimal (no other workloads) | Isolate measurements |
| Network (for WireGuard) | Same topology, same NICs | Consistent baseline |

### Experiment Log Template
| Date | Experiment ID | Variable Changed | Result Summary | Raw Data Location |
|------|---------------|------------------|----------------|-------------------|
| | EXP-001 | | | |

---

## 📦 Reproducibility Pack Checklist

> This is the difference between "cool results" and "publishable results."

### Environment Documentation
- [ ] Kernel config + exact version string (`uname -a`, `/proc/version`)
- [ ] `sysctl` values that matter (scheduler, networking, vm)
- [ ] CPU governor settings (`cpupower frequency-info`)
- [ ] NUMA topology (`numactl --hardware`)
- [ ] Filesystem mount options (`mount | grep <device>`)

### Benchmark Artifacts
- [ ] Full command lines for all benchmarks
- [ ] Configuration files used
- [ ] Raw outputs saved (not just screenshots!)
- [ ] Git commit hashes for any code/scripts

### The Holy Grail
- [ ] **`run_all.sh`** — Single script that reproduces baseline
- [ ] **`README.md`** — Step-by-step setup instructions
- [ ] **`results/`** — Directory with all raw data, organized by date/experiment

> 🏆 If your supervisor can rerun your baseline in one command, you become legendary.

---

## �📖 Reading List & Resources

### From André Freyssinet
| Resource | Link | Status | Notes |
|----------|------|--------|-------|
| Lord of the io_uring | https://unixism.net/loti/ | ✅ Done | Fully read + notes + live investigation — see `notes/notes_Lord_of_io_uring.md` and `IO_URING_REFERENCE.md` |
| Cloudflare: Missing Manuals - io_uring Worker Pool | https://blog.cloudflare.com/missing-manuals-io_uring-worker-pool/ | ✅ Done | Full notes in `notes/notes_cloudfare_worker_pool_article.md`. Key insight: sockets take poll path by default; workers only spawn with `IOSQE_ASYNC`. Built `udp_read.rs` reproducer. |
| LWN: io_uring Article (803070) | https://lwn.net/Articles/803070/ | ⬜ Not Started | |
| LWN: Asynchronism in Kernel (223899) | https://lwn.net/Articles/223899/ | ⬜ Not Started | Old article on workqueues |
| LWN: Asynchronism in Kernel (236206) | https://lwn.net/Articles/236206/ | ⬜ Not Started | Old article on workqueues |

### From Alain Tchana
| Resource | Status | Notes |
|----------|--------|-------|
| Paper: "The Impact of Kernel Asynchronous APIs on the Performance of a Kernel VPN" | ✅ Done | Full notes in `notes/notes_kernelVPN_paper.md`. Root cause: EoI — GRO (softirq, high priority) preempts Decryption (workqueue, normal priority). Fix: run GRO in kthreads (4×, 65% latency↓) or workqueues (4.7×, 46% latency↓). |

### Additional Reading (From Notes)
| Resource | Status | Notes |
|----------|--------|-------|
| io_uring for High-Performance DBMSs: When and How to Use It | ✅ Done | Notes in `notes/notes_io_uring for High-Performance DBMSs...md` |

---

## 🧪 Practical Work

### Benchmarking Tools
- Contact: **Researcher in Toulouse** (via Alain)
- Purpose: Learn how to use existing stress testing software
- Status: ⬜ Pending contact/meeting

### Applications to Analyze
| Application | Type | Status | Notes |
|-------------|------|--------|-------|
| WireGuard | VPN | ⬜ Not Started | Main case study - io_uring vs Go implementation |

### Benchmarks to Run
- [ ] Understand existing benchmark suite
- [ ] Setup benchmark environment
- [ ] Run initial benchmarks
- [ ] Document baseline results

---

## 📊 Weekly Progress Log

> 📝 **Log Format:** Don't just list tasks. Capture learnings, surprises, and blockers.

---

### Week 1 (Jan 27-31, 2026)

#### Day 1 — Wednesday, Jan 29
**What I did:**
- 🟢 Internship kickoff
- 🟢 Met with Alain Tchana - received context on research hypothesis
- 🟢 Received resources from André Freyssinet

**What I learned:**
- io_uring-based WireGuard is slower than Go user-level version (surprising!)
- Hypothesis centers on workqueue overhead and context switches
- Benchmarks already exist — need to learn them from Toulouse researcher

**What surprised me:**
- Thread blocking (not just task) is suspected — need to understand difference

**Blockers:**
- None yet

---

#### Day 2 — Friday, Jan 31
**What I did:**
- 🟢 Created comprehensive internship tracker
- 🟢 Started reading "Lord of the io_uring"
- 🟢 Took detailed notes on async programming models and io_uring basics

**What I learned:**
- Different Linux process models (iterative, forking, preforked, threaded, prethreaded, poll, epoll) and their tradeoffs
- Thread-pool based servers compete well with epoll until ~11,000 concurrent users
- Thread-based designs are simpler to implement than asynchronous epoll servers
- Linux AIO limitations: mainly works with O_DIRECT, can still block, device request slots limit, extra overhead (104 bytes + 2 syscalls per operation)
- **Critical insight:** select()/poll()/epoll() always return "ready" for regular files even when they might block → Achilles' heel for async file I/O
- io_uring solves this by providing uniform interface for files, sockets, and other FDs

**What surprised me:**
- Legacy async APIs (select/poll/epoll) fundamentally don't work for regular files → explains why io_uring was needed
- Libraries like libuv have to use separate thread pools just for file I/O to work around this limitation
- Threaded models remain competitive until very high concurrency (11K users) despite being "simpler"

**Concrete output produced:**
- `INTERNSHIP_TRACKER.md` — structured research tracking document
- `notes/notes_Lord_of_io_uring.md` — detailed notes covering async programming models, Linux async APIs evolution, and io_uring motivation

**Next steps:**
- Continue reading "Lord of the io_uring" (architecture, usage patterns)
- Read Cloudflare worker pool article
- Take notes on when/why io_uring offloads to workers

**Blockers:**
- None

---

### April 3, 2026 — Kernel VPN Paper + Cloudflare Notes Completed

#### Friday, April 3
**What I did:**
- ✅ Finished Cloudflare worker pool article notes (sections on `io_uring_task`/`task_struct` internals, multi-threaded pitfall with `RLIMIT_NPROC`, NUMA topology effects)
- ✅ Read Kernel VPN paper ("The Impact of Kernel Asynchronous APIs on the Performance of a Kernel VPN") cover to cover
- ✅ Wrote full notes: background (softirqs/kthreads/workqueues), WireGuard TX/RX pipelines, EoI root cause, the patch (§4), and evaluation (§5)

**What I learned:**
1. **EoI is the root cause** — `spin_unlock_bh` in WireGuard's decryption path re-enables bottom halves, triggering NAPI/GRO softirqs before decryption finishes. GRO fires, finds nothing, wastes cycles. Batching is destroyed.
2. **The fix is a priority alignment** — move GRO from softirq (high priority) to kthreads or workqueues (normal scheduler priority). No more preemption of decryption.
3. **Workqueues > kthreads for throughput** (4.7× vs 4×) because fixed thread pool avoids scheduling explosion. kthreads win on latency (65% vs 46% reduction) because one dedicated thread per peer = more predictable scheduling.
4. **The patch is small** — 136 LoC in NAPI subsystem + 55 LoC in WireGuard. The kernel already had all the infrastructure needed.
5. **Transmission is completely unaffected** — EoI is isolated to the RX pipeline. TX scales linearly to 22 Gbps in all configurations.
6. **Connection to Cloudflare article** — the paper's workqueue fix uses the same `work_struct` / `queue_work_on` infrastructure as io-wq. Understanding worker pool sizing from the Cloudflare article directly applies here.

**What surprised me:**
- The CPU imbalance (94% vs 20%) is self-reinforcing: `napi_schedule()` pins GRO pollers to whichever core the decryption worker ran on, with zero load awareness. The scheduler never corrects this.
- The fix requires no changes to the Linux scheduler — just moving GRO to a different execution context is enough.
- kthreads can be enabled with a single `echo 1 > /sys/class/net/.../threaded` — zero kernel code changes. Yet it still delivers 4× throughput improvement.

**Concrete outputs:**
- `notes/notes_cloudfare_worker_pool_article.md` — fully completed
- `notes/notes_kernelVPN_paper.md` — fully written (new file)

**Next steps:**
- Contact Brice / Teo for WireGuard test environment
- Contact Toulouse researcher for benchmark suite
- Run `bpftrace` on `udp_read.rs --async` to confirm `io_uring_queue_async_work` fires on network I/O (validate H6)

**Blockers:**
- None on reading side. Need external contacts to move forward on reproduction.

---

### Week N (March 6, 2026) — Live Kernel Investigation

#### Friday, March 6
**What I did:**
- ✅ Completed full read of "Lord of the io_uring" — from async models through raw API, SQE/CQE structure, and low-level cat example
- ✅ Built and ran `cat_uring` (raw io_uring, no liburing) — successfully reads and prints files
- ✅ Ran live kernel investigation using strace, perf, and bpftrace
- ✅ Created `IO_URING_REFERENCE.md` — structured reference document for supervisor discussions
- ✅ Set up git repo `git@github.com:AnasAEA/Io-uring-Internship.git` — all work committed and pushed

**What I learned:**
1. **`IORING_FEAT_NO_IOWAIT` changes everything for file reads** — on kernel 5.18+, buffered reads block inline inside `io_uring_enter()` rather than spawning io-wq workers. `io_uring_queue_async_work` never fired, even with cold cache.
2. **Warm vs cold cache latency:** 3.7µs (warm) vs 132µs (cold) — 35.9× difference. Pure storage latency.
3. **Context switches confirmed at small scale:** 4 ctx switches + 1 CPU migration for a single cold 11KB read. At WireGuard scale, this penalty multiplies.
4. **The io-wq bottleneck is network-path, not file-path on modern kernels.** WireGuard research must focus on the socket/network operations in io_uring, not file reads.
5. **17 io_uring kernel tracepoints available** on this kernel. The suite of tools (bpftrace, perf, strace, trace-cmd) all confirmed working.
6. **`IORING_FEAT_NATIVE_WORKERS` present** — io-wq workers are native threads since 5.12, which reduces but does not eliminate worker overhead.

**What surprised me:**
- The textbook "buffered read → io-wq worker" path is obsolete on modern kernels. The architecture changed in 5.18 with `NO_IOWAIT`. Old io_uring articles describe behavior that no longer applies.
- Zero sys time with warm cache — the program completes without the kernel scheduling anything at all.

**Concrete outputs:**
- `io_uring_examples/cat_program_io_uring/cat_uring` — compiled and working
- `io_uring_examples/cat_program_io_uring/Makefile` — build + run + clean targets
- `notes/notes_Lord_of_io_uring.md` — full notes with deep analysis + live results
- `IO_URING_REFERENCE.md` — **new** structured reference document
- GitHub: 3 commits pushed

**Next steps:**
- Read Cloudflare worker pool article (NOW high priority — need to understand io-wq network path)
- Read the Kernel VPN paper (understand the WireGuard result before trying to reproduce)
- Write a minimal io_uring TCP server and attach bpftrace to see if io-wq fires on the network path

**Blockers:**
- None

---

### Week 2 (Feb 3-7, 2026)

#### Wednesday, Feb 5 — Goal: Understand io_uring worker model
**Plan:**
- [ ] Read Cloudflare worker pool article (https://blog.cloudflare.com/missing-manuals-io_uring-worker-pool/)
- [ ] Take structured notes

**Target Output:**
- 1-page summary: "When/why io_uring uses workers + what overhead it introduces"
- List of testable hypotheses derived from the article

**What I did:**
- 🟢 Started writing io_uring example code (cat program using io_uring)
- 🟢 Hit `linux/fs.h` missing — realized macOS can't compile or run io_uring code at all
- 🟢 Researched and prepared Fedora Asahi Remix dual-boot guide for M1 Pro MacBook
- ⬜ Cloudflare article reading (deferred — need Linux env first)

**What I learned:**
1. io_uring is Linux-only — need native Linux to compile anything with `linux/fs.h`, `liburing`, etc.
2. Fedora Asahi Remix is the best Linux option for Apple Silicon (M1 Pro) with full HW support
3. Can dual-boot safely without losing macOS — SIP stays enabled for macOS

**What surprised me:**
- Should have set up Linux earlier — can't do any real io_uring development on macOS

**Blockers:**
- 🔴 **BLOCKED on Linux install** — need to run Fedora Asahi Remix installer before any io_uring code/benchmarks work

---

#### Friday, Feb 7 — Goal: Understand the WireGuard case study
**Plan:**
- [ ] Read "The Impact of Kernel Asynchronous APIs on the Performance of a Kernel VPN" paper
- [ ] Extract key information

**Target Output:**
- Summary with:
  - Workload setup (traffic model)
  - Metrics used in the paper
  - Where the 4.7× improvement comes from
  - What's needed to reproduce in your environment

**What I did:**
- *Fill in*

**What I learned:**
1.
2.
3.

**What surprised me:**
-

**Blockers:**
-

---

### Week 3 (Feb 10-14, 2026)

#### Wednesday, Feb 12
**Plan:**
- [ ] Read LWN articles on workqueues (223899, 236206)
- [ ] Build mental model of kernel async mechanisms

**Target Output:**
- Notes: "Workqueues 101 — how they work, why they cause overhead"

---

#### Friday, Feb 14
**Plan:**
- [ ] Contact Toulouse researcher (coordinate via Alain)
- [ ] Get WireGuard setup info from Brice/Teo

**Target Output:**
- Meeting scheduled or async communication started
- Environment requirements documented

---

## 🤝 Contacts

| Name | Role | Email/Contact | Notes |
|------|------|---------------|-------|
| André Freyssinet | Supervisor | Andre.Freyssinet@scalagent.com | ScalAgent Distributed Technologies |
| Alain Tchana | Team Lead (KrakOS) | - | Professor, Ensimag - Grenoble INP |
| Researcher (Toulouse) | Benchmark Tools | TBD | Contact via Alain |
| Brice Ekane | Team Member | - | Has WireGuard setup |
| Teo Pisenti | Team Member | - | Has WireGuard setup |

---

## 📝 Meeting Notes

### Meeting 1: Kickoff with Alain (Day 1)
**Date:** January 29, 2026

**Key Points:**
- Main hypothesis: io_uring inefficiency in real-world apps
- WireGuard case study: io_uring version slower than Go user-level version
- Suspected causes:
  - Workqueue usage patterns
  - Context switches on kernel thread fetch
  - Thread blocking (not just task)
- Need to understand kernel-level behavior
- Benchmarks already exist - need to learn them

**Action Items:**
- [ ] Read provided resources
- [ ] Contact Toulouse researcher for benchmark training
- [ ] Get WireGuard setup from Brice/Teo

---

## 💡 Ideas & Questions

### Questions to Ask
- [ ] ~~What specific metrics should I focus on in benchmarks?~~ → See Metrics section above
- [ ] What kernel versions are we targeting? (Ask André/Alain)
- [ ] What hardware setup will be used for experiments? (Ask André)
- [ ] How to access/setup the WireGuard test environment? (Ask Brice/Teo)
- [ ] What's the exact traffic model used in the kernel VPN paper?
- [ ] Are there existing scripts from the Toulouse researcher I can start from?

### Research Ideas
- Investigate `IORING_SETUP_SQPOLL` — does it avoid worker thread overhead?
- Compare io_uring with different `IORING_SETUP_*` flags
- Measure CPU affinity impact on worker threads
- Profile with `bpftrace` to capture exact wakeup patterns

### Hypotheses to Test
| ID | Hypothesis | How to Test | Status |
|----|------------|-------------|--------|
| H1 | io_uring workers cause excessive context switches | Measure ctx switches with/without worker offload | 🟡 Partially confirmed — 4 ctx switches seen even for 1 tiny cold read. Need scale. |
| H2 | Workers migrate between CPUs, causing cache misses | Track CPU migrations with `perf stat` | 🟡 Partially confirmed — 1 CPU migration seen on cold read. Need scale. |
| H3 | Batching SQEs reduces wakeup overhead | Compare throughput at batch sizes 1/8/32/128 | ⬜ |
| H4 | CPU pinning workers improves tail latency | Test with taskset/cgroups | ⬜ |
| H5 | `IORING_FEAT_NO_IOWAIT` means io-wq is NOT taken for buffered reads on modern kernels | Verified with bpftrace — `io_uring_queue_async_work` never fired | ✅ Confirmed on kernel 6.18 |
| H6 | io-wq IS triggered for network socket operations (WireGuard-relevant path) | Run bpftrace on loopback TCP with io_uring RECV | ⬜ To test |

---

## 🔗 Quick Links

- **LIG KrakOS Team:** https://lig-membres.imag.fr/tchanaa/index.html
- **JoramMQ:** http://mqtt.jorammq.com
- **André LinkedIn:** https://www.linkedin.com/in/andre-freyssinet

---

## 📁 File Structure

```
Internship-Io-uring/
├── INTERNSHIP_TRACKER.md           # This file
├── IO_URING_REFERENCE.md           # ✅ Structured reference for supervisor discussions
├── notes/
│   ├── notes_Lord_of_io_uring.md              # ✅ Full notes: async models → raw API → live investigation
│   ├── notes_cloudfare_worker_pool_article.md  # ✅ Worker pool, 3 request paths, 4 cap methods, NUMA
│   ├── notes_kernelVPN_paper.md               # ✅ EoI root cause, kthread/workqueue patch, evaluation
│   ├── notes_io_uring for High-Performance DBMSs...md  # ✅ DBMS paper notes
│   └── setup_fedora_asahi_remix_dual_boot.md
├── io_uring_examples/
│   ├── cat_program_io_uring/
│   │   ├── cat.c                   # ✅ Raw io_uring cat implementation (372 lines, no liburing)
│   │   ├── cat_uring               # ✅ Compiled binary
│   │   └── Makefile                # ✅ Build + run + clean
│   └── worker_pool_tests/
│       └── udp_read.rs             # ✅ Cloudflare reproducer: observe io-wq worker pool (--async flag)
├── experiments/                    # Experiment configs and raw data (to be filled)
│   ├── baseline/
│   └── exp-001-network-io-wq/      # Next: bpftrace on udp_read.rs --async, confirm worker spawn
├── scripts/
│   └── run_all.sh                  # Holy grail: reproduce everything
└── .vscode/
    ├── settings.json               # ✅ C11, format-on-save, hide binaries
    └── extensions.json             # ✅ Recommended extensions
```

---

## ✅ Next Actions (Priority Order)

### Completed
1. ✅ Created internship tracker
2. ✅ Installed Fedora Asahi Remix on MacBook M1 Pro
3. ✅ Installed dev tools (`perf`, `bpftrace`, `trace-cmd`, `gcc`, `git`)
4. ✅ Read "Lord of the io_uring" — full tutorial, detailed notes
5. ✅ Built and ran `cat_uring` — raw io_uring working
6. ✅ Live kernel investigation with strace, perf, bpftrace
7. ✅ Created `IO_URING_REFERENCE.md` — structured supervisor reference
8. ✅ Set up GitHub repo and pushed all work
9. ✅ Read Cloudflare worker pool article — notes complete, built `udp_read.rs` reproducer
10. ✅ Read Kernel VPN paper — fully read, notes complete with EoI analysis + patch + evaluation
11. ✅ Read DBMS paper — notes complete

### Now (April 2026)
1. 🔴 **Contact Brice Ekane / Teo Pisenti** — get WireGuard test environment + existing benchmark setup
2. 🔴 **Contact Toulouse researcher** (via Alain) — access existing io_uring stress test suite
3. ⬜ Verify io-wq fires on network I/O — run bpftrace on `udp_read.rs --async`, confirm `io_uring_queue_async_work` tracepoint + count workers
4. ⬜ Read LWN workqueue internals articles (223899, 236206) — understand workqueue scheduler to connect Cloudflare + VPN paper findings

### Before End of April
5. ⬜ Have WireGuard benchmark environment running
6. ⬜ Reproduce the 19.2% throughput result from the VPN paper with <10% variance
7. ⬜ Attribute overhead to at least one measurable mechanism (context switches / CPU migrations)

---

## 🧠 Core Principle

> **"Don't start by trying to optimize io_uring. Start by making the slowdown boringly reproducible with a clean baseline."**
>
> If you can't reproduce it reliably:
> - Every explanation will be shaky
> - Every "fix" will look like random luck
> - You'll waste weeks arguing with noise
>
> **Reproduction first. Always.**

---

*Last Updated: April 3, 2026*
