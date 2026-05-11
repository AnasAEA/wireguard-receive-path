# Technical Writing & Speaking — Complete Writing Guide
# M1 MoSIG 2025-2026

> Reference document for writing the intermediate and final internship reports.
> Follow these guidelines for every section of the paper.

---

## 1. Tools

### LaTeX
- Cloud: **Overleaf** (recommended)
- Local: VS Code + LaTeX Workshop extension
- Template for this internship: `resources/latex_style/` (IJCAI-26 format)

### Useful extras
- **Grammarly** — grammar checking
- **QuillBot** — paraphrasing (use carefully, always verify)

---

## 2. Writing the Introduction — The 5-Stage Framework

This is the most important structural rule. Every introduction must follow these five stages in order.

| Stage | Purpose | What to write |
|-------|---------|---------------|
| **1** | Establish context | General statements about the research field |
| **2** | Review related work | Specific statements about what others have already studied |
| **3** | Identify the gap | Indicate the need for more investigation |
| **4** | State purpose | Very specific statement of your study's objectives |
| **5** | Justify value *(optional)* | Explain practical or theoretical benefits |

---

### Stage 1 — Establishing Context ("Setting")

**The Universe → Galaxy → Star approach:**
1. **Universe:** Broad accepted facts about the general area
2. **Galaxy:** The subarea that includes your specific topic
3. **Star:** Your specific topic

Move from general to specific. Begin with what is familiar to the reader.

**Old-to-new information flow:**
- Place **old/known information at the beginning** of each sentence
- Place **new information at the end**
- This creates a logical chain between sentences

**Generic noun phrases (no "the"):**
```
✅ "Workqueues are kernel mechanisms for asynchronous task execution"
✅ "A workqueue is a kernel mechanism for asynchronous task execution"
✅ "Asynchronous I/O reduces latency in network-intensive applications"
```

**Specific noun phrases (use "the"):**
- Use "the" for assumed shared knowledge
- Use "the" when pointing back to something already mentioned
- Use "the" when pointing forward to specifying information

**Pitfalls to avoid:**
```
❌ "io_uring is important." → ✅ "io_uring is important because it provides..."
❌ "Since the invention of the internet..." (unrelated historical facts)
```

---

### Stage 2 — Reviewing Related Work

**Two types of citations:**

| Type | Structure | When to use |
|------|-----------|-------------|
| **Information prominent** | `"Information [citation]"` | Beginning of related work; general area |
| **Author prominent** | `"Author [citation] showed that..."` | Studies closely related to yours |

**Verb tenses:**
- **Present tense** → information prominent (accepted scientific facts)
- **Present perfect** → weak author prominent, general research activity statements
- **Simple past** → author prominent (individual study findings)

```
✅ "io_uring provides a unified interface for asynchronous I/O [Axboe, 2019]."  (present, info-prominent)
✅ "Several studies have investigated workqueue overhead in Linux [X, Y, Z]."   (present perfect)
✅ "Mounah et al. [2025] showed that GRO preempts decryption workers..."        (past, author-prominent)
```

**Citation ordering strategies:**
1. **Distant to close** (default — start far from your topic, end closest)
2. **Chronological** (to show research history)
3. **Different approaches** (when many citations cover different methods)

---

### Stage 3 — Identifying the Research Gap

**Three writing strategies:**
1. **Inadequate/ignored aspect** — important aspect ignored by others
2. **Unresolved conflict** — disagreement among previous studies
3. **Extension/new question** — suggests extension of prior work

**Signal words to mark the gap:**
- Connectors: **however, but, yet**
- Subordinating conjunctions: **although, while**
- Modifiers: **few, little, no** (in the gap statement itself)

```
✅ "However, existing work does not address..."
✅ "Although X has been studied, little attention has been paid to..."
✅ "No study has examined the interaction between io-wq and..."
```

---

### Stage 4 — Statement of Purpose

**Two orientations:**

| Orientation | Tense | Example |
|-------------|-------|---------|
| **Toward the report** | Present / Future | "This paper examines..." / "This study will investigate..." |
| **Toward the research activity** | Past | "The aim of this study was to..." |

**Connecting to research questions:**
- **Yes/No questions** → use **whether / if** + modal (would / could)
- **Open questions** → omit if/whether, use infinitive or noun phrase

