#!/usr/bin/env python3
"""Phase D confirmation — fail-closed paired within-block analysis.

Handles BOTH gate artifacts (mode autodetected from the CSV header):
  confirm_*.csv    gate A: uncapped single-tunnel replication of Finding 8
  fixedload_*.csv  gate B: matched-load CPU + same-tunnel tail latency

FAIL-CLOSED VALIDATION (coordinator audit 2026-07-16). Before ANY statistics
are printed, the artifact must have: the exact expected block count (gate A
12, gate B 8; override with --blocks N only for deliberately shortened runs),
exactly one row per (block, condition), only the four known conditions, a
single srcversion, knob readbacks that MATCH the row's condition label (a
mislabeled treatment is unrecoverable after the fact), and finite, positive-
where-required numeric values. Any violation aborts with a message and exit
status 1 — no inference is printed from partially valid data, no block is
silently dropped, no missing value becomes zero.

VALIDITY GATES (exit status 2 when any fires; the affected inference is
replaced by a VOID line, never printed underneath a warning):
  load gate (gate B)   for every comparison, every within-block pair must
                       satisfy |load_a - load_b| / pair_mean <= 1.5% on
                       load_window_gbps (the exact T0-T1 wg0 rx_bytes load).
                       One failing pair voids the whole comparison for CPU
                       and latency (dropping just that block would be silent
                       data selection).
  loss gate (gate B)   dropped/sent > 1.0% on any involved row voids the
                       comparison's LATENCY metrics (condition-dependent UDP
                       loss can fake a tail improvement); CPU is retained.
  support gate         p99.9 inference requires >= 100000 valid observations
                       on every involved row (~100 obs in the top 0.1%);
                       p50/p90/p99 require >= 10000.

ENDPOINTS AND MULTIPLICITY (declared before the runs):
  Gate A co-primary    steal4-off on gbps (favorable: +) AND on total_busy_ce
                       (favorable: -): the Finding 8 headline REPLICATES only
                       if BOTH pass sign-flip p < 0.05 in the favorable
                       direction. Efficiency (gbps per busy CE) is secondary.
  Gate B primary       steal4-off on total_busy_ce at matched load.
  Latency primary      steal4-off on p99_half_rtt_us (gate B); all other
                       latency numbers are EXPLORATORY.
  Secondary family     both-off, bsteal4-steal4, bsteal4-both, bsteal4-off,
                       and the 2x2 interaction (bsteal4-steal4)-(both-off),
                       Holm-corrected within the family per metric.
  A large p-value is reported as "no incremental effect detected", never as
  proof of redundancy/equivalence (no equivalence margin was predeclared).

STATS: exact sign-flip test on within-block deltas (audited; unchanged).
Floors: 12 blocks -> 2/4096 ~= 0.000488; 8 blocks -> 2/256 = 0.0078125 —
do not read finer resolution into smaller-looking output. Paired bootstrap
95% CI on the mean delta (10000 resamples of blocks, fixed seed 20260716).
sockperf ping-pong values are HALF-RTT (columns are named accordingly).
The classifier columns (unc_*) are only comparable between conditions that
leave wg_supp off (off, steal4).

Usage:
  python3 scripts/cloudlab/analyze_confirm.py data/cloudlab/confirm_<TS>.csv
  python3 scripts/cloudlab/analyze_confirm.py data/cloudlab/fixedload_<TS>.csv
  python3 scripts/cloudlab/analyze_confirm.py --selftest
Exit status: 0 valid + all gates passed; 1 invalid artifact (no inference);
2 artifact valid but at least one validity gate voided an inference.
"""
import csv
import io
import math
import os
import random
import statistics as st
import sys
import tempfile

CONDS = ["off", "both", "steal4", "bsteal4"]
KNOB_EXPECT = {"off": (0, 0, 0), "both": (1, 1, 0),
               "steal4": (0, 0, 4), "bsteal4": (1, 1, 4)}
EXPECT_BLOCKS = {"confirm": 12, "fixedload": 8}
# (label, family): families are 'primary', 'secondary' (Holm), 'exploratory'
COMPS = [("steal4", "off"), ("both", "off"), ("bsteal4", "steal4"),
         ("bsteal4", "both"), ("bsteal4", "off")]
SECONDARY = [("both", "off"), ("bsteal4", "steal4"),
             ("bsteal4", "both"), ("bsteal4", "off")]
