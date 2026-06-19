# Speaker notes — subject presentation (detailed script)

Speaking script for `SLIDES_SUJET_EN.md` (and its PDF). One section per slide, in order.
For each slide: the **target duration**, the **text to say** (close to word-for-word), the
**transition**, and, where useful, the **pocket answers** to likely questions.

**Total ≈ 22 min of content → aim for 15–18 min when speaking.** Priority if time is cut:
slides **4, 9, 10, 11** (map → assemble → bug → fix).

---

## Glossary — the words that appear on the diagrams

*(re-read before presenting; pull out if someone gets stuck on a term)*

**Networking / packets**

- **packet (`skb`)**: a chunk of data traveling on the network; in the kernel, a struct
  called `sk_buff`.
- **encrypted / decrypted**: a WireGuard packet arrives *encrypted* (unreadable);
  *decrypting* it (ChaCha20-Poly1305) makes it readable.
- **UDP**: a simple, fast way to send packets; WireGuard packets travel *inside* UDP.

**Execution contexts** (where code runs — central to the whole talk)

- **interrupt (IRQ)**: a *hardware* signal that forces the CPU to drop everything to handle
  an event ("a packet arrived"). Must be **ultra-short**.
- **softirq**: the "bottom half" of network processing — code run *just after* an interrupt,
  with **no thread of its own**, **not allowed to sleep**, must stay short.
- **process context**: the opposite — code running in a *real thread*, can take its time, be
  paused, and **sleep**.
- **thread / kthread**: a flow of execution scheduled by the OS; a *kthread* is a *kernel*
  thread (e.g. `kworker`, `ksoftirqd`).

**NAPI**

- **NAPI**: the "ring once, then collect the mailbox in batches" mechanism. It is a
  *record (struct) + a `poll` function*, **not** a running program.
- **`poll()`**: a NAPI's collection function; in WireGuard it is `wg_packet_rx_poll`.
- **budget**: max packets handled per poll pass (= 64).
- **`napi_schedule`**: "wake the NAPI" = mark it "to do" + raise the softirq (runs *nothing*
  immediately).
- **`napi_complete_done`**: "I'm done" = flush GRO, remove itself, re-arm the interrupt.
- **`net_rx_action`**: the network softirq handler that calls the `poll()` functions.
- **WireGuard's NAPI**: a *software* NAPI, **one per peer**, on `wg0` — see the dedicated
  note (Slide 6).

**Workqueue**

- **workqueue**: a queue of *deferred work*, run *later* by **kernel threads** (workers), in
  **process context** (so they can take their time / sleep).
- **worker / `kworker`**: the kernel thread that runs the work placed on a workqueue.
- **`queue_work_on(cpu, …)`**: "place this work on that core"; a worker of that core runs it.
- **per-CPU**: **one worker per core** → work runs *in parallel* across cores.

**GRO**

- **GRO**: group several packets of the *same flow* into one big one, to cross the stack
  **only once**.
- **GRO #1 / #2**: #1 on the *external encrypted* UDP (NIC side, **conditional**); #2 on the
  *internal decrypted* packets (`wg0` side, done **explicitly** by WireGuard).

**Peer / WireGuard**

- **peer**: the other end of a tunnel, identified by its **public key**.
- **`wg0`**: the **virtual** (software) network interface created by WireGuard; it carries
  the tunnel's address.
- **public key**: a peer's cryptographic identity (not its IP).
- **allowed-ips**: the IP ranges a peer is allowed to use (cryptokey routing).
- **keypairs**: the session (encryption) keys of the relationship with a peer.

**Queue and bug**

- **`rx_queue`**: a peer's **ordered** receive queue (remembers delivery order).
- **MPSC (Vyukov queue)**: "multi-producer, **single consumer**" — several actors enqueue,
  one (the poll) dequeues; this is what makes the fix **safe**.
- **`UNCRYPTED` / `CRYPTED`**: a packet's state in the queue (not yet decrypted / decrypted).
- **`work_done`**: number of packets actually *delivered* on a poll pass; **`work_done = 0`**
  = a **wasted** pass = the bug's signature.
- **EoI (Execution Order Inversion)**: the bug — we wake the NAPI while the *head* of the
  queue is not ready.

---

## Slide 1 — Title  *(≈30 s)*

