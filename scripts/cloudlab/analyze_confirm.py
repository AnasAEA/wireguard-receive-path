#!/usr/bin/env python3
"""Phase D confirmation — fail-closed paired within-block analysis.

Handles the gate artifacts (mode autodetected from the CSV header, and
cross-checked against --mode when given):
  confirm_*.csv        gate A: uncapped single-tunnel replication of Finding 8
  fixedload_*.csv      gate B legacy: matched-load CPU + same-tunnel latency
  fixedload_cpu_*.csv  gate B CPU-ONLY (coordinator-approved 2026-07-17):
                       matched-delivered-load CPU confirmation, no latency
                       probe. Requires --cpu-only, and --cpu-only requires
                       the artifact's cpu_only/probe_mode=none markers —
                       either direction of mismatch is exit 1. Inference is
                       total_busy_ce only: primary steal4-off (no
                       multiplicity, single primary), secondary five-test
                       Holm family {both-off, bsteal4-steal4, bsteal4-both,
                       bsteal4-off, interaction}. softirq/system CE, per-core,
                       classifier and steal counters are DESCRIPTIVE only.
                       Latency inference was withdrawn before the full run;
                       no sockperf field is required, parsed, or emitted.
                       Reliability gates (exit 2): absolute load +-5% of the
                       3.8 Gb/s delivered target, pairwise 1.5%, and any
                       per-run kernel warning (dmesg gate, CPU-only mode).

FAIL-CLOSED VALIDATION (exit 1, zero inferential output). Before ANY
statistics: exact final block count (gate A 12, gate B 8 — a different
--blocks value is allowed ONLY together with --smoke), exactly one row per
(block, condition), positions 1-4 exactly once per block, only the four known
conditions, a single NONEMPTY srcversion, and a nonempty, parseable,
COMPLETE treatment readback per row covering exactly
{supp, headwake, steal, diag, delay, trig_k}: supp/headwake/steal must match
the condition label, diag must match the campaign mode (gate A: 0, gate B: 1),
delay and trig_k must be 0. Missing, duplicated, unknown, malformed or
unexpected knobs = mislabeled/unverified treatment = unusable artifact.
Gate B additionally requires integral, nonnegative message counters with a
possible accounting: total_run_sent>0, 0<total_run_recv<=total_run_sent,
lat_duration_s>0, valid_sent>0, 0<valid_recv<=valid_sent,
0<=valid_dropped<=valid_sent, dup/ooo>=0, 0<lat_n<=valid_recv (sockperf's
observation count cannot exceed what the valid window received; no exact
equality is imposed because sockperf does not guarantee one). raw_ref must
be nonempty and follow the <tool>_b<block>p<pos>_<cond>.<ext> naming; gate B
rows must reference a sockperf raw file. Nothing is dropped or zero-filled.

VALIDITY GATES (exit 2; a VOID line replaces the inference, never sits above
a printed p-value):
  absolute load     every gate B row must sit within +-5% of the target load
                    (--target-load, default 3.8 Gb/s): pairwise equality at
                    the wrong operating point is not the predeclared regime.
                    --target-load is ONLY for a run that was intentionally
                    predeclared at a different load — never to rescue data
                    after observing that it failed the gate.
  pairwise load     within every block of a comparison,
                    |load_a - load_b| / pair_mean <= 1.5%; one failing pair
                    voids the whole comparison (dropping the block would be
                    silent selection).
  interaction       the 2x2 interaction (bsteal4-steal4)-(both-off) is
                    load-gated on its ACTUAL COMPONENTS, bsteal4-steal4 AND
                    both-off; if either fails, the interaction is VOID.
  loss              valid-period UDP loss (valid_dropped/valid_sent) > 1.0%
                    on any involved row voids the comparison's LATENCY
                    metrics (condition-dependent loss can fake a tail win);
                    CPU inference is retained.
  support           p99.9 needs lat_n >= 100000 on every involved row
                    (~100 obs in the top 0.1%); p50/p90/p99 need >= 10000.

SOCKPERF FIELD MODEL: [Total Run] counters include warm-up and are context
only (total_run_*). The latency distribution, loss and support gates use the
[Valid Duration] section exclusively: lat_duration_s, valid_*_msgs, lat_n.
Percentiles are HALF-RTT (sockperf ping-pong convention), named *_half_rtt_us.

SMOKE MODE (--smoke): structural validation of a shortened run (e.g.
--blocks 1). All schema checks and validity gates run; descriptive rows and
deltas are printed for debugging; NO p-values, CIs, Holm or verdicts are
printed, and the output is watermarked "SMOKE / STRUCTURAL VALIDATION ONLY —
NOT A FINAL RESULT". Exit: 0 structurally valid, 1 invalid, 2 gates voided.

ENDPOINTS AND MULTIPLICITY (final analysis only; declared before the runs):
  Gate A co-primary    steal4-off on gbps (+) AND total_busy_ce (-), both
                       must pass sign-flip p<0.05 favorably -> REPLICATED.
  Gate B primary       steal4-off on total_busy_ce at matched load.
  Latency primary      steal4-off on p99_half_rtt_us; other latency numbers
                       are EXPLORATORY.
  Secondary family     both-off, bsteal4-steal4, bsteal4-both, bsteal4-off,
                       interaction — Holm within the family per metric.
  A large p-value is reported as "no incremental effect detected", never as
  proof of redundancy/equivalence (no equivalence margin was predeclared).

STATS: exact sign-flip test on within-block deltas (audited; unchanged).
Floors: 12 blocks -> 2/4096 ~= 0.000488; 8 blocks -> 2/256 = 0.0078125.
Paired bootstrap 95% CI on the mean delta (10000 resamples, seed 20260716).
The classifier columns (unc_*) are only comparable between conditions that
leave wg_supp off (off, steal4).

Usage:
  analyze_confirm.py data/cloudlab/confirm_<TS>.csv
  analyze_confirm.py data/cloudlab/fixedload_<TS>.csv
  analyze_confirm.py --mode confirm --blocks 1 --smoke confirm_smoke_<TS>.csv
  analyze_confirm.py --selftest
Exit status: 0 valid (final or smoke); 1 invalid artifact/schema/treatment
evidence or invalid invocation; 2 validity gate void.
"""
import csv
import io
import math
import os
import random
import re
import statistics as st
import sys
import tempfile

CONDS = ["off", "both", "steal4", "bsteal4"]
KNOB_EXPECT = {"off": (0, 0, 0), "both": (1, 1, 0),
               "steal4": (0, 0, 4), "bsteal4": (1, 1, 4)}
KNOB_KEYS = {"supp", "headwake", "steal", "diag", "delay", "trig_k"}
DIAG_EXPECT = {"confirm": 0, "fixedload": 1, "fixedload_cpu": 1}
EXPECT_BLOCKS = {"confirm": 12, "fixedload": 8, "fixedload_cpu": 8}
COMPS = [("steal4", "off"), ("both", "off"), ("bsteal4", "steal4"),
         ("bsteal4", "both"), ("bsteal4", "off")]
SECONDARY = [("both", "off"), ("bsteal4", "steal4"),
             ("bsteal4", "both"), ("bsteal4", "off")]
INTERACTION_COMPONENTS = [("bsteal4", "steal4"), ("both", "off")]
LOAD_GATE_PCT = 1.5
TARGET_LOAD_GBPS = 3.8      # gate B predeclared operating point
ABS_LOAD_TOL_PCT = 5.0      # +-5%: generous vs the 1.5% pairwise gate, but
                            # rules out "pairwise equal yet nowhere near the
                            # intended high-load regime" (e.g. everything at
                            # 2 Gb/s would idle the receive path under test)
MAX_LOSS_PCT = 1.0
MIN_OBS_P999 = 100_000
MIN_OBS_OTHER = 10_000
BOOT_N = 10_000
SEED = 20260716
SMOKE_MARK = "SMOKE / STRUCTURAL VALIDATION ONLY — NOT A FINAL RESULT"

FAVOR = {"gbps": +1, "eff_gbps_per_ce": +1, "total_busy_ce": -1,
         "softirq_ce": -1, "p50_half_rtt_us": -1, "p90_half_rtt_us": -1,
         "p99_half_rtt_us": -1, "p999_half_rtt_us": -1}


class Invalid(Exception):
    pass


def fnum(row, key, ctx, positive=False):
    raw = row.get(key)
    if raw is None:
        raise Invalid(f"{ctx}: missing column {key!r}")
    try:
        v = float(raw)
    except ValueError:
        raise Invalid(f"{ctx}: malformed numeric {key}={raw!r}")
    if not math.isfinite(v):
        raise Invalid(f"{ctx}: non-finite {key}={raw!r}")
    if positive and v <= 0:
        raise Invalid(f"{ctx}: {key}={raw!r} must be > 0")
    return v


def inum(row, key, ctx, lo=0, hi=None, min_excl=False):
    raw = row.get(key)
    if raw is None:
        raise Invalid(f"{ctx}: missing column {key!r}")
    try:
        v = int(raw)
    except ValueError:
        raise Invalid(f"{ctx}: {key}={raw!r} is not an integer count")
    if v < lo or (min_excl and v == lo):
        raise Invalid(f"{ctx}: impossible count {key}={v} (< {'=' if min_excl else ''}{lo})")
    if hi is not None and v > hi:
        raise Invalid(f"{ctx}: impossible count {key}={v} > {hi}")
    return v


