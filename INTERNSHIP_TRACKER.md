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
- [ ] Evaluate io_uring performance for transparent file system access in heterogeneous environments
- [ ] Analyze queueing/scheduling bottlenecks related to kernel threads and workqueues in async I/O path
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
| Phase | Deliverable | Target Date |
|-------|-------------|-------------|
| 0. Setup | Linux environment (Fedora Asahi Remix) on MacBook | **Feb 6-7** |
| 1. Understand | Reading summaries + knowledge base | Mid-February |
| 2. Reproduce | Clean baseline benchmark with <10% variance | End of February |
| 3. Measure | Overhead attribution report (context switches, migrations, etc.) | Mid-March |
| 4. Mitigate | Tested improvement with one approach | April |
| 5. Document | Final report + reproducibility pack | End of internship |

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
| Lord of the io_uring | https://unixism.net/loti/ | 🟡 In Progress | Started Jan 31 - covered async models, Linux AIO limitations, regular file problem |
| Cloudflare: Missing Manuals - io_uring Worker Pool | https://blog.cloudflare.com/missing-manuals-io_uring-worker-pool/ | ⬜ Not Started | About workqueues usage in io_uring |
| LWN: io_uring Article (803070) | https://lwn.net/Articles/803070/ | ⬜ Not Started | |
| LWN: Asynchronism in Kernel (223899) | https://lwn.net/Articles/223899/ | ⬜ Not Started | Old article on workqueues |
| LWN: Asynchronism in Kernel (236206) | https://lwn.net/Articles/236206/ | ⬜ Not Started | Old article on workqueues |

### From Alain Tchana
| Resource | Status | Notes |
|----------|--------|-------|
| Paper: "The Impact of Kernel Asynchronous APIs on the Performance of a Kernel VPN" | ⬜ Not Started | Key paper - demonstrates 4.7× throughput increase, 65% tail latency reduction |

### Additional Reading (From Notes)
| Resource | Status | Notes |
|----------|--------|-------|
| io_uring for High-Performance DBMSs: When and How to Use It | ⬜ Not Started | Already have notes file |

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
| H1 | io_uring workers cause excessive context switches | Measure ctx switches with/without worker offload | ⬜ |
| H2 | Workers migrate between CPUs, causing cache misses | Track CPU migrations with `perf stat` | ⬜ |
| H3 | Batching SQEs reduces wakeup overhead | Compare throughput at batch sizes 1/8/32/128 | ⬜ |
| H4 | CPU pinning workers improves tail latency | Test with taskset/cgroups | ⬜ |

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
├── notes/
│   ├── notes_io_uring for High-Performance DBMSs...md
│   └── setup_fedora_asahi_remix_dual_boot.md
├── readings/                       # Summaries of papers/articles
│   ├── cloudflare_worker_pool.md
│   ├── kernel_vpn_paper.md
│   └── lwn_workqueues.md
├── experiments/                    # Experiment configs and raw data
│   ├── baseline/
│   ├── exp-001-sqpoll/
│   └── exp-002-affinity/
├── scripts/
│   ├── run_all.sh                  # Holy grail: reproduce everything
│   ├── setup_env.sh
│   └── collect_metrics.sh
├── results/                        # Processed results and graphs
├── reports/                        # Weekly/monthly reports
└── code/                           # Any code written
```

---

## ✅ Next Actions (Priority Order)

### This Week (Jan 31)
1. ✅ Created internship tracker
2. ✅ Started reading "Lord of the io_uring" tutorial

### This Week (Feb 5-7)
3. 🔴 **PRIORITY: Install Fedora Asahi Remix** → See `notes/setup_fedora_asahi_remix_dual_boot.md`
4. ⬜ After Linux is running: install dev tools (`liburing-devel`, `perf`, `bpftrace`, `fio`)
5. ⬜ Read Cloudflare worker pool article → Output: 1-page summary
6. ⬜ **Fri (Feb 7):** Read Kernel VPN paper → Output: extraction of setup/metrics/results

### Week After (Feb 10-14)
5. ⬜ Read LWN workqueue articles (223899, 236206)
6. ⬜ Contact Toulouse researcher for benchmark setup
7. ⬜ Get WireGuard setup info from Brice/Teo

### Before End of February
8. ⬜ Have benchmark environment running
9. ⬜ Reproduce baseline slowdown with <10% variance

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

*Last Updated: February 6, 2026*