"Hello, I'm Anas Ait El Hadj. This is my internship at Inria, in the KrakOS team, supervised
by Alain Tchana and André Freyssinet. My subject is the path by which WireGuard — a VPN —
*receives* packets, and more precisely a timing problem inside it that shows up when a server
has many clients. The title has three verbs: understand, measure, fix. I won't dive into the
technical detail yet — let's first set the scene."

- **Avoid:** listing technical detail right now. Stay high-level.
- **Transition →** "First, what we're talking about."

---

## Slide 2 — The setting  *(≈1 min 15)*

"You may know WireGuard: a modern VPN, known for being simple and fast, built straight into
the Linux kernel. A VPN, concretely, connects machines through *encrypted tunnels*.

For personal use — one client, one tunnel — no problem, it's very fast. The problem shows up
on the *server* side: when a single machine has to handle hundreds, even thousands of clients
at once. And here's the key point: it isn't the *network* that saturates, it's the *CPU*.
The per-packet processing, on *receive*, can saturate one core — and throughput plateaus.

Hence my internship question, in two parts: *why* does it plateau, specifically on this
receive path, and *how* to do better."

- **Hammer:** the bottleneck is the per-packet CPU cost on receive, not bandwidth.
- **Transition →** "To answer that, I have a starting point: a recent paper."

---

## Slide 3 — What motivates this  *(≈1 min 15)*

"My starting point is a 2025 paper, at SYSTOR, by Mounah and co-authors. Their idea: in
WireGuard's receive path, *move* one specific step — GRO, I'll explain it — from where it
runs today into a 'workqueue'. The result: up to *4.7 times* more throughput on a
multi-client server. That's huge, and it shows the stakes are real.

My angle isn't to *repeat* the paper. It's to: (1) really *master* this receive mechanism —
NAPI, workqueue, GRO — and *prove it from the code*, not just assert it; (2) *measure* it
myself; (3) study a *related bug* on this path — the Execution Order Inversion, or EoI — and
its fix."

- **If asked about the io_uring link:** the internship starts from optimizing the kernel
  network path; the WireGuard analysis is its concrete application.
- **Transition →** "Before all that, we need a mental map of a packet's journey."

---

## Slide 4 — The map (teaser)  *(≈1 min — don't rush past it)*

"Here's the map. For now I'm asking you *not* to read it in detail — just keep one thing:
when an encrypted packet arrives, it crosses *three big engines*, in this order. One: the
*NIC's NAPI*, which receives it. Two: a *workqueue*, which decrypts it. Three: a *second
NAPI*, WireGuard's, which re-orders it and does GRO. And the key point: these three engines
run in three different *execution contexts* — I'll explain what that means. We'll unpack each
brick one by one, then come back to *exactly* this map."

- **Purpose of the slide:** give a destination, so the 4 bricks make sense.
- **Transition →** "First brick, the simplest: who are we talking to?"

---

## Slide 5 — Brick 1: the "peer"  *(≈1 min 30)*

"First brick: the peer. WireGuard is a VPN, so the first question is: who am I talking to?
Each correspondent at the other end of a tunnel is a *peer*.

Think of one *record per correspondent*. On the record: its identity — and its identity is
its *public key*, not its IP address, because the address can change if it switches from
Wi-Fi to 4G.

The key point for what follows is twofold. First, a single interface — `wg0` — can carry
*many* peers: a thousand in the paper. Second, look at the diagram: each peer has *its own*
queue and *its own* mailbox — its NAPI. But at the very bottom, there is only *one*
decryption workshop, *shared* by all.

Keep that contrast — each its own queue, but one shared workshop — because it's exactly what
will explain why the bug *grows with the number of peers*."

- **Transition →** "That 'mailbox' each peer has — what is it exactly? It's the NAPI."

---

## Slide 6 — Brick 2: NAPI  *(≈2 min — central brick, take your time)*

"Second brick: NAPI. I'll explain it with an analogy.

A network card that receives a packet normally tells the CPU through an *interrupt* — picture
a postman ringing your doorbell for *every* letter. For two letters a day, fine. But at a
*million* packets a second, the CPU spends its life running to answer the door: it collapses.
That's the 'interrupt storm'.

NAPI's idea: ring *once*, then *mute* the doorbell, and say 'I'll collect the mailbox myself,
in batches'.