LOAD_GATE_PCT = 1.5
MAX_LOSS_PCT = 1.0
MIN_OBS_P999 = 100_000
MIN_OBS_OTHER = 10_000
BOOT_N = 10_000
SEED = 20260716

# metric -> favorable sign of the (a-b) delta: +1 more is better, -1 less is
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


def load_artifact(path, blocks_override=None):
    with open(path) as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        raise Invalid(f"{path}: empty artifact")
    mode = "fixedload" if "p999_half_rtt_us" in rows[0] else "confirm"
    want = blocks_override or EXPECT_BLOCKS[mode]

    src = {r.get("srcversion") for r in rows}
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
                      f"(use --blocks N only for a deliberately shortened run)")
    for b in blocks:
        missing = [c for c in CONDS if (b, c) not in table]
        if missing:
            raise Invalid(f"block {b}: missing condition(s) {missing}")

    for (b, c), r in table.items():
        ctx = f"block {b} cond {c}"
        knobs = r.get("knobs", "")
        if knobs:
            try:
                kv = dict(p.split("=", 1) for p in knobs.split(";"))
                got = (int(kv["supp"]), int(kv["headwake"]), int(kv["steal"]))
            except (ValueError, KeyError):
                raise Invalid(f"{ctx}: unparseable knobs field {knobs!r}")
            if got != KNOB_EXPECT[c]:
                raise Invalid(f"{ctx}: knob readback (supp,headwake,steal)="
                              f"{got} != expected {KNOB_EXPECT[c]} — "
                              f"MISLABELED TREATMENT, artifact unusable")
        req = [("softirq_ce", True), ("system_ce", True), ("total_busy_ce", True)]
        if mode == "confirm":
            req += [("gbps", True)]
        else:
            req += [("load_window_gbps", True), ("sent_msgs", True),
                    ("recv_msgs", True), ("dropped_msgs", False),
                    ("lat_n", True), ("p50_half_rtt_us", True),
                    ("p90_half_rtt_us", True), ("p99_half_rtt_us", True),
                    ("p999_half_rtt_us", True)]
        for k, pos in req:
            fnum(r, k, ctx, positive=pos)
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
    """pairs: list of (key, p). Returns {key: p_holm} (step-down, capped at 1,
    monotone)."""
    m = len(pairs)
    adj, running = {}, 0.0
    for rank, (key, p) in enumerate(sorted(pairs, key=lambda kp: kp[1])):
        running = max(running, min(1.0, (m - rank) * p))
        adj[key] = running
    return adj


def fmt_deltas(deltas):
    return " ".join(f"{d:+.4g}" for d in deltas)


class Analysis:
    def __init__(self, mode, blocks, table):
        self.mode, self.blocks, self.table = mode, blocks, table
        self.rng = random.Random(SEED)
        self.voided = False

    def row(self, b, c):
        return self.table[(b, c)]

    def metric(self, name, b, c):
        r = self.row(b, c)
        if name == "eff_gbps_per_ce":
            return float(r["gbps"]) / float(r["total_busy_ce"])
        return float(r[name])

    def load_void_reason(self, a, b):
        """Gate B pairwise load gate: any failing pair voids the comparison."""
        if self.mode != "fixedload":
            return None
        for blk in self.blocks:
            la = float(self.row(blk, a)["load_window_gbps"])
            lb = float(self.row(blk, b)["load_window_gbps"])
            mis = 100 * abs(la - lb) / ((la + lb) / 2)
            if mis > LOAD_GATE_PCT:
                return (f"load gate: block {blk} {a}={la:.3f} vs {b}={lb:.3f} "
                        f"Gb/s, mismatch {mis:.2f}% > {LOAD_GATE_PCT}%")
        return None

    def latency_void_reason(self, metric, conds):
        """Loss and sample-support gates for a latency metric."""
        for blk in self.blocks:
            for c in conds:
                r = self.row(blk, c)
                sent, drop = float(r["sent_msgs"]), float(r["dropped_msgs"])
                loss = 100 * drop / sent if sent else 100.0
                if loss > MAX_LOSS_PCT:
                    return (f"loss gate: block {blk} cond {c} UDP loss "
                            f"{loss:.2f}% > {MAX_LOSS_PCT}%")
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
        obs, p = signflip_p(deltas)
        lo, hi = boot_ci(deltas, self.rng)
        pos = sum(1 for d in deltas if d > 0)
        neg = sum(1 for d in deltas if d < 0)
        zero = n - pos - neg
        direction = ("favorable" if obs * fav > 0 else
                     "unfavorable" if obs * fav < 0 else "zero")
        rel = 100 * obs / base_mean
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