def parse_knobs(raw, ctx):
    if not raw:
        raise Invalid(f"{ctx}: EMPTY knob readback — treatment evidence missing, "
                      f"artifact unusable")
    pairs = raw.split(";")
    kv = {}
    for p in pairs:
        if "=" not in p:
            raise Invalid(f"{ctx}: unparseable knob entry {p!r}")
        k, _, v = p.partition("=")
        if k in kv:
            raise Invalid(f"{ctx}: duplicated knob {k!r} in readback")
        try:
            kv[k] = int(v)
        except ValueError:
            raise Invalid(f"{ctx}: malformed knob value {p!r}")
    if set(kv) != KNOB_KEYS:
        raise Invalid(f"{ctx}: knob readback keys {sorted(kv)} != required "
                      f"{sorted(KNOB_KEYS)} (missing/unknown knob)")
    return kv


def check_treatment(kv, cond, mode, ctx):
    supp, head, steal = KNOB_EXPECT[cond]
    exp = {"supp": supp, "headwake": head, "steal": steal,
           "diag": DIAG_EXPECT[mode], "delay": 0, "trig_k": 0}
    for k, want in exp.items():
        if kv[k] != want:
            raise Invalid(f"{ctx}: knob {k}={kv[k]}, expected {want} for cond "
                          f"{cond!r} in mode {mode!r} — MISLABELED/CONTAMINATED "
                          f"TREATMENT, artifact unusable")


def check_raw_ref(row, mode, ctx):
    raw = (row.get("raw_ref") or "").strip()
    if not raw:
        raise Invalid(f"{ctx}: empty raw_ref — raw evidence unreferenced")
    pat = re.compile(rf"^(iperf|sockperf)_b{row['block']}p{row['position']}"
                     rf"_{row['cond']}\.(json|txt)$")
    parts = raw.split(";")
    for part in parts:
        if not pat.match(part):
            raise Invalid(f"{ctx}: raw_ref part {part!r} does not match the "
                          f"expected <tool>_b{row['block']}p{row['position']}"
                          f"_{row['cond']}.<ext> naming")
    if mode == "fixedload" and not any(p.startswith("sockperf_") for p in parts):
        raise Invalid(f"{ctx}: gate B row lacks a sockperf raw reference")
    if mode == "fixedload_cpu":
        if any(p.startswith("sockperf_") for p in parts):
            raise Invalid(f"{ctx}: CPU-only row references a sockperf raw file "
                          f"— contradicts probe_mode=none")
        if not any(p.startswith("iperf_") for p in parts):
            raise Invalid(f"{ctx}: CPU-only row lacks an iperf raw reference")


# Predeclared CPU-only identity (fourth audit §1): metadata must state
# EXACTLY these settings — metadata is a witness of the predeclared design,
# never a channel that redefines the analyzer's target or gates. Numeric
# values are compared numerically after a no-surrounding-whitespace check;
# strings must match exactly.
CPU_META_EXACT_NUM = {"application_cap_gbps": 3.58, "per_stream_mbit": 895,
                      "delivered_target_gbps": 3.8,
                      "absolute_tolerance_pct": 5, "paired_tolerance_pct": 1.5}
CPU_META_EXACT_STR = {"cpu_only": "1", "probe_mode": "none",
                      "delivered_target_metric": "wg0_rx_bytes_exact_window"}
CPU_META_VALIDATED = (set(CPU_META_EXACT_NUM) | set(CPU_META_EXACT_STR)
                      | {"module_srcversion", "audited_head", "harness_gitrev"})


def check_cpu_sidecars(path, table, src):
    """CPU-only artifact linkage (audit §5 + fourth audit §1-3): the .meta
    and .percore sidecars must exist next to the CSV, carry the EXACT
    predeclared identity and canonical provenance, agree with the CSV, and
    align row-for-row with finite nonnegative values. Missing or
    contradictory linkage is exit 1 — no inference."""
    meta_p, pc_p = path + ".meta", path + ".percore"
    if not os.path.exists(meta_p):
        raise Invalid(f"missing metadata sidecar {meta_p}")
    kv = {}
    with open(meta_p) as fh:
        for line in fh:
            if "=" in line:
                k, _, v = line.rstrip("\n").partition("=")
                if k in CPU_META_VALIDATED and k in kv:
                    raise Invalid(f"{meta_p}: duplicate metadata field {k!r} "
                                  f"({kv[k]!r} then {v!r}) — ambiguous "
                                  f"identity, artifact unusable")
                kv[k] = v
    for k, want in CPU_META_EXACT_STR.items():
        got = kv.get(k)
        if got is None:
            raise Invalid(f"{meta_p}: missing identity field {k!r}")
        if got != want:
            raise Invalid(f"{meta_p}: {k}={got!r} != predeclared {want!r} — "
                          f"metadata cannot redefine the design")
    for k, want in CPU_META_EXACT_NUM.items():
        raw = kv.get(k)
        if raw is None:
            raise Invalid(f"{meta_p}: missing identity field {k!r}")
        if raw != raw.strip() or not raw:
            raise Invalid(f"{meta_p}: {k}={raw!r} has unexpected whitespace")
        try:
            num = float(raw)
        except ValueError:
            raise Invalid(f"{meta_p}: {k}={raw!r} is not numeric")
        if not math.isfinite(num) or num != want:
            raise Invalid(f"{meta_p}: {k}={raw!r} != predeclared {want} — "
                          f"metadata cannot redefine the analyzer's target "
                          f"or gates")
    if kv.get("module_srcversion") != src:
        raise Invalid(f"{meta_p}: module_srcversion="
                      f"{kv.get('module_srcversion')!r} != CSV srcversion "
                      f"{src!r}")
    ah = kv.get("audited_head") or ""
    if not ah or ah != ah.strip():
        raise Invalid(f"{meta_p}: audited_head={ah!r} must be a nonempty "
                      f"commit with no surrounding whitespace")
    # canonical provenance stamp (fourth audit §2): exact whole-line equality
    # with the harness validator's canonical form — rejects wrong branch,
    # dirty!=0, wrong/missing commit, extra/duplicate/reordered fields and
    # any stray whitespace in one comparison
    expected_gitrev = (f"commit={ah} branch=cloudlab-receive-path-findings "
                       f"dirty=0")
    got_gitrev = kv.get("harness_gitrev")
    if got_gitrev != expected_gitrev:
        raise Invalid(f"{meta_p}: harness_gitrev is not the canonical stamp "
                      f"for audited_head — expected {expected_gitrev!r}, "
                      f"got {got_gitrev!r}")

    if not os.path.exists(pc_p):
        raise Invalid(f"missing per-core sidecar {pc_p}")
    runs = {}
    with open(pc_p) as fh:
        header = fh.readline().split()
        if header[:8] != ["timestamp", "block", "position", "cond", "cpu",
                          "busy_ce", "softirq_ce", "system_ce"]:
            raise Invalid(f"{pc_p}: unexpected header {header}")
        for n, line in enumerate(fh, start=2):
            f = line.split()
            if len(f) != 8:
                raise Invalid(f"{pc_p}:{n}: expected 8 fields, got {len(f)}")
            for x in f[5:8]:
                try:
                    v = float(x)
                except ValueError:
                    raise Invalid(f"{pc_p}:{n}: malformed CE value {x!r}")
                if not math.isfinite(v):
                    raise Invalid(f"{pc_p}:{n}: non-finite CE value {x!r}")
                if v < 0:
                    raise Invalid(f"{pc_p}:{n}: negative CE value {x!r}")
            runs.setdefault((f[1], f[2]), {"cond": set(), "cpus": []})
            runs[(f[1], f[2])]["cond"].add(f[3])
            runs[(f[1], f[2])]["cpus"].append(f[4])
    want_runs = {(b, r["position"]): c for (b, c), r in table.items()}
    if set(runs) != set(want_runs):
        raise Invalid(f"{pc_p}: per-core runs {sorted(runs)} != CSV runs "
                      f"{sorted(want_runs)}")
    cpu_sets = set()
    for key, info in runs.items():
        if info["cond"] != {want_runs[key]}:
            raise Invalid(f"{pc_p}: run block={key[0]} pos={key[1]} labeled "
                          f"{sorted(info['cond'])}, CSV says {want_runs[key]} "
                          f"— contradictory linkage")
        cpu_sets.add(tuple(sorted(info["cpus"])))
    if len(cpu_sets) != 1:
        raise Invalid(f"{pc_p}: per-run CPU sets differ — topology "
                      f"inconsistent across runs")