The cycle is the diagram: (1) the doorbell rings once; (2) we tick 'to do' and raise a flag —
and I stress: at that moment *nothing runs yet*, 'waking the NAPI' is just ticking a box; (3)
a bit later, we collect the mailbox, that is, we call the poll() function; (4) poll() collects
up to *64* packets — that quota is the *budget*; (5) mailbox empty, we say 'I'm done, put me
back to sleep' and re-arm the doorbell.

The line to remember, at the bottom: *NAPI is not a running program, it is a record + a
function, and that function runs in a 'softirq'.* And right here I define the word
immediately, because it'll come back: a *softirq* is *the moment we actually collect the
mailbox — just after the doorbell rang*. It is not a dedicated employee; it's borrowed time,
and you're **not allowed to linger** there or fall asleep. Just keep that for now."

**And what is 'WireGuard's NAPI' exactly? — chain this in, it matters later:**

"Everything I just described is the *normal* NAPI, the one of a *real* network card. But
WireGuard does something clever: it *builds its own NAPI*, *one per peer*, connected to *no*
hardware. It hangs it on the *virtual* interface `wg0` — a *fake* network device, purely
software. And instead of being woken by a *card interrupt*, it is woken *by hand* by the
decryption workers — that's the famous `napi_schedule`. What is it for? *Only* to re-do GRO
on the *decrypted* packets and deliver them *in order*.

So, throughout the talk, there are *two* NAPIs:

- **NAPI #1** = the *real card's* (hardware, woken by an interrupt);
- **NAPI #2** = *WireGuard's* (software, *one per peer*, on `wg0`, woken *by hand*).

And the bug is on NAPI #2."

- **If asked "why build a fake NAPI?":** because GRO only works *inside* a NAPI; after
  decryption packets no longer arrive from a card, so WireGuard simulates a NAPI to still
  group them.
- **Transition →** "Exactly: why isn't everything done in that poll? Because some tasks are
  too long. Hence the workqueue."

---

## Slide 7 — Brick 3: the workqueue  *(≈2 min 30 — here we plant THE cause of the bug)*

**First: what is a workqueue, exactly?**

"Third brick: the workqueue. Let me define it clearly, because it's central. A workqueue is a
kernel mechanism for *deferring work*: instead of doing a computation *right now*, we *drop it
into a queue*, and a *kernel thread* — called a *worker*, which you see in the system as
`kworker` — runs it *later*. The key point: that worker runs in *process context*, that is,
like a *real thread* scheduled by the system — it's allowed to *take its time*, be paused, and
even *sleep*."

**Why WireGuard needs it here:**

"Remember the softirq from the previous brick: it's *borrowed*, short time where you're *not
allowed to do long work* or 'take a pause'. But *decrypting* a packet — the ChaCha20-Poly1305
computation — is *heavy*. Doing it in the softirq would block everything else. So WireGuard
*delegates* that decryption to a workqueue."

**The analogy (to say):**

"The softirq is the *front desk* of a company: you can't keep a visitor twenty minutes, it
blocks the queue. The workqueue is the *back office*, with *real employees* — the workers —
who *do* have time. 'Dropping the work', in code, is called `queue_work_on`: in plain terms,
*'you, the employee on that core, go decrypt this packet'*."

**The decisive detail (the seed of the bug):**

"WireGuard puts *one worker PER CORE*. So several packets decrypt *AT THE SAME TIME*, on
several cores. It's fast — but, and this is *the seed of the bug*, keep this word: they finish
*OUT OF ORDER*. The core handling packet 5 may finish before the one handling packet 2. Once
done, each worker 'rings' the peer's NAPI — that's the `napi_schedule` from earlier."

- **Definition to remember:** workqueue = *deferred work*, run by *kernel threads* (workers /
  `kworker`) in *process context* (so they can take their time / sleep).
- **Key difference to be able to say:** softirq = short, *not allowed to sleep*; workqueue =
  *real thread*, can take its time. That's *why* decryption goes there.
- **Pitfall to avoid:** don't say "several workqueues". It's **one** workqueue, with **one
  worker** per core (see Appendix A if asked).
- **Transition →** "Last brick before we assemble: the optimization we're trying to preserve
  — GRO."

---

## Slide 8 — Brick 4: GRO  *(≈2 min)*

