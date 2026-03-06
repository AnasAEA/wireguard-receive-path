## Reading: Lord of io_uring

### Overview

- **"Lord of io_uring"** is a comprehensive guide that delves into the intricacies of the `io_uring` interface in Linux.
---
### Asynchronous Programming Under Linux

#### Process Model (Single-Threaded, Synchronous)

- In general, the program blocks on syscalls until the kernel returns the result, which is inefficient for I/O-bound applications that need to wait for I/O operations to complete.

#### Multi-Threaded Programs

- In multi-threaded programs, threads can be blocked on syscalls while other threads continue executing, but this approach has overhead due to context switching and synchronization.
- Thread pools can help manage threads more efficiently, but they still incur overhead.

#### Why Asynchronous Programming?

- Asynchronous programming allows a single thread to initiate multiple I/O operations without blocking, enabling it to perform other tasks while waiting for I/O to complete.
- This can lead to better resource utilization and improved performance, especially in I/O-bound applications.
---
### Analyzing Different Linux Server Models

#### Iterative Model

- The iterative model processes one request at a time in a single thread. There is a limit to how many concurrent connections it can queue: Linux queues up to **128** for kernel versions below 5.4, and **4096** for versions 5.4 and above (this is the `SOMAXCONN` listen backlog).

#### Forking Model

- The forking model creates a new process for each incoming request, which can handle multiple requests concurrently, but it has high overhead due to process creation and context switching.
- When there are multiple available CPU cores, the forking model can utilize them effectively, but the overhead can still be significant.

#### Preforked Model

- This type of server avoids the overhead of process creation by maintaining a pool of pre-created processes that are assigned incoming requests.
- When the number of incoming requests exceeds the number of pre-created processes, new requests have to wait until a process becomes available, which can lead to increased latency.
- Administrators need to carefully size the process pool based on expected load to balance resource utilization and responsiveness.

#### Threaded Model

- The threaded model uses multiple threads within a single process to handle incoming requests concurrently, which can reduce the overhead associated with process creation and context switching.
- However, threads share the same memory space, which can lead to synchronization issues and increased complexity in managing shared resources.

#### Prethreaded Model

- Similar to the preforked model, the prethreaded model maintains a pool of pre-created threads to handle incoming requests.
- This approach can reduce latency and improve responsiveness, but it also requires careful management of the thread pool to ensure optimal performance.
#### Poll-Based Model

- This type of server is single-threaded and uses the `poll(2)` system call to multiplex between requests.
- **Note:** Unlike `select(2)` (which is limited to `FD_SETSIZE`, typically 1024 file descriptors), `poll(2)` does **not** have a hard FD limit — it uses a dynamically-sized array of `pollfd` structures. However, `poll(2)` still has **O(n)** scanning overhead: the kernel must iterate through the entire array on every call, which becomes a bottleneck at high concurrency.
- Additionally, `poll(2)` requires the application to repeatedly pass the full list of file descriptors on each call, which adds unnecessary data copying overhead.

#### Epoll-Based Model

- `epoll` is an improved mechanism designed for high-concurrency applications. It uses the `epoll(7)` family of system calls to efficiently monitor large numbers of file descriptors.
- `epoll` uses a more efficient **event notification** mechanism, allowing applications to be notified only when specific events occur on monitored file descriptors, reducing the need for repeated linear scans.
- `epoll` can handle a much larger number of file descriptors compared to `poll` or `select`, making it far more suitable for high-concurrency applications.
---
### Benchmarking Different Models

- When benchmarking different server models:
  - The prethreaded model (or the threaded model) based web servers give the `epoll(7)`-based servers a run for their money until a concurrency of ~11,000 users in the benchmark. Beyond this point, the epoll-based servers start to outperform the threaded ones.
  - This is very significant given that, in terms of complexity, thread-pool-based servers are **way easier** to implement than asynchronous epoll-based servers.
---

### Making Asynchronous Programming Easier

- Usually, when building a program with an asynchronous architecture, you use a high-level framework or library that abstracts away the low-level details of asynchronous programming.
- Examples of such frameworks include **Node.js** (JavaScript), **asyncio** (Python), and **Boost.Asio** (C++).
- Generally, we don't need to deal with programming at these low-level APIs directly — unless building specialized applications like web frameworks or high-performance network services.
---
### Linux Asynchronous APIs Before io_uring

#### `select()`, `poll()`, `epoll()` — Event Notification (Readiness-Based)