def load_artifact(path, mode_flag=None, blocks_override=None, cpu_only=False):
    with open(path) as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        raise Invalid(f"{path}: empty artifact")
    is_cpu = "cpu_only" in rows[0]
    if is_cpu and not cpu_only:
        raise Invalid("artifact carries the cpu_only marker: analyze it with "
                      "--cpu-only (a CPU-only artifact must never be judged "
                      "against latency-era expectations)")
    if cpu_only and not is_cpu:
        raise Invalid("--cpu-only was passed but the artifact has no cpu_only "
                      "marker — this is a legacy probe artifact; analyze it "
                      "without --cpu-only")
    mode = ("fixedload_cpu" if is_cpu else
            "fixedload" if "p999_half_rtt_us" in rows[0] else "confirm")
    ok_flags = {mode, "fixedload"} if mode == "fixedload_cpu" else {mode}
    if mode_flag and mode_flag not in ok_flags:
        raise Invalid(f"--mode {mode_flag} but the artifact is a {mode} CSV")
    want = blocks_override or EXPECT_BLOCKS[mode]

    src = {(r.get("srcversion") or "").strip() for r in rows}
    if "" in src:
        raise Invalid("empty srcversion — module build evidence missing")
    if len(src) != 1:
        raise Invalid(f"multiple srcversions in one artifact: {sorted(src)}")

    table = {}
    for i, r in enumerate(rows, start=2):
        cond = r.get("cond")
        if cond not in CONDS:
            raise Invalid(f"line {i}: unknown condition {cond!r}")
        key = (r.get("block"), cond)
        if key in table:
            raise Invalid(f"duplicate row for block={key[0]} cond={cond}")
        table[key] = r

    labels = {b for b, _ in table}
    if mode == "fixedload_cpu":
        # exact block-ID validation (audit §3): integral labels forming
        # exactly 1..want — not merely `want` distinct arbitrary labels
        try:
            ids = sorted(int(b) for b in labels)
        except (ValueError, TypeError):
            raise Invalid(f"non-integral block label among {sorted(labels)}")
        if ids != list(range(1, want + 1)):
            raise Invalid(f"block ids {ids} != required exactly "
                          f"1..{want} (CPU-only mode)")
    blocks = sorted(labels, key=lambda x: int(x))
    if len(blocks) != want:
        raise Invalid(f"{len(blocks)} blocks found, expected exactly {want} "
                      f"(--blocks N is allowed only together with --smoke)")
    for b in blocks:
        missing = [c for c in CONDS if (b, c) not in table]
        if missing:
            raise Invalid(f"block {b}: missing condition(s) {missing}")
        pos = sorted(table[(b, c)].get("position") for c in CONDS)
        if pos != ["1", "2", "3", "4"]:
            raise Invalid(f"block {b}: positions {pos} != one each of 1-4")

    for (b, c), r in table.items():
        ctx = f"block {b} cond {c}"
        check_treatment(parse_knobs(r.get("knobs"), ctx), c, mode, ctx)
        check_raw_ref(r, mode, ctx)
        for k, pos in (("softirq_ce", True), ("system_ce", True),
                       ("total_busy_ce", True)):
            fnum(r, k, ctx, positive=pos)
        if mode == "confirm":
            fnum(r, "gbps", ctx, positive=True)
        elif mode == "fixedload_cpu":
            if r.get("cpu_only") != "1":
                raise Invalid(f"{ctx}: cpu_only={r.get('cpu_only')!r} — the "
                              f"marker must be exactly '1' in every row")
            if r.get("probe_mode") != "none":
                raise Invalid(f"{ctx}: probe_mode={r.get('probe_mode')!r} — a "
                              f"CPU-only artifact cannot claim a live probe")
            fnum(r, "load_window_gbps", ctx, positive=True)
            fnum(r, "load_iperf_gbps", ctx, positive=True)
            fnum(r, "window_s", ctx, positive=True)
            fnum(r, "ping_ms", ctx, positive=True)
            inum(r, "retransmits", ctx, lo=0)
            inum(r, "hs_age_s", ctx, lo=0)
            inum(r, "dmesg_new", ctx, lo=0)
            for k in ("unc_n", "unc_total_ns", "steal_pulled",
                      "steal_unblocked", "steal_dryruns"):
                inum(r, k, ctx, lo=0)
        else:
            fnum(r, "load_window_gbps", ctx, positive=True)
            fnum(r, "lat_duration_s", ctx, positive=True)
            trs = inum(r, "total_run_sent_msgs", ctx, lo=0, min_excl=True)
            inum(r, "total_run_recv_msgs", ctx, lo=0, hi=trs, min_excl=True)
            vs = inum(r, "valid_sent_msgs", ctx, lo=0, min_excl=True)
            vr = inum(r, "valid_recv_msgs", ctx, lo=0, hi=vs, min_excl=True)
            inum(r, "valid_dropped_msgs", ctx, lo=0, hi=vs)
            inum(r, "valid_dup_msgs", ctx, lo=0)
            inum(r, "valid_ooo_msgs", ctx, lo=0)
            inum(r, "lat_n", ctx, lo=0, hi=vr, min_excl=True)
            for k in ("p50_half_rtt_us", "p90_half_rtt_us",
                      "p99_half_rtt_us", "p999_half_rtt_us"):
                fnum(r, k, ctx, positive=True)
    if mode == "fixedload_cpu":
        check_cpu_sidecars(path, table, next(iter(src)))
    return mode, blocks, table, src.pop()


def signflip_p(deltas):
    """Exact two-sided sign-flip test on the mean of paired deltas (audited)."""
    n = len(deltas)
    if n > 20:
        raise SystemExit(f"{n} blocks: exact 2^n enumeration too large")
    obs = st.mean(deltas)
    hits = 0
    for m in range(1 << n):
        s = sum(d if (m >> i) & 1 else -d for i, d in enumerate(deltas))
        if abs(s / n) >= abs(obs) - 1e-12:
            hits += 1
    return obs, hits / (1 << n)


def boot_ci(deltas, rng):
    n = len(deltas)
    means = sorted(st.mean(rng.choices(deltas, k=n)) for _ in range(BOOT_N))
    return means[int(0.025 * BOOT_N)], means[int(0.975 * BOOT_N)]


def holm(pairs):
    """pairs: list of (key, p) -> {key: p_holm} (step-down, capped, monotone)."""
    m = len(pairs)
    adj, running = {}, 0.0
    for rank, (key, p) in enumerate(sorted(pairs, key=lambda kp: kp[1])):
        running = max(running, min(1.0, (m - rank) * p))
        adj[key] = running
    return adj


def fmt_deltas(deltas):
    return " ".join(f"{d:+.4g}" for d in deltas)


class Analysis:
    def __init__(self, mode, blocks, table, smoke, target):
        self.mode, self.blocks, self.table = mode, blocks, table
        self.smoke, self.target = smoke, target
        self.rng = random.Random(SEED)
        self.voided = False

    def row(self, b, c):
        return self.table[(b, c)]

    def metric(self, name, b, c):
        r = self.row(b, c)
        if name == "eff_gbps_per_ce":
            return float(r["gbps"]) / float(r["total_busy_ce"])
        return float(r[name])

    def _abs_load_row_reason(self, blk, c):
        """Absolute gate on one row. fixedload_cpu: inclusive endpoints on the
        never-rounded measured value with a 1e-9 float guard (audit §6).
        Legacy fixedload keeps its original comparison and diagnostic wording
        byte-for-byte (third audit §5)."""
        l = float(self.row(blk, c)["load_window_gbps"])
        if self.mode == "fixedload_cpu":
            lo = self.target * (1 - ABS_LOAD_TOL_PCT / 100)
            hi = self.target * (1 + ABS_LOAD_TOL_PCT / 100)
            if l < lo - 1e-9 or l > hi + 1e-9:
                return (f"absolute load gate: block {blk} cond {c} measured "
                        f"{l:.6g} Gb/s, target {self.target} Gb/s, allowed "
                        f"[{lo:.3f}, {hi:.3f}] — not the predeclared regime")
            return None
        dev = 100 * abs(l - self.target) / self.target
        if dev > ABS_LOAD_TOL_PCT:
            return (f"absolute load gate: block {blk} cond {c} "
                    f"{l:.3f} Gb/s is {dev:.1f}% from the "
                    f"{self.target} Gb/s target (> {ABS_LOAD_TOL_PCT}%)"
                    f" — not the predeclared regime")
        return None

    def abs_load_reason(self, conds):
        """Gate B absolute plausibility: every involved row must sit at the
        intended operating point, not merely match its partner."""
        if self.mode not in ("fixedload", "fixedload_cpu"):
            return None
        for blk in self.blocks:
            for c in conds:
                reason = self._abs_load_row_reason(blk, c)
                if reason:
                    return reason
        return None

    def campaign_void_reasons(self):
        """CPU-only campaign-level reliability preflight (audit §1/§7):
        EVERY row must pass the absolute-load and dmesg gates, and EVERY
        predeclared pair must pass the 1.5% paired gate in EVERY block.
        Any failure voids the whole campaign — no primary, no secondaries,
        no interaction, no reduced Holm family, exit 2."""
        if self.mode != "fixedload_cpu":
            return []
        reasons = []
        for blk in self.blocks:
            for c in CONDS:
                reason = self._abs_load_row_reason(blk, c)
                if reason:
                    reasons.append(reason)
                if int(float(self.row(blk, c)["dmesg_new"])) > 0:
                    reasons.append(f"dmesg gate: block {blk} cond {c} logged "
                                   f"kernel warnings during the window")
        for a, b in COMPS:
            for blk in self.blocks:
                la = float(self.row(blk, a)["load_window_gbps"])
                lb = float(self.row(blk, b)["load_window_gbps"])
                mis = 100 * abs(la - lb) / ((la + lb) / 2)
                if mis > LOAD_GATE_PCT + 1e-9:
                    reasons.append(f"pairwise load gate: block {blk} "
                                   f"{a}={la:.3f} vs {b}={lb:.3f} Gb/s, "
                                   f"mismatch {mis:.2f}% > {LOAD_GATE_PCT}%")
        return reasons

    def load_void_reason(self, a, b):
        """Gate B matched-load gates for one comparison: absolute plausibility
        of both conditions, then the pairwise 1.5% gate per block."""
        if self.mode not in ("fixedload", "fixedload_cpu"):
            return None
        reason = self.abs_load_reason((a, b))
        if reason:
            return reason
        for blk in self.blocks:
            la = float(self.row(blk, a)["load_window_gbps"])
            lb = float(self.row(blk, b)["load_window_gbps"])
            mis = 100 * abs(la - lb) / ((la + lb) / 2)
            if mis > LOAD_GATE_PCT:
                return (f"pairwise load gate: block {blk} {a}={la:.3f} vs "
                        f"{b}={lb:.3f} Gb/s, mismatch {mis:.2f}% > {LOAD_GATE_PCT}%")
        return None

    def dmesg_void_reason(self, conds):
        """CPU-only reliability gate: a kernel warning during any involved run
        voids CPU inference (legacy modes keep dmesg as a reported field)."""
        if self.mode != "fixedload_cpu":
            return None
        for blk in self.blocks:
            for c in conds:
                if int(float(self.row(blk, c)["dmesg_new"])) > 0:
                    return (f"dmesg gate: block {blk} cond {c} logged kernel "
                            f"warnings during the window")
        return None

    def interaction_void_reason(self, metric):
        """The interaction is gated on its ACTUAL components:
        bsteal4-steal4 and both-off (second audit blocker)."""
        for a, b in INTERACTION_COMPONENTS:
            reason = self.load_void_reason(a, b)
            if reason:
                return f"component {a}-{b} failed its load gate — {reason}"
        reason = self.dmesg_void_reason(CONDS)
        if reason:
            return reason
        if metric.endswith("_us"):
            reason = self.latency_void_reason(metric, CONDS)
            if reason:
                return reason
        return None

    def latency_void_reason(self, metric, conds):
        for blk in self.blocks:
            for c in conds:
                r = self.row(blk, c)
                sent = float(r["valid_sent_msgs"])
                drop = float(r["valid_dropped_msgs"])
                loss = 100 * drop / sent
                if loss > MAX_LOSS_PCT:
                    return (f"loss gate: block {blk} cond {c} valid-period UDP "
                            f"loss {loss:.2f}% > {MAX_LOSS_PCT}%")
                need = MIN_OBS_P999 if metric == "p999_half_rtt_us" else MIN_OBS_OTHER
                if float(r["lat_n"]) < need:
                    return (f"support gate: block {blk} cond {c} lat_n="
                            f"{int(float(r['lat_n']))} < {need} required for {metric}")
        return None

    def deltas_for(self, metric, a, b):
        return [self.metric(metric, blk, a) - self.metric(metric, blk, b)
                for blk in self.blocks]

    def interaction_deltas(self, metric):
        return [(self.metric(metric, blk, "bsteal4") - self.metric(metric, blk, "steal4"))
                - (self.metric(metric, blk, "both") - self.metric(metric, blk, "off"))
                for blk in self.blocks]

    def report_line(self, label, deltas, base_mean, fav, tag, p_adj=None):
        n = len(deltas)
        rel = 100 * st.mean(deltas) / base_mean
        if self.smoke:
            print(f"  {label:<18} n={n}  mean {st.mean(deltas):+.4f} ({rel:+.2f}%)"
                  f"  [descriptive only — smoke]")
            print(f"    {'deltas:':<10} {fmt_deltas(deltas)}")
            return None
        obs, p = signflip_p(deltas)
        lo, hi = boot_ci(deltas, self.rng)
        pos = sum(1 for d in deltas if d > 0)
        neg = sum(1 for d in deltas if d < 0)
        zero = n - pos - neg
        direction = ("favorable" if obs * fav > 0 else
                     "unfavorable" if obs * fav < 0 else "zero")
        adj = f"  p_holm={p_adj:.4f}" if p_adj is not None else ""
        print(f"  {label:<18} n={n}  mean {obs:+.4f} ({rel:+.2f}%)  "
              f"median {st.median(deltas):+.4f}  CI95 [{lo:+.4f},{hi:+.4f}]  "
              f"+{pos}/-{neg}/0:{zero}  p={p:.4f}{adj}  [{tag}, {direction}]")
        print(f"    {'deltas:':<10} {fmt_deltas(deltas)}")
        return obs, p

    def void_line(self, label, reason):
        self.voided = True
        print(f"  {label:<18} VOID — {reason}")
        print(f"    inference suppressed; raw rows remain in the artifact")


