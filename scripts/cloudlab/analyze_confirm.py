#!/usr/bin/env python3
"""Phase D confirmation — fail-closed paired within-block analysis.

Handles BOTH gate artifacts (mode autodetected from the CSV header, and
cross-checked against --mode when given):
  confirm_*.csv    gate A: uncapped single-tunnel replication of Finding 8
  fixedload_*.csv  gate B: matched-load CPU + same-tunnel tail latency

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
DIAG_EXPECT = {"confirm": 0, "fixedload": 1}
EXPECT_BLOCKS = {"confirm": 12, "fixedload": 8}
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


def load_artifact(path, mode_flag=None, blocks_override=None):
    with open(path) as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        raise Invalid(f"{path}: empty artifact")
    mode = "fixedload" if "p999_half_rtt_us" in rows[0] else "confirm"
    if mode_flag and mode_flag != mode:
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

    blocks = sorted({b for b, _ in table}, key=lambda x: int(x))
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

    def abs_load_reason(self, conds):
        """Gate B absolute plausibility: every involved row must sit at the
        intended operating point, not merely match its partner."""
        if self.mode != "fixedload":
            return None
        for blk in self.blocks:
            for c in conds:
                l = float(self.row(blk, c)["load_window_gbps"])
                dev = 100 * abs(l - self.target) / self.target
                if dev > ABS_LOAD_TOL_PCT:
                    return (f"absolute load gate: block {blk} cond {c} "
                            f"{l:.3f} Gb/s is {dev:.1f}% from the "
                            f"{self.target} Gb/s target (> {ABS_LOAD_TOL_PCT}%)"
                            f" — not the predeclared regime")
        return None

    def load_void_reason(self, a, b):
        """Gate B matched-load gates for one comparison: absolute plausibility
        of both conditions, then the pairwise 1.5% gate per block."""
        if self.mode != "fixedload":
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

    def interaction_void_reason(self, metric):
        """The interaction is gated on its ACTUAL components:
        bsteal4-steal4 and both-off (second audit blocker)."""
        for a, b in INTERACTION_COMPONENTS:
            reason = self.load_void_reason(a, b)
            if reason:
                return f"component {a}-{b} failed its load gate — {reason}"
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
            target=TARGET_LOAD_GBPS):
    """Returns exit status: 0 ok, 2 validity gates voided something.
    Raises Invalid for unusable artifacts (caller exits 1)."""
    mode, blocks, table, src = load_artifact(path, mode_flag, blocks_override)
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

    metrics = (["gbps", "total_busy_ce", "eff_gbps_per_ce"] if mode == "confirm"
               else ["total_busy_ce", "softirq_ce",
                     "p99_half_rtt_us", "p999_half_rtt_us",
                     "p90_half_rtt_us", "p50_half_rtt_us"])

    print(f"{'cond':>8} " + " ".join(f"{m:>18}" for m in metrics))
    for c in CONDS:
        cells = [f"{st.mean([an.metric(m, b, c) for b in blocks]):>18.4f}"
                 for m in metrics]
        print(f"{c:>8} " + " ".join(cells))

    if mode == "fixedload":
        means = {c: st.mean([float(an.row(b, c)['load_window_gbps'])
                             for b in blocks]) for c in CONDS}
        print(f"\nexact-window load (wg0 rx_bytes over T0-T1), target "
              f"{target} Gb/s +-{ABS_LOAD_TOL_PCT}%: " +
              " ".join(f"{c}={means[c]:.3f}" for c in CONDS) +
              f"  — absolute + pairwise {LOAD_GATE_PCT}% gates applied per "
              f"comparison below")

    verdict = {}
    for metric in metrics:
        fav = FAVOR[metric]
        is_lat = metric.endswith("_us")
        fam_primary = ((mode == "confirm" and metric in ("gbps", "total_busy_ce"))
                       or (mode == "fixedload" and metric == "total_busy_ce")
                       or (mode == "fixedload" and metric == "p99_half_rtt_us"))
        print(f"\n{metric} — within-block paired deltas "
              f"(favorable direction: {'+' if fav > 0 else '-'}):")
        base = {b_: st.mean([an.metric(metric, blk, b_) for blk in blocks])
                for b_ in {b for _, b in COMPS}}

        sec_ps = []
        results = {}
        for a, b in COMPS:
            label = f"{a}-{b}"
            reason = an.load_void_reason(a, b)
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


def _run(path, blocks=None, smoke=False):
    """analyze() with stdout captured -> ('ok'|'void'|'invalid', output)."""
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    try:
        rc = analyze(path, blocks_override=blocks, smoke=smoke)
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
    if len(argv) != 1:
        if len(argv) > 1:
            print(f"expected exactly one artifact, got {len(argv)}: {argv} — "
                  f"a glob matched several CSVs; select one explicitly "
                  f"(newest: ls -1t ... | head -n1)", file=sys.stderr)
        else:
            print("usage: analyze_confirm.py [--mode confirm|fixedload] "
                  "[--smoke [--blocks N]] [--target-load G] <artifact.csv> | --selftest",
                  file=sys.stderr)
        return 1
    try:
        return analyze(argv[0], mode_flag=mode_flag, blocks_override=blocks,
                       smoke=smoke, target=target)
    except Invalid as e:
        print(f"INVALID ARTIFACT — no inference printed.\n{e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"cannot read artifact: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
