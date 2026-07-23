# Related-work map

How each cited work positions the paper, and why it earns its place. The paper
is not a new VPN protocol, a new cipher, a receive-steering algorithm, a removal
of ordered delivery, or a general-purpose task scheduler. It is a bounded
receive-path mechanism inside WireGuard's existing ordering model. Every entry
below is used to sharpen that boundary.

Metadata for all added entries was verified against the ACM Digital Library,
USENIX, DBLP, and kernel.org before it was added to `paper/reference.bib`. No
BibTeX was fabricated.

## Entries and their role

| Key | Category | Role in the paper | Where cited |
|---|---|---|---|
| `donenfeld2017` | WireGuard architecture | Defines the system and its in-kernel receive path. | Intro, Related, Background |
| `wireguard-linux` | WireGuard implementation | Source of the two-queue receive model. | Background, Design |
| `rfc8439` | Cipher | ChaCha20-Poly1305, the decrypt work being scheduled. | Background, Related |
| `noise` | Protocol framework | Handshake context; one line only. | Related |
| `mounah2025` | Kernel VPN performance (closest prior work) | Same receive path, different lever: they change where deferred processing executes; we advance the pending work from the blocked consumer. | Intro, Related |
| `hoiland2018xdp` | Kernel-bypass fast path | Contrast: bypass trades the stack for speed; WireGuard and our mechanism stay in-kernel. One sentence. | Related |
| `salim2001beyond` | NAPI foundation | Establishes the batched-poll receive model the paper builds on. | Background, Related |
| `linux-napi` | NAPI + RSS/RPS/RFS | Receive steering that spreads flows across cores. | Background, Related |
| `pesterev2012affinity` | Receive locality (Affinity-Accept) | Steering/placement acts between flows; cannot divide one tunnel. | Background, Related |
| `linux-padata` | Parallel kernel crypto with ordered output | Contrast: padata restores order with a serialization stage; WireGuard uses a per-peer ordered queue, and our mechanism is explicitly not padata. | Related |
| `blumofe1999` | Work stealing (theory) | Names the lineage; we contrast intent (blocked consumer, not idle worker) and structure (shared ring, not per-worker deques). | Related |
| `frigo1998cilk` | Work-stealing runtime (Cilk-5) | The canonical randomized-deque scheduler we are *not*; sharpens "not a general-purpose scheduler". | Related |
| `hendler2010flat` | Cooperative execution (flat combining) | Closest conceptual analog: a blocked thread performs others' pending work. Our purpose (unblock ordered delivery) and hard per-pass bound differ. | Related |

## Category coverage (brief's seven areas)

1. WireGuard architecture and Linux implementation -> `donenfeld2017`,
   `wireguard-linux`, `rfc8439`, `noise`.
2. Linux NAPI and receive steering -> `salim2001beyond`, `linux-napi`,
   `pesterev2012affinity`.
3. Parallel packet processing with ordered completion -> `linux-padata`,
   `mounah2025`.
4. Head-of-line blocking in parallel systems -> discussed conceptually in the
   ordered-completion paragraph; no forced citation.
5. Work stealing -> `blumofe1999`, `frigo1998cilk`.
6. Cooperative kernel/network execution -> `hendler2010flat`, `mounah2025`.
7. Encrypted-tunnel receive performance -> `mounah2025`, `donenfeld2017`,
   `hoiland2018xdp`.

## Deliberately excluded

- Generic VPN comparison surveys (IPsec vs. OpenVPN vs. WireGuard throughput):
  out of scope; the paper is about one receive-path mechanism, not a survey.
- General user-space work-stealing schedulers beyond the two anchors: cited only
  enough to draw the contrast; more would blur it.
- DPDK/netmap kernel-bypass beyond the single XDP positioning sentence.

## Open verification note

The one-line characterization of `mounah2025` ("improves the same receive path
by changing where deferred receive processing executes") is flagged with a
`% TECHNICAL REVIEW:` comment in `06-related.tex` and `02-introduction.tex`
because it summarizes prior-work internals not covered by the evidence matrix.
Agent 1 should confirm it before the abstract is finalized.