def analyze(path, mode_flag=None, blocks_override=None, smoke=False,
            target=TARGET_LOAD_GBPS, cpu_only=False):
    """Returns exit status: 0 ok, 2 validity gates voided something.
    Raises Invalid for unusable artifacts (caller exits 1)."""
    mode, blocks, table, src = load_artifact(path, mode_flag, blocks_override,
                                             cpu_only)
    an = Analysis(mode, blocks, table, smoke, target)
    n = len(blocks)
    if smoke:
        print(f"=== {SMOKE_MARK} ===")
    print(f"{path}  (mode {mode}, srcversion {src}, {n} complete blocks)")
    print(f"structure OK: {n} block(s) x 4 conditions, one row each, "
          f"positions 1-4, knob readbacks match labels (diag={DIAG_EXPECT[mode]}, "
          f"delay=0, trig_k=0), raw refs named correctly")
    if not smoke:
        print(f"exact sign-flip p floor with {n} blocks: 2/{1 << n} = "
              f"{2 / (1 << n):.6g} — do not read finer resolution into the output")
    print()

    if mode == "confirm":
        metrics = ["gbps", "total_busy_ce", "eff_gbps_per_ce"]
        summary = metrics
    elif mode == "fixedload_cpu":
        metrics = ["total_busy_ce"]      # the ONLY inferential metric
        summary = ["total_busy_ce", "softirq_ce", "system_ce"]
    else:
        metrics = ["total_busy_ce", "softirq_ce",
                   "p99_half_rtt_us", "p999_half_rtt_us",
                   "p90_half_rtt_us", "p50_half_rtt_us"]
        summary = metrics

    print(f"{'cond':>8} " + " ".join(f"{m:>18}" for m in summary))
    for c in CONDS:
        cells = [f"{st.mean([an.metric(m, b, c) for b in blocks]):>18.4f}"
                 for m in summary]
        print(f"{c:>8} " + " ".join(cells))
    if mode == "fixedload_cpu":
        print("  (softirq_ce / system_ce / per-core / diag counters are "
              "DESCRIPTIVE only in CPU-only mode)")

    if mode in ("fixedload", "fixedload_cpu"):
        means = {c: st.mean([float(an.row(b, c)['load_window_gbps'])
                             for b in blocks]) for c in CONDS}
        print(f"\nexact-window load (wg0 rx_bytes over T0-T1), target "
              f"{target} Gb/s +-{ABS_LOAD_TOL_PCT}%: " +
              " ".join(f"{c}={means[c]:.3f}" for c in CONDS) +
              f"  — absolute + pairwise {LOAD_GATE_PCT}% gates applied per "
              f"comparison below")

    # CPU-only campaign-level reliability preflight (audit §1/§7): any
    # absolute-load, paired-load or dmesg failure anywhere in the campaign
    # suppresses ALL inference — no primary verdict, no secondary p-values,
    # no interaction, no CIs, no reduced Holm family. Descriptive artifact
    # information above/below is allowed; inferential output is not.
    if mode == "fixedload_cpu":
        reasons = an.campaign_void_reasons()
        if reasons:
            print(f"\nCAMPAIGN VOID — {len(reasons)} reliability failure(s); "
                  f"fail-closed policy suppresses every inferential result:")
            for r_ in reasons:
                print(f"  VOID — {r_}")
            print("\ndescriptive diag counters (per-window means; classifier "
                  "comparable only where wg_supp is off — off, steal4):")
            for c in CONDS:
                un = st.mean([float(an.row(b, c)["unc_n"]) for b in blocks])
                sp = st.mean([float(an.row(b, c)["steal_pulled"])
                              for b in blocks])
                print(f"  {c:>8}: unc_n {un:>12,.0f}   steal_pulled {sp:>12,.0f}")
            if smoke:
                print(f"\n=== {SMOKE_MARK} — no scientific verdict is implied ===")
            return 2

    verdict = {}
    for metric in metrics:
        fav = FAVOR[metric]
        is_lat = metric.endswith("_us")
        fam_primary = ((mode == "confirm" and metric in ("gbps", "total_busy_ce"))
                       or (mode == "fixedload" and metric == "total_busy_ce")
                       or (mode == "fixedload_cpu" and metric == "total_busy_ce")
                       or (mode == "fixedload" and metric == "p99_half_rtt_us"))
        print(f"\n{metric} — within-block paired deltas "
              f"(favorable direction: {'+' if fav > 0 else '-'}):")
        base = {b_: st.mean([an.metric(metric, blk, b_) for blk in blocks])
                for b_ in {b for _, b in COMPS}}

        sec_ps = []
        results = {}
        for a, b in COMPS:
            label = f"{a}-{b}"
            reason = an.load_void_reason(a, b) or an.dmesg_void_reason((a, b))
            if reason is None and is_lat:
                reason = an.latency_void_reason(metric, (a, b))
            if reason:
                an.void_line(label, reason)
                results[(a, b)] = None
                continue
            deltas = an.deltas_for(metric, a, b)
            results[(a, b)] = (deltas, base[b])
            if not smoke and (a, b) in SECONDARY:
                sec_ps.append(((a, b), signflip_p(deltas)[1]))

        i_reason = an.interaction_void_reason(metric)
        ideltas = None
        if i_reason is None:
            ideltas = an.interaction_deltas(metric)
            if not smoke:
                sec_ps.append((("interaction", ""), signflip_p(ideltas)[1]))
        adj = holm(sec_ps) if sec_ps else {}

        for a, b in COMPS:
            label = f"{a}-{b}"
            if results[(a, b)] is None:
                continue
            deltas, bmean = results[(a, b)]
            if (a, b) == ("steal4", "off"):
                tag = "PRIMARY" if fam_primary else ("SECONDARY" if not is_lat
                                                     else "EXPLORATORY")
                r = an.report_line(label, deltas, bmean, fav, tag)
                if not smoke and fam_primary:
                    obs, p = r
                    verdict[metric] = (obs * fav > 0) and (p < 0.05)
            else:
                tag = ("SECONDARY, Holm" if not is_lat or metric == "p99_half_rtt_us"
                       else "EXPLORATORY")
                an.report_line(label, deltas, bmean, fav, tag,
                               p_adj=adj.get((a, b)))
        if ideltas is None:
            an.void_line("interaction", i_reason)
        else:
            base_off = st.mean([an.metric(metric, blk, "off") for blk in blocks])
            an.report_line("interaction", ideltas, base_off, fav,
                           "SECONDARY, Holm", p_adj=adj.get(("interaction", "")))
            if smoke:
                print("    SMOKE MODE: interaction structure validated; no "
                      "inferential interpretation is produced from a "
                      "shortened artifact.")
            else:
                print("    An interaction near zero would be consistent with "
                      "approximate additivity on this metric's scale; a nonzero "
                      "interaction indicates the incremental effect of stealing "
                      "depends on whether the wake-side fixes are active. Read the "
                      "estimate, CI, p and favorable direction above together — "
                      "synergy/antagonism is not declared from the p-value alone.")

    print()
    if smoke:
        dm = max((int(float(r["dmesg_new"])) for r in table.values()
                  if r.get("dmesg_new", "").replace(".", "").isdigit()), default=0)
        print(f"dmesg: max per-run new warnings {dm}")
        print(f"=== {SMOKE_MARK} — no scientific verdict is implied ===")
        return 2 if an.voided else 0

    if mode == "confirm":
        if all(k in verdict for k in ("gbps", "total_busy_ce")):
            ok = verdict["gbps"] and verdict["total_busy_ce"]
            print("GATE A CO-PRIMARY (steal4-off on gbps AND total_busy_ce, both "
                  f"must pass p<0.05 favorably): {'REPLICATED' if ok else 'NOT REPLICATED'}")
        else:
            print("GATE A CO-PRIMARY: VOID — see suppressed comparisons above")
    elif mode == "fixedload_cpu":
        if "total_busy_ce" in verdict:
            print("GATE B PRIMARY (CPU-only: steal4-off on total_busy_ce at "
                  "matched delivered load): "
                  f"{'PASS' if verdict['total_busy_ce'] else 'no favorable effect detected'}")
        else:
            print("GATE B PRIMARY: VOID — a reliability gate suppressed the "
                  "matched-load CPU claim (see VOID lines above)")
        print("\ndescriptive diag counters (per-window means; classifier "
              "comparable only where wg_supp is off — off, steal4):")
        for c in CONDS:
            un = st.mean([float(an.row(b, c)["unc_n"]) for b in blocks])
            sp = st.mean([float(an.row(b, c)["steal_pulled"]) for b in blocks])
            print(f"  {c:>8}: unc_n {un:>12,.0f}   steal_pulled {sp:>12,.0f}")
    else:
        if "total_busy_ce" in verdict:
            print("GATE B PRIMARY (steal4-off on total_busy_ce at matched load): "
                  f"{'PASS' if verdict['total_busy_ce'] else 'no favorable effect detected'}")
        else:
            print("GATE B PRIMARY: VOID — load gate failed, matched-load CPU claim unavailable")
        if "p99_half_rtt_us" in verdict:
            print("LATENCY PRIMARY (steal4-off on p99_half_rtt_us): "
                  f"{'favorable at p<0.05' if verdict['p99_half_rtt_us'] else 'no favorable effect detected'}")
        elif an.voided:
            print("LATENCY PRIMARY: VOID where marked above")

    dm = sum(int(float(r["dmesg_new"])) for r in table.values()
             if r.get("dmesg_new", "").replace(".", "").isdigit())
    worst = max((int(float(r["dmesg_new"])) for r in table.values()
                 if r.get("dmesg_new", "").replace(".", "").isdigit()), default=0)
    print(f"dmesg: any run with warnings? {'YES' if worst > 0 else 'no'} "
          f"(max per-run {worst}, total {dm})")
    return 2 if an.voided else 0


