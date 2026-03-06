# io_uring: Internship Reference Document

> **Purpose:** Consolidated reference covering everything learned about io_uring — how it works, live measurement results, and how it connects to the Inria KrakOS internship objectives.
> **Audience:** Self-reference + talking points for supervisor meetings.
> **Last Updated:** March 6, 2026
> **Environment:** Fedora Asahi Remix 42, kernel `6.18.10-402.asahi.fc42.aarch64+16k`, Apple M1 Pro (ARM64)

---

## Table of Contents

1. [The Problem io_uring Solves](#1-the-problem-io_uring-solves)
2. [How io_uring Works — Architecture](#2-how-io_uring-works--architecture)
3. [The Lifecycle of a Request](#3-the-lifecycle-of-a-request)
4. [The Synchronous vs Asynchronous Distinction](#4-the-synchronous-vs-asynchronous-distinction)
5. [Live Investigation: cat_uring on Real Hardware](#5-live-investigation-cat_uring-on-real-hardware)
6. [Key Kernel Feature Flags Explained](#6-key-kernel-feature-flags-explained)
7. [Available Kernel Tracepoints](#7-available-kernel-tracepoints)
8. [Connection to Internship Objectives](#8-connection-to-internship-objectives)
9. [Open Questions and Next Steps](#9-open-questions-and-next-steps)

---

## 1. The Problem io_uring Solves

### Why existing async APIs were broken for files

Before io_uring (Linux 5.1, 2019), Linux had no truly uniform asynchronous I/O interface. The landscape looked like this:

| API | Type | Problem |
|---|---|---|
| `select()` / `poll()` | Readiness-based | **Always reports regular files as "ready"** — useless for disk I/O |
| `epoll()` | Readiness-based | Same fundamental limitation on regular files |
| `aio(7)` / `libaio` | Completion-based | Only works with `O_DIRECT`; can still block; 2 syscalls + 104 bytes copied per operation |

The core irony: `select`, `poll`, and `epoll` tell you a file descriptor is *ready to read* — but a regular file is always "ready" from the kernel's perspective, whether data is cached in RAM or sitting on a cold disk 30ms away. This made them useless for true async file I/O.

Libraries like **libuv** (used by Node.js) worked around this by keeping a dedicated thread pool just for file I/O, hiding the discrepancy from users. This is extra complexity and overhead that should not be necessary.

### What io_uring does differently

io_uring is **completion-based**, not readiness-based. Instead of asking "is this fd ready?", you say "read 4KB from this file" and get back the actual result — bytes read or error code — when the operation is done, regardless of whether the fd is a socket, a file, a pipe, or anything else.

This unification is the architectural reason io_uring can outperform everything else at scale.

---

## 2. How io_uring Works — Architecture

### The two ring buffers

io_uring sets up **two ring buffers in shared memory** between your process and the kernel:

```
 Userspace                          Kernel
 ─────────────────────────────────────────────────
 ┌──────────────────────┐
 │  Submission Queue    │  ←  you write SQEs here
 │  (SQ Ring)           │
 │  head → tail         │  ───────→  kernel reads SQEs
 └──────────────────────┘
 ┌──────────────────────┐
 │  Completion Queue    │  ←  kernel writes CQEs here
 │  (CQ Ring)           │
 │  head → tail         │  ←─────── you read CQEs
 └──────────────────────┘
```

Both rings live in the **same physical RAM pages**, mapped into both your process and the kernel with `mmap`. No data is ever copied across the syscall boundary for the ring metadata itself. Submitting a request means updating a pointer; the kernel sees it immediately.

### Setup: three mmap calls (two on modern kernels)

```c
ring_fd = io_uring_setup(queue_depth, &params);
// Three regions to map:
sq_ptr  = mmap(..., ring_fd, IORING_OFF_SQ_RING);   // SQ ring metadata
cq_ptr  = mmap(..., ring_fd, IORING_OFF_CQ_RING);   // CQ ring metadata
sqe_ptr = mmap(..., ring_fd, IORING_OFF_SQES);      // SQE array (the actual slots)
```

On kernels with `IORING_FEAT_SINGLE_MMAP` (present on this system), the SQ and CQ metadata share one page, reducing to two mmap calls. This was confirmed by live strace:

```
io_uring_setup(1, {..., features=IORING_FEAT_SINGLE_MMAP|...}) = 3
mmap(NULL, 132, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, 3, 0)           → SQ+CQ ring
mmap(NULL, 64,  PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, 3, 0x10000000)  → SQE array
```

### Submission Queue Entry (SQE) — what you write

Each SQE is a 64-byte struct describing one operation:

| Field | Purpose |
|---|---|
| `opcode` | What to do: `IORING_OP_READV`, `IORING_OP_WRITEV`, `IORING_OP_ACCEPT`, etc. |
| `fd` | File descriptor to operate on |
| `addr` | Pointer to buffer (for read/write) or iovec array |
| `len` | Buffer size or number of iovecs |
| `off` | File offset |
| `user_data` | **Your correlation ID** — kernel ignores it, echoes it back in the CQE unchanged |
| `flags` | Modifiers: `IOSQE_IO_DRAIN` (force ordering), `IOSQE_IO_LINK` (chain ops), etc. |

### Completion Queue Entry (CQE) — what you get back

Each CQE is a 16-byte struct:

| Field | Meaning |
|---|---|
| `user_data` | Copied verbatim from the original SQE — used to match completion to request |
| `res` | Result: bytes read/written (positive) or `-errno` (negative, on error) |
| `flags` | Additional metadata about the completion |

### Memory barriers

Direct shared-memory communication requires CPU memory ordering. The code uses:
- `write_barrier()` — after writing an SQE, before advancing the SQ tail (ensures data is visible before the kernel sees the new tail)
- `read_barrier()` — before reading from the CQ ring (ensures CQE data is fully written before we read it)

On ARM64 (this machine), these translate to `dmb ishst` / `dmb ish` data memory barriers.

---

## 3. The Lifecycle of a Request

Using `cat.c` as the concrete example (reads a file using `IORING_OP_READV`):

```
1. app_setup_uring()
   ├── syscall: io_uring_setup(depth=1, &params)  →  ring_fd=3
   ├── mmap: SQ+CQ ring metadata  (132 bytes at offset 0)
   └── mmap: SQE array            (64 bytes at offset 0x10000000)

2. submit_to_sq(filename)
   ├── open file  →  file_fd=4
   ├── allocate iovec array (one entry per 1KB block of the file)
   ├── grab SQE slot at index (*sq.sqhead & ring_mask)
   ├── fill SQE: opcode=READV, fd=file_fd, addr=iovecs, len=nblocks, user_data=&fi
   ├── write_barrier()
   ├── advance *sq.tail  ←  kernel will notice this
   └── syscall: io_uring_enter(ring_fd, to_submit=1, min_complete=1, IORING_ENTER_GETEVENTS)
       ↑ this is the only syscall for the actual I/O — it submits and waits

3. [kernel processes IORING_OP_READV]
   └── kernel reads file pages into iovecs, posts CQE to CQ tail

4. io_uring_enter() returns  (min_complete=1 was satisfied)

5. read_from_cq()
   ├── check *cq.head != *cq.tail  (new CQE available)
   ├── read CQE: res=11041, user_data=0x15f3c310
   ├── cast user_data back to (struct file_info *)  ←  correlation
   ├── write each 1KB block to stdout
   └── advance *cq.head  ←  tells kernel the CQE slot is free
```

**Observed via bpftrace:**
```
1. CREATE:  sq_entries=1  cq_entries=2  flags=0x0
3. SUBMIT:  opcode=1  user_data=0x15f3c310
7. COMPLETE: res=11041  user_data=0x15f3c310
```

The `user_data` value is identical in SUBMIT and COMPLETE — the pointer round-trips through the kernel unchanged, proving the correlation mechanism.

---

## 4. The Synchronous vs Asynchronous Distinction

This is the most important conceptual point for the internship.

### How `cat.c` actually behaves (synchronous)

```c
io_uring_enter(ring_fd, 1, 1, IORING_ENTER_GETEVENTS)
//                            ↑
//                    min_complete=1 → "don't return until at least 1 CQE is ready"
```

By passing `min_complete=1`, the program **blocks inside the syscall** until the read is done. This is functionally identical to calling `preadv()`. The io_uring infrastructure is being used, but there is zero async benefit.

### What true async looks like

```c
// Phase 1: submit many requests without waiting
for (i = 0; i < 1000; i++) {
    fill_sqe(&sqes[i], ...);
}
io_uring_enter(ring_fd, 1000, 0, 0);    // submit 1000, wait for 0
//                              ↑
//                        min_complete=0 → return immediately

// Phase 2: do other work here while kernel processes I/O

// Phase 3: harvest completions without any syscall
while (*cq.head != *cq.tail) {
    process_cqe(&cq.cqes[*cq.head & mask]);
    (*cq.head)++;
}
```

The power of io_uring at scale: **one syscall submits N requests; zero syscalls harvest N completions**.

### The batching multiplier

| Pattern | Syscalls for 1000 ops |
|---|---|
| Traditional `read()` | 1000 |
| Linux AIO (`io_submit` + `io_getevents`) | 2000 |
| io_uring (async, batched) | 1 (submission) + 0 (completions via ring poll) |
| io_uring + SQPOLL (kernel polls SQ) | 0 |

---

## 5. Live Investigation: cat_uring on Real Hardware

All tests run on: kernel `6.18.10-402.asahi.fc42.aarch64+16k` (Fedora Asahi Remix 42, M1 Pro)  
File under test: `cat.c` — 11,041 bytes

---

### 5.1 strace — syscall boundary view

```
io_uring_setup(1, {
    sq_entries=1, cq_entries=2,
    features=IORING_FEAT_SINGLE_MMAP | IORING_FEAT_NODROP | IORING_FEAT_SUBMIT_STABLE |
             IORING_FEAT_NATIVE_WORKERS | IORING_FEAT_FAST_POLL | IORING_FEAT_NO_IOWAIT | ...
}) = 3

mmap(NULL, 132, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, 3, 0)           = 0xffff...
mmap(NULL,  64, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, 3, 0x10000000)  = 0xffff...

openat(AT_FDCWD, "cat.c", O_RDONLY) = 4

io_uring_enter(3, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0) = 1
```

Total syscalls for the read: **1** (`io_uring_enter`). Compare to `open + read + close` = 3.

---

### 5.2 perf stat — warm vs cold cache

| Metric | Warm cache | Cold cache (drop_caches) |
|---|---|---|
| context-switches | **0** | **4** |
| cpu-migrations | **0** | **1** |
| cycles | 597,605 | 1,201,914 (2.0×) |
| instructions | 927,832 | 1,375,331 |
| IPC (instructions/cycle) | 1.55 | 1.14 (lower — memory stalls) |
| user time | 0.404 ms | 0.000 ms |
| sys time | **0.000 ms** | **0.655 ms** |
| total elapsed | 0.380 ms | 1.357 ms (3.6×) |

**Warm cache:** zero sys time, zero context switches. The read was served entirely from the page cache — the kernel did not schedule any kernel threads.

**Cold cache:** 655µs of kernel time, 4 context switches, 1 CPU migration. The kernel had to go to storage and the task was rescheduled during the wait.

---

### 5.3 bpftrace — full event lifecycle

Command used:
```bash
sudo bpftrace -e '
tracepoint:io_uring:io_uring_create        { printf("1. CREATE: sq=%d cq=%d\n", args->sq_entries, args->cq_entries); }
tracepoint:io_uring:io_uring_submit_req    { printf("3. SUBMIT: opcode=%d user_data=0x%llx\n", args->opcode, args->user_data); }
tracepoint:io_uring:io_uring_queue_async_work { printf("4. QUEUE_ASYNC_WORK: opcode=%d\n", args->opcode); }
tracepoint:io_uring:io_uring_complete      { printf("7. COMPLETE: res=%d user_data=0x%llx\n", args->res, args->user_data); }
' -c './cat_uring cat.c'
```

**Result (identical for both warm and cold cache):**
```
1. CREATE:  sq_entries=1  cq_entries=2  flags=0x0
3. SUBMIT:  opcode=1  user_data=0x15f3c310       ← opcode 1 = IORING_OP_READV
7. COMPLETE: res=11041  user_data=0x15f3c310     ← 11,041 bytes = exact file size
```

**Events that never fired (both warm and cold):**

| Event | Expected to fire? | Fired? | Meaning |
|---|---|---|---|
| `io_uring_queue_async_work` | Yes (cold cache) | **No** | io-wq not used |
| `io_uring_task_add` | Possibly | **No** | No task deferral |
| `io_uring_local_work_run` | Possibly | **No** | No local work queue |
| `io_uring_file_get` | Yes | **No** | Tracepoint removed or renamed in 6.x |

---

### 5.4 bpftrace — submit→complete latency

```bash
sudo bpftrace -e '
tracepoint:io_uring:io_uring_submit_req { @start[tid] = nsecs; }
tracepoint:io_uring:io_uring_complete   { printf("latency: %lld ns\n", nsecs - @start[tid]); }
' -c './cat_uring cat.c'
```

| Cache state | Measured latency |
|---|---|
| Warm (file in page cache) | **3,667 ns** (~3.7 µs) |
| Cold (after `drop_caches`) | **131,875 ns** (~132 µs) |

Cold cache is **35.9× slower** than warm. The entire difference is storage latency — the kernel blocking on the block layer to fetch the page.

---

### 5.5 The surprising finding: `io_uring_queue_async_work` never fired

The textbook description of buffered reads on regular files says:
> File read cannot complete inline → kernel defers to io-wq → `io_uring_queue_async_work` fires

This **did not happen**, even with cold cache.

The reason is `IORING_FEAT_NO_IOWAIT` — present in the feature set returned by `io_uring_setup`. This flag, introduced around kernel 5.18, changes the internal path: instead of offloading to io-wq worker threads, the kernel blocks the calling thread's wait inside `io_uring_enter()` itself and wakes it when the page is ready.

Old path (pre-5.18, or without `NO_IOWAIT`):
```
io_uring_enter() → kernel sees page not cached → io_uring_queue_async_work()
                                                  → io-wq worker thread fetches page
                                                  → wakes up caller
```

New path (kernel 6.x with `IORING_FEAT_NO_IOWAIT`):
```
io_uring_enter() → kernel sees page not cached → submits request → sleeps inline
                                                  kernel wakes caller when page arrives
                                                  (no io-wq worker involved)
```

This is a meaningful architectural change. The io-wq worker wakeup overhead that the Inria hypothesis centers on is **not triggered by buffered file reads on modern kernels** (5.18+).

---

## 6. Key Kernel Feature Flags Explained

Returned by `io_uring_setup` on this system:

| Flag | Since | What it means |
|---|---|---|
| `IORING_FEAT_SINGLE_MMAP` | 5.4 | SQ+CQ rings share one mmap — 2 mmaps instead of 3 |
| `IORING_FEAT_NODROP` | 5.5 | Kernel never silently drops CQEs on ring overflow |
| `IORING_FEAT_SUBMIT_STABLE` | 5.5 | SQE data is read before `io_uring_enter()` returns — buffers can be reused immediately |
| `IORING_FEAT_FAST_POLL` | 5.7 | For poll-able fds (sockets), io_uring directly arms a poll handler instead of going through io-wq |
| `IORING_FEAT_NATIVE_WORKERS` | 5.12 | io-wq workers are native kernel threads rather than kthreads — reduces wakeup latency |
| `IORING_FEAT_NO_IOWAIT` | ~5.18 | **Most relevant to internship** — kernel no longer calls `io_schedule()` for blocked reads; inline wait instead of io-wq offload |

---

## 7. Available Kernel Tracepoints

Full list available on this kernel via `/sys/kernel/tracing/available_events | grep io_uring`:

### io_uring namespace

| Tracepoint | When it fires | Key fields |
|---|---|---|
| `io_uring_create` | Ring initialized | `sq_entries`, `cq_entries`, `flags` |
| `io_uring_register` | `io_uring_register()` called | `opcode`, `nr_files` |
| `io_uring_file_get` | File retrieved for operation | `fd` |
| `io_uring_submit_req` | SQE submitted to kernel | `opcode`, `user_data` |
| `io_uring_queue_async_work` | **Request offloaded to io-wq** | `opcode`, `rw` (0=normal queue, 1=hashed), `work` ptr |
| `io_uring_complete` | CQE posted | `res`, `user_data` |
| `io_uring_task_add` | Task work item added | `opcode`, `mask`, `user_data` |
| `io_uring_task_work_run` | Task work processed | `count`, `loops` |
| `io_uring_local_work_run` | Local (inline) work processed | `count`, `loops` |
| `io_uring_poll_arm` | Poll armed for a socket/pipe fd | `opcode`, `mask` |
| `io_uring_cqring_wait` | Thread waiting for CQE | `min_events` |
| `io_uring_cqe_overflow` | CQ ring overflowed | |
| `io_uring_req_failed` | Request failed | `opcode`, `res` |
| `io_uring_defer` | Request deferred | |
| `io_uring_link` | Linked request queued | |
| `io_uring_fail_link` | Linked request failed | |
| `io_uring_short_write` | Partial write occurred | |

### The one that matters most for workqueue research

```
io_uring_queue_async_work — fires whenever io_uring cannot complete a request inline
                             and must hand it off to the io-wq worker pool
```

Format: `ring %p, request %p, user_data 0x%llx, opcode %s, flags 0x%llx, %s queue, work %p`

The `rw` field distinguishes *normal* vs *hashed* workqueue scheduling (hashed = work items for the same fd are serialized to avoid ordering issues).

### Useful bpftrace snippets

```bash
# detect io-wq usage at all
sudo bpftrace -e 'tracepoint:io_uring:io_uring_queue_async_work { @[comm] = count(); }'

# measure submit→complete latency distribution
sudo bpftrace -e '
tracepoint:io_uring:io_uring_submit_req { @start[args->user_data] = nsecs; }
tracepoint:io_uring:io_uring_complete   {
    @latency_ns = hist(nsecs - @start[args->user_data]);
    delete(@start[args->user_data]);
}'

# watch for CQ ring overflow (dropped completions)
sudo bpftrace -e 'tracepoint:io_uring:io_uring_cqe_overflow { printf("OVERFLOW on ring %p\n", args->ctx); }'
```

---

## 8. Connection to Internship Objectives

### The research hypothesis (from supervisor meeting, Jan 29)

> io_uring-based WireGuard is slower than the Go user-level implementation due to:
> - Inefficient workqueue usage
> - Context switches when kernel threads fetch from workqueues
> - Thread blocking (not just task blocking)
> - Non-optimal queueing/scheduling policies

### What we now know that refines this hypothesis

**Finding 1: The workqueue path is kernel-version dependent.**

The assumption of "buffered reads → io-wq" no longer holds on kernel 5.18+. `IORING_FEAT_NO_IOWAIT` changed the architecture. To reliably trigger io-wq today, the workload must use:

| Workload type | Triggers io-wq? |
|---|---|
| Buffered file reads (modern kernel) | **No** — inline wait |
| `O_DIRECT` file reads | **Yes** — when device queue is full |
| Network sockets with io_uring | **Yes** — for some operations |
| `IORING_OP_ACCEPT` / `IORING_OP_CONNECT` | **Yes** — when they cannot complete immediately |

WireGuard is **network I/O**, not file I/O. Network sockets can be poll-armed via `IORING_FEAT_FAST_POLL` (also present on this kernel) which avoids io-wq for the fast path, but falls back to io-wq for blocking operations. The hypothesis likely still applies to WireGuard — but via the network socket path, not the file path.

**Finding 2: Context switches are a real signal.**

The cold cache perf stat showed **4 context switches and 1 CPU migration** even for a tiny 11KB buffered file read. At WireGuard scale (hundreds to thousands of concurrent tunnels), this multiplies to a significant scheduling overhead — exactly what the hypothesis predicts.

**Finding 3: The measurable smoking guns are confirmed.**

The tools work. We can measure:
- `io_uring_queue_async_work` fires → workqueue path taken
- `perf stat` context-switches + cpu-migrations → scheduling overhead
- bpftrace submit→complete latency → end-to-end cost

**Finding 4: `IORING_FEAT_NATIVE_WORKERS` is relevant.**

This flag (present) means io-wq workers are native threads since kernel 5.12. The Inria research is likely comparing behavior across kernel versions where this transition happened — "native workers" have lower wakeup overhead, which should *reduce* the bottleneck, but the hypothesis says the bottleneck is still there at scale. Understanding *why it persists despite native workers* is probably the core research question.

---

### Mapping to specific internship tasks

| Internship task | Current status | How our findings help |
|---|---|---|
| Understand io_uring architecture | ✅ Done | Deep understanding of SQ/CQ, mmap, lifecycle, async vs sync |
| Identify when io-wq is triggered | ✅ Done (for file reads) | Need to verify for network path (WireGuard-relevant) |
| Reproduce context switch overhead | 🟡 Partially — seen at small scale | Need to scale up to reproduce WireGuard-scale overhead |
| Measure overhead with real tools | ✅ Tools verified working | bpftrace, perf stat, strace all confirmed functional |
| Attribute overhead to mechanisms | ⬜ Not yet | Need WireGuard workload running |
| Propose mitigation | ⬜ Not yet | Requires baseline first |

---

## 9. Open Questions and Next Steps

### Immediate questions to investigate

1. **Does `io_uring_queue_async_work` fire for WireGuard-type network I/O on this kernel?**
   - Test: write a minimal TCP server using raw io_uring with `IORING_OP_RECV`
   - Expected: yes, for operations that cannot be fast-polled

2. **What triggers the io-wq fallback from `IORING_FEAT_FAST_POLL`?**
   - Fast poll handles the "already readable" case for sockets
   - What happens when the socket isn't ready and fast poll "misses"?

3. **At what concurrency does the workqueue bottleneck become visible?**
   - Our single-request test showed 4 ctx switches for one cold file read
   - Run 100, 1000, 10000 concurrent requests and observe scaling

4. **How did `IORING_FEAT_NO_IOWAIT` change file read performance?**
   - Compare with a pre-5.18 kernel (or disable the feature if possible)
   - This isolates the architectural change impact

### Next reading to do

| Article | Why it matters now |
|---|---|
| Cloudflare: io_uring Worker Pool | Directly describes the worker pool behavior we are investigating |
| LWN 223899 / 236206 (workqueues) | Background on workqueue kernel internals |
| Paper: "Kernel Asynchronous APIs + VPN performance" | The actual result we are trying to understand and reproduce |

### Key command to run next (verify io-wq on network path)

```bash
# While running a loopback TCP benchmark with io_uring:
sudo bpftrace -e '
tracepoint:io_uring:io_uring_queue_async_work {
    @by_opcode[args->opcode] = count();
}
interval:s:1 { print(@by_opcode); }
'
```

If this counts non-zero for network operations, the workqueue path is active and the hypothesis is on solid ground.

---

## Quick Reference Card

```
io_uring in one paragraph
─────────────────────────
Two ring buffers (SQ + CQ) in shared memory between process and kernel.
You write SQEs (requests) to SQ, bump the tail pointer.
One syscall (io_uring_enter) tells the kernel to process them.
Kernel processes requests and writes CQEs to CQ tail.
You read CQEs from CQ head — no syscall needed.
For high throughput: batch N requests in one enter() call, poll CQ with zero syscalls.

Key numbers from live measurement (M1 Pro, kernel 6.18, cat.c 11KB)
────────────────────────────────────────────────────────────────────────
Warm cache latency:   3,667 ns  (~3.7 µs)    context switches: 0
Cold cache latency: 131,875 ns  (~132 µs)    context switches: 4
Warm/cold ratio: 35.9×                       CPU migrations (cold): 1
io-wq triggered: NO (IORING_FEAT_NO_IOWAIT changes path on kernel 6.x)

Tracepoint to watch for workqueue activity
────────────────────────────────────────────
io_uring:io_uring_queue_async_work  →  fires when io-wq is used
```