- **Idea:** Instead of calling `read()` or `write()` and blocking until the operation completes, the application first calls `select()`, `poll()`, or `epoll()` to wait for the file descriptor to become **ready** for reading or writing.
- A **file descriptor (FD)** is just an integer that represents an open file, socket, or other I/O resource in a Unix-like operating system.
- **"Ready"** usually means:
  - **Readable:** `read()` would not block because there is data available to read.
  - **Writable:** `write()` would not block because there is space available to write data.
  - **Acceptable:** `accept()` would not block because there is an incoming connection waiting to be accepted.
- So an FTP server can:
  - Wait for new client connections on its listening socket (`accept()`).
  - Wait for commands on connected client sockets (`read()`).
  - Send responses to clients (`write()`).
- …all in a single thread, by checking which FDs are ready for the desired operations using `select()`, `poll()`, or `epoll()`.
#### Linux Kernel AIO: `aio(7)` — Asynchronous I/O (with Limitations)

- Linux also introduced asynchronous I/O (AIO), often called **"Linux AIO"** or **"libaio"**, to allow applications to submit I/O requests that the kernel processes in the background and notifies the application when they are complete.
- However, Linux AIO has several limitations:
  1. **Works mainly with `O_DIRECT` / unbuffered I/O:**
     - Normally, Linux uses the **page cache** to buffer file I/O: reads/writes go through memory caching to improve performance.
     - `O_DIRECT` means: *"skip the page cache and go directly to/from the disk"*, which can be less efficient for small I/O operations.
     - Many apps want the page cache for performance and simplicity. Also, `O_DIRECT` comes with annoying constraints (like alignment requirements). So this restriction makes AIO unusable for a lot of normal file I/O workloads.
  2. **"Async I/O" can still block:**
     - Even if the file is opened in unbuffered mode, AIO can still block when the kernel needs to perform file metadata operations (like allocating space on disk) that require data not yet in memory.
  3. **Submission can block because devices have limited request slots:**
     - Storage devices and the block layer often have a maximum number of in-flight requests they can handle.
     - If an application submits more requests than the device can handle, the kernel may block the application until some requests complete — defeating the purpose of asynchronous I/O.
  4. **Extra overhead per operation (copies and syscalls):**
     - About **104 bytes** copied per submission + completion (kernel ↔ userspace).
     - **Two syscalls** per operation: `io_submit()` + `io_getevents()` (to fetch completions).

---
### The Trouble with Regular Files

- On a server that is not very busy, reading or writing a file might not take long. Take our FTP server example from above, written using an asynchronous design.
- When the server is really busy — with many concurrent users downloading and uploading large files simultaneously — `read(2)` and `write(2)` calls can begin to **block significantly**.
- Won't `select(2)`, `poll(2)`, or the `epoll(7)` family of system calls help here? **Unfortunately, no.** These system calls will always report regular files as being ready for I/O. This is their **Achilles' heel**.
- We won't go into why this is, but it is important to understand: while they work really well for sockets, they **always return "ready" for regular files**.
- This makes file descriptors **non-uniform** under asynchronous programming. File descriptors backing regular files are discriminated against. For this reason, libraries like **libuv** use a separate thread pool for I/O on regular files, exposing an API that hides this discrepancy from the user.

#### Does This Problem Exist in io_uring?

- **No.** `io_uring` presents a uniform interface whether dealing with regular files, sockets, or other types of file descriptors.
- Due to the design of the API, programs receive the **actual result** of the I/O operation (data read, bytes written) directly, rather than being told when a file descriptor is "ready" for I/O. This is a **completion-based** model, not a **readiness-based** model.
- This uniformity simplifies the design of asynchronous applications and improves performance by avoiding unnecessary blocking on regular files.
---

### What is io_uring?

- `io_uring` is a Linux kernel interface (introduced in **Linux 5.1**) that provides a high-performance asynchronous I/O mechanism.
- It aims to provide an API **without the limitations** of previous asynchronous I/O interfaces in Linux.

### The io_uring Interface

- `io_uring` uses **two ring buffers** shared between the application and the kernel:
  - **Submission Queue (SQ):** Where the application submits I/O requests to the kernel (e.g., read, write, fsync, etc.).
  - **Completion Queue (CQ):** Where the kernel places completed I/O results for the application to retrieve.
- The application can submit multiple I/O requests in a batch to the SQ and later retrieve their completions from the CQ, allowing for efficient asynchronous I/O operations with reduced system call overhead.
#### The Mental Model

