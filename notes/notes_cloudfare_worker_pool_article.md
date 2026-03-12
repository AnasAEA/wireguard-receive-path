## Reading: Cloudflare — Missing Manuals: io_uring Worker Pool

> Source: https://blog.cloudflare.com/missing-manuals-io_uring-worker-pool/

---

### Overview

Calling io_uring "just an async I/O interface" is an understatement. Underneath the API calls, io_uring is a **full-blown runtime** for processing I/O requests. It spawns threads, sets up work queues, and dispatches I/O requests for processing. All this happens in the background so that the userspace process doesn't have to manage it — but the process can still block while waiting for I/O completion if it wants to.

Using io_uring in a real project raises immediate questions:
- How many threads will be created for my workload by default?
- How can I monitor and control the thread pool size?

These questions are not answered in the *Efficient I/O with io_uring* article or the *Lord of the io_uring* guide — the two main pieces of available documentation. The io_uring man page does touch on it with:

> *"By default, io_uring limits the unbound workers created to the maximum processor count set by `RLIMIT_NPROC`, and the bound workers is a function of the SQ ring size and the number of CPUs in the system."*

But that raises further questions:
- What is an **unbounded** worker?
- How does it differ from a **bounded** worker?

---

### Not All I/O Requests Are Created Equal

io_uring can perform I/O on any kind of file descriptor — regular files, network sockets, character devices. However, the **type** of file descriptor determines which worker pool category the request falls into.

io-wq (the internal io_uring work queue) divides work into two categories:

| Category | Description | Pool limit |
|---|---|---|
| **Bounded work** | Completes in bounded time — e.g., reading from a regular file (`S_IFREG`) or block device (`S_IFBLK`) | Based on SQ ring size × number of CPU cores |
| **Unbounded work** | May never complete — e.g., reading from a network socket (`S_IFSOCK`) or character device | Limited by `RLIMIT_NPROC` |

**Unbounded workers** handle I/O that operates on neither regular files nor block devices — network sockets, pipes, character devices like `/dev/null`. This is the category that matters for **network I/O** (WireGuard, proxies, etc.).

The two worker categories have different limits, which is why understanding which path your workload takes is critical before tuning anything.

---

### Capping the Unbounded Worker Pool Size

Cloudflare's workload is network I/O — pushing data through sockets. In io_uring terms, that means submitting **unbounded work** requests. The article focuses on understanding and controlling the unbounded worker pool.

#### The test workload: `udp_read.rs`

To study how io_uring spawns workers, the approach is:
- Submit many read requests on a **UDP socket**
- Send **no packets** to that socket — so requests never complete naturally
- This gives full control over when completions happen, making worker lifecycle observable

The program (`udp_read.rs`, now in `io_uring_examples/worker_pool_tests/`) does this in a loop:
1. Fill the submission queue with `IORING_OP_READ` requests on a UDP socket
2. Call `submit_and_wait(1)` — blocks until at least one request completes
3. Drain the completion queue
4. Repeat

Because no UDP packets arrive, the reads block indefinitely — the io-wq workers are spawned and sit waiting, which is exactly the state needed to count and observe them.

#### Why strace won't work here

strace only shows syscalls made by the **main thread**. Worker threads run in the background and their syscalls are invisible to strace. Instead, use **in-kernel tracing via tracepoints**.

Discover all available io_uring tracepoints:
```bash
sudo perf list | grep io_uring
# or
sudo bpftrace -l 'tracepoint:io_uring:*'
```

The number of tracepoints available shows that io_uring takes **worker pool visibility seriously**. The key one for worker lifecycle:

```
io_uring:io_uring_queue_async_work  →  fires every time a request is offloaded to io-wq
```

#### Request lifecycle diagram (annotated with tracepoints)

There are **three paths** a request can take after `io_uring_enter()` consumes it from the submission queue:

```
submission queue
      │
      │  [io_uring_enter() called]
      ▼
  request  ──── tracepoint: io_uring:io_uring_submit_sqe
      │
      ├─── PATH 1: complete inline (fast-path)
      │         Data is immediately available — no blocking needed.
      │         → publish fast-path → completion queue
      │         → tracepoint: io_uring:io_uring_complete
      │
      ├─── PATH 2: blocking wait → worker pool
      │         Request cannot complete inline AND was marked IOSQE_ASYNC
      │         (or io_uring decides a blocking attempt is warranted).
      │         → tracepoint: io_uring:io_uring_queue_async_work
      │         → added to run queue → picked up by io-wq worker thread
      │         → [worker blocks until data arrives]
      │         → tracepoint: io_uring:io_uring_complete
      │
      └─── PATH 3: non-blocking wait → poll set  ← DEFAULT for sockets
                Request cannot complete inline. io_uring tries a non-blocking
                read first → gets EAGAIN → registers a wake-up via vfs_poll.
                → tracepoint: io_uring:io_uring_poll_arm
                → request sits in poll set, waiting for socket readiness
                → when socket becomes readable: io_async_wake() fires
                → tracepoint: io_uring:io_uring_poll_wake
                → moved to task list → completion queue
                → tracepoint: io_uring:io_uring_complete
```

