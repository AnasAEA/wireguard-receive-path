# Scientific guardrails

## Endpoint hierarchy

1. Gate A throughput and total busy CPU are co-primary endpoints.
2. Gate A throughput per busy CE is secondary and derived.
3. Gate A composition contrasts are secondary and multiplicity-adjusted.
4. Gate B `steal4-off` total busy CPU is the primary endpoint.
5. Gate B softirq, per-core results, and module counters are descriptive.

## Required wording

- “We detect a throughput/CPU effect” only for Gate A's declared co-primaries.
- “No favorable effect was detected at the tested matched load” for Gate B.
- Gate B was favorable in **3/8** paired blocks, not five: lower CPU is the
  favorable direction.
- The Gate B CI95 `[-0.245,+0.134] CE` spans both benefit and cost.
- “This pattern is consistent with...” for cross-regime interpretation.
- “The experiment does not establish...” for interaction, causality,
  equivalence, latency, and production-safety limitations.
- “Descriptive mechanism counters show...” for classifier and pull counts.

## Prohibited inferences

- Gate B is not proof of zero effect.
- The Gate B confidence interval does not establish equivalence.
- The two regimes do not constitute a formal saturation-by-treatment
  interaction test.
- Saturation is not established as the cause of the different estimates.
- The data do not establish that benefit exists only at saturation.
- Wake fixes are not proven redundant.
- Non-detection of an incremental combined-treatment effect is not
  equivalence.
- Module counters are not inferential endpoints.
- Classified blocked duration is not end-to-end packet latency.
- The withdrawn Sockperf smoke supports no latency result.
- No user-visible latency claim is allowed.
- Same-instantiation paired confirmation is not independent fresh-node
  replication.
- Absence of relevant dmesg records is not proof of production safety.
- The implementation must be described as a research prototype.

## Mechanism wording

- The current NAPI/softirq CPU performs stolen decryption synchronously.
- Jobs come from the device-wide decrypt `ptr_ring`.
- A stolen job need not belong to the blocked peer.
- `ptr_ring_consume_bh` transfers exclusive ownership under the ring's
  consumer lock.
- A worker and NAPI cannot consume the same ring element.
- Completion reuses `wg_queue_enqueue_per_peer_rx`.
- Delivery still advances through the per-peer ordered queue.
- `wg_steal` does not bypass ordering.
- `wg_steal=4` bounds successful consumes in one steal pass.
- Fewer than four jobs may be consumed.
- Four is not a CPU or thread count.
- Four is not necessarily a complete-poll limit.
- One poll can enter multiple steal passes and pull more than four jobs total.
- Stolen crypto time is not charged to NAPI `work_done`.
- The bounded pass mitigates but does not eliminate softirq-duration and
  fairness risk.

## Numbers that must remain synchronized

### Gate A

- Throughput: +1.96%, exact p=0.0103, favorable 9/12.
- Total busy CPU: -3.66%, exact p=0.000488, favorable 12/12.
- Efficiency: +5.83%, exact p=0.000488, favorable 12/12; secondary derived.

### Gate B

- Delivered load: 3.8012--3.8027 Gb/s.
- Maximum target deviation: 0.071%.
- Worst required paired mismatch: 0.0316%.
- Total CPU: -0.047 CE (-1.17%), CI95 [-0.245,+0.134] CE, exact p=0.6562,
  favorable 3/8.
- Classified episodes: approximately 743,942 off and 10,021 steal4/window,
  about 98.7% lower.
- Pulls: approximately 2.32 million jobs/window.

## Forbidden phrases

- “proved null”
- “no effect exists”
- “equivalent”
- “wake fixes are redundant”
- “saturation caused the benefit”
- “benefit exists only at saturation”
- “latency improved”
- “production-safe”
- “four jobs per complete poll”
- “four decryption cores”