---

### Stage 5 — Statement of Value *(optional for intermediate report)*

**Two perspectives:**
1. **Practical benefit** — how findings can be applied
2. **Theoretical benefit** — how the study advances knowledge

**Use modal auxiliaries for tentativeness** (sound modest, not certain):

| Certainty | Modal |
|-----------|-------|
| High → Low | will → would → can → could → **may → might** |

Stage 5 should use **may, might, could** — never "will".

```
✅ "These findings may help system designers tune workqueue configurations..."
✅ "This work could contribute to the understanding of kernel scheduling overhead..."
❌ "This work will solve the problem of..."
```

---

## 3. Writing with Energy — Verb and Voice Rules

### Use strong verbs

```
❌ "is presented"           → ✅ "presents"
❌ "are discussed"          → ✅ "discusses"
❌ "made the arrangement"   → ✅ "arranged"
❌ "is dependent on"        → ✅ "depends on"
❌ "There are X workers..." → ✅ "X workers handle..."
```

Avoid nominalizations — they drain energy from your sentences.

### Active vs. Passive voice

**Prefer active** when the subject is important:
```
✅ "WireGuard's GRO handler preempts the decryption worker."
```

**Use passive** when:
- The actor is unknown or unimportant
- You want to keep focus on the subject being studied
- You need to place old information at the beginning

**First person (I / we):**
- Use when YOU assumed, measured, or decided
- Avoid starting a sentence with "I" or "We" (too heavy at the start)
```
✅ "To verify this, we ran bpftrace on the live kernel..."
❌ "We found that io-wq does not fire..." → ✅ "Our measurements show that io-wq does not fire..."
```

---

## 4. Conciseness — Cut These

### Redundancies
```
❌ "already existing"       → ✅ "existing"
❌ "basic fundamentals"     → ✅ "fundamentals"
❌ "completely eliminate"   → ✅ "eliminate"
❌ "continue to remain"     → ✅ "remain"
❌ "end result"             → ✅ "result"
❌ "future plans"           → ✅ "plans"
```

### "Writing zeroes" — empty filler phrases (delete on sight)
```
❌ "It is interesting to note that..."
❌ "It is significant that..."
❌ "It should be pointed out that..."
❌ "The fact that..."
❌ "In the course of..."
❌ "It is worth mentioning that..."
```

---

## 5. Methodology Section

### Suggested order
1. Overview of the experiment
2. Population / Sample
3. Location / Environment
4. Restrictions / Limiting conditions
5. Sampling technique
6. Procedures (algorithm / workflow / framework)
7. Materials (hardware / software)
8. Variables
9. Statistical treatment

### Organization strategies

| Strategy | Best for |
|----------|----------|
| **Chronological** | Timeline processes, cyclic processes, phased workflows |
| **Spatial** | Objects, software architecture descriptions |
| **Classification/Division** | Complex systems with distinct components |

### Headings — be descriptive
```
❌ "Phase 1, Phase 2, Phase 3"
✅ "Kernel Investigation Setup, Worker Pool Measurement, Network Path Verification"
✅ Even better: "Setting Up the io_uring Tracing Environment, Measuring Worker Pool Behavior, Verifying the Network I/O Path"
```

### Verb tenses
- **Simple past** → procedures YOU used
- **Present tense** → standard procedures commonly used by others
- **Passive voice** is conventional (depersonalizes, emphasizes the procedure over the actor)
- **Mix active and passive** for readability

---

## 6. Results, Discussion & Conclusion

### Results section — three elements

| Element | Purpose | Tense |
|---------|---------|-------|
| **Locate figures** | Tell readers where to find results | Present |
| **Present findings** | Report the most important findings | Past |
| **Comment on results** | Brief statistical or analytical commentary | Present |

```
✅ "Figure 1 shows the per-core CPU usage under three configurations."   (present — locate)
✅ "The workqueue configuration achieved 4.7× higher throughput."        (past — finding)
✅ "This represents a near-linear improvement over the baseline."         (present — comment)
```

### Discussion section
- Interpret what results mean
- Compare with previous research
- Explain unexpected findings
- Discuss limitations
- State implications

