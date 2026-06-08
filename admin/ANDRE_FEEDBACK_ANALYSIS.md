# André's feedback — analysis and responses

12 comments from the annotated PDF. For each: what he's saying, whether he's right,
and what to do.

---

## C1 — Abstract: "référence ?"
**Location:** Abstract, sentence "Prior work traced this to an Execution Order Inversion
(EoI): concurrent decryption triggers GRO reassembly so frequently that the CPU saturates."

**What he's saying:** The claim that prior work identified the EoI has no citation at
that exact point in the abstract.

**Is he right?** Yes. Mounah 2025 is cited later in the intro but not here in the abstract.
Abstracts in the IJCAI style don't usually carry citations, but the floating reference to
"prior work" without a name or number is ambiguous.

**Fix:** Add `\cite{mounah2025}` inline: "Prior work~\cite{mounah2025} traced this to an
Execution Order Inversion..." — or rewrite to name the authors: "Mounah et al. (SYSTOR 2025)
traced this..."

---

## C2 — §2.3: "C'est hors-sujet ici, mais il y a des workqueues avec des workers en haute-priorité"
**Location:** §2.3 opening sentence "Workqueues defer work to normal-priority background threads."

**What he's saying:** The statement that workqueues run at normal priority is a simplification.
Linux has `WQ_HIGHPRI` workqueues whose workers run at higher priority. He's flagging this
as technically incomplete (while acknowledging it's off-topic here).

**Is he right?** Technically yes. `WQ_HIGHPRI` exists and creates high-priority workers. But
for WireGuard's decrypt workqueue (`WQ_PERCPU`), normal priority is correct. The sentence
is an oversimplification of the general mechanism.

**Fix:** Add a qualifier: "Workqueues defer work to background kernel threads. By default these
run at normal scheduler priority (`SCHED_NORMAL`); WireGuard's decrypt workqueue uses this
default." This both acknowledges the simplification and stays accurate for our case.

---

## C3 — §2.3: "La relation de cause à effet ne me paraît pas évidente"
**Location:** "Workers run at SCHED_NORMAL and can be preempted by softirqs at any BH
re-enable point, **which is why decryption cannot run in the softirq directly**."

**What he's saying:** The causal link between "workers can be preempted by softirqs" and
"decryption cannot run in the softirq" is not clear to him. These are two different
constraints — the reason decryption can't run in the softirq is that it takes too long
and would block other bottom-half work, not because of preemption.

**Is he right?** Yes, he's right. The sentence conflates two separate things:
- Softirqs cannot sleep or take long — that's why decryption can't run there.
- Workers can be preempted by softirqs — that's a separate (related but different) fact.

The "which is why" is logically wrong. The real reason is: softirqs must be short and
cannot sleep; ChaCha20 decryption is heavy; therefore decryption must go to a workqueue.
The preemption point is a consequence of how Linux BH locking works, not the cause.

**Fix:** Split the sentence. Remove the causal "which is why" and state both facts
independently:
"Workers run at SCHED_NORMAL. The softirq context, by contrast, cannot sleep and must
complete quickly, which rules out running ChaCha20 decryption there — hence the delegation
to the workqueue."

---

## C4 — §2.1: "list ?"
**Location:** The bullet list introducing the two queues ("The per-peer RX queue...
The global device ring...").

**What he's saying:** He's questioning the use of a bullet list here. His note is terse —
he may be saying it reads awkwardly as a list (maybe prose would flow better), or he may
be unsure what the list is for.

**Is he right?** The list is reasonable in a two-column paper to contrast two items, which
is a standard use. However, given the IJCAI style it can feel slightly informal. This is
a minor stylistic point.

**Fix:** Either keep as-is (lists are fine in IJCAI papers) or convert to a short prose
paragraph: "Two separate queues serve different purposes: the per-peer RX queue holds
packets in arrival order to fix delivery order, while the global device ring distributes
packets across cores for decryption." Given space constraints, this is acceptable either way.
Ask André at the meeting whether he prefers prose.

---

## C5 — §3: "Quid de la version 'user' de WireGuard ?"
**Location:** "WireGuard deliberately stays in the kernel to inherit the security guarantees..."

**What he's saying:** What about WireGuard-go, the userspace implementation? If we're
arguing WireGuard stays in-kernel by design, we should acknowledge the userspace version
exists and explain why we focus on the kernel one.

**Is he right?** Yes. WireGuard-go (the reference userspace implementation) and
wireguard-rs exist. The EoI we study is specific to the kernel implementation
(`drivers/net/wireguard`). A reader who knows about WireGuard-go would wonder whether
the same issue exists there, and why we focus on the kernel version.

**Fix:** Add a clarifying sentence in §3: "WireGuard has two implementations: a kernel
module (`drivers/net/wireguard`, merged in Linux 5.6) and a userspace reference
(`wireguard-go`). This work focuses on the kernel implementation, where the scheduling
interaction with NAPI and the workqueue is the bottleneck studied by~\cite{mounah2025}.
The userspace implementation has a different I/O path and is not subject to the same EoI."

---

## C6 — §4.4: "Sans doute légèrement plus faible, le premier arrivé ayant un léger avantage temporel"
**Location:** "Among N packets decrypting concurrently, the head finishes first with
probability ≈ 1/N."

**What he's saying:** The probability that the head finishes first is probably slightly
*less* than 1/N, not equal to it. His reason: the head packet was dispatched first, so
it started decryption slightly earlier than the others, giving it a small temporal
advantage. This would push the probability *above* 1/N (not below). Wait — he says
"légèrement plus faible" (slightly lower). Let me re-read.

Actually, re-reading: "le premier arrivé ayant un léger avantage temporel" — the first
to arrive (= the head) has a slight temporal advantage. If the head starts decrypting
slightly earlier, it should finish slightly earlier than pure random, pushing the
probability slightly *above* 1/N. So André's "plus faible" (lower) seems to be saying
the probability of a useful poll is slightly lower — meaning the head is *less* likely to
finish first. That would mean the head has a disadvantage, not an advantage.

This is an important nuance. The head is dispatched first via round-robin, so CPU c0
starts working on packet 0 first. But c0 may already be busy with a previous peer's
packet when packet 0 arrives, creating a queuing delay. So the head can actually be
*delayed* compared to later packets that land on idle cores. This is the "head
structural disadvantage" we removed from an earlier draft.

**Is he right?** He's raising a real point: the head is not symmetric with other packets.
Whether it has an advantage or disadvantage depends on the system load. Under high load,
c0 is likely busy, so the head is delayed (probability < 1/N). Under low load, the head
might start first (probability > 1/N). The 1/N approximation is only exact in the
uniform-random case.

**Fix:** Add a nuance: "Under uniform random completion order, the probability is exactly
1/N. In practice, under high load, the core assigned to the head may already be busy
with a previous packet, introducing a slight delay — making the useful-poll fraction
somewhat lower than 1/N. We use 1/N as an upper bound and measure the actual rate
in Section 6."

---

## C7 — Fig. 2: "cette explication concernant uncrypted/crypted semble inversée à crypted/decrypted"
**Location:** Figure 2 caption and surrounding text using UNCRYPTED/CRYPTED.

**What he's saying:** The terminology UNCRYPTED/CRYPTED is confusing compared to
ENCRYPTED/DECRYPTED. He notes there is pink highlighting earlier suggesting the same
confusion. The issue: a packet starts as UNCRYPTED (not yet decrypted), becomes CRYPTED
(decrypted). This terminology is WireGuard's internal naming in the source code
(`enum packet_state { PACKET_STATE_UNCRYPTED, PACKET_STATE_CRYPTED, PACKET_STATE_DEAD }`),
but it is counterintuitive to readers who expect ENCRYPTED/DECRYPTED.

**Is he right?** He's right that the naming is confusing. CRYPTED meaning "decrypted"
is backwards from natural language (crypted → encrypted, but WireGuard uses it to mean
the opposite). This is the actual kernel naming convention (the packet is "crypted" =
processed by the crypto), but we should clarify it.

**Fix:** Add a one-time clarification when first introducing the states:
"A packet's state (...) takes one of three values: UNCRYPTED (awaiting decryption),
CRYPTED (decryption succeeded — named from the kernel's perspective of having been
'processed by crypto'), or DEAD (failed)." After that, add a parenthetical in a key
location: "CRYPTED (i.e., decrypted and ready to deliver)".

---

## C8 — §4.2: "'together' n'est pas le bon terme"
**Location:** "Consecutive packets from one peer are not decrypted **together**."

**What he's saying:** "Together" is ambiguous — it could mean "simultaneously" or "in
the same group" or "in sequence". The intended meaning is "not on the same core
sequentially" or "not in isolation from other packets".

**Is he right?** Yes. "Together" is vague. The intended meaning is that consecutive
packets are dispatched to *different* cores and decrypt in parallel — they don't wait
for each other. A better word would be "sequentially" or "on a single core" or
"in order".

**Fix:** Rewrite to: "Consecutive packets from one peer are not decrypted sequentially
on a single core. The device ring assigns each to a different core by round-robin..."
This makes the contrast (parallel across cores, not sequential on one) explicit.

---

## C9 — §4.3: "Le problème est sans doute plus lié aux traitements parallèles qu'à cet enchaînement"
**Location:** §4.3 "The Trigger Ignores Both" — the code snippet showing
`atomic_set_release` followed by `napi_schedule`.

**What he's saying:** The bug is better described as a consequence of *parallel processing*
(multiple workers finishing simultaneously and all calling napi_schedule) rather than the
sequence of two operations in one worker. He's right that the sequence
`atomic_set_release; napi_schedule` is not the real problem — the problem is that
*N workers each do this independently*, not the ordering within one worker.

**Is he right?** Completely right. The real issue is: N independent workers each call
napi_schedule unconditionally, and since they work in parallel, they mostly fire when
the head isn't ready. The code snippet in §4.3 shows one worker doing it, which could
mislead a reader into thinking it's a sequencing problem within a single worker.

**Fix:** Reframe §4.3 to emphasize the parallel aspect. The intro sentence should be:
"The problem is not within a single worker's sequence of operations — it's that N
independent workers each unconditionally call napi_schedule, and since they work in
parallel they mostly fire when the head is not yet ready." The code shows what *each*
worker does, but the harm comes from all of them doing it at once.

---

## C10 — §5.1: "ce nœud particulier ne peut-il pas être détecté ? Est-ce que cela vaut la peine ?"
**Location:** "If tail points to the stub sentinel (a dummy node the queue uses to mark
the empty state), we schedule unconditionally, which costs at most one extra poll."

**What he's saying:** Can we detect the stub sentinel and handle it specifically —
perhaps skip the wake entirely, rather than scheduling unconditionally? Is the
unconditional scheduling in this case actually necessary?

**Is he right?** This is a good question. The stub sentinel (`rx_queue.empty`) means the
queue is empty — no packets are pending. In that case, scheduling a poll seems pointless
(there's nothing to deliver). However, the reason we schedule unconditionally on the
sentinel is safety: we can't be sure the queue is truly empty (there could be a race
where a new packet was enqueued right after we read tail). Scheduling unconditionally
costs one harmless extra poll, which is cheap.

Could we detect the sentinel and skip? Technically yes — `tail == &peer->rx_queue.empty`
is the exact check. But skipping could miss a packet that was enqueued between our read
and the poll running. The unconditional schedule is a conservative safety net.

**Fix in the report:** Add a sentence explaining the reasoning: "We could skip the wake
in the sentinel case (the queue appears empty), but a packet may have been enqueued
between our read and the poll running. Scheduling unconditionally costs at most one
empty poll and avoids this race. The optimization is possible but not worth the
added complexity."

This is also a good question to discuss with André at the meeting.

---

## C11 — Fig. 3: "L'évolution en fonction du nombre de peers semble plus erratique qu'autre chose :-( L'explication ci-dessous ne cible que le cas 1 peer"
**Location:** Figure 3 (wasted polls per second) and the paragraph below it.

**What he's saying:** Two problems:
1. The results don't show a clean monotonic trend with peer count — 1 peer has ~43k, then
   2 peers ~50k, then 4 peers drops to ~34k, then 8 jumps to ~64k, then 16 drops again.
   It's not a clean "more peers = more waste" story.
2. The text explanation below the figure only explains the 1-peer case and why the
   reduction is modest there — it doesn't explain the non-monotonic behavior across
   all peer counts.

**Is he right?** Yes, this is a legitimate criticism. The irregular pattern (4 peers
lower than 2, 8 peers higher than 16) is not well explained. This is likely because:
- At 4 peers with 32/4=8 streams/peer, the load per peer is higher than at 8 peers
  with 32/8=4 streams/peer, affecting the number of concurrent workers.
- The relationship isn't just "number of peers" but "concurrent decryptions per peer queue".
- High variance in the measurements could also contribute.

**Fix:** The results paragraph needs a fuller explanation of the non-monotonic pattern,
not just the 1-peer case. Need to add: the relevant variable is not peer count in isolation
but *concurrent decryptions per peer queue* (which depends on both peer count AND
streams per peer). At 4 peers × 8 streams = high per-queue load; at 8 peers × 4 streams
= less load per queue. This explains why the pattern isn't simply monotonic in peer count.

This is the most significant experimental criticism. The current text doesn't address it.

---

## C12 — §7: "Peut-on réellement attendre un double gain ?"
**Location:** Conclusion, sentence about combining the two fixes: "applying both together
should give additional improvement over either alone."

**What he's saying:** Can we really expect a *double* gain from combining his fix (lower
cost per poll) with our fix (fewer polls)? He's skeptical — the effects may not be
additive, and calling it "double" or expecting additive benefit may be overconfident.

