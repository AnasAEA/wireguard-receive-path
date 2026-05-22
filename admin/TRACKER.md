# Internship Tracker
# Last updated: May 22, 2026

---

## Hard deadlines

| Date | Deliverable |
|---|---|
| **June 5, noon** | Final report (6 pages) |
| **June 8** | Defense slides |
| **June 9–12** | Defenses |
| **End of July** | Full solution + deeper analysis (post-defense continuation) |

---

## Overall status

| Phase | Status | Notes |
|---|---|---|
| EoI proof — source walk-through | ✅ DONE | Presented May 21, Alain + André convinced |
| Knowledge gaps — pipeline internals | ✅ DONE | Documented in CODE_STUDY_PART2.md |
| Solution design — André's conditional check | ✅ DONE | Verified, diff ready, proposal document written |
| Pipeline diagrams | 🟡 IN PROGRESS | Generating today from PIPELINE_SKETCH_GUIDE.md |
| Kernel patch — compile and test | ⬜ TODO | Apply diff to linux-source, build WireGuard module |
| Baseline measurement | ⬜ TODO | Run throughput + latency before patch |
| Patched measurement | ⬜ TODO | Run throughput + latency after patch |
| Paper solution reproduction | ⬜ TODO | Move napi_schedule → queue_work_on, measure |
| Final report | ⬜ TODO | Due June 5 noon |
| Defense slides | ⬜ TODO | Due June 8 |

---

## What is done (as of May 22)

### Source analysis
- Full EoI chain traced: `peer.c:57` → `device.c:346` → `receive.c:493` → `ptr_ring.h:371` → `queueing.h:196` → `dev.c:4957` → `ptr_ring.h:371` (fires) → `receive.c:451` (finds nothing)
- `wg_packet_rx_poll` behavior confirmed: flushes full contiguous run per call, DEAD packets consumed (not blocking), budget = 64, `napi_complete_done` called only when work_done < budget
- Queue structure confirmed: `queue->tail` consumer-only write, `peeked` independent, STUB = `&queue->empty`
- Packet distribution confirmed: round-robin via `wg_cpumask_next_online`, same-peer packets decrypted concurrently on different CPUs
- Paper's solution analyzed: reduces overhead, does not eliminate root cause (ordering constraint unchanged)

### Solution design
- André's condition verified: check `READ_ONCE(peer->rx_queue.tail)` state before `napi_schedule`
- Diff written and verified (`admin/ANDRE_SOLUTION_PROPOSAL.md`)
- Probabilistic argument added: 87.5% wasted calls on 8 cores, head packet systematic disadvantage
- Residual limitation documented: narrow timing gap after mid-queue GRO delivery

### Documents produced
- `admin/PRESENTATION_EOI_PROOF.md` — 9-step source walk-through (used May 21)
- `admin/SPEAKER_NOTES_FR.md` — French speaker notes + definitions appendix
- `admin/SPEAKER_NOTES_EN.md` — English speaker notes
- `admin/MEETING_NOTES_2026-05-21.md` — full meeting outcome + updated plan
- `CODE_STUDY_PART2.md` — Block 1–4 source investigation, four cases, solution
- `admin/ANDRE_SOLUTION_PROPOSAL.md` — full proposal for André (diff + reasoning + limitations)
- `admin/PIPELINE_SKETCH_GUIDE.md` — 7-diagram sketch guide for visual figures

---

## Today's plan — May 22

### Block 1 — Finish diagrams (morning, currently in progress)
Generate the 7 diagrams from `PIPELINE_SKETCH_GUIDE.md`. Priority order:
1. Diagram 1 — top-level 3-stage pipeline (most important for report)
2. Diagram 4 — EoI cycle detail (second most important)
3. Diagram 5 — the fix, before/after
4. Diagrams 2, 3, 6, 7 — supporting diagrams if time allows

### Block 2 — Apply the patch to the source tree (afternoon)
Apply the diff from `ANDRE_SOLUTION_PROPOSAL.md` to `linux-source/drivers/net/wireguard/queueing.h`. Confirm it compiles cleanly.

Steps:
1. Apply the 6-line diff to `queueing.h:188–198`
2. Build the WireGuard kernel module: `make -C linux-source M=drivers/net/wireguard`
3. Fix any compilation errors
4. Confirm no warnings on the modified function

### Block 3 — Set up the measurement environment (afternoon/evening)
Before measuring anything, establish the baseline:
1. Confirm `bpftrace` and `perf` are available on the test machine
2. Identify the right tracepoints: `workqueue_execute_start`, `napi_poll`, `net:napi_poll`
3. Run a simple WireGuard throughput test with `iperf3` to confirm the test setup works
4. Record baseline: throughput (Gbps) and latency (p50, p99) without any patch

---

## Remaining open questions

| Question | Priority | Status |
|---|---|---|
| Does the patch compile cleanly? | HIGH | ⬜ Not yet attempted |
| Does the patch preserve correctness (no dropped packets)? | HIGH | ⬜ Needs test |
| What is the baseline throughput/latency on this machine? | HIGH | ⬜ Not yet measured |
| What is the throughput/latency improvement with the patch? | HIGH | ⬜ Not yet measured |
| What workqueue did the paper use for GRO? | MEDIUM | ⬜ Unknown — paper has no code |
| Can we reproduce the paper's 4.7× result? | MEDIUM | ⬜ Deferred to next week |
| Does the residual gap latency spike matter in practice? | LOW | ⬜ Will appear in measurements |
