# io_uring: Internship Reference Document

> **Purpose:** Consolidated reference covering everything learned about io_uring — how it works, live measurement results, and how it connects to the Inria KrakOS internship objectives.
> **Audience:** Self-reference + talking points for supervisor meetings.
> **Last Updated:** May 18, 2026
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
8. [io-wq Internals: What the Source Code Actually Shows](#8-io-wq-internals-what-the-source-code-actually-shows)
9. [Connection to Internship Objectives](#9-connection-to-internship-objectives)
10. [Open Questions and Next Steps](#10-open-questions-and-next-steps)

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
| `IORING_FEAT_NATIVE_WORKERS` | 5.12 | io-wq workers are created as proper `task_struct`-based kernel threads (via `create_io_thread`) rather than the older io_wq implementation — reduces wakeup latency. Note: these workers ARE kthreads; the flag means they are *native* task_struct threads, not that they switched away from kthreads |
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

## 8. io-wq Internals: What the Source Code Actually Shows

*Added May 2026 after reading `io_uring/io-wq.c` and `io_uring/io-wq.h` from torvalds/linux master.*

This section is the most important update to this document. The source code contradicts a claim that appeared in the internship report and presentation plan, and that André flagged as not convincing. The correction matters for the meeting with Alain.

### 8.1 io-wq workers are kthreads, not workqueue workers

The claim in the report was: *"io-wq dispatches work through `work_struct` items via `queue_work_on` — the same kernel primitives as WireGuard's workqueue."*

**This is wrong.** Reading `io-wq.c` shows the actual dispatch path:

**`io-wq.c:920` — worker creation:**
```c
tsk = create_io_thread(io_wq_worker, worker, NUMA_NO_NODE);
```

`create_io_thread` creates a **kernel thread** (`task_struct` with `PF_KTHREAD | PF_IO_WORKER` flags) running the `io_wq_worker` function. This is the same mechanism as any other kthread in the kernel — not the `alloc_workqueue` / `queue_work_on` subsystem.

**Dispatch path for work items:**
```
io_wq_enqueue(wq, work)
  └─ io_wq_insert_work()       adds work to per-acct list (raw_spin_lock)
  └─ io_acct_activate_free_worker()
       └─ wake_up_process()    wakes idle kthread worker
  └─ io_wq_create_worker()     if no idle worker, creates new kthread
```

No `queue_work_on`. No `work_struct` in the dispatch path. The kthread wakes, picks up the work item from an internal list, and runs it.

### 8.2 Where `work_struct` actually appears in io-wq

`work_struct` is used in exactly one place: **worker creation retry**.

**`io-wq.c:924`:**
```c
INIT_DELAYED_WORK(&worker->work, io_workqueue_create);
```

When `create_io_thread` fails (e.g., because the calling context doesn't allow direct kthread creation), io-wq schedules `io_workqueue_create` on the system workqueue as a fallback. That function then calls `create_io_thread` again. This is an error recovery path, not the normal dispatch path.

The primary worker creation path uses `task_work_add()` (`io-wq.c:411`), which attaches work to the io_uring task's task_work list — again, not `queue_work_on`.

### 8.3 What io-wq and WireGuard's workqueue actually share

Despite the different dispatch mechanisms, there are real similarities worth noting:

| Property | WireGuard `packet_crypt_wq` | io-wq |
|---|---|---|
| Worker type | Workqueue kthreads (via `alloc_workqueue`) | Kthreads (via `create_io_thread`) |
| Dispatch API | `queue_work_on()` | `wake_up_process()` on idle kthread |
| Scheduler priority | `SCHED_NORMAL` | `SCHED_NORMAL` |
| Preemptable by softirqs | Yes | Yes |
| Worker pool bounded | Yes (`WQ_PERCPU` — one per CPU) | Yes (bounded/unbounded caps) |
| `work_struct` in dispatch | Yes (core mechanism) | No (only for worker creation retry) |

Both run at normal scheduler priority and are preemptable by softirqs. The scheduling *behavior* is comparable at a high level — both can suffer from priority inversion if a high-priority softirq fires while they are running. But the implementation path is different, which means:

- Tracepoints for the kernel workqueue subsystem (`workqueue_queue_work`, `workqueue_execute_start`) apply to WireGuard's `packet_crypt_wq` **but not to io-wq workers**, because io-wq bypasses that subsystem entirely.

### 8.4 Consequence for the proxy argument

The proxy argument as stated — io-wq is a proxy for WireGuard's workqueue because they share the same kernel primitives — is not accurate at the implementation level.

A weaker but defensible version: *both run bounded pools of `SCHED_NORMAL` kernel threads that can be preempted by softirqs, so io-wq can be used to study priority-inversion scheduling patterns in a controlled single-machine setting, even though the dispatch mechanisms differ.* Whether this weaker claim is sufficient for the internship objective is the question for the Alain meeting.

The cleaner path, revealed by the source reading: **WireGuard's workqueue is directly instrumentable.** The tracepoints identified (`workqueue_queue_work`, `workqueue_execute_start`, `napi_poll`) apply directly to `packet_crypt_wq` and `wg_packet_decrypt_worker`. A proxy may not be needed at all.

### 8.5 Confirmed io-wq behavior from udp_read.rs experiment

The socket path experiment confirmed (before the source reading):

- Without `IOSQE_ASYNC`: 0 io-wq workers across 4,096 submitted socket reads. io_uring takes the fast-poll path; io-wq kthreads never created.
- With `IOSQE_ASYNC`: 4,096 io-wq kthreads created immediately. The flag forces the async path, bypassing the non-blocking attempt.

This confirms that `IOSQE_ASYNC` is the switch that activates io-wq for socket I/O — consistent with the source code showing that without it, the poll arm path (`IORING_FEAT_FAST_POLL`) handles sockets without touching io-wq.

---

## 9. Connection to Internship Objectives

*Revised May 2026 to reflect source code findings and the meeting with André.*

### 9.1 Current situation (as of May 2026)

The internship objective is not yet finalized. André and Alain agree that the proxy argument as written in the intermediate report is not strong enough. A three-way meeting (May 19) will set the actual objective for the full-time phase.

The study of io_uring was requested by Alain specifically. The reason may be one of:
- io_uring as a measurement proxy (original framing — now known to be inaccurate at the implementation level)
- io_uring as an alternative design for WireGuard's receive path
- io_uring as the subject, with WireGuard as motivation (EoI is a general pattern in any workqueue-below-softirq pipeline)
- io_uring for load generation on the client side of the WireGuard benchmark

The meeting will clarify which of these is the actual intent.

### 9.2 What the experiments established (still valid)

| Finding | How established | Still valid |
|---|---|---|
| `IORING_FEAT_NO_IOWAIT` routes file reads inline, bypassing io-wq | bpftrace on cat_uring | Yes |
| Socket path: 0 workers without `IOSQE_ASYNC`, 4096 with it | udp_read.rs | Yes |
| Context switches are observable at small scale (4 per cold file read) | perf stat | Yes |
| io-wq workers are kthreads, not workqueue workers | io-wq.c source reading | Yes — new finding |
| WireGuard EoI chain confirmed at source level | receive.c + queueing.h | Yes — new finding |
| `packet_crypt_wq` flags: `WQ_CPU_INTENSIVE | WQ_PERCPU` | device.c source reading | Yes — new finding |

### 9.3 What tracepoints work where

| Tracepoint | Applies to WireGuard `packet_crypt_wq` | Applies to io-wq |
|---|---|---|
| `workqueue_queue_work` | **Yes** — fires when work enqueued to packet_crypt_wq | No — io-wq bypasses kernel workqueue subsystem |
| `workqueue_execute_start` | **Yes** — fires at start of `wg_packet_decrypt_worker` | No |
| `io_uring:io_uring_queue_async_work` | No | **Yes** — fires when request offloaded to io-wq |
| `napi_poll` | **Yes** — fires for `wg_packet_rx_poll` (Stage 3) | No |

This table matters: if the objective is direct WireGuard measurement, the first three rows are the tools. If the objective involves io-wq, the fourth row is the tool.

### 9.4 Mapping to likely full-time phases

These phases may be revised after the May 19 meeting, but are the current working hypothesis:

| Phase | Goal | Key tool | Blocker |
|---|---|---|---|
| 1 — Reproduce | Reproduce 4.8 Gbps / 19.2% ceiling from Mounah et al. with <10% variance | WireGuard test environment | Need Brice Ekane / Teo Pisenti access |
| 2 — Attribute | Measure scheduler latency between workqueue dispatch and execution; isolate context switches vs CPU migrations vs wakeup latency | `workqueue_queue_work`, `workqueue_execute_start`, `napi_poll` via bpftrace | Stable baseline from Phase 1 |
| 3 — Compare | Kernel WireGuard vs wireguard-go under same workload; quantify workqueue cost relative to goroutine scheduler | Throughput measurement + Phase 2 tracepoints | Phase 1 + wireguard-go setup |

---

## 10. Open Questions and Next Steps

### 10.1 Questions answered since March

| Question | Answer |
|---|---|
| Does `io_uring_queue_async_work` fire for socket I/O? | Yes, but only with `IOSQE_ASYNC`. Default socket path uses fast-poll. |
| Does io-wq use `queue_work_on`? | No. io-wq uses kthreads via `create_io_thread` and `wake_up_process`. |
| What are WireGuard's workqueue flags? | `WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU` — per-CPU, not WQ_UNBOUND. |
| Where exactly does EoI trigger? | `queueing.h:196` — `napi_schedule(&peer->napi)` called from `wg_queue_enqueue_per_peer_rx`, inside the decryption worker loop. |
| Is EoI possible in wireguard-go? | No. Stage 3 (`RoutineSequentialReceiver`) blocks on a mutex held by Stage 2 (`RoutineDecryption`). No softirq preemption in user space. |

### 10.2 Questions to resolve at the May 19 meeting

1. **What is Alain's actual intent for io_uring in this internship?** Proxy, alternative design, client-side load generator, or something else?
2. **Is direct WireGuard instrumentation sufficient for the objective?** If so, the proxy argument can be dropped entirely.
3. **Is the wireguard-go comparison (Phase 3) still part of the scope?**
4. **What is the timeline pressure for the final report (June 5)?**

### 10.3 Next technical steps (this week, before the meeting)

- [ ] Read `kernel/workqueue.c` — understand `queue_work_on` dispatch, `WQ_PERCPU` behavior, `WQ_CPU_INTENSIVE` effect on concurrency limit
- [ ] Read `drivers/net/wireguard/peer.c` — find `netif_napi_add` call, understand per-peer NAPI setup
- [ ] Read `wireguard-go/tun/tun_linux.go` — confirm TUN write batch size and syscall count

### 10.4 bpftrace commands ready to run on the WireGuard test environment

```bash
# Measure scheduler latency: time between work enqueue and execution start
sudo bpftrace -e '
tracepoint:workqueue:workqueue_queue_work /str(args->workqueue_name) == "wg-crypt-wg0"/ {
    @enqueue[args->work] = nsecs;
}
tracepoint:workqueue:workqueue_execute_start /str(args->workqueue_name) == "wg-crypt-wg0"/ {
    if (@enqueue[args->work]) {
        @latency_ns = hist(nsecs - @enqueue[args->work]);
        delete(@enqueue[args->work]);
    }
}'

# Count NAPI poll invocations (Stage 3 preemptions)
sudo bpftrace -e 'tracepoint:napi:napi_poll { @[args->dev_name] = count(); }'

# Watch for EoI: napi_schedule calls from within workqueue context
sudo bpftrace -e '
kprobe:napi_schedule {
    if (curtask->flags & 0x00400000) {  // PF_WQ_WORKER
        @eoi_count = count();
    }
}'
```

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
io-wq triggered for files: NO  (IORING_FEAT_NO_IOWAIT, kernel 5.18+)
io-wq triggered for sockets: YES, but only with IOSQE_ASYNC flag

io-wq architecture (from source, May 2026)
───────────────────────────────────────────
Workers: kthreads created via create_io_thread() — NOT queue_work_on
Dispatch: wake_up_process() on idle kthread worker
work_struct used only for: worker creation retry (INIT_DELAYED_WORK)
WireGuard workqueue (packet_crypt_wq): alloc_workqueue, queue_work_on
  → WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU (device.c:346)
Conclusion: io-wq and WireGuard use DIFFERENT dispatch mechanisms

EoI trigger (confirmed from source)
────────────────────────────────────
queueing.h:196  napi_schedule(&peer->napi)
  called from: wg_queue_enqueue_per_peer_rx()
  called from: wg_packet_decrypt_worker()  [receive.c:503]
  stale pointer: napi_schedule records current CPU — not a live load query

Tracepoints for WireGuard measurement (no proxy needed)
─────────────────────────────────────────────────────────
workqueue:workqueue_queue_work    →  work enqueued to packet_crypt_wq
workqueue:workqueue_execute_start →  wg_packet_decrypt_worker begins
napi:napi_poll                    →  wg_packet_rx_poll (Stage 3) runs
io_uring:io_uring_queue_async_work → io-wq activated (socket path only)
```
