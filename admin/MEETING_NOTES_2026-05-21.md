# Meeting Notes — May 21, 2026
# Alain Tchana + André Freyssinet

---

## Outcome

The EoI chain was explained and understood. Alain and André were convinced that the problem is real and the route is promising. The discussion went deep into source code and revealed several gaps in the current understanding that need to be resolved before a solution can be proposed seriously.

**The paper's solution was analyzed and found insufficient.** A new preliminary solution was proposed by André.

**Next hard deadline: June 6 (report), June 8 (slides), June 9–12 (defenses).**

---

## What was confirmed

- The EoI chain is real and traceable at source level
- The problem is structurally caused by GRO being scheduled as a softirq on the same CPU as the decrypt worker
- This is a promising research direction worth continuing past the defense (until end of July)

---

## Open questions — must investigate before proposing a solution

These are the gaps identified during the meeting. Each one needs a dedicated source code investigation.

### 1. How does parallelism work in the decrypt pipeline exactly?

The decrypt workqueue (`packet_crypt_wq`) is `WQ_PERCPU` — one worker per CPU. But the question is: **how are packets from the same peer, or the same TCP flow, distributed across CPUs?**

- Is it possible that two packets from the same peer end up being decrypted simultaneously on two different CPUs?
- If yes, their relative order in the per-peer RX queue is determined by whichever worker finishes first — which is non-deterministic
- This is directly relevant to GRO: if packets from the same TCP flow are decrypted out-of-order on different cores, GRO cannot reassemble them until the ordering constraint is satisfied
- Need to trace exactly how packets enter `packet_crypt_wq` — which CPU gets which packet, and what determines that assignment

**Files to read:** `queueing.c` (the `wg_packet_percpu_multicore_worker_alloc` and enqueue path), `receive.c` (Stage 1 UDP handler — how packets are pushed into the global ring)

### 2. Is the `napi_struct` per-peer or per-packet?

Currently documented as per-peer. But the question is: **when multiple packets from the same peer are decrypted in parallel on different CPUs, how many NAPI instances are involved?**

- Each peer has one `napi_struct` (confirmed at `peer.c:57`)
- Each decrypt worker calls `napi_schedule(&peer->napi)` after its packet
- `NAPI_STATE_SCHED` prevents double-scheduling — only the first call wins, the rest are no-ops
- So GRO fires at most once per peer at a time, but may be triggered by any of the N CPUs working on that peer's packets
- This means GRO is bound to whichever CPU happened to finish a packet first — not necessarily the one with the most progress

**Need to clearly document this race and its consequences for the ordering constraint.**

### 3. When exactly is GRO called in relation to each packet?

This needs to be nailed down at source level with exact line numbers. The current understanding is:

- `wg_queue_enqueue_per_peer_rx` calls `napi_schedule` after every single packet (`queueing.h:196`)
- `napi_schedule` raises `NET_RX_SOFTIRQ`
- The softirq fires at the next `spin_unlock_bh` inside `ptr_ring_consume_bh` (next iteration)
- `wg_packet_rx_poll` is called — this is WireGuard's GRO poll function

But is GRO truly called after **every** decrypted packet, or is there a batching mechanism that groups multiple packets before triggering? This needs verification in the source.

**Files to read:** `receive.c` — `wg_packet_rx_poll` full implementation, especially `napi_gro_receive` call sites

### 4. What is `skb` — individual packet or aggregate?

`skb` (`struct sk_buff`) in the Linux kernel represents a **single network packet** — not an aggregate. It is a fixed-size header with pointers to the packet's data buffers.

However, WireGuard uses `skb_list_walk_safe` in the encrypt path, which means the TX side chains multiple skbs into a linked list for batching. On the RX side, each skb corresponds to one UDP datagram received — one WireGuard data message — which after decryption becomes one inner IP packet.

**Need to confirm:** does `ptr_ring_consume_bh` in the decrypt worker always return a single skb, or can it return a chain? Check `receive.c:496-501`.

### 5. GRO — software (kernel) vs hardware offload

There are two levels of GRO:
- **Software GRO** (kernel, `napi_gro_receive` in `net/core/gro.c`) — done by the CPU in `wg_packet_rx_poll`
- **Hardware GRO** — some NICs can merge packets in hardware before the CPU ever sees them

WireGuard uses **software GRO only** — it explicitly calls `napi_gro_receive` from `wg_packet_rx_poll`. The NIC hardware GRO (if the physical NIC supports it) operates on the outer UDP packets before Stage 1 even runs — but that is a different layer.

**Need to confirm:** does WireGuard's GRO interact with the hardware GRO path, or are they completely independent? What does `napi_gro_receive` do exactly with a WireGuard inner IP packet?

**Files to read:** `receive.c` — `wg_packet_rx_poll`, specifically the `napi_gro_receive` call and what precedes it

---