The mental model for using `io_uring` to build programs that process I/O asynchronously is as follows:

1. There are **two ring buffers** shared between the application and the kernel: the **Submission Queue (SQ)** and the **Completion Queue (CQ)**.
2. These ring buffers are set up with a single syscall `io_uring_setup()` and then mapped into user space with `mmap(2)` calls (one for each ring).
3. You tell `io_uring` what you need done (read/write a file, accept client connections on a socket, etc.) by filling out **Submission Queue Entries (SQEs)** and placing them into the SQ ring buffer.
4. You then tell the kernel via the `io_uring_enter()` syscall that there are new requests to process. You can add multiple SQEs before calling `io_uring_enter()` to batch submissions together.
5. Optionally, `io_uring_enter()` can also wait for completions to become available in the CQ ring buffer.
6. The kernel processes the submitted requests and adds **Completion Queue Events (CQEs)** to the tail of the CQ ring buffer as requests complete.
7. The application reads CQEs from the head of the CQ ring buffer to retrieve the results of completed I/O operations. There is **one CQE corresponding to each SQE** submitted, and it contains the status of that particular I/O operation (success, error code, number of bytes read/written, etc.).
8. You continue adding SQEs and reaping CQEs as needed to perform asynchronous I/O operations.
9. There is a **polling mode** available in which the kernel polls for new submissions in the SQ ring buffer without needing to be notified via `io_uring_enter()`. This avoids the overhead of syscalls for submission notifications.
---
### io_uring Performance

- `io_uring` can be a **zero-copy interface** in some scenarios, meaning that data can be transferred directly between user space and the kernel without additional copying. This is because of the shared ring buffers between the kernel and user space — copying bytes becomes necessary when system calls that transfer data between kernel and user space are involved (e.g., `read()`, `write()`).
- We still need to avoid syscalls as much as possible to minimize overhead and maximize performance.
- By batching multiple I/O operations together in a single submission and completion, `io_uring` reduces the number of syscalls required, which in turn reduces the amount of data copied between user space and the kernel.
- You can also have the kernel **poll** and pick up new submissions from the SQ ring buffer, avoiding the `io_uring_enter()` syscall entirely. For high-throughput applications, this means even less system call overhead.
- With clever use of shared ring buffers, `io_uring` performance is really **memory-bound**: in polling mode, we can do away with syscalls almost entirely. This means performance is limited by how fast data can be moved in memory, rather than how fast syscalls can be made.
- **Benchmark figures** (from the io_uring paper, on a reference machine):
  - In **polling mode**, `io_uring` managed to clock **1.7 million 4K IOPS** (I/O operations per second — reading or writing 4 KB blocks 1.7 million times per second) with a single core. Meanwhile, `aio(7)` manages **608,000 IOPS** under the same conditions.
  - This is not a perfectly fair comparison since `aio(7)` doesn't have a polling mode. But even in **non-polling mode** (which involves syscalls), `io_uring` still outperforms `aio(7)` with **1.2 million IOPS** vs. **608,000 IOPS**.
  - To measure raw throughput of the `io_uring` interface itself, there is a **no-op request type**. On the reference machine, `io_uring` achieves **~20 million messages per second**.
---
### An example using the low level API
- I will make an example program that reads files and prints their contents like how the unix `cat` command does, but using `io_uring` to perform the file I/O asynchronously. This will demonstrate how to use the low-level `io_uring` API directly.
- we will do it later
---
### Just use liburing
- knowing about the low-level API is useful for understanding how `io_uring` works, but in practice, we want to probably use the higher level interface provided by the **liburing** library, which abstracts away some of the complexities of working with the raw `io_uring` API.
- Programs like **QEMU** and already use it to perform high-performance I/O operations, and many other applications can benefit from it as well.
- i should put some effort into understanding the low level io-uring interface, but by defaulyt, i should probably just use liburing for my applications.
---
## Chapter: The low-levelio-uring interface
- like mentioned before the low-level `io_uring` interface is useful for understanding how the API works, but in practice, we will likely want to use the higher-level interface provided by the **liburing** library, which abstracts away some of the complexities of working with the raw `io_uring` API.
- to practive , we will create a simple program that reads files and prints their contents like the unix `cat` command, but using `io_uring` to perform the file I/O asynchronously. This will demonstrate how to use the low-level `io_uring` API directly.
### Familiarity with the readv(2) system call
- to understand this example, we need to be familiar with the `readv(2)` system call, which allows us to read data from a file descriptor into multiple buffers in a single call. This is useful for efficiently reading data into non-contiguous memory regions.
- `readv(2)` takes three arguments:
  1. `fd`: The file descriptor to read from.
  2. `iov`: A pointer to an array of `struct iovec` structures, which describe the buffers to read into.
  3. `iovcnt`: The number of buffers in the `iov` array.
