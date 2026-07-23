# Narrative style guide

Scope: the narrative sections (`02-introduction`, `03-background-motivations`,
`06-related`, `07-conclusion`) and the abstract, once written. The goal is prose
that a systems and networking reader who does not know WireGuard internals can
follow, that reads as human research writing, and that never overstates the
evidence. Numbers and claim scope are governed by `CLAIM_EVIDENCE_MATRIX.md` and
`SCIENTIFIC_GUARDRAILS.md`; this document governs voice and terminology.

## Voice

- Direct, technical, restrained. Active voice where natural.
- Short paragraphs, one idea each. Explicit transitions between them.
- State claim scope in the sentence that makes the claim, not in a footnote.
- Prefer: "We observe", "We measure", "The receive poll reaches", "No favorable
  effect was detected", "This result narrows the claim", "This pattern is
  consistent with", "The experiment does not establish".

## Do not use

- Filler: "It is worth noting that", "In today's world", "As we can see".
- Certainty inflation: "obviously", "clearly proves", "definitively
  demonstrates", "groundbreaking", "revolutionary".
- Result-overstating shortcuts: "the null result proves", "no effect exists",
  "equivalent", "proved null" (see the forbidden list in
  `SCIENTIFIC_GUARDRAILS.md`).
- Repetitive paragraph shapes and generic one-line summaries.

## Preferred terminology (canonical -> avoid)

Use the definitions in `TERMINOLOGY.md`. In prose specifically:

- receive poll / RX/NAPI context  (not "the NAPI", "the softirq handler")
- decrypt worker  (not "the padata thread" -- the implementation is not padata)
- pending decrypt job  (not "queued packet", ambiguously)
- ordered head / ordered delivery  (not "the front", "in-order-ness")
- execution-order inversion  (spell it out; do not abbreviate to "EoI" in prose)
- head-of-line blocking / blocked head
- steal budget / `k` / `wg_steal=4` = up to four successful consumes per pass
- core-equivalent (CE)
- matched load  (not "controlled load")
- uncapped saturated regime  (not "full load")
- non-detection / "no favorable effect was detected"  (never "no effect",
  "no difference", "equivalent")
- descriptive mechanism evidence  (for the counters; never "proof")

## Internal names

Keep internal labels out of the reader-facing prose, or introduce them once
after the scientific question. Reader-facing names to prefer:

- "the saturated paired confirmation"  (not "Gate A" in a topic sentence)
- "the matched-load CPU confirmation"  (not "Gate B" first)
- "the empty-poll cost measurement"  (not "E10")
- "the classified ordered-head blocking experiment"  (not "E11-C")

Never introduce `wg_supp`, `wg_headwake`, `sdfn`, `srcversion`,
`instantiation #N`, or `MISSED` into narrative prose. `wg_steal` is the one
mechanism name that is kept.

## The three claims writers most often overstate

1. The matched-load result is a **non-detection**, favorable in **3/8** blocks,
   with a CI spanning benefit and cost. Never "null", "no effect", or
   "equivalent".
2. The cross-regime reading is **consistent with** a binding-core explanation;
   it is not a saturation threshold, a causal claim, or an interaction test.
3. The wake-side changes are **real but cheap**, not redundant. Absence of an
   incremental combined-treatment effect is not equivalence.

No user-visible latency claim appears anywhere. The prototype is a research
prototype; no production-safety claim is made.