**Is he right?** He's right to be skeptical. The two fixes address different dimensions:
- His fix: moves GRO to lower-priority context (removes preemption of workers).
- Our fix: reduces how often GRO is scheduled.

They are logically orthogonal, but in practice, on the M1, the throughput effect of
his fix is already significant. Adding our fix on top may reduce *some* residual overhead
but not necessarily produce another 4.7×. The gain of combining them on real hardware
is genuinely unknown.

**Fix in the report:** Soften the claim. Replace "should give additional improvement over
either alone" with "may give additional improvement, though the precise gain depends on
whether the two bottlenecks are independent at the regime where throughput collapses —
something only real-hardware measurements can confirm."

---

## Summary — what requires a fix in the report

| # | Fix required | Difficulty |
|---|---|---|
| C1 | Add `\cite{mounah2025}` in abstract | Trivial |
| C2 | Qualify "normal-priority" to be specific to WG's case | Easy |
| C3 | Rewrite the causal sentence in §2.3 | Easy |
| C4 | Convert bullet list to prose (or keep — ask André) | Easy |
| C5 | Add WireGuard-go paragraph in §3 | Easy |
| C6 | Add "≤ 1/N under load" nuance in §4.4 | Easy |
| C7 | Clarify UNCRYPTED/CRYPTED naming convention on first use | Easy |
| C8 | Replace "together" with "sequentially on a single core" | Trivial |
| C9 | Reframe §4.3 to emphasize parallel workers, not code sequence | Medium |
| C10 | Add reasoning for unconditional sentinel schedule | Easy |
| C11 | Explain non-monotonic Fig. 3 pattern properly | Medium |
| C12 | Soften "double gain" claim in conclusion | Easy |

## The two hardest ones to answer

**C11 (erratic results)** is the most technically difficult. The non-monotonic graph
is real — 4 peers is lower than 2, 16 is lower than 8. The explanation lies in
*concurrent decryptions per peer queue* varying non-monotonically with (N peers ×
32/N streams/peer). Need to think this through carefully and either re-run with
more controlled conditions or add a clear explanation.

**C10 (sentinel detection)** is a good design question André is genuinely curious
about. Worth exploring: could we compare `tail` to `&peer->rx_queue.empty` and
simply not schedule? The answer is probably "yes but risky" — discuss with him.

## Questions to bring to the meeting

1. **C4** — Does he prefer prose to a bullet list for the two queues? Quick ask.
2. **C10** — Is the sentinel always detectable, and would skipping the wake there
   be safe? Ask if he has a specific concern about the race.
3. **C11** — Does he want us to re-run with a controlled concurrent-decryptions-per-queue
   sweep instead of a peer-count sweep, to show a cleaner trend?
4. **C12** — What regime does he have in mind for "double gain"? On a loopback rig
   vs. a real NIC, the answer may be different.