- Each `struct iovec` has two fields:
  - `iov_base`: A pointer to the buffer where the data should be stored.
  - `iov_len`: The length of the buffer in bytes.
- The `readv(2)` system call will read data from the file descriptor and fill the buffers described by the `iov` array, returning the total number of bytes read across all buffers.
- In our `io_uring` example, we will use `readv(2)` to read data from a file descriptor into multiple buffers, and we will submit this operation to the `io_uring` interface to perform it asynchronously.
### Introduction to the low-level interface
- The low-level `io_uring` interface involves directly interacting with the submission and completion queues, which are shared memory regions between the application and the kernel.
- We submit information on various operations (like read, write, etc.) by filling out **Submission Queue Entries (SQEs)** and placing them into the Submission Queue (SQ) ring buffer.
- we can place as more than one request. As many requests as the queue depth (which we specify when setting up the `io_uring` instance) allows. This is called **batching** and can significantly improve performance by reducing the number of syscalls needed to submit multiple operations.
- then we can call `io_uring_enter()` to notify the kernel that there are new requests to process. Optionally, we can also wait for completions to become available in the Completion Queue (CQ) ring buffer at this point.
- The kernel processes the submitted requests and adds **Completion Queue Events (CQEs)** to the tail of the CQ ring buffer as requests complete. These CQEs can bbe accessed from user space instantly since they are plcaed in a buffer shared between the kernel and user space.
- Before doing all of this, we need to set up the `io_uring` instance by calling `io_uring_setup()`, which initializes the shared ring buffers and returns a file descriptor that we can use to interact with the `io_uring` interface. We then map the SQ and CQ ring buffers into user space using `mmap(2)` calls.
- Once we have the `io_uring` instance set up and the ring buffers mapped, we can start submitting I/O requests and retrieving their completions as needed to perform asynchronous I/O operations.
---
### Completion queue Entry
- Now that we have a mental model of how things work, let's dive in more details.Compared to the Submission Queue Entry (SQE), the Completion Queue Entry (CQE) is much simpler.The SQE is an instance of `struct io_uring_sqe`, which we use to submit requests. You add it to the submission ring buffer. the CQE is an instance of `struct io_uring_cqe`, which the kernel responds with for every io_uring_sqe strucure instance that is added to the submission queue. This contains the result of the operation (e.g., number of bytes read/written, or an error code if the operation failed).
- The CQE has the following fields:
  - `user_data`: This is a 64-bit value that we can set in the corresponding SQE when we submit a request. It is returned in the CQE so that we can identify which request the completion corresponds to. This is especially useful when we have multiple requests in flight and we want to match completions to their respective requests.
  - `res`: This field contains the result of the I/O operation. For example, for a read operation, it would contain the number of bytes read, or a negative error code if the operation failed.
  - `flags`: This field contains flags that provide additional information about the completion. For example, it can indicate if the completion is part of a batch of operations or if there are more completions to process.