"Fourth brick: GRO. The problem it solves: pushing a packet up through all the layers of the
system has a *fixed cost*, paid *for every packet*, regardless of its size. With millions of
small packets, you pay that 'toll' millions of times — and that's the bottleneck.

The analogy: you have 40 envelopes to carry up to the 10th floor. Either you make *40* trips
up the stairs, or you *staple* the 40 into one big parcel and go up *once*. GRO is the second
option: it groups packets of the *same flow* into one big one, and crosses the stack only
once.

On the diagram: 4 packets, we staple them, that makes a parcel, and when the NAPI finishes
its pass, we push the parcel up.

An important detail for WireGuard — and a question I was asked: there are *TWO* GRO moments.
One on the *external encrypted* envelope, NIC side, which is *conditional* and which WireGuard
*does not enable* itself; and one on the *internal decrypted* letter, `wg0` side, that one
done *explicitly* by WireGuard. It's this second one that concerns us."

- **Transition →** "We have the four bricks. Let's put them back together."

---

## Slide 9 — We assemble  *(≈2 min — point at each block as you speak)*

"We reassemble — and now you can *read* the map. I'll follow the journey:
(1) on the left, the NIC's NAPI, with GRO #1 (conditional);
(2) WireGuard receives the packet and enqueues it in *two phases*: an *ordered* per-peer queue
on one side, and on the other it places the decryption on a core;
(3) in the middle, in red, the per-CPU workqueue that decrypts *in parallel* — so, out of
order;
(4) the boxed red block: the *wake* of the NAPI, done after *every* packet, *unconditionally*;
(5) WireGuard's NAPI that dequeues *in order*;
(6) and GRO #2 toward the application.

That's the complete machine, and it works. The question now: *where does it jam?*"

- **Note:** the detailed diagram (with all the source lines) is in the report / proof dossier;
  here we stay on the "6 blocks" version.
- **Transition →** "Exactly at the seam between the workqueue and the second NAPI."

---

## Slide 10 — The bug (EoI)  *(≈2 min 30 — THE CORE of the talk, slow down)*

"This is the core of my talk. Let's bring back the two ingredients we set up.

*One*: the workqueue decrypts in parallel, so packets finish *out of order* — here, core 2
finished packet 5 before core 0 finished packet 2.

*Two*: after *every* decrypted packet, we wake the NAPI, *unconditionally*.

Now, what does the NAPI do when it wakes? It must deliver *in order*, so it looks at the
*head* of the queue. And the head is packet 2… which isn't ready yet. So it *leaves without
doing anything*: work_done = 0. That's the Execution Order Inversion.

And there's a *double cost*. Not only did we waste a softirq pass, but on top of that, since
the NAPI woke for nothing, GRO #2 couldn't staple anything — it *loses its big parcels*. So
the bug doesn't just waste CPU: it also *breaks batching*. On the right, in green, I'm already
showing what we'll change."

- **Punchline (say it verbatim):** "we wake up to deliver, but there's nothing to deliver."
- **Transition →** "And precisely, the fix fits in one idea."

---

## Slide 11 — The fix  *(≈1 min 30)*

"The fix, proposed in the team, fits in one *idea*: before waking the NAPI, we *read the head
cursor* of the queue, and we wake *ONLY IF* that head is already decrypted.

If the head isn't ready, we do nothing — and that's fine: the worker that eventually finishes
that head will trigger the wake then.

Why is it *safe*? Because that head cursor is written by only *one* actor — the queue's single
consumer; it's a so-called MPSC queue, single consumer. So no data race. Worst case, in an
edge case, we miss a wake, but it's caught right after.

Expected result: we *remove the empty wakes*, and GRO *gets its batches back*."

- **Avoid:** reading the code line by line. Just point at the condition "if head != UNCRYPTED".
- **Transition →** "Let's see what I actually did and measured."

---

## Slide 12 — What I did (measurements, M1/ARM)  *(≈2 min — own the limit, it's a strength)*

"Concretely, here's my work. I *reproduced* the mechanism on my own machine — a Mac M1, on
Fedora Asahi — in a *multi-peer* setup.

What I measured confirms the analysis: the drop in GRO efficiency *grows with the number of
peers*. At one peer, you see nothing; at 8, 16, 32 peers, the effect appears and grows. That's
exactly consistent with 'the bug is per peer'.