# ---------------------------------------------------------------- selftest
def _write(path, mode, blocks, mutate=None):
    """Synthetic artifact writer. mutate(rows) edits the row-dict list."""
    g = {"off": 4.19, "both": 4.19, "steal4": 4.37, "bsteal4": 4.38}
    ce = {"off": 4.79, "both": 4.76, "steal4": 4.63, "bsteal4": 4.61}
    p99 = {"off": 610.0, "both": 605.0, "steal4": 585.0, "bsteal4": 580.0}
    diag = DIAG_EXPECT[mode]
    kn = {c: f"supp={s};headwake={h};steal={t};diag={diag};delay=0;trig_k=0"
          for c, (s, h, t) in KNOB_EXPECT.items()}
    rng = random.Random(1)
    rows = []
    for b in range(1, blocks + 1):
        drift = rng.gauss(0, 0.04)
        for pos, c in enumerate(CONDS, 1):
            ref = f"iperf_b{b}p{pos}_{c}.json"
            if mode == "fixedload":
                ref += f";sockperf_b{b}p{pos}_{c}.txt"
            r = {"date": "2026-07-20", "srcversion": "ABC", "block": str(b),
                 "position": str(pos), "cond": c, "knobs": kn[c],
                 "softirq_ce": "0.983",
                 "system_ce": f"{ce[c] + drift - 0.03:.3f}",
                 "total_busy_ce": f"{ce[c] + drift:.3f}",
                 "dmesg_new": "0", "raw_ref": ref}
            if mode == "confirm":
                r["gbps"] = f"{g[c] + drift + rng.gauss(0, 0.02):.4f}"
            elif mode == "fixedload_cpu":
                r.update({"cpu_only": "1", "probe_mode": "none",
                          "load_window_gbps": f"{3.8 + rng.gauss(0, 0.005):.4f}",
                          "load_iperf_gbps": "3.58", "window_s": "60.1",
                          "retransmits": "900", "ping_ms": "0.62",
                          "hs_age_s": "12",
                          "unc_n": str(800000 if "steal" not in c else 8000),
                          "unc_total_ns": "5000000000",
                          "steal_pulled": "2000000" if "steal" in c else "0",
                          "steal_unblocked": "30000" if "steal" in c else "0",
                          "steal_dryruns": "1000"})
            else:
                q = p99[c] + drift * 100 + rng.gauss(0, 8)
                r.update({"load_window_gbps": f"{3.8 + rng.gauss(0, 0.005):.4f}",
                          "load_iperf_gbps": "3.79",
                          "total_run_sent_msgs": "120400",
                          "total_run_recv_msgs": "120399",
                          "lat_duration_s": "59.6",
                          "valid_sent_msgs": "119200",
                          "valid_recv_msgs": "119200",
                          "valid_dropped_msgs": "0", "valid_dup_msgs": "0",
                          "valid_ooo_msgs": "0", "lat_n": "119199",
                          "p50_half_rtt_us": "95.0", "p90_half_rtt_us": "180.0",
                          "p99_half_rtt_us": f"{q:.1f}",
                          "p999_half_rtt_us": f"{q * 2.4:.1f}",
                          "max_half_rtt_us": f"{q * 8:.0f}"})
            rows.append(r)
    if mutate:
        mutate(rows)
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    if mode == "fixedload_cpu":
        # emit the linked sidecars the analyzer now requires (audit §5),
        # built from the (possibly mutated) rows so they stay consistent
        with open(path + ".meta", "w") as m:
            m.write("campaign=fixedload_gateB\ncpu_only=1\nprobe_mode=none\n")
            m.write(f"module_srcversion={rows[0]['srcversion']}\n")
            m.write("audited_head=FAKEHEAD\n")
            m.write("harness_gitrev=commit=FAKEHEAD "
                    "branch=cloudlab-receive-path-findings dirty=0\n")
            m.write("application_cap_gbps=3.58\nper_stream_mbit=895\n")
            m.write("delivered_target_metric=wg0_rx_bytes_exact_window\n")
            m.write("delivered_target_gbps=3.8\nabsolute_tolerance_pct=5\n")
            m.write("paired_tolerance_pct=1.5\n")
        with open(path + ".percore", "w") as pfh:
            pfh.write("timestamp block position cond cpu busy_ce "
                      "softirq_ce system_ce\n")
            for r in rows:
                for cpu in ("cpu0", "cpu1"):
                    pfh.write(f"t {r['block']} {r['position']} {r['cond']} "
                              f"{cpu} 0.100 0.010 0.090\n")


def _run(path, blocks=None, smoke=False, cpu_only=False):
    """analyze() with stdout captured -> ('ok'|'void'|'invalid', output)."""
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    try:
        rc = analyze(path, blocks_override=blocks, smoke=smoke,
                     cpu_only=cpu_only)
        return ("void" if rc == 2 else "ok"), buf.getvalue()
    except Invalid as e:
        return "invalid", str(e)
    finally:
        sys.stdout = old


def _run_cli(argv):
    """main() with stdout+stderr captured -> (exit_status, output)."""
    buf, olds = io.StringIO(), (sys.stdout, sys.stderr)
    sys.stdout = sys.stderr = buf
    try:
        return main(list(argv)), buf.getvalue()
    finally:
        sys.stdout, sys.stderr = olds