**Organization options:**
1. General-to-specific
2. By importance (most important first)
3. By research question
4. By hypothesis

### Conclusion section
- Summary of main findings
- Answer to the research question
- Implications / applications
- Recommendations for future research

**Tenses:**
- Present perfect → what you have done
- Present → established facts
- Future → future work

---

## 7. Abstract

### Structure (≤ 200 words for this report)

| Component | Content |
|-----------|---------|
| **Purpose** | The question investigated (1–2 sentences) |
| **Methods** | Experimental design, basic methodology |
| **Results** | Major findings, key quantitative results, trends |
| **Conclusions** | Brief interpretation and implications |

**Rules:**
- Must stand alone — no citations, no figures, no tables
- Include keywords for literature searches
- Write the abstract **last**, after the full paper is done

---

## 8. Title

**Two essential functions:**
1. **Identify** the field of work
2. **Separate** your work from other papers in that field

**Good title checklist:**
- [ ] Specific and informative
- [ ] Contains searchable keywords
- [ ] No jargon or unexplained abbreviations
- [ ] Accurately reflects the content

---

## 9. Citation Rules (named.bst style — IJCAI template)

### In-text citations
```latex
% Information prominent:
"Workqueues allow asynchronous task execution across multiple CPU cores \cite{mounah2025}."

% Author prominent:
"Mounah et al. \shortcite{mounah2025} showed that GRO preempts decryption workers..."
```

### Citing borrowed figures or tables
Every figure reused from another paper must say in its caption:
```
Figure X: [Description]. (Figure borrowed from Mounah et al. [2025].)
Figure X: [Description]. (Partially based on Cloudflare [2022].)
```

### What counts as a citable source
- Academic papers (HAL, arXiv, conference proceedings) ✅
- Blog posts (Cloudflare, LWN) — cite as `@misc` with URL and access date ✅
- Kernel documentation — cite as `@misc` ✅
- "Lord of the io_uring" guide — cite as `@misc` ✅

---

## 10. Complete Pre-Submission Checklist

### Introduction
- [ ] Stage 1: Context established (universe → galaxy → star)
- [ ] Stage 2: Related work reviewed with information-prominent and author-prominent citations
- [ ] Stage 3: Research gap clearly marked with signal words (however, although, yet...)
- [ ] Stage 4: Purpose statement present (report or research orientation)
- [ ] Stage 5: Value statement if applicable, with modal auxiliaries (may/might/could)
- [ ] Correct verb tenses throughout (present for facts, past for findings, present perfect for activity)
- [ ] Old-to-new information flow at sentence level

### Writing quality
- [ ] Strong verbs, no nominalizations
- [ ] No "writing zeroes" (empty filler phrases deleted)
- [ ] No redundancies
- [ ] Active/passive mix is appropriate
- [ ] First person used only where you personally acted

### Results / Discussion
- [ ] Figures located (present tense)
- [ ] Findings reported (past tense)
- [ ] Comments on results (present tense)
- [ ] Results clearly separated from interpretation

### Abstract
- [ ] Purpose in first 1–2 sentences
- [ ] Methods briefly described
- [ ] Key results included
- [ ] Conclusions stated
- [ ] ≤ 200 words
- [ ] Stands alone (no citations, no figures)

### Format (IJCAI-26 template)
- [ ] Plagiarism statement present and signed
- [ ] All borrowed figures cited in caption
- [ ] All in-text citations use `\cite{}` or `\shortcite{}`
- [ ] `.bib` file includes all references with correct fields
- [ ] ≤ 2 pages body (+ references for internship report)
- [ ] File named `LastName.pdf`

---

## 11. Key Principles — Quick Reference

| Rule | Application |
|------|-------------|
| **Structure is everything** | Follow the 5-stage introduction |
| **Old-to-new flow** | Connect sentences: end of one = beginning of next |
| **Verbs provide energy** | Active, direct verbs at start/middle of sentences |
| **Tense signals meaning** | Present = facts, Past = your findings, Present perfect = research activity |
| **Be concise** | Delete redundancies and filler phrases |
| **Cite properly** | Info-prominent for general, author-prominent for specific |
| **Write for your reader** | Define unfamiliar terms, start with familiar concepts |
| **Sound modest** | Use may/might/could for value claims, never "will" |
