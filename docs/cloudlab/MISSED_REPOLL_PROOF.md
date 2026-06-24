# Source-level proof: the wasted poll is a `MISSED`-driven re-poll

> Claim to prove, in the kernel source, line by line:
> **Under load the peer NAPI is already scheduled, so a decrypt-completion wake does
> not start a poll — it only sets `NAPI_STATE_MISSED`. When the running poll finishes,
> `napi_complete_done` sees `MISSED`, re-schedules the NAPI, and the immediate re-poll
> finds the head still `UNCRYPTED` → a wasted poll.**
>
> Empirically confirmed already (trace build, 8 peers):
> `wasted_after_resched / wasted = 897,901 / 900,812 = 99.7 %`,
> `resched / polls = 57 %`. This document is the *why*, from the code.

## Kernel-version note (read this first)

Citations below are from the **curated tree in `linux-source/`** (`net/core/dev.c`,
`include/linux/netdevice.h`) — a recent 6.x kernel. The **DUT runs 5.15.0-177**. The
`SCHED`/`MISSED` machinery is **functionally identical** across these: it was
introduced in v4.10 (Eric Dumazet / Alexander Duyck, *"net: solve a NAPI race"*,
commit `39e6c8208d7b`) and the two decisive snippets — `napi_schedule_prep` setting
`MISSED`, and `napi_complete_done` re-scheduling on `MISSED` — are byte-for-byte the
same in 5.15. Line numbers differ between versions; the logic does not. (If we want
version-exact 5.15 line numbers, `apt-get source linux-image-$(uname -r)` on the DUT
and re-cite — the code is the same.)

The WireGuard side (`receive.c`, `queueing.h`) is the module source (reference v6.1 =
DUT 5.15, verified identical earlier).

---

## The two state bits

```c
// include/linux/netdevice.h:422-423
NAPI_STATE_SCHED,        /* Poll is scheduled */
NAPI_STATE_MISSED,       /* reschedule a napi */
```
- `SCHED` = "this NAPI is scheduled / a poll instance owns it." Only one poll runs at
  a time per NAPI.
- `MISSED` = "someone asked to schedule while a poll was already running — run the
  poll once more after it finishes." This is the bit that exists to avoid lost
  wakeups, and it is exactly what turns into our wasted re-poll.

The actors:
- **Producer**: the decrypt worker, on completion, calls `napi_schedule(&peer->napi)`
  via `wg_queue_enqueue_per_peer_rx` (`queueing.h`).
- **The poll**: `wg_packet_rx_poll` (`receive.c:438`), the NAPI `->poll` callback.
- **The softirq loop**: `net_rx_action` → `napi_poll` → `__napi_poll` → `->poll`.

---

## The sequence, phase by phase

### Phase 0 — a poll is already running ⇒ `SCHED` is set

`net_rx_action` is draining this CPU's poll list and is currently inside
`wg_packet_rx_poll` for `peer`. So `peer->napi.state` has `NAPIF_STATE_SCHED` set.
`__napi_poll` only calls `->poll` while scheduled:
```c
// net/core/dev.c:7732-7733  (in __napi_poll)
if (napi_is_scheduled(n)) {
    work = n->poll(n, weight);     /* == wg_packet_rx_poll */
```

### Phase 1 — a decrypt completes and "wakes" the NAPI ⇒ this is where `MISSED` is set

The decrypt worker finishes a packet and calls:
```c
// drivers/net/wireguard/queueing.h  (in wg_queue_enqueue_per_peer_rx;
// queueing.h:204 in the v6.1 reference — same in DUT 5.15)
napi_schedule(&peer->napi);
```
```c
// include/linux/netdevice.h:558-566
static inline bool napi_schedule(struct napi_struct *n)
{
    if (napi_schedule_prep(n)) {   /* false here: already SCHED */
        __napi_schedule(n);        /* NOT taken */
        return true;
    }
    return false;
}
```
`napi_schedule_prep` — **the exact line where `MISSED` is set**:
```c
// net/core/dev.c:6729-6749  (napi_schedule_prep)
do {
    if (unlikely(val & NAPIF_STATE_DISABLE)) return false;
    new = val | NAPIF_STATE_SCHED;
    /* Sets STATE_MISSED bit if STATE_SCHED was already set */
    new |= (val & NAPIF_STATE_SCHED) / NAPIF_STATE_SCHED *   /* dev.c:6744-6745 */
                       NAPIF_STATE_MISSED;
} while (!try_cmpxchg(&n->state, &val, new));
return !(val & NAPIF_STATE_SCHED);    /* dev.c:6748: FALSE, because SCHED was set */
```
So: because `SCHED` was already set (Phase 0), this **sets `MISSED`** (6744-6745) and
**returns false** (6748). `napi_schedule` therefore does **not** call `__napi_schedule`
— **no poll is started, the wake is a no-op that only records `MISSED`.** This is the
"state missed" you described, and it is why gating this `napi_schedule` (the M1 fix)
changes nothing: it is already a no-op.