- When we retrieve a CQE from the completion queue, we can check the `res` field to see if the operation was successful (positive value) or if it failed (negative value). We can also use the `user_data` field to identify which request this completion corresponds to, allowing us to handle the completion appropriately based on the original request we submitted.
---
### Correlating completions to submissions
- as mentioned before, the `user_data` field is passed as-is from the SQE to the corresponding CQE, since requests are not necessarily completed in the same order they were submitted. This allows us to correlate completions to their respective submissions, which is crucial when we have multiple requests in flight.
- For example, if we submit three read requests with different `user_data` values (e.g., 1, 2, and 3), when we retrieve the completions from the completion queue, we can check the `user_data` field in each CQE to determine which read request it corresponds to. This way, we can handle the completion of each request appropriately based on its original submission.
- The comlpletion queue entry is simple since it mainly concerns with a system call return value, which is stored in the `res` field.
---
### Ordering
- while order of CQEs is not guaranteed to match the order of SQEs, we can force ordering by using the `IOSQE_IO_DRAIN` flag in the SQE. This flag tells the kernel to ensure that all previously submitted requests are completed before processing the current request. By using this flag, we can ensure that the completions for the requests are returned in the same order as they were submitted.
- However, using `IOSQE_IO_DRAIN` can introduce additional latency, as it forces the kernel to wait for all previous requests to complete before processing the current request. Therefore, it should be used judiciously, only when strict ordering of completions is necessary for the application logic.
---
### Submission Queue Entry
- The Submission Queue Entry (SQE) is a bit more complex than the Completion Queue Entry (CQE) because it needs to be generic enough to represent various types of I/O operations (e.g., read, write, fsync, etc.) and their associated parameters. The `struct io_uring_sqe` has the following fields:
  - `opcode`: This field specifies the type of I/O operation being submitted (e.g., `IORING_OP_READV`, `IORING_OP_WRITEV`, etc.).
  - `flags`: This field contains flags that modify the behavior of the I/O operation (e.g., `IOSQE_IO_DRAIN` for ordering).
  - `ioprio`: This field can be used to specify the I/O priority of the request.
  - `fd`: This field specifies the file descriptor on which the I/O operation should be performed.
  - `off`: This field specifies the offset in the file for read/write operations.
  - `addr`: This field is a pointer to a buffer in user space for read/write operations.
  - `len`: This field specifies the length of the buffer for read/write operations.
  - `user_data`: This is a 64-bit value that we can set to identify this request when we receive its completion in a CQE.
- When we want to read a file using `readv(2)` system call:
  - opcode is used to specify the type of I/O operation (e.g., `IORING_OP_READV`).
  - fd is set to the file descriptor of the file we want to read from.
  - addr is set to a pointer to an array of `struct iovec` that describes the buffers we want to read into.
  - len is set to the number of buffers in the `iovec` array.
  - user_data can be set to a unique value to identify this read request when we receive its completion in a CQE.
- By filling out the SQE with the appropriate values for the desired I/O operation and submitting it to the submission queue, we can perform asynchronous I/O operations using `io_uring`. When the operation completes, we can retrieve the result from the corresponding CQE and use the `user_data` field to correlate it back to the original request.
---

## Cat with io_uring
- Now that we have a good understanding of the low-level `io_uring` interface, let's implement a simple program that reads files and prints their contents like the unix `cat` command, but using `io_uring` to perform the file I/O asynchronously. This will demonstrate how to use the low-level `io_uring` API directly.
- The program will take one or more file names as command-line arguments and print the contents of each file to stdout.

---

### cat.c — Deep Analysis

#### The Three Syscalls (from strace)

```
io_uring_setup(1, {...}) = 3
mmap(NULL, 132,  MAP_SHARED|MAP_POPULATE, fd=3, offset=0)          → shared SQ+CQ ring
mmap(NULL, 64,   MAP_SHARED|MAP_POPULATE, fd=3, offset=0x10000000) → SQE array
io_uring_enter(3, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0) = 1
```

That is the entire io_uring interaction for reading one file. Four calls total — compare to a traditional read: `open → read → close`.

---

#### Stage 1 — `app_setup_uring()`: Building the shared memory channel

`io_uring_setup(1, &params)` asks the kernel to create a ring of depth 1. It returns `fd=3`. This fd is not for reading/writing — it is a **handle to shared memory**.

Two mmaps then map that memory into the process:

| mmap offset | size | what it maps |
|---|---|---|
| `0` (IORING_OFF_SQ_RING) | 132 bytes | SQ ring heads/tails + CQ ring heads/tails (merged — see below) |
| `0x10000000` (IORING_OFF_SQES) | 64 bytes | The actual SQE slot (1 × 64 bytes) |

The strace shows `IORING_FEAT_SINGLE_MMAP` in the feature set the kernel returned. When this flag is set, the SQ ring and CQ ring metadata live **in the same physical memory page** — so one mmap covers both. That is why the code sees only 2 mmaps instead of the 3 the tutorial describes.

No data ever crosses the syscall boundary. The userspace process and the kernel literally read/write the same RAM. Submit a request: update a pointer. The kernel polls that pointer without any syscall.

---

#### Stage 2 — `submit_to_sq()`: Writing an SQE

For a file of N bytes, the code allocates `ceil(N/1024)` iovec structs, then grabs the one available SQE slot (index = `*sq.sqe_head & *sq.ring_mask`) and fills it:

```c
sqe->opcode   = IORING_OP_READV;    // vectorized async read
sqe->fd       = file_fd;
sqe->addr     = (uint64_t)iovecs;   // pointer to iovec array in userspace
sqe->len      = nr_blocks;          // number of iovec elements
sqe->off      = 0;                  // file offset
sqe->user_data = (uint64_t)fi;      // YOUR pointer, kernel echoes it back untouched
```

`user_data` is the key correlation mechanism — the kernel never looks at it, just copies it to the CQE. When the completion comes back, casting `cqe->user_data` back to `(struct file_info *)` reveals exactly which request completed.

After filling the SQE, the code does a `write_barrier()` (`__sync_synchronize` / `asm volatile("" ::: "memory")`) and advances the SQ tail. This signals to the kernel: *there is a new entry*.

---

#### Stage 3 — `io_uring_enter()`: Submitting and waiting

```c
io_uring_enter(ring_fd, 1, 1, IORING_ENTER_GETEVENTS)
//                       ^  ^
//                       |  min_complete=1 → BLOCK until at least 1 CQE is ready
//                       to_submit=1
```

**Critical observation:** this program is actually synchronous. The `min_complete=1` flag means the syscall does not return until the kernel has finished the read and placed a CQE. It is functionally identical to calling `preadv()`. The io_uring mechanics are there, but the async benefit is zero.

True async usage would be:

```c
// submit without waiting
io_uring_enter(ring_fd, 1, 0, 0);
// ... do other work ...
// later, poll the CQ ring without any syscall:
if (*cq.head != *cq.tail) { /* completion available */ }
```

Or submit a batch of 1000 requests with one `io_uring_enter`, then poll completions without ever entering the kernel again.

---

#### Stage 4 — `read_from_cq()`: Harvesting completions

The code polls the CQ ring directly (no syscall):

```c
while (*cq.head != *cq.tail) {          // kernel-visible tail
    cqe = &cq.cqes[*cq.head & mask];   // read the entry
    fi = (struct file_info *)cqe->user_data;
    // write blocks to stdout
    (*cq.head)++;                        // advance head: tells kernel slot is free
}
```

---

#### Kernel feature flags (from live strace)

The kernel returned this feature set to `io_uring_setup`:

| Flag | Meaning |
|---|---|
| `IORING_FEAT_SINGLE_MMAP` | 2 mmaps instead of 3 (active in this run) |
| `IORING_FEAT_NATIVE_WORKERS` | kernel 5.12+: io-wq uses native threads, not kthreads |
| `IORING_FEAT_FAST_POLL` | if fd is poll-able, uses fast-path instead of io-wq |
| `IORING_FEAT_NODROP` | kernel never silently drops CQEs |
| `IORING_FEAT_SUBMIT_STABLE` | SQE data is read before `enter()` returns |
| `IORING_FEAT_NO_IOWAIT` | kernel won't sleep on `io_schedule()` for io-wq |

`IORING_FEAT_NATIVE_WORKERS` is directly relevant to Inria KrakOS research: it changed the internal worker architecture and affects the workqueue bottlenecks under study.

---

### Investigating the Kernel Path

#### 1 — io_uring tracepoints

```bash
# List all available io_uring tracepoints
sudo cat /sys/kernel/tracing/available_events | grep io_uring

# Trace all io_uring events for one run
sudo trace-cmd record -e 'io_uring:*' ./cat_uring cat.c
sudo trace-cmd report | head -60
```

Key tracepoints:

| Tracepoint | When it fires |
|---|---|
| `io_uring:io_uring_create` | Ring created, shows depth and flags |
| `io_uring:io_uring_submit_sqe` | Each SQE submitted, shows opcode |
| `io_uring:io_uring_queue_async_work` | **The important one** — fires when I/O is offloaded to io-wq |
| `io_uring:io_uring_complete` | CQE posted, shows result |

If `io_uring_queue_async_work` fires, the request went through the workqueue (slow path). If it doesn't, the I/O completed inline (fast path — possible for cached reads or poll-capable fds).

---

#### 2 — bpftrace: live kernel tracing

```bash
# See exactly when work is queued to io-wq
sudo bpftrace -e '
tracepoint:io_uring:io_uring_queue_async_work {
    printf("pid=%d work_queued opcode=%d flags=%d\n", pid, args->opcode, args->flags);
}'

# Time how long each SQE takes from submit to complete
sudo bpftrace -e '
tracepoint:io_uring:io_uring_submit_sqe  { @start[args->user_data] = nsecs; }
tracepoint:io_uring:io_uring_complete    {
    $lat = nsecs - @start[args->user_data];
    printf("latency = %lld ns\n", $lat);
    delete(@start[args->user_data]);
}'
```