To measure *cleanly*, I built a harness: variance control, *direct* metrics — the GRO
counters, the work_done distribution — and a parameter sweep.

And I want to be *honest* about the limit: my local loopback *does not saturate* throughput, I
have no real 25-gigabit card. So I clearly see the *mechanism*, but not the paper's
*throughput regime*."

- **If asked for numbers:** May 28 campaign — at 8 peers ≈ −17% GRO, etc. (report). Stay
  cautious: high variance on M1 (P/E cores).
- **Transition →** "And that's exactly what justifies the next step."

---

## Slide 13 — x86 validation + next steps (CloudLab)  *(≈1 min 30)*

"Two points to close on the concrete side.

First: does all this hold for the paper's architecture — x86, an older kernel — while I'm on
ARM? I checked *file by file*: the bug site, the fix, the queue, the poll function are
*identical* between the two versions; the only difference is a *workqueue flag*, with no effect
on behavior. So my analysis and the fix transfer as-is.

Then, next steps: I obtained access to *CloudLab* — x86 machines, with a real 25-gigabit card,
and enough to scale up to *a thousand* peers. That's where I'll be able to test the *throughput
regime*, and therefore the *real gain* of the fix, where the paper measures."

- **Strong point:** the ARM↔x86 comparison is done and traced (`COMPARAISON_CODE_VERSIONS`).
- **Transition →** "In summary."

---

## Slide 14 — Conclusion  *(≈1 min — finish clean, look at the jury)*

"To conclude, three points.

One: I *understood* WireGuard's receive mechanism — NAPI, workqueue, GRO — and I *proved it
from the code*, line by line.

Two: I *located* the bug — an unconditional wake — and the fix is *simple and safe*: read the
head before waking.

Three: I *measured it on ARM*, and the x86 validation, via CloudLab, is *in progress*.

Thank you for your attention — I'm ready for your questions."

- **In reserve (Appendices A–D):** "one workqueue / per-CPU workers"; NAPI lifecycle; Front #1
  call chain; bpftrace proof (bucket 0 of `work_done`); fix safety (Vyukov MPSC queue, single
  consumer writes `tail`).

---

# Pocket answers (appendix slides)

## Appendix A — "one workqueue" vs "per-CPU"

"Good question. It's not contradictory: there is *one* workqueue object, `packet_crypt_wq`,
allocated once for the interface. 'Per-CPU' describes the *workers*: there's one worker per
core, and WireGuard keeps one *work item* per CPU, submitted with `queue_work_on` on a
*specific* core. So 'per-CPU' means 'the workers are per core', not 'there are N workqueues'.
That's exactly what the brick-3 diagram shows: one red box, several employees."

## Appendix B — NAPI lifecycle (7 steps)

"The full lifecycle is seven steps: we *create* the NAPI with `netif_napi_add`, *enable* it
with `napi_enable`, *wake* it with `napi_schedule`, its poll function is `wg_packet_rx_poll`,
it *finishes* with `napi_complete_done`, then on peer destruction we do `napi_disable` and
`netif_napi_del`. The struct itself *lives in* `struct wg_peer` — so one per peer. And
'waking', I remind you, is just ticking a list and raising the softirq, it runs nothing."

## Appendix C — Front #1: call chain (generic, outside WireGuard)

"Here's the full call chain of the first front, from the NIC's poll down to `udp_gro_receive`:
`napi_gro_receive`, `gro_receive_skb`, `dev_gro_receive` — which dispatches by Ethernet type —
`inet_gro_receive` — which dispatches by IP protocol — then `udp4_gro_receive`, then
`udp_gro_receive`. *All* of that is in the generic kernel: WireGuard *never* appears. And the
merging of the external UDP is *conditional* — WireGuard doesn't enable UDP GRO, so this front
only coalesces if the card has certain options turned on. That's why I drew it
'conditional'."

## Appendix D — runtime proof (bpftrace)

"To prove it at runtime, I use bpftrace: I trace the *return value* of `wg_packet_rx_poll` —
that's `work_done`, the number of packets delivered on each pass. A *spike in bucket 0* is the
passes where nothing was delivered: the exact signature of the bug. And the fix must *melt
that bucket 0* and shift the mass toward values above 1 — that is, real batches, hence
efficient GRO. It's a *direct* measurement of the mechanism, and it's *independent of the
kernel version*."
