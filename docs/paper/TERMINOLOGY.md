# Terminology

**RX/NAPI context**  
The softirq execution context running a peer's `wg_packet_rx_poll` callback.
It is the single consumer that advances that peer's ordered receive queue.

**Receive poll**  
One invocation of `wg_packet_rx_poll` with a delivery budget. A poll can
deliver terminal-state packets, stop at an incomplete head, and complete or be
rescheduled.

**Decrypt worker**  
A normal per-CPU `wg-crypt-*` workqueue worker that consumes SKBs from the
device decrypt ring, decrypts them, and publishes completion.

**Device-wide decrypt ring**  
The `ptr_ring` in `wg_device.decrypt_queue`. It contains pending decrypt jobs
for the whole WireGuard device and is shared by normal workers and `wg_steal`.

**Per-peer ordered queue**  
The `prev_queue` that records a peer's packets in arrival order. Parallel
decryption does not reorder this queue.

**Ordered head**  
The next SKB that the peer's receive poll is allowed to remove and deliver.
Later completed packets cannot pass it.

**Execution-order inversion**  
A mismatch between parallel completion order and required delivery order: a
later job completes before the ordered prerequisite, leaving the delivery
consumer unable to advance.

**Head blocking**  
An interval in which the receive poll reaches an ordered head whose state is
still `UNCRYPTED`.

**Steal pass**  
One entry into the `wg_steal` loop after a poll finds an `UNCRYPTED` head.
The pass ends when the configured number of jobs has been consumed, the head
becomes terminal, or no ring job is available.

**Steal budget**  
The maximum number of successful device-ring consumes in one steal pass. It is
not a CPU count, thread count, guaranteed batch size, or necessarily a
full-poll limit.

**Core-equivalent (CE)**  
Average CPU occupancy over a measurement window. One CE means that one CPU
core was busy continuously for the full window; four CE can mean four
continuously busy cores or equivalent aggregate occupancy.

**Matched load**  
A comparison in which delivered bytes over the exact measurement window are
constrained to the same target and checked both absolutely and within paired
blocks.

**Saturated uncapped regime**  
The single-tunnel experiment without an application rate cap, where throughput
is limited by the receive path and RX/softirq consumption is near one CE.

**Descriptive mechanism evidence**  
Counters, durations, or distributions that show how an implementation path
behaved but were not declared or tested as inferential endpoints.

**Non-detection**  
An experiment whose test did not detect an effect in the favorable direction.
It is not proof of zero, absence, or equivalence; interpretation must include
the estimate and confidence interval.
