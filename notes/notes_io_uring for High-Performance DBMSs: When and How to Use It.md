## Notes on "io_uring for High-Performance DBMSs: When and How to Use It" research paper

### Overview
- they studied how modern database systems can leverage the linux io_uring interface to improve I/O performance.
- io_uring is a new asynchronous I/O interface in Linux that provides better performance and lower latency compared to traditional I/O interfaces like aio and epoll.
### Evaluation
- they evaluate it in two use cases:
  - Integrating io_uring into a storage base -bound buffer manager, this focuses on how to use io_uring to efficiently read and write data pages from/to disk.
  - Using io_uring for high-throughput data shuffling (e.g., during joins or aggregations), this means using io_uring to move data between different parts of the system efficiently. 
- they further analyze how advanced io_uring features , such as registered buffers (which allow pre-registering memory regions for I/O operations) and passthrough I/O (which allows direct I/O operations bypassing the kernel), affect end-to-end performance.
- they show when low-level optimizations translate into tangible system-wide gains and how architechtural choices influence these benefits.
- they derive practical guidelines for designing I/O-intensive systems using io-uring and validate their effectiveness in a case study of PostgreSQL's recent io_uring integration (PG18).
- io_uring in PostgreSQL 18
The io_uring method uses Linux's io_uring interface, which requires kernel version 5.1 or later and PostgreSQL built with --with-liburing support. This method creates shared ring buffers between PostgreSQL and the kernel, reducing system call overhead and typically providing the best performance
- applying their guidelines yields a performance of 14%.
---
### Key Findings
#### Challenges of user-space I/O
- frameworks such as DPDK and SPDK and RDMA (Remote Direct Memory Access) , bypass the kernel to achieve high performance, but they require significant changes to the system architecture and are not suitable for all workloads, they also reqquire exclusive control of SSDs or NICs (because they bypass the kernel).
- io_uring provides a middle ground by allowing asynchronous I/O operations while still leveraging the kernel's capabilities.
##### Deatils on DPDK, SPDK, RDMA
- DPDK (Data Plane Development Kit) is a set of libraries and drivers for fast packet processing (networking) in user space, bypassing the kernel's networking stack to achieve high performance.
- SPDK (Storage Performance Development Kit) is a set of tools and libraries for high-performance storage applications, allowing direct access to NVMe SSDs and other storage devices from user space, bypassing the kernel.
- RDMA (Remote Direct Memory Access) is a technology that allows direct memory access from the memory of one computer into that of another without involving either one's operating system, enabling high-throughput and low-latency networking.
#### Benefits of io_uring
- It combines three key features distinguishing it from earlier kernel I/O interfaces:
  - unified interface integreates storage , network and other I/O types (e.g., timers, signals) under a single API.
  - Secondly, fully asynchronous operations allow applications to perform useful work while waiting for I/O operations to complete.
  - Thirdly, batched submission and completion process multiple operations with a single system call, reducing overhead.
  - these features make io_uring particularly well-suited for high-performance database systems that issue large numbers of storage and network I/O operations.
#### Low Overhread I/O with io_uring ?
- they compare the performance of io_uring off the shelf instead of libaio for storage I/O in a buffer manager, or instead of epoll for network I/O in a data shuffling operator.
- only modest performance improvements are observed when simply replacing existing I/O interfaces with io_uring. (1.06x and 1.10 times faster, respectively).
- In contrast , when the system is explicitly designed to leverage io_uring's capabilities (e.g., batching I/O operations) and using appropriate optimizations (e.g., registered buffers), the end to end performance become:  2.05x  for the buffer manager and 2.31x for the network shuffling operator. 
### Questions the paper tries to answer
- When to use io_uring? Under which system conditions - especially high I/O intensive scenarios - does io_uring provide the greatest benefit?
- How to integrate io_uring? How should a DBMS architecture incorporate io_uring to exploit its capabilities effectively?
- How to tune io_uring? Which io_uring features and optimizations yield the best performance for different DBMS components and workloads?