def analyze(path, blocks_override=None):
    """Returns exit status: 0 ok, 2 validity gates voided something.
    Raises Invalid for unusable artifacts (caller exits 1)."""
    mode, blocks, table, src = load_artifact(path, blocks_override)
    an = Analysis(mode, blocks, table)
    n = len(blocks)
    print(f"{path}  (mode {mode}, srcversion {src}, {n} complete blocks)")
    print(f"exact sign-flip p floor with {n} blocks: 2/{1 << n} = {2 / (1 << n):.6g} "
          f"— do not read finer resolution into the output\n")

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
        print("\nexact-window load (wg0 rx_bytes over T0-T1): " +
              " ".join(f"{c}={means[c]:.3f}" for c in CONDS) +
              "  — the pairwise 1.5% gate is applied per comparison below")

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
            obs, p = signflip_p(deltas)
            results[(a, b)] = (deltas, obs, p, base[b])
            if (a, b) in SECONDARY:
                sec_ps.append(((a, b), p))

        ir = None
        i_reason = (an.load_void_reason("bsteal4", "off")
                    or an.load_void_reason("both", "steal4"))
        if i_reason is None and is_lat:
            i_reason = an.latency_void_reason(metric, CONDS)
        if i_reason is None:
            ideltas = an.interaction_deltas(metric)
            iobs, ip = signflip_p(ideltas)
            ir = (ideltas, iobs, ip)
            sec_ps.append((("interaction", ""), ip))
        adj = holm(sec_ps) if sec_ps else {}

        for a, b in COMPS:
            label = f"{a}-{b}"
            if results[(a, b)] is None:
                continue
            deltas, obs, p, bmean = results[(a, b)]
            if (a, b) == ("steal4", "off"):
                tag = "PRIMARY" if fam_primary else ("SECONDARY" if not is_lat
                                                     else "EXPLORATORY")
                an.report_line(label, deltas, bmean, fav, tag)
                if fam_primary:
                    verdict[metric] = (obs * fav > 0) and (p < 0.05)
            else:
                tag = ("SECONDARY, Holm" if not is_lat or metric == "p99_half_rtt_us"
                       else "EXPLORATORY")
                an.report_line(label, deltas, bmean, fav, tag,
                               p_adj=adj.get((a, b)))
        if ir is None:
            an.void_line("interaction", i_reason)
        else:
            ideltas, iobs, ip = ir
            base_off = st.mean([an.metric(metric, blk, "off") for blk in blocks])
            an.report_line("interaction", ideltas, base_off, fav,
                           "SECONDARY, Holm", p_adj=adj.get(("interaction", "")))
            print("    interaction ~0: approximately additive on this scale; "
                  "toward favorable: synergy; away: reduced incremental benefit. "
                  "A large p means 'no incremental effect detected', NOT redundancy.")

    print()
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
    kn = {c: f"supp={s};headwake={h};steal={t};diag=%d;delay=0;trig_k=0" %
          (0 if mode == "confirm" else 1)
          for c, (s, h, t) in KNOB_EXPECT.items()}
    rng = random.Random(1)
    rows = []
    for b in range(1, blocks + 1):
        drift = rng.gauss(0, 0.04)
        for pos, c in enumerate(CONDS, 1):
            r = {"date": "2026-07-20", "srcversion": "ABC", "block": str(b),
                 "position": str(pos), "cond": c, "knobs": kn[c],
                 "softirq_ce": "0.983",
                 "system_ce": f"{ce[c] + drift - 0.03:.3f}",
                 "total_busy_ce": f"{ce[c] + drift:.3f}",
                 "dmesg_new": "0"}
            if mode == "confirm":
                r["gbps"] = f"{g[c] + drift + rng.gauss(0, 0.02):.4f}"
            else:
                q = p99[c] + drift * 100 + rng.gauss(0, 8)
                r.update({"load_window_gbps": f"{3.8 + rng.gauss(0, 0.005):.4f}",
                          "load_iperf_gbps": "3.79", "sent_msgs": "120000",
                          "recv_msgs": "120000", "dropped_msgs": "0",
                          "dup_msgs": "0", "ooo_msgs": "0", "lat_n": "119999",
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


def _run(path, blocks=None):
    """Run analyze with stdout captured; return ('ok'|'void'|'invalid', msg)."""
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    try:
        rc = analyze(path, blocks)
        return ("void" if rc == 2 else "ok"), buf.getvalue()
    except Invalid as e:
        return "invalid", str(e)
    finally:
        sys.stdout = old


def selftest():
    td = tempfile.mkdtemp(prefix="analyze_confirm_selftest_")
    fails = []

    def check(name, expect, got, detail=""):
        ok = got == expect
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: expected {expect}, got {got}"
              + (f" ({detail[:90]})" if detail and not ok else ""))
        if not ok:
            fails.append(name)

    def art(name, mode, blocks, mutate=None):
        p = os.path.join(td, name + ".csv")
        _write(p, mode, blocks, mutate)
        return p

    # valid artifacts
    check("valid gate A", "ok", _run(art("a", "confirm", 12))[0])
    check("valid gate B", "ok", _run(art("b", "fixedload", 8))[0])

    # effect-direction sanity on the paired machinery
    for name, vals, wantp in (("all-positive", [0.1] * 12, "small"),
                              ("all-negative", [-0.1] * 12, "small"),
                              ("all-zero", [0.0] * 12, "not-small"),
                              ("mixed", [0.10, -0.09, 0.11, -0.10, 0.08, -0.12,
                                         0.07, -0.08, 0.09, -0.11, 0.10, -0.06],
                               "not-small")):
        obs, p = signflip_p(vals)
        got = "small" if p < 0.01 else "not-small"
        check(f"sign-flip {name}", wantp, got, f"p={p}")
    check("sign-flip all-zero p==1", True, signflip_p([0.0] * 12)[1] == 1.0)

    # schema violations -> invalid
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

    def nan(rows): rows[4]["gbps"] = "nan"
    check("NaN value", "invalid", _run(art("nan", "confirm", 12, nan))[0])

    def inf(rows): rows[4]["total_busy_ce"] = "inf"
    check("Inf value", "invalid", _run(art("inf", "confirm", 12, inf))[0])

    def bad(rows): rows[4]["gbps"] = "4.2.1"
    check("malformed numeric", "invalid", _run(art("bad", "confirm", 12, bad))[0])

    def knob(rows):
        for r in rows:
            if r["block"] == "2" and r["cond"] == "steal4":
                r["knobs"] = "supp=0;headwake=0;steal=0;diag=0;delay=0;trig_k=0"
    check("knob/label mismatch", "invalid",
          _run(art("knob", "confirm", 12, knob))[0])

    # validity gates -> void (exit 2), never silent
    def pairmis(rows):
        # global means stay ~equal, but block 4 is skewed +2%/-2% between conds
        for r in rows:
            if r["block"] == "4":
                r["load_window_gbps"] = "3.876" if r["cond"] == "steal4" else "3.724"
    st_, out = _run(art("loadmis", "fixedload", 8, pairmis))
    check("paired load mismatch (global means equal)", "void", st_)
    check("  ...voids the CPU primary", True, "GATE B PRIMARY: VOID" in out)

    def lossy(rows):
        for r in rows:
            if r["block"] == "2" and r["cond"] == "off":
                r["dropped_msgs"] = "2400"  # 2% of 120000
    st_, out = _run(art("loss", "fixedload", 8, lossy))
    check("UDP loss threshold", "void", st_)
    check("  ...CPU inference retained under loss", True,
          "total_busy_ce — within-block" in out and
          "GATE B PRIMARY (steal4-off" in out)

    def few(rows):
        for r in rows:
            r["lat_n"] = "50000"  # ok for p99, not for p99.9
    st_, out = _run(art("few", "fixedload", 8, few))
    check("insufficient p99.9 support", "void", st_)
    check("  ...p99 still analyzed at 50k obs", True,
          "p99_half_rtt_us — within-block" in out)

    print(f"\nselftest: {'ALL PASS' if not fails else 'FAILURES: ' + ', '.join(fails)}")
    return 0 if not fails else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    blocks = None
    if "--blocks" in argv:
        i = argv.index("--blocks")
        blocks = int(argv[i + 1])
        del argv[i:i + 2]
    if not argv:
        print("usage: analyze_confirm.py [--blocks N] <artifact.csv> | --selftest",
              file=sys.stderr)
        return 1
    try:
        return analyze(argv[0], blocks)
    except Invalid as e:
        print(f"INVALID ARTIFACT — no inference printed.\n{e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"cannot read artifact: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