## Analysis of the paper's solution

### What the paper proposes

Replace `napi_schedule(&peer->napi)` with `queue_work_on(cpu, gro_wq, &peer->rx_work)` — moving GRO execution from softirq context to a workqueue at `SCHED_NORMAL`.

### Why this is insufficient (conclusion from the meeting)

**The paper's fix reduces overhead but does not eliminate the root cause.**

The ordering constraint in `wg_packet_rx_poll` (`receive.c:451`) is unchanged: GRO still walks from the queue head and stops at the first UNCRYPTED packet. Moving GRO to a workqueue changes *when* and *at what priority* GRO runs — but it does not change *what GRO finds when it runs*.

**Important correction on the preemption framing:** it is not accurate to say GRO preempts decryption mid-work. Decryption of a packet always completes fully before GRO can run. The real problem is different: WireGuard schedules GRO after *every single packet decryption*, regardless of whether the packets needed for in-order assembly are actually ready. This is the fundamental design question — why trigger GRO after every packet? Why not wait until all packets from that peer's current batch are decrypted, or at minimum check that the head is ready before triggering at all?

Under concurrent decryption, the per-peer RX queue frequently has a gap — the head is UNCRYPTED while packets further back are CRYPTED. GRO is invoked by the worker that just finished packet N, but packet N may not be at the head. GRO walks from the head, hits the UNCRYPTED gap, and exits with nothing done. The CPU cycle is wasted — not because decryption was interrupted, but because GRO was invoked unconditionally when it had no chance of making progress.

The paper's fix changes the scheduling mechanism but not the trigger logic: GRO is still scheduled after every packet, it just runs at `SCHED_NORMAL` instead of as a high-priority softirq. This reduces *overhead per wasted call* but does not reduce the *number of wasted calls*. The throughput gain (4.7×) likely comes from eliminating the softirq preemption cost, not from fixing the logical ordering problem. This also explains why the paper does not analyze latency impact from their fix — it is possible latency did not improve meaningfully.

**We do not know which workqueue the paper used for GRO** — the paper does not provide implementation code. The three existing workqueues in `device.c` are `packet_crypt_wq`, `handshake_receive_wq`, and `handshake_send_wq`. The paper likely added a fourth dedicated one. This needs to be reproduced experimentally.

---

## André's proposed solution (preliminary implementation target)

**High-level idea:** instead of triggering GRO unconditionally after every decrypted packet, add a conditional check — only schedule GRO when it has a real chance of making progress. This eliminates structurally wasted GRO invocations.

**From the meeting transcript (André):**
> "Dans le work de décrypt, avant de déclencher le processus, il faut vérifier si le paquet a déjà été décrypté. Si ce n'est pas le cas, on lance le traitement. Ainsi, le dernier paquet décrypté de la série déclenche l'action suivante."

Translation: in the decrypt work item, before triggering GRO, check whether the preceding packet has already been decrypted. If not, skip. The last packet decrypted in a sequence (the one that completes a contiguous run from the head) is the one that should trigger GRO.

**Open questions about the exact condition — not yet resolved:**

1. **Checking just the head is not sufficient.** If the head of the per-peer RX queue is CRYPTED, that means GRO can process it. But what about the packet that just got decrypted (packet N) — it may not be at the head. There could be a gap of UNCRYPTED packets between the head and packet N, meaning GRO would process some packets from the head and then stop at the gap, not reaching packet N anyway. Checking only the head tells us GRO can start but not how far it can go.

2. **What does GRO actually do when it runs?** This is still not fully understood at source level. The question is: when `wg_packet_rx_poll` is called, does it walk the entire queue from the head until it hits an UNCRYPTED packet, delivering all CRYPTED packets it encounters along the way? Or does it deliver only specific packets? If it walks and delivers everything up to the first gap, then the correct trigger condition is: "the packet I just decrypted is adjacent to the head, or the head is now CRYPTED and I am the one who made it reachable." This needs to be confirmed in `receive.c:438–490`.

3. **What is the right check exactly?** André's intent from the transcript is: check whether the packet *preceding* packet N in the queue has already been decrypted. If the predecessor is CRYPTED (or N itself is the head), then decrypting N creates a new contiguous run from the head — GRO can now make progress. If the predecessor is still UNCRYPTED, GRO cannot reach packet N anyway, so skip the trigger.

**Rough sketch of the condition (pending source verification):**

```
After marking packet N as CRYPTED:
  → check the state of the packet just before N in peer->rx_queue
  → if that predecessor is CRYPTED (or N is the head): schedule GRO
  → if that predecessor is UNCRYPTED: skip napi_schedule entirely
```

This is closer to André's intent than a simple head check — it captures the idea that the *last packet in a contiguous run* is the one that should trigger GRO.

