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

Under concurrent decryption, the head is still frequently UNCRYPTED when GRO executes. The difference is:
- **Before the fix:** GRO preempts the decrypt worker at high priority (softirq), wasting CPU immediately
- **After the fix:** GRO runs at `SCHED_NORMAL`, so the decrypt worker can finish its packet before GRO gets a time slice — reducing the *frequency* of wasted GRO calls, but not eliminating them

The throughput gain (4.7×) is real but comes from removing the high-priority preemption overhead, not from fixing the logical ordering problem. This also explains why the paper does not analyze latency results from their fix — likely because latency did not improve as expected (GRO still fires without guaranteeing readiness, but now at lower frequency).

**We do not know which workqueue the paper used for GRO** — the paper does not provide implementation code. The three existing workqueues in `device.c` are `packet_crypt_wq`, `handshake_receive_wq`, and `handshake_send_wq`. The paper likely added a fourth dedicated one. This needs to be reproduced experimentally.

---

## André's proposed solution (preliminary implementation target)

**Idea:** add a conditional check inside the GRO trigger — before calling `napi_schedule`, verify that the head of the peer's RX queue is CRYPTED (i.e., assembly is possible). If the head is still UNCRYPTED, do not schedule GRO at all.

**In the decrypt worker loop, the logic would be:**

```
After decrypting packet N and marking it CRYPTED:
  → peek at the head of peer->rx_queue
  → if head is CRYPTED: schedule GRO (it will find work to do)
  → if head is UNCRYPTED: do NOT schedule GRO (it would waste a cycle)
```

**Why this makes sense:** the only case where GRO can make progress is when the head of the ordered queue is CRYPTED. Calling GRO in any other state is guaranteed to be a wasted cycle. This check costs almost nothing (an atomic read of the head's state) and eliminates all structurally wasted GRO invocations.

**From the meeting transcript (André):**
> "Dans le work de décrypt, avant de déclencher le processus, il faut vérifier si le paquet a déjà été décrypté. Si ce n'est pas le cas, on lance le traitement. Ainsi, le dernier paquet décrypté de la série déclenche l'action suivante."

Translation: in the decrypt work item, before triggering GRO, check whether the preceding packet has already been decrypted. If not, skip GRO. The last packet decrypted in a series (the one that makes the head ready) is the one that triggers GRO.

**Also mentioned:** it may be possible to assign a higher priority to the GRO work item than the decrypt worker, which combined with the conditional check could further improve scheduling behavior.

**Implementation location:** `queueing.h` — `wg_queue_enqueue_per_peer_rx`, specifically between `atomic_set_release` (line 195) and `napi_schedule` (line 196). Or alternatively inside `wg_packet_rx_poll` if the check needs access to the full queue state.

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