**Critical distinction:** Path 3 (poll) is the default for sockets — io_uring does **not** spawn worker threads by default for socket reads. This is a surprising result addressed in the next section.

---

### Connection to Internship Research

This is the **missing link** between the `cat.c` investigation (where `io_uring_queue_async_work` never fired) and the WireGuard hypothesis:

| Workload | File type | io-wq used? | Worker category |
|---|---|---|---|
| `cat_uring` (buffered file read) | `S_IFREG` | ❌ No (kernel 6.x + `NO_IOWAIT`) | — |
| WireGuard tunnel I/O | `S_IFSOCK` | ✅ Yes | **Unbounded** |
| UDP socket reads | `S_IFSOCK` | ✅ Yes | **Unbounded** |

The workqueue bottleneck the Inria hypothesis describes **is real for socket I/O** — it just doesn't apply to file I/O on modern kernels. WireGuard uses sockets, so the hypothesis is on solid ground.

The `udp_read.rs` program gives us a minimal, controllable way to study the exact worker pool behavior that affects WireGuard performance.

---

### Default Behavior: io_uring Polls Sockets, It Doesn't Block on Them

Counter-intuitive finding: **submitting requests is not enough to spawn worker threads.**

Experiment — verify that 4096 SQEs were submitted:
```bash
sudo perf stat -e io_uring:io_uring_submit_sqe -- timeout 1 ./udp-read
# Output: 4096 io_uring:io_uring_submit_sqe events, 1.049s elapsed
```

But check the thread count:
```bash
./udp-read & p=$!; sleep 1; ps -o thcount $p; kill $p; wait $p
# THCNT: 1  ← single-threaded! No workers spawned.
```

This is because io_uring is **smart about sockets**: it knows sockets support non-blocking I/O and can be polled for readiness. So the default path is:

1. Try a non-blocking read on the socket
2. Get `EAGAIN` (no data available)
3. Register a wake-up call via `io_async_wake()` — this calls `vfs_poll` internally
4. Wait to be notified when the socket becomes readable

This is functionally equivalent to using `select()` or `epoll()` from userspace. No worker threads are needed — io_uring just polls and waits. Unless an `IORING_OP_LINK_TIMEOUT` was also submitted, it waits indefinitely.

Confirm with bpftrace that it's the poll path being hit (opcode 22 = `IORING_OP_READ`):
```bash
sudo bpftrace -lv t:io_uring:io_uring_poll_arm
# Fields: ctx, req, opcode, user_data, mask, events

sudo bpftrace -e 't:io_uring:io_uring_poll_arm { @[probe, args->opcode] = count(); } i:s:1 { exit(); }' -c ./udp-read
# Output: @[tracepoint:io_uring:io_uring_poll_arm, 22]: 4096

sudo bpftool btf dump id 1 format c | grep 'IORING_OP_.*22'
# IORING_OP_READ = 22
```

All 4096 read requests took the **poll path** (Path 3), not the worker pool path (Path 2). Zero workers spawned.

---

### Forcing the Worker Pool: `IOSQE_ASYNC`

To make io_uring spawn worker threads, requests must be forced through the **blocking path** (Path 2). This is done with the `IOSQE_ASYNC` flag per-SQE.

From the `io_uring_enter(2)` man page:
```
IOSQE_ASYNC
    Normal operation for io_uring is to try and issue an sqe as
    non-blocking first, and if that fails, execute it in an async
    manner. To support more efficient overlapped operation of requests
    that the application knows/assumes will always (or most of the time)
    block, the application can ask for an sqe to be issued async from
    the start. Available since 5.6.
```

Setting `IOSQE_ASYNC` bypasses the non-blocking attempt entirely. The call chain becomes:

```
io_queue_sqe()  →  io_queue_async_work()  →  create_io_worker()  →  create_io_thread()
```

`create_io_thread()` spawns a new kernel thread to process the work. Remember that function — it comes up again later in the article.

Experiment — run with `--async` flag (which sets `IOSQE_ASYNC` on all SQEs):
```bash
./udp-read --async & pid=$!; sleep 1; ps -o pid,thcount $pid; kill $pid; wait $pid
# PID     THCNT
# 3457597 4097   ← 4096 workers + 1 main thread
```

Thread count jumped from 1 to **4097**: one worker per submitted read request. io_uring has spawned workers — one for each in-flight blocking read.