---

#### 3 — perf: workqueue statistics

```bash
# Count io-wq worker wakeups and context switches
perf stat -e context-switches,sched:sched_wakeup,workqueue:workqueue_execute_start \
    ./cat_uring cat.c

# Full perf trace (like strace with kernel timestamps)
sudo perf trace ./cat_uring cat.c
```

---

#### 4 — /proc inspection (during a long-running test)

```bash
# In one terminal
./cat_uring /dev/urandom &
PID=$!

# In another
cat /proc/$PID/maps | grep -i uring   # shared ring memory regions
cat /proc/$PID/fdinfo/3               # inspect the ring fd state
ls /proc/$PID/task                    # see io-wq worker threads the kernel spawned
```

---

#### 5 — Kernel source path for `IORING_OP_READV`

```
io_uring_enter()
  └─ io_submit_sqes()
       └─ io_queue_sqe()
            └─ io_issue_sqe()
                 └─ io_read()                    ← in io_uring/rw.c (kernel 6.x)
                      └─ (regular file, cannot complete inline)
                           └─ io_uring_queue_async_work()  ← pushes onto io-wq
                                └─ io_wq_submit_work()
                                     └─ io_read()  ← runs again in worker thread
```

---

#### Connection to Internship Research

`cat.c` uses **buffered I/O** (`O_RDONLY`, no `O_DIRECT`). On a warm page cache the read completes inline (no io-wq). To test the actual workqueue path:

```bash
# Drop page cache, then trace
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo bpftrace -e 'tracepoint:io_uring:io_uring_queue_async_work { printf("went async!\n"); }' &
./cat_uring cat.c
```

If `went async!` appears after the cache drop, the io-wq path was taken. That wakeup cost — and what happens when 1000 requests all hit it simultaneously — is precisely the bottleneck being measured.

With `O_DIRECT` + page-aligned buffers, some ops can complete inline, bypassing the workqueue entirely. That tradeoff (and the cost of io-wq thread wakeup overhead) is the core of the workqueue performance problem.

---

## Live Kernel Investigation Results

> **Environment:** kernel `6.18.10-402.asahi.fc42.aarch64+16k`, Apple M1 Pro (ARM64), Fedora Asahi Remix 42
> **Tools used:** `bpftrace`, `perf stat`, `strace`
> **File tested:** `cat.c` (11,041 bytes)

---

### Available io_uring tracepoints on this kernel

```
# io_uring namespace
io_uring:io_uring_create
io_uring:io_uring_register
io_uring:io_uring_file_get
io_uring:io_uring_submit_req
io_uring:io_uring_queue_async_work
io_uring:io_uring_complete
io_uring:io_uring_task_add
io_uring:io_uring_task_work_run
io_uring:io_uring_local_work_run
io_uring:io_uring_poll_arm
io_uring:io_uring_fail_link
io_uring:io_uring_link
io_uring:io_uring_defer
io_uring:io_uring_cqring_wait
io_uring:io_uring_cqe_overflow
io_uring:io_uring_req_failed
io_uring:io_uring_short_write

# syscall entry/exit wrappers
syscalls:sys_enter_io_uring_setup
syscalls:sys_exit_io_uring_setup
syscalls:sys_enter_io_uring_enter
syscalls:sys_exit_io_uring_enter
syscalls:sys_enter_io_uring_register
syscalls:sys_exit_io_uring_register
```

---

### perf stat — warm cache vs cold cache

**Warm cache** (file already in page cache):

```
context-switches:    0
cpu-migrations:      0
cycles:          597,605   (apple_firestorm P-core only — no E-core activity)
instructions:    927,832   (1.55 IPC)
time elapsed:    0.000380s
user time:       0.000404s
sys time:        0.000000s   ← zero kernel time
```

**Cold cache** (after `echo 3 > /proc/sys/vm/drop_caches`):

```
context-switches:    4
cpu-migrations:      1       ← io-wq ran on a different core
cycles:        1,201,914   (2x more than warm)
instructions:  1,375,331   (1.14 IPC — lower due to memory stalls)
time elapsed:    0.001357s  (3.6x slower)
user time:       0.000000s
sys time:        0.000655s   ← 655µs of kernel time for the actual block I/O
```