> Many completions may land during the one poll; any that find `SCHED` set just
> re-assert `MISSED`. (This is the ~63%-no-op figure from the diag build.)

### Phase 2 — the poll stops at the uncrypted head and completes

`wg_packet_rx_poll` drains contiguous-crypted packets and stops at the first
`UNCRYPTED` head:
```c
// drivers/net/wireguard/receive.c:451-453  (in wg_packet_rx_poll)
while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&
       (state = atomic_read_acquire(&PACKET_CB(skb)->state)) !=
            PACKET_STATE_UNCRYPTED) {
    ...
}
```
Then, since `work_done < budget` almost always:
```c
// drivers/net/wireguard/receive.c:487-488  (in wg_packet_rx_poll)
if (work_done < budget)
    napi_complete_done(napi, work_done);
```

### Phase 3 — `napi_complete_done` sees `MISSED` and RE-SCHEDULES ⇒ the re-poll is born

`napi_complete_done` spans `dev.c:6771-6838`. The state cmpxchg clears the bits but
**re-arms `SCHED` if `MISSED` was set**:
```c
// net/core/dev.c:6817-6827  (in napi_complete_done)
new = val & ~(NAPIF_STATE_MISSED | NAPIF_STATE_SCHED | ...);
/* If STATE_MISSED was set, leave STATE_SCHED set,
 * because we will call napi->poll() one more time. */
new |= (val & NAPIF_STATE_MISSED) / NAPIF_STATE_MISSED *      /* dev.c:6825-6826 */
                    NAPIF_STATE_SCHED;
```
Then — **the exact re-schedule**:
```c
// net/core/dev.c:6829-6832  (in napi_complete_done)
if (unlikely(val & NAPIF_STATE_MISSED)) {
    __napi_schedule(n);     /* dev.c:6830: re-enqueue + raise softirq */
    return false;           /* dev.c:6831: "not complete" */
}
```
`wg_packet_rx_poll` ignores this `false` return — but the damage is done:
`__napi_schedule` ran.

### Phase 3b — `__napi_schedule` re-enqueues the NAPI and raises the softirq

`__napi_schedule` (`dev.c:6710-6717`) → `____napi_schedule`:
```c
// net/core/dev.c:4982-4990  (in ____napi_schedule)
use_local_napi:
    list_add_tail(&napi->poll_list, &sd->poll_list);  /* dev.c:4984: back on poll list */
    WRITE_ONCE(napi->list_owner, smp_processor_id());
    if (!sd->in_net_rx_action)
        raise_softirq_irqoff(NET_RX_SOFTIRQ);          /* dev.c:4990 */
```
So the peer NAPI is **back on this CPU's `poll_list`**, scheduled to run again.

> Note: the re-poll does **not** come through the `*repoll` path of `__napi_poll`.
> When `wg_packet_rx_poll` returns `work < weight`, `__napi_poll` returns early
> (`dev.c:7743-7744`) **without** setting `*repoll`. The re-poll exists **only**
> because `napi_complete_done` re-added the NAPI in Phase 3.

### Phase 4 — `net_rx_action` runs the re-added NAPI again, immediately

`net_rx_action` (`dev.c:7914-7973`) loops over the poll list calling `napi_poll`
(`dev.c:7952-7953`), and after the loop re-checks / re-raises so a NAPI re-added
mid-pass is processed in the **same** softirq pass or the very next one:
```c
// net/core/dev.c (in net_rx_action): re-poll of a NAPI re-added by napi_complete_done
n = list_first_entry(&list, struct napi_struct, poll_list);  // dev.c:7952
budget -= napi_poll(n, &repoll);                              // dev.c:7953
...
if (!list_empty(&sd->poll_list))        // dev.c:7944 (goto start) / dev.c:7972
    goto start;                         //   or dev.c:7972-7973 re-raise NET_RX_SOFTIRQ
```
`napi_poll` (`dev.c:7796`) → `__napi_poll` (`dev.c:7733`) → `n->poll(n, weight)` =
**`wg_packet_rx_poll` runs again** (`receive.c:438`), microseconds after Phase 2.

