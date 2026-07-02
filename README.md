![WireGuard's receive path — source-level analysis and a six-line fix for the Execution Order Inversion](diagrams/banner.png)

# Workqueue Scheduling Overhead in WireGuard

### Source-level analysis and a targeted fix for Execution Order Inversion

> **Inria KrakOS internship** (LIG, Grenoble) · M1 MOSIG
> Anas Ait El Hadj — supervised by **Alain Tchana** and **André Freyssinet**

---

WireGuard is a modern VPN built into the Linux kernel. Under sustained
multi-gigabit traffic with 1,000 concurrent clients, it reaches only **19.2 %**
of available bandwidth. Prior work ([Mounah *et al.*, SYSTOR 2025](#references))
traced this to an **Execution Order Inversion (EoI)**: concurrent decryption
triggers Generic Receive Offload (GRO) reassembly so frequently that one CPU
core saturates. Moving reassembly to a background thread recovered 4.7× throughput.

This project shows, through **source-level analysis**, that the prior fix is
*incomplete*: it makes each wasted reassembly cheaper, but not less frequent.
WireGuard schedules reassembly after **every** decrypted packet, even when no
progress is possible. With decryption spread over *N* cores, the packet due for
delivery next is rarely the first to finish — so most reassembly passes find
nothing to deliver. We propose a **six-line conditional guard** that triggers
reassembly only when the next packet due is actually ready.

## The break point

The receive path chains three kernel engines — NAPI, a per-CPU workqueue, and
GRO. The flow turns *down* into the unconditional `napi_schedule` call: that
single line, fired after every out-of-order completion, is where the bug lives.

![Receive pipeline](diagrams/slide_pipeline_en.png)

## The fix

Before waking the NAPI, check whether the head of the per-peer queue is ready.
If it is still encrypted, skip the wake — the worker that finishes the head will
do it.

```c
tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);     // otherwise: skip
```

The read is lock-free and safe: `tail` is written only by the single consumer.
The worst case is a stale read that skips one wake, which NAPI's internal
*MISSED* mechanism recovers — no packet is ever stranded.

## Results (Apple M1 Pro, loopback, 5 runs each)

| peers | Δ wasted polls | GRO batch size |
|------:|:--------------:|:--------------:|
| 1     | −8.8 %         | 3.1 → 3.3      |
| 8     | **−21.9 %**    | 8.7 → **9.6**  |
| 32    | **−20.7 %**    | 7.7 → **8.9**  |

The reduction grows with peer count — exactly what the *1/N* model predicts —
and rising batch size confirms the mechanism: GRO is woken less often but
delivers more each time. Throughput is flat on loopback (the softirq never
saturates). **These loopback results motivated, and are partly corrected by, the
real-hardware validation below.**

## Status — CloudLab validation on real 10G hardware (June–July 2026)

The M1 story above was re-tested on CloudLab `c220g2` nodes (2× Xeon E5-2660 v3,
10 GbE, kernel 5.15). The full, honest synthesis is
[`docs/cloudlab/RECEIVE_PATH_FINDINGS.md`](docs/cloudlab/RECEIVE_PATH_FINDINGS.md);
the headline corrections:

- **Saturated throughput is controlled by receive-side parallelism, not by the
  EoI fix.** The NIC's IP-only flow hash funnels all tunnels onto one core;
  adding the UDP ports to the hash (`ethtool … rx-flow-hash udp4 sdfn`) spreads
  receive across 8 cores and lifts stock WireGuard **4.1 → 9.0 Gb/s (×2.2)**.
- **The original six-line producer-side fix alone is a null on real hardware.**
  The working version is the **two-sided fix** (producer gate `wg_headwake` +
  consumer suppress `wg_supp`), which **halves wasted polls, ~27% → ~14%**, flat
  from 8 to 64 peers — real removed work, but the M1 "grows with peer count"
  effect does not reproduce here.
- **Phase A sub-saturation campaign: a clean CPU null on c220g2.** The saved
  work does not show up as measurable CPU reduction (softirq/system/total,
  deltas −4.7%…+1.6%, p≈0.4–1.0) at 0/2/4/6 Gb/s.
- **Tail latency shows only a weak, noisy favorable trend** (~7–8% lower p99 for
  the fix at mid loads, not significant, power-state-confounded) — not claimed.
- **Phase B (in progress) tests whether the fix matters when decrypt is slower**
  (`wg_decrypt_delay_ns` sweep): the remaining place a user-visible win could
  live, per the cost model (~1 µs/poll saved vs ~5–6 µs decrypt on these Xeons).

## Repository layout

| Path | Contents |
|------|----------|
| `report/` | Final 6-page report (LaTeX source + figures) |
| `docs/cloudlab/` | CloudLab measurement phase: plan, runbook, lab log, findings |
| `docs/defense/` | Defense slides (`SLIDES_DEFENSE_EN`), speaker notes, builder |
| `docs/study/` | Source/pipeline analysis (`CODE_STUDY_*`, diagrams, solution proposal) |
| `docs/meetings/` | Supervisor meeting notes, prep, and progress reports |
| `docs/experiments/` | M1 experiment runbooks |
| `diagrams/` | Graphviz sources (`.dot`) and rendered `.svg`/`.png` |
| `linux-source/` | Curated kernel files cited as proof (WireGuard module, GRO, UDP offload) |
| `scripts/` | Measurement harness (`cloudlab/` testbed + multi-peer, repeated runs, analysis) |
| `notes/`, `reference/` | Source-study notes and reference material |
| `io_uring_examples/` | Early io_uring exploration (the original framing) |

## Report & slides

- **Report:** `report/main.tex` — *Workqueue Scheduling Overhead in WireGuard:
  Source-Level Analysis and a Targeted Fix for Execution Order Inversion*
- **Defense deck:** `docs/defense/SLIDES_DEFENSE_EN.md` (Marp → HTML/PDF)

## References

- C. Mounah *et al.*, "The Impact of Kernel Asynchronous APIs on the Performance
  of a Kernel VPN," SYSTOR 2025.
- [WireGuard](https://www.wireguard.com/) — Jason A. Donenfeld.

## License

Released under the **GNU General Public License v2.0** — see [`LICENSE`](LICENSE).
GPL-2.0 is used throughout because the kernel modification (`linux-source/.../receive.c`)
is a derivative of the Linux kernel and WireGuard, both GPL-2.0.