**Also mentioned:** it may be possible to give the GRO work item a higher scheduling priority than the decrypt worker. This is a separate orthogonal improvement — once the conditional check avoids unnecessary triggers, priority tuning could further reduce latency for the cases where GRO does run.

**Implementation location:** `queueing.h` — `wg_queue_enqueue_per_peer_rx`, between `atomic_set_release` (line 195) and `napi_schedule` (line 196). Access to the per-peer queue and the predecessor packet's state is available through `peer->rx_queue` and `wg_prev_queue_peek`.

**Prerequisite:** fully understand what `wg_packet_rx_poll` does at source level before finalizing the condition. The trigger logic must match exactly what GRO needs to make progress.

---

## Plan until June 6

### Phase 1 — Fill the knowledge gaps (this week)

| # | Task | Files |
|---|---|---|
| 1 | Document exactly how packets are distributed across CPUs — trace the enqueue path from Stage 1 to `packet_crypt_wq` | `receive.c` (Stage 1), `queueing.c`, `queueing.h` |
| 2 | Confirm skb is per-packet on RX side, not a chain | `receive.c:496–501` |
| 3 | Trace `wg_packet_rx_poll` fully — what `napi_gro_receive` does and when GRO is triggered | `receive.c:438–490` |
| 4 | Clarify software vs hardware GRO interaction | `net/core/gro.c`, `receive.c` |
| 5 | Document the NAPI per-peer race under concurrent decryption | `queueing.h:188–197`, `net/core/dev.c` |

### Phase 2 — Reproduce the paper's solution (this week / early next week)

| # | Task |
|---|---|
| 1 | Identify which workqueue the paper likely used (or create a new dedicated `gro_wq`) |
| 2 | Move `napi_schedule` → `queue_work_on` in `queueing.h` or `receive.c` |
| 3 | Measure throughput and latency on the test environment |
| 4 | Compare with baseline — confirm the paper's 4.7× result or document the difference |

### Phase 3 — Implement André's conditional check (next week)

| # | Task |
|---|---|
| 1 | Add head-readiness check in `wg_queue_enqueue_per_peer_rx` before `napi_schedule` |
| 2 | Test for correctness — no packets dropped, ordering preserved |
| 3 | Measure throughput and latency |
| 4 | Compare with paper's solution and baseline |

### Phase 4 — Write the report (by June 5, noon)

Structure:
1. Problem statement — EoI chain (source code walk-through, condensed)
2. Current state — confirmed bug, source-level evidence
3. Paper's solution — what it does, why it is incomplete
4. Proposed solution — André's conditional check, rationale
5. Experimental results — baseline vs paper's fix vs André's fix
6. Conclusion and open questions for future work (end of July)

---

## Deadlines

| Date | Deliverable |
|---|---|
| **June 5, noon** | Final report (6 pages) |
| **June 8** | Defense slides |
| **June 9–12** | Defenses |
| **End of July** | Full solution + deeper analysis |

---

## Raw transcript excerpt (end of meeting)

> "Si c'est le tien, si c'est celui lié à WireGuard, tu sais que tu ne dois pas le traiter comme les autres. Tu crées un work, tu fais le Q‑Work. Tu peux en créer plusieurs. Soit tu mets le work déjà présent, tu fais l'expérimentation en voie, puis tu peux dire « ok » et le placer dans une autre work, en lui donnant une priorité beaucoup plus forte. On se demande s'il est possible d'optimiser un peu plus, toujours dans le décryptage, dans l'ORC du décrypt. Je ne sais pas quel accès on a au paquet précédent, mais dans le work de décrypt, avant de déclencher le processus, il faut vérifier si le paquet a déjà été décrypté. Si ce n'est pas le cas, on lance le traitement. Ainsi, le dernier paquet décrypté de la série déclenche l'action suivante."

> "Il faut se poser la question du timing. Tu m'as dit que la soutenance était le 6 juin, puis le 8 juin, et que le rapport doit être rendu le 6 juin. La question est : implémente‑t‑il directement cette solution ? Que pouvons‑nous faire d'ici le 6 juin ? Peut‑être suivons‑nous tes recommandations pour avoir quelque chose à inclure dans le rapport. Il continuera ensuite, et nous évaluerons les résultats avant le 6 juin. Tu pourras les présenter dans le rapport. Après cela, il faut viser la fin juillet, ce qui nous laisse environ deux mois."

> "Résoudre le problème fondamentalement est possible, mais je ne sais pas si nous aurons le temps d'analyser correctement. Nous commençons à avoir une vue d'ensemble, mais il faut, d'ici le 6 juin, préparer une présentation du problème. Sinon, les membres du jury ne poseront pas les bonnes questions et ne comprendront pas. Il faut donc une présentation plus fluide et compréhensible. Explique clairement le problème, montre l'état actuel, indique les limites et pourquoi la solution proposée n'est pas optimale. Propose d'implémenter la solution d'André tout en expliquant les raisons."