def selftest():
    td = tempfile.mkdtemp(prefix="analyze_confirm_selftest_")
    fails = []
    count = [0]

    def check(name, expect, got, detail=""):
        count[0] += 1
        ok = got == expect
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: expected {expect!r}, got {got!r}"
              + (f" ({detail[:90]})" if detail and not ok else ""))
        if not ok:
            fails.append(name)

    def art(name, mode, blocks, mutate=None):
        p = os.path.join(td, name + ".csv")
        _write(p, mode, blocks, mutate)
        return p

    # --- valid artifacts and paired machinery
    check("valid gate A", "ok", _run(art("a", "confirm", 12))[0])
    stat, out = _run(art("b", "fixedload", 8))
    check("valid gate B", "ok", stat)
    check("  interaction analyzed when both components valid", True,
          any(l.strip().startswith("interaction") and "VOID" not in l
              for l in out.splitlines()))
    for name, vals, wantp in (("all-positive", [0.1] * 12, "small"),
                              ("all-negative", [-0.1] * 12, "small"),
                              ("all-zero", [0.0] * 12, "not-small"),
                              ("mixed", [0.10, -0.09, 0.11, -0.10, 0.08, -0.12,
                                         0.07, -0.08, 0.09, -0.11, 0.10, -0.06],
                               "not-small")):
        obs, p = signflip_p(vals)
        check(f"sign-flip {name}", wantp, "small" if p < 0.01 else "not-small",
              f"p={p}")
    check("sign-flip all-zero p==1", True, signflip_p([0.0] * 12)[1] == 1.0)

    # --- schema violations -> invalid, exit 1
    def dup(rows): rows.append(dict(rows[0]))
    check("duplicate row", "invalid", _run(art("dup", "confirm", 12, dup))[0])

    def drop_cond(rows): rows[:] = [r for r in rows
                                    if not (r["block"] == "3" and r["cond"] == "both")]
    check("missing condition", "invalid",
          _run(art("miss", "confirm", 12, drop_cond))[0])

    def unk(rows): rows[5]["cond"] = "turbo"
    check("unknown condition", "invalid", _run(art("unk", "confirm", 12, unk))[0])

    check("wrong block count", "invalid", _run(art("short", "confirm", 9))[0])

    def twosrc(rows): rows[7]["srcversion"] = "XYZ"
    check("multiple srcversions", "invalid",
          _run(art("src", "confirm", 12, twosrc))[0])

    def nosrc(rows):
        for r in rows: r["srcversion"] = ""
    check("empty srcversion", "invalid", _run(art("esrc", "confirm", 12, nosrc))[0])

    def nan(rows): rows[4]["gbps"] = "nan"
    check("NaN value", "invalid", _run(art("nan", "confirm", 12, nan))[0])

    def inf(rows): rows[4]["total_busy_ce"] = "inf"
    check("Inf value", "invalid", _run(art("inf", "confirm", 12, inf))[0])

    def bad(rows): rows[4]["gbps"] = "4.2.1"
    check("malformed numeric", "invalid", _run(art("bad", "confirm", 12, bad))[0])

    # --- treatment evidence -> invalid
    def knob(rows):
        for r in rows:
            if r["block"] == "2" and r["cond"] == "steal4":
                r["knobs"] = "supp=0;headwake=0;steal=0;diag=0;delay=0;trig_k=0"
    check("knob/label mismatch", "invalid",
          _run(art("knob", "confirm", 12, knob))[0])

    def eknob(rows): rows[3]["knobs"] = ""
    check("empty knob readback", "invalid",
          _run(art("eknob", "confirm", 12, eknob))[0])

    def nodiag(rows):
        rows[3]["knobs"] = "supp=0;headwake=0;steal=0;delay=0;trig_k=0"
    check("missing diag knob", "invalid",
          _run(art("nodiag", "confirm", 12, nodiag))[0])

    def wdiag_a(rows):
        for r in rows: r["knobs"] = r["knobs"].replace("diag=0", "diag=1")
    check("wrong diag for gate A", "invalid",
          _run(art("wdiaga", "confirm", 12, wdiag_a))[0])

    def wdiag_b(rows):
        for r in rows: r["knobs"] = r["knobs"].replace("diag=1", "diag=0")
    check("wrong diag for gate B", "invalid",
          _run(art("wdiagb", "fixedload", 8, wdiag_b))[0])

    def delay(rows):
        rows[6]["knobs"] = rows[6]["knobs"].replace("delay=0", "delay=1000")
    check("nonzero decrypt delay", "invalid",
          _run(art("delay", "confirm", 12, delay))[0])

    def trig(rows):
        rows[6]["knobs"] = rows[6]["knobs"].replace("trig_k=0", "trig_k=3")
    check("nonzero trig_k", "invalid", _run(art("trig", "confirm", 12, trig))[0])

    # --- gate B counts / evidence -> invalid
    def negdrop(rows): rows[5]["valid_dropped_msgs"] = "-5"
    check("negative dropped count", "invalid",
          _run(art("negd", "fixedload", 8, negdrop))[0])

    def rgts(rows): rows[5]["valid_recv_msgs"] = "119300"  # > valid_sent 119200
    check("recv > sent", "invalid", _run(art("rgts", "fixedload", 8, rgts))[0])

    def latgt(rows): rows[5]["lat_n"] = "200000"  # > valid_recv
    check("lat_n > recv", "invalid", _run(art("latgt", "fixedload", 8, latgt))[0])

    def noref(rows): rows[5]["raw_ref"] = ""
    check("missing raw_ref", "invalid",
          _run(art("noref", "fixedload", 8, noref))[0])

    def badref(rows): rows[5]["raw_ref"] = "iperf_b9p9_off.json"
    check("raw_ref naming mismatch", "invalid",
          _run(art("badref", "fixedload", 8, badref))[0])

    def nodur(rows):
        for r in rows: del r["lat_duration_s"]
    check("missing valid-duration column", "invalid",
          _run(art("nodur", "fixedload", 8, nodur))[0])

    def zdur(rows): rows[5]["lat_duration_s"] = "0"
    check("zero valid duration", "invalid",
          _run(art("zdur", "fixedload", 8, zdur))[0])

    # --- validity gates -> void, exit 2
    def pairmis(rows):
        for r in rows:
            if r["block"] == "4":
                r["load_window_gbps"] = "3.876" if r["cond"] == "steal4" else "3.724"
    stat, out = _run(art("loadmis", "fixedload", 8, pairmis))
    check("paired load mismatch (global means equal)", "void", stat)
    check("  ...voids the CPU primary", True, "GATE B PRIMARY: VOID" in out)

    def i_left(rows):   # bsteal4-steal4 mismatched, both-off untouched
        for r in rows:
            if r["block"] == "2" and r["cond"] == "bsteal4":
                r["load_window_gbps"] = "3.880"
            elif r["block"] == "2" and r["cond"] == "steal4":
                r["load_window_gbps"] = "3.800"
    stat, out = _run(art("ileft", "fixedload", 8, i_left))
    check("interaction VOID via bsteal4-steal4 mismatch", "void", stat)
    check("  ...interaction line is VOID", True,
          any(l.strip().startswith("interaction") and "VOID" in l
              and "bsteal4-steal4" in l for l in out.splitlines()))
    check("  ...both-off still analyzed", True,
          any(l.strip().startswith("both-off") and "p=" in l
              for l in out.splitlines()))

    def i_right(rows):  # both-off mismatched, bsteal4-steal4 untouched
        for r in rows:
            if r["block"] == "5" and r["cond"] == "both":
                r["load_window_gbps"] = "3.880"
            elif r["block"] == "5" and r["cond"] == "off":
                r["load_window_gbps"] = "3.800"
    stat, out = _run(art("iright", "fixedload", 8, i_right))
    check("interaction VOID via both-off mismatch", "void", stat)
    check("  ...interaction line is VOID", True,
          any(l.strip().startswith("interaction") and "VOID" in l
              and "both-off" in l for l in out.splitlines()))
    check("  ...bsteal4-steal4 still analyzed", True,
          any(l.strip().startswith("bsteal4-steal4") and "p=" in l
              for l in out.splitlines()))

    def lowload(rows):  # pairwise equal but nowhere near the 3.8 target
        for r in rows: r["load_window_gbps"] = "2.000"
    stat, out = _run(art("lowload", "fixedload", 8, lowload))
    check("sub-target pairwise-equal load", "void", stat)
    check("  ...absolute gate named in reason", True, "absolute load gate" in out)

    def lossy(rows):
        for r in rows:
            if r["block"] == "2" and r["cond"] == "off":
                r["valid_dropped_msgs"] = "2400"  # 2% of 119200
    stat, out = _run(art("loss", "fixedload", 8, lossy))
    check("UDP loss threshold (valid-period)", "void", stat)
    check("  ...CPU inference retained under loss", True,
          "total_busy_ce — within-block" in out and
          "GATE B PRIMARY (steal4-off" in out)

    def few(rows):
        for r in rows:
            r["lat_n"] = "50000"  # ok for p99, not p99.9
    stat, out = _run(art("few", "fixedload", 8, few))
    check("insufficient p99.9 support", "void", stat)
    check("  ...p99 still analyzed at 50k obs", True,
          "p99_half_rtt_us — within-block" in out)

    # --- CPU-only mode (coordinator-approved gate B redesign, 2026-07-17)
    cpu_full = art("cpu_full", "fixedload_cpu", 8)
    rc, out = _run_cli(["--cpu-only", cpu_full])
    check("valid CPU-only full artifact", 0, rc)
    check("  ...CPU-only primary verdict", True,
          "GATE B PRIMARY (CPU-only" in out)
    check("  ...no latency metrics or verdicts emitted", True,
          "half_rtt" not in out and "LATENCY" not in out)
    check("  ...secondary Holm family present", True, "p_holm=" in out)
    rc, out = _run_cli(["--cpu-only", "--smoke", "--blocks", "1",
                        art("cpu_smoke1", "fixedload_cpu", 1)])
    check("valid CPU-only smoke", 0, rc)
    check("  ...watermarked, descriptive only", True,
          SMOKE_MARK in out and "p=" not in out)
    rc, out = _run_cli(["--cpu-only", art("legacy_as_cpu", "fixedload", 8)])
    check("--cpu-only on legacy sockperf artifact rejected", 1, rc)
    rc, out = _run_cli([cpu_full])
    check("CPU-only artifact without --cpu-only rejected", 1, rc)

    def nomark(rows):
        for r in rows:
            r["cpu_only"] = ""
    check("missing cpu_only marker", "invalid",
          _run(art("nomark", "fixedload_cpu", 8, nomark), cpu_only=True)[0])

    def badprobe(rows):
        rows[3]["probe_mode"] = "sockperf_pingpong"
    check("probe_mode other than none", "invalid",
          _run(art("badprobe", "fixedload_cpu", 8, badprobe), cpu_only=True)[0])

    def nocpu(rows):
        for r in rows:
            del r["total_busy_ce"]
    check("cpu-only missing CPU field", "invalid",
          _run(art("nocpuf", "fixedload_cpu", 8, nocpu), cpu_only=True)[0])

    def badloadc(rows):
        rows[5]["load_window_gbps"] = "4.2.1"
    check("cpu-only malformed load", "invalid",
          _run(art("badloadc", "fixedload_cpu", 8, badloadc), cpu_only=True)[0])

    def cdrop(rows):
        rows[:] = [r for r in rows
                   if not (r["block"] == "2" and r["cond"] == "steal4")]
    check("cpu-only incomplete pairing", "invalid",
          _run(art("cdrop", "fixedload_cpu", 8, cdrop), cpu_only=True)[0])

    def cknob(rows):
        rows[3]["knobs"] = ""
    check("cpu-only malformed treatment", "invalid",
          _run(art("cknob", "fixedload_cpu", 8, cknob), cpu_only=True)[0])

    def csrc(rows):
        for r in rows:
            r["srcversion"] = ""
    check("cpu-only malformed provenance (empty srcversion)", "invalid",
          _run(art("csrc", "fixedload_cpu", 8, csrc), cpu_only=True)[0])

    def cref(rows):
        rows[3]["raw_ref"] = (f"iperf_b{rows[3]['block']}p{rows[3]['position']}"
                              f"_{rows[3]['cond']}.json;sockperf_b"
                              f"{rows[3]['block']}p{rows[3]['position']}"
                              f"_{rows[3]['cond']}.txt")
    check("cpu-only sockperf raw_ref contradiction", "invalid",
          _run(art("cref", "fixedload_cpu", 8, cref), cpu_only=True)[0])

    def suppressed(out):
        """True iff the output contains NO inferential result whatsoever."""
        return ("p=" not in out and "CI95" not in out and "p_holm" not in out
                and "deltas:" not in out and "GATE B PRIMARY" not in out
                and "CAMPAIGN VOID" in out)

    def clow(rows):
        for r in rows:
            r["load_window_gbps"] = "2.000"
    stat, out = _run(art("clow", "fixedload_cpu", 8, clow), cpu_only=True)
    check("cpu-only absolute-load gate", "void", stat)
    check("  ...ALL inference suppressed (no primary/p/CI/Holm)", True,
          suppressed(out))

    def bothbad(rows):   # only 'both' rows fail; steal4-off pair itself valid
        for r in rows:
            if r["cond"] == "both":
                r["load_window_gbps"] = "3.500"
    stat, out = _run(art("bothbad", "fixedload_cpu", 8, bothbad),
                     cpu_only=True)
    check("campaign-invalid 'both' suppresses valid steal4-off primary",
          "void", stat)
    check("  ...no PRIMARY PASS despite valid steal4-off pair", True,
          suppressed(out))

    def cpair(rows):
        for r in rows:
            if r["block"] == "4":
                r["load_window_gbps"] = ("3.876" if r["cond"] == "steal4"
                                         else "3.724")
    stat, out = _run(art("cpair", "fixedload_cpu", 8, cpair), cpu_only=True)
    check("cpu-only paired-load gate", "void", stat)
    check("  ...paired failure also suppresses everything", True,
          suppressed(out))

    def cdm(rows):
        rows[2]["dmesg_new"] = "3"
    stat, out = _run(art("cdm", "fixedload_cpu", 8, cdm), cpu_only=True)
    check("cpu-only dmesg reliability gate", "void", stat)
    check("  ...dmesg gate named in reason", True, "dmesg gate" in out)
    check("  ...dmesg failure suppresses ALL inference", True, suppressed(out))

    # fixed five-test Holm family: ONE failing secondary pair must not shrink
    # the family — the whole campaign voids instead (regression for the
    # reduced-Holm defect)
    def bb_pair(rows):   # bsteal4-both mismatch in block 3, all else valid
        for r in rows:
            if r["block"] == "3" and r["cond"] == "bsteal4":
                r["load_window_gbps"] = "3.830"
            elif r["block"] == "3" and r["cond"] == "both":
                r["load_window_gbps"] = "3.770"
            elif r["block"] == "3":
                r["load_window_gbps"] = "3.800"
    stat, out = _run(art("bb_pair", "fixedload_cpu", 8, bb_pair),
                     cpu_only=True)
    check("one invalid secondary pair -> campaign void", "void", stat)
    check("  ...no reduced Holm family computed", True,
          "p_holm" not in out and suppressed(out))
    check("  ...the failing pair is named", True,
          "bsteal4=3.830 vs both=3.770" in out)

    # absolute-load boundary semantics (inclusive endpoints, audit §6)
    def setload(v):
        def f(rows):
            for r in rows:
                r["load_window_gbps"] = v
        return f
    check("abs-load 3.61 lower endpoint passes", "ok",
          _run(art("b361", "fixedload_cpu", 8, setload("3.61")),
               cpu_only=True)[0])
    check("abs-load 3.99 upper endpoint passes", "ok",
          _run(art("b399", "fixedload_cpu", 8, setload("3.99")),
               cpu_only=True)[0])
    check("abs-load 3.609999 voids", "void",
          _run(art("b360", "fixedload_cpu", 8, setload("3.609999")),
               cpu_only=True)[0])
    check("abs-load 3.990001 voids", "void",
          _run(art("b400", "fixedload_cpu", 8, setload("3.990001")),
               cpu_only=True)[0])

    # window_s evidence (audit §4)
    def no_window(rows):
        for r in rows:
            del r["window_s"]
    check("cpu-only missing window_s", "invalid",
          _run(art("nowin", "fixedload_cpu", 8, no_window), cpu_only=True)[0])

    def zero_window(rows):
        rows[4]["window_s"] = "0"
    check("cpu-only window_s=0", "invalid",
          _run(art("zwin", "fixedload_cpu", 8, zero_window), cpu_only=True)[0])

    # exact block IDs (audit §3)
    def shift_blocks(rows):
        for r in rows:
            r["block"] = str(int(r["block"]) + 1)   # 2..9: eight labels, wrong ids
    check("cpu-only blocks 2..9 rejected", "invalid",
          _run(art("shift", "fixedload_cpu", 8, shift_blocks),
               cpu_only=True)[0])

    def nonint_block(rows):
        for r in rows:
            if r["block"] == "5":
                r["block"] = "b5"
    check("cpu-only non-integral block label rejected", "invalid",
          _run(art("nonint", "fixedload_cpu", 8, nonint_block),
               cpu_only=True)[0])
    # (exact blocks 1..8 accepted is proven by the valid-full test above)

    # sidecar linkage (audit §5)
    p_ = art("meta_gone", "fixedload_cpu", 8)
    os.remove(p_ + ".meta")
    check("cpu-only missing .meta sidecar", "invalid",
          _run(p_, cpu_only=True)[0])

    p_ = art("meta_contra", "fixedload_cpu", 8)
    with open(p_ + ".meta") as fh:
        txt = fh.read()
    with open(p_ + ".meta", "w") as fh:
        fh.write(txt.replace("module_srcversion=ABC", "module_srcversion=XYZ"))
    check("meta/CSV srcversion contradiction", "invalid",
          _run(p_, cpu_only=True)[0])

    p_ = art("pc_gone", "fixedload_cpu", 8)
    os.remove(p_ + ".percore")
    check("cpu-only missing .percore sidecar", "invalid",
          _run(p_, cpu_only=True)[0])

    p_ = art("pc_contra", "fixedload_cpu", 8)
    with open(p_ + ".percore") as fh:
        pls = fh.readlines()
    pls[1] = pls[1].replace(" off ", " both ")
    with open(p_ + ".percore", "w") as fh:
        fh.writelines(pls)
    check("percore/CSV condition contradiction", "invalid",
          _run(p_, cpu_only=True)[0])

    # exact metadata identity (fourth audit §1): edit one .meta line, expect
    # exit 1 with zero inference
    def meta_case(name, old, new):
        p = art(name, "fixedload_cpu", 8)
        with open(p + ".meta") as fh:
            txt = fh.read()
        assert old in txt, f"selftest fixture bug: {old!r} not in meta"
        with open(p + ".meta", "w") as fh:
            fh.write(txt.replace(old, new))
        return _run(p, cpu_only=True)

    check("meta application_cap_gbps mismatch", "invalid",
          meta_case("m_cap", "application_cap_gbps=3.58",
                    "application_cap_gbps=9.9")[0])
    check("meta per_stream_mbit mismatch", "invalid",
          meta_case("m_psm", "per_stream_mbit=895", "per_stream_mbit=950")[0])
    check("meta delivered_target_gbps mismatch", "invalid",
          meta_case("m_tgt", "delivered_target_gbps=3.8",
                    "delivered_target_gbps=2.0")[0])
    check("meta absolute_tolerance mismatch", "invalid",
          meta_case("m_atol", "absolute_tolerance_pct=5",
                    "absolute_tolerance_pct=99")[0])
    check("meta paired_tolerance mismatch", "invalid",
          meta_case("m_ptol", "paired_tolerance_pct=1.5",
                    "paired_tolerance_pct=99")[0])
    check("meta whitespace-padded value", "invalid",
          meta_case("m_ws", "delivered_target_gbps=3.8",
                    "delivered_target_gbps= 3.8")[0])
    check("meta duplicate contradictory identity field", "invalid",
          meta_case("m_dup", "application_cap_gbps=3.58",
                    "application_cap_gbps=3.58\napplication_cap_gbps=9.9")[0])

    # canonical harness_gitrev (fourth audit §2)
    _G = ("harness_gitrev=commit=FAKEHEAD "
          "branch=cloudlab-receive-path-findings dirty=0")
    stat, out = _run(art("g_ok", "fixedload_cpu", 8), cpu_only=True)
    check("canonical harness_gitrev accepted", "ok", stat)
    check("meta wrong-branch gitrev rejected", "invalid",
          meta_case("g_branch", _G,
                    "harness_gitrev=commit=FAKEHEAD branch=main dirty=0")[0])
    check("meta dirty=1 gitrev rejected", "invalid",
          meta_case("g_dirty", _G,
                    "harness_gitrev=commit=FAKEHEAD "
                    "branch=cloudlab-receive-path-findings dirty=1")[0])
    check("meta wrong-commit gitrev rejected", "invalid",
          meta_case("g_commit", _G,
                    "harness_gitrev=commit=OTHERHEAD "
                    "branch=cloudlab-receive-path-findings dirty=0")[0])
    check("meta extra-token gitrev rejected", "invalid",
          meta_case("g_extra", _G, _G + " extra=1")[0])
    check("meta duplicate gitrev field rejected", "invalid",
          meta_case("g_dupline", _G, _G + "\n" + _G)[0])

    # per-core value semantics (fourth audit §3)
    def pc_case(name, repl):
        p = art(name, "fixedload_cpu", 8)
        with open(p + ".percore") as fh:
            lines = fh.readlines()
        lines[1] = lines[1].replace("0.100", repl)
        with open(p + ".percore", "w") as fh:
            fh.writelines(lines)
        return _run(p, cpu_only=True)

    check("percore zero value accepted", "ok", pc_case("pc_zero", "0.000")[0])
    check("percore nan rejected", "invalid", pc_case("pc_nan", "nan")[0])
    check("percore inf rejected", "invalid", pc_case("pc_inf", "inf")[0])
    check("percore -inf rejected", "invalid", pc_case("pc_ninf", "-inf")[0])
    check("percore negative rejected", "invalid",
          pc_case("pc_neg", "-0.100")[0])

    # CPU-only smoke block contract (fourth audit §4)
    rc, out = _run_cli(["--cpu-only", "--smoke", "--blocks", "2",
                        art("sm2", "fixedload_cpu", 2)])
    check("cpu-only smoke --blocks 2 rejected", 1, rc)
    rc, out = _run_cli(["--cpu-only", "--smoke",
                        art("sm_nb", "fixedload_cpu", 1)])
    check("cpu-only smoke without --blocks rejected", 1, rc)

    def blk2(rows):
        for r in rows:
            r["block"] = "2"
    check("cpu-only smoke block ID 2 rejected", "invalid",
          _run(art("sm_id2", "fixedload_cpu", 1, blk2), blocks=1,
               smoke=True, cpu_only=True)[0])

    # legacy gate B keeps its original absolute-load wording (fourth audit §5)
    def leg_low(rows):
        for r in rows:
            r["load_window_gbps"] = "2.000"
    stat, out = _run(art("leg_low", "fixedload", 8, leg_low))
    check("legacy abs-load wording restored", True,
          "is 47.4% from the 3.8 Gb/s target (> 5.0%)" in out
          and "allowed [" not in out, out[:200])

    # known-value interaction construction: (bsteal4-steal4)-(both-off)
    tbl_ = {("1", "off"): {"total_busy_ce": "1.5"},
            ("1", "both"): {"total_busy_ce": "2.0"},
            ("1", "steal4"): {"total_busy_ce": "3.0"},
            ("1", "bsteal4"): {"total_busy_ce": "4.0"}}
    an_ = Analysis("confirm", ["1"], tbl_, False, TARGET_LOAD_GBPS)
    check("interaction known-value: (4-3)-(2-1.5) = 0.5", True,
          abs(an_.interaction_deltas("total_busy_ce")[0] - 0.5) < 1e-12)

    # campaign-void smoke stays descriptive and fails closed
    rc, out = _run_cli(["--cpu-only", "--smoke", "--blocks", "1",
                        art("cpu_smoke_void", "fixedload_cpu", 1,
                            setload("2.0"))])
    check("cpu-only smoke fails closed on reliability gates", 2, rc)
    check("  ...smoke void watermarked, no inference", True,
          SMOKE_MARK in out and "p=" not in out and "CAMPAIGN VOID" in out)

    # legacy latency mode must be untouched by the CPU-only additions
    stat, out = _run(art("legacy_regress", "fixedload", 8))
    check("legacy fixedload mode unchanged", "ok", stat)
    check("  ...legacy latency verdict still present", True,
          "LATENCY PRIMARY" in out)

    # --- smoke CLI semantics
    one_a = art("smoke1", "confirm", 1)
    rc, out = _run_cli(["--blocks", "1", one_a])
    check("--blocks 1 without --smoke rejected", 1, rc)
    rc, out = _run_cli(["--smoke", "--blocks", "1", one_a])
    check("--smoke --blocks 1 exits 0", 0, rc)
    check("  ...watermarked", True, SMOKE_MARK in out)
    check("  ...no scientific verdict", True,
          "REPLICATED" not in out and "PASS" not in out and "p=" not in out)
    check("  ...smoke interaction note, no final guidance", True,
          "SMOKE MODE: interaction structure validated" in out
          and "synergy/antagonism" not in out)
    rc, out = _run_cli([one_a, art("smoke1dup", "confirm", 1)])
    check("two positional artifacts rejected", 1, rc)
    check("  ...names the ambiguity", True, "expected exactly one artifact" in out)
    one_b = art("smoke1b", "fixedload", 1)
    rc, out = _run_cli(["--smoke", "--blocks", "1", one_b])
    check("gate B smoke exits 0 + watermark", True, rc == 0 and SMOKE_MARK in out)
    rc, out = _run_cli([art("final", "confirm", 12)])
    check("final block count -> normal analysis", True,
          rc == 0 and "GATE A CO-PRIMARY" in out and SMOKE_MARK not in out)

    print(f"\nselftest: {count[0]} checks, "
          f"{'ALL PASS' if not fails else 'FAILURES: ' + ', '.join(fails)}")
    return 0 if not fails else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    smoke = "--smoke" in argv
    if smoke:
        argv.remove("--smoke")
    cpu_only = "--cpu-only" in argv
    if cpu_only:
        argv.remove("--cpu-only")
    mode_flag, blocks, target = None, None, TARGET_LOAD_GBPS
    for flag, cast in (("--mode", str), ("--blocks", int), ("--target-load", float)):
        if flag in argv:
            i = argv.index(flag)
            try:
                val = cast(argv[i + 1])
            except (IndexError, ValueError):
                print(f"bad value for {flag}", file=sys.stderr)
                return 1
            if flag == "--mode":
                mode_flag = val
            elif flag == "--blocks":
                blocks = val
            else:
                target = val
            del argv[i:i + 2]
    if blocks is not None and not smoke:
        print(f"--blocks {blocks} without --smoke is refused: a shortened "
              f"artifact must never produce final-looking analysis. Add "
              f"--smoke for structural validation.", file=sys.stderr)
        return 1
    if cpu_only and smoke and blocks != 1:
        # fourth audit §4: the CPU-only smoke contract is exactly one block,
        # requested explicitly — anything else (omitted, 2, ...) is refused
        print(f"--cpu-only --smoke requires an explicit --blocks 1 "
              f"(got {'omitted' if blocks is None else blocks}): the CPU-only "
              f"smoke contract is exactly one block", file=sys.stderr)
        return 1
    if len(argv) != 1:
        if len(argv) > 1:
            print(f"expected exactly one artifact, got {len(argv)}: {argv} — "
                  f"a glob matched several CSVs; select one explicitly "
                  f"(newest: ls -1t ... | head -n1)", file=sys.stderr)
        else:
            print("usage: analyze_confirm.py [--mode confirm|fixedload] "
                  "[--cpu-only] [--smoke [--blocks N]] [--target-load G] "
                  "<artifact.csv> | --selftest",
                  file=sys.stderr)
        return 1
    try:
        return analyze(argv[0], mode_flag=mode_flag, blocks_override=blocks,
                       smoke=smoke, target=target, cpu_only=cpu_only)
    except Invalid as e:
        print(f"INVALID ARTIFACT — no inference printed.\n{e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"cannot read artifact: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