**Key takeaway:** Zero sys time with warm cache — the entire read completes in userspace-visible time without entering kernel scheduling. With cold cache the kernel actually does I/O work: 655µs spent inside the kernel, 4 context switches, 1 CPU migration.

---

### bpftrace — full event lifecycle

Command used:
```bash
sudo bpftrace -e '
tracepoint:io_uring:io_uring_create    { printf("1. CREATE: sq=%d cq=%d flags=0x%x\n", args->sq_entries, args->cq_entries, args->flags); }
tracepoint:io_uring:io_uring_submit_req { printf("3. SUBMIT: opcode=%d user_data=0x%llx\n", args->opcode, args->user_data); }
tracepoint:io_uring:io_uring_queue_async_work { printf("4. ASYNC_WORK: opcode=%d rw=%d\n", args->opcode, args->rw); }
tracepoint:io_uring:io_uring_task_add  { printf("5. TASK_ADD: opcode=%d mask=%d\n", args->opcode, args->mask); }
tracepoint:io_uring:io_uring_local_work_run { printf("6. LOCAL_WORK: count=%d loops=%d\n", args->count, args->loops); }
tracepoint:io_uring:io_uring_complete  { printf("7. COMPLETE: res=%d user_data=0x%llx\n", args->res, args->user_data); }
' -c './cat_uring cat.c'
```

**Warm cache output:**
```
1. CREATE: sq=1 cq=2 flags=0x0
3. SUBMIT: opcode=1 user_data=0x15f3c310
7. COMPLETE: res=11041 user_data=0x15f3c310
```

**Cold cache output (identical sequence):**
```
1. CREATE: sq=1 cq=2 flags=0x0
3. SUBMIT: opcode=1 user_data=0x66f4310
7. COMPLETE: res=11041 user_data=0x66f4310
```

**`io_uring_queue_async_work` never fired** — neither with warm nor cold cache.
**`io_uring_task_add` never fired** — no deferred task scheduling.
**`io_uring_local_work_run` never fired** — no local work queue used.

`opcode=1` = `IORING_OP_READV`. `res=11041` = 11,041 bytes read (exact size of `cat.c`). The `user_data` value is the pointer to `struct file_info` cast to `uint64_t`, returned unchanged.

---

### bpftrace — submit→complete latency

```bash
sudo bpftrace -e '
tracepoint:io_uring:io_uring_submit_req { @start[tid] = nsecs; }
tracepoint:io_uring:io_uring_complete   {
    if (@start[tid]) {
        printf("latency: %lld ns\n", nsecs - @start[tid]);
        delete(@start[tid]);
    }
}' -c './cat_uring cat.c'
```

| Cache state | Latency |
|---|---|
| Warm (page cache hot) | **3,667 ns (~3.7 µs)** |
| Cold (after drop_caches) | **131,875 ns (~132 µs)** |

Cold cache is **35.9× slower** than warm. The extra time is entirely kernel time — going through the VFS, block layer, and NVMe driver to fetch the page from storage.

---

### Surprising finding: `IORING_FEAT_NO_IOWAIT` changes the kernel path

The old expectation (documented in older io_uring resources) was:
> buffered reads on regular files → `io_uring_queue_async_work` → io-wq worker thread

**This did not happen.** Even with a cold page cache, `io_uring_queue_async_work` never fired.

The reason is `IORING_FEAT_NO_IOWAIT`, which is present in this kernel (`6.18`). This feature flag (added ~kernel 5.18) tells userspace that io_uring will no longer call `io_schedule()` to sleep when waiting for I/O — instead, buffered reads that cannot complete immediately are handled **inline in the submission thread**, blocking inside `io_uring_enter()` itself without spawning or waking any io-wq workers.

**Implication for internship research:** The io-wq worker wakeup bottleneck being studied at Inria is less relevant for pure buffered reads on modern kernels. To reliably trigger the `io_uring_queue_async_work` path today, you need:
- `O_DIRECT` reads with large enough request depth to overflow the inline path, **or**
- Operations that genuinely cannot complete inline (e.g. network sockets, `IORING_OP_ACCEPT`, certain `IORING_OP_CONNECT` calls), **or**
- Older kernel (pre-5.18) where `IORING_FEAT_NO_IOWAIT` is absent.

The workqueue bottleneck is still real for those workloads — it just does not apply to the `cat.c` example on this kernel.