### Phase 5 — the re-poll finds the head still UNCRYPTED ⇒ WASTED

Back in `wg_packet_rx_poll`, the `while` head-check (`receive.c:451-453`) reads the
head state. It was `UNCRYPTED` at the end of Phase 2 and **only ~sub-µs have elapsed**,
while a decrypt takes `T_decrypt ≈ 5 µs` → it is still `UNCRYPTED`. The loop body never
executes → `work_done == 0` → `napi_complete_done` again → if another completion set
`MISSED` in the meantime, repeat.

---

## Why it is *premature* (the crux for the fix)

The re-poll is enqueued by `napi_complete_done` **at the very moment the poll just
proved the head is not ready**, and it runs within the same/next softirq pass.

> **Measured (2026-06-22, `measure_repoll_gap.sh` stock @8p):** the gap is **~1–2 µs**
> (median ≈ 1.6 µs), not sub-µs as first asserted. Against `T_decrypt ≈ 5 µs` the
> re-poll is therefore **~3× too early** — early enough that it's a *coin flip*
> (~49% wasted at the dominant gap), not "almost always wasted." The useful fraction
> climbs with the gap (49% at ~1.5 µs → 67% at 2–4 µs → ~72% by 8–16 µs), so the head's
> decrypt simply hasn't finished yet: at poll-end its *remaining* time is spread over
> ~[0, 5 µs] and the re-poll at ~1.6 µs catches only about half. See
> `CLOUDLAB_EXPERIMENTS_LOG.md` (2026-06-22) and `TRIGGER_DESIGN.md` §2.

The conclusion stands, with the corrected magnitude: the `MISSED` re-poll is
**structurally too early** — it fires at ~one-third of a decrypt time — and the fix is
to defer it by ~one `T_decrypt` so the head can finish.

- This is independent of the producer-side wake decision: `MISSED` is set by *any*
  completion landing during the poll, and the bit, not the wake, drives the re-poll.
- It is therefore unfixable at `napi_schedule` (Phase 1, already a no-op). The lever is
  Phase 3 / Phase 2: **decide at poll completion whether the re-poll is worth running**,
  using the authoritative head state read inside the poll — and if the head is
  `UNCRYPTED`, defer the re-poll by ~`T_decrypt` instead of letting `MISSED` fire it now.

## Map: empirical ↔ source

| measured | source mechanism |
|----------|------------------|
| `resched` = 57% of polls (`napi_complete_done` returned false) | `dev.c:6829-6831` MISSED branch taken |
| `napi_schedule` ~63% no-op (diag) | `dev.c:6748` returns false when `SCHED` set |
| `wasted_after_resched / wasted = 99.7%` | re-poll from Phase 3 finds UNCRYPTED head (Phase 5) |
| 44% of reschedules productive | head *did* crypt in the gap → poll delivers (keep these) |

## Exact citations (curated 6.x tree; 5.15 identical in logic)

| step | symbol | file:line |
|------|--------|-----------|
| state bits | `NAPI_STATE_SCHED` / `_MISSED` | `netdevice.h:422-423` |
| wake (inline) | `napi_schedule` | `netdevice.h:558-566` |
| **MISSED set** | `napi_schedule_prep` | `dev.c:6744-6745`, ret `6748` |
| enqueue+raise | `____napi_schedule` | `dev.c:4984`, `4990` |
| poll head-check | `wg_packet_rx_poll` | `receive.c:451-453` |
| poll completes | `napi_complete_done` call | `receive.c:487-488` |
| **MISSED re-arm SCHED** | `napi_complete_done` | `dev.c:6825-6826` |
| **MISSED re-schedule** | `napi_complete_done` | `dev.c:6829-6831` |
| re-poll early-return (no *repoll) | `__napi_poll` | `dev.c:7743-7744` |
| softirq loop / re-raise | `net_rx_action` | `dev.c:7952-7953`, `7944`, `7972-7973` |
