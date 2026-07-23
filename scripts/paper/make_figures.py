#!/usr/bin/env python3
"""Generate publication figures directly from committed experiment evidence.

The script intentionally has one non-standard dependency, ReportLab. It draws
vector primitives into deterministic PDFs and embeds ReportLab's bundled Vera
TrueType fonts. Confirmation statistics are parsed from the committed analyzer
outputs; paired points are recomputed from the committed CSVs.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
import statistics as stats
from collections import defaultdict
from pathlib import Path

from reportlab import rl_config
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.lib.colors import Color, HexColor
from reportlab.lib.units import inch
import reportlab


ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data" / "cloudlab"
OUT = ROOT / "paper" / "figures" / "generated"

BLUE = HexColor("#0072B2")
ORANGE = HexColor("#D55E00")
GREEN = HexColor("#009E73")
PURPLE = HexColor("#7B3294")
BLACK = HexColor("#222222")
MID = HexColor("#666666")
GRID = HexColor("#D9D9D9")
PALE_BLUE = HexColor("#DCEEF7")
PALE_ORANGE = HexColor("#F8E5DC")
WHITE = HexColor("#FFFFFF")

rl_config.TTFSearchPath.append(
    str(Path(reportlab.__file__).resolve().parent / "fonts")
)
FONT_DIR = Path(reportlab.__file__).resolve().parent / "fonts"
pdfmetrics.registerFont(TTFont("PaperSans", str(FONT_DIR / "Vera.ttf")))
pdfmetrics.registerFont(TTFont("PaperSans-Bold", str(FONT_DIR / "VeraBd.ttf")))
FONT = "PaperSans"
BOLD = "PaperSans-Bold"


STAT_RE = re.compile(
    r"^\s+steal4-off\s+n=(\d+)\s+mean\s+([-+\d.]+)\s+"
    r"\(([-+\d.]+)%\)\s+median\s+\S+\s+"
    r"CI95\s+\[([-+\d.]+),([-+\d.]+)\]\s+"
    r"\+(\d+)/-(\d+)/0:(\d+)\s+p=([\d.]+)"
)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"evidence check failed: {message}")


def close(actual: float, expected: float, tolerance: float, name: str) -> None:
    require(abs(actual - expected) <= tolerance,
            f"{name}: expected {expected}, observed {actual}")


def parse_primary(path: Path, metric: str) -> dict[str, float | int]:
    section = None
    result = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.replace("\N{MINUS SIGN}", "-")
        if line and not line.startswith(" ") and "within-block paired deltas" in line:
            section = line.split(" ", 1)[0]
        match = STAT_RE.match(line)
        if match and section == metric:
            n, mean, pct, lo, hi, pos, neg, zero, pval = match.groups()
            result = {
                "n": int(n), "mean": float(mean), "pct": float(pct),
                "lo": float(lo), "hi": float(hi), "pos": int(pos),
                "neg": int(neg), "zero": int(zero), "p": float(pval),
            }
    require(result is not None, f"cannot parse {metric} from {path}")
    return result  # type: ignore[return-value]


def paired_table(path: Path, expected_blocks: int) -> tuple[dict, list[int]]:
    rows = read_csv(path)
    table = {}
    for row in rows:
        key = (int(row["block"]), row["cond"])
        require(key not in table, f"duplicate paired row {key} in {path}")
        table[key] = row
    blocks = sorted({key[0] for key in table})
    require(len(blocks) == expected_blocks,
            f"{path} has {len(blocks)} blocks, expected {expected_blocks}")
    expected = {"off", "both", "steal4", "bsteal4"}
    for block in blocks:
        observed = {cond for b, cond in table if b == block}
        require(observed == expected, f"block {block} conditions: {observed}")
    return table, blocks


def paired_deltas(table: dict, blocks: list[int], metric: str) -> list[float]:
    return [
        float(table[(block, "steal4")][metric])
        - float(table[(block, "off")][metric])
        for block in blocks
    ]


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    lo = math.floor(position)
    hi = math.ceil(position)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] * (hi - position) + ordered[hi] * (position - lo)


def new_pdf(filename: str, width_in: float, height_in: float,
            title: str) -> tuple[canvas.Canvas, float, float]:
    OUT.mkdir(parents=True, exist_ok=True)
    width, height = width_in * inch, height_in * inch
    c = canvas.Canvas(
        str(OUT / filename), pagesize=(width, height),
        pageCompression=1, invariant=1,
        initialFontName=FONT, initialFontSize=8,
    )
    c.setTitle(title)
    c.setAuthor("WireGuard receive-path experiment artifact")
    c.setCreator("scripts/paper/make_figures.py")
    return c, width, height


def header(c: canvas.Canvas, width: float, height: float, title: str,
           subtitle: str = "") -> None:
    c.setFillColor(BLACK)
    c.setFont(BOLD, 9.4)
    c.drawCentredString(width / 2, height - 13, title)
    if subtitle:
        c.setFillColor(MID)
        c.setFont(FONT, 6.6)
        c.drawCentredString(width / 2, height - 23, subtitle)


def axes(c: canvas.Canvas, box: tuple[float, float, float, float],
         xlim: tuple[float, float], ylim: tuple[float, float],
         xticks: list[tuple[float, str]], yticks: list[tuple[float, str]],
         xlabel: str = "", ylabel: str = ""):
    x0, y0, width, height = box
    xmin, xmax = xlim
    ymin, ymax = ylim

    def sx(value: float) -> float:
        return x0 + (value - xmin) * width / (xmax - xmin)

    def sy(value: float) -> float:
        return y0 + (value - ymin) * height / (ymax - ymin)

    c.setLineWidth(0.45)
    c.setStrokeColor(GRID)
    for value, _ in yticks:
        y = sy(value)
        c.line(x0, y, x0 + width, y)
    c.setStrokeColor(BLACK)
    c.line(x0, y0, x0, y0 + height)
    c.line(x0, y0, x0 + width, y0)

    c.setFont(FONT, 6.2)
    c.setFillColor(MID)
    for value, label in yticks:
        c.drawRightString(x0 - 4, sy(value) - 2, label)
    for value, label in xticks:
        c.drawCentredString(sx(value), y0 - 10, label)
    if xlabel:
        c.setFont(FONT, 6.5)
        c.drawCentredString(x0 + width / 2, y0 - 20, xlabel)
    if ylabel:
        c.saveState()
        c.translate(x0 - 29, y0 + height / 2)
        c.rotate(90)
        c.setFont(FONT, 6.5)
        c.drawCentredString(0, 0, ylabel)
        c.restoreState()
    return sx, sy


def marker(c: canvas.Canvas, x: float, y: float, color: Color,
           shape: str = "circle", size: float = 2.6,
           fill: bool = True) -> None:
    c.setStrokeColor(color)
    c.setFillColor(color if fill else WHITE)
    c.setLineWidth(0.8)
    if shape == "circle":
        c.circle(x, y, size, stroke=1, fill=int(fill))
    elif shape == "square":
        c.rect(x - size, y - size, 2 * size, 2 * size,
               stroke=1, fill=int(fill))
    elif shape == "diamond":
        path = c.beginPath()
        path.moveTo(x, y + size * 1.25)
        path.lineTo(x + size, y)
        path.lineTo(x, y - size * 1.25)
        path.lineTo(x - size, y)
        path.close()
        c.drawPath(path, stroke=1, fill=int(fill))
    elif shape == "triangle":
        path = c.beginPath()
        path.moveTo(x, y + size)
        path.lineTo(x + size, y - size)
        path.lineTo(x - size, y - size)
        path.close()
        c.drawPath(path, stroke=1, fill=int(fill))


def legend(c: canvas.Canvas, entries: list[tuple[str, Color, str]],
           x: float, y: float, spacing: float = 66) -> None:
    c.setFont(FONT, 6.2)
    for index, (label, color, shape) in enumerate(entries):
        xx = x + index * spacing
        marker(c, xx, y + 1.5, color, shape, 2.1)
        c.setFillColor(BLACK)
        c.drawString(xx + 5, y, label)


def finish(c: canvas.Canvas) -> None:
    c.showPage()
    c.save()


def figure_steering() -> None:
    sd = read_csv(DATA / "cpu_sd_spread.csv")
    sdfn = read_csv(DATA / "cpu_sdfn_spread.csv")
    require(len(sd) == 40 and len(sdfn) == 40, "steering CPU CSV row count")
    sd_soft = sorted((float(row["softirq_pct"]) for row in sd), reverse=True)
    sdfn_soft = sorted((float(row["softirq_pct"]) for row in sdfn), reverse=True)

    log = (ROOT / "docs/cloudlab/CLOUDLAB_EXPERIMENTS_LOG_RAW.md").read_text(
        encoding="utf-8"
    )
    sd_match = re.search(r"(?m)^sd\s+([0-9.]+)[-–]([0-9.]+)", log)
    sdfn_match = re.search(r"(?m)^sdfn\s+([0-9.]+)[-–]([0-9.]+)", log)
    require(sd_match is not None and sdfn_match is not None,
            "steering throughput ranges missing from committed log")
    sd_range = (float(sd_match.group(1)), float(sd_match.group(2)))
    sdfn_range = (float(sdfn_match.group(1)), float(sdfn_match.group(2)))
    close(sd_range[0], 4.08, 0.001, "sd throughput lower")
    close(sdfn_range[0], 8.99, 0.001, "sdfn throughput")

    c, width, height = new_pdf(
        "steering_baseline.pdf", 3.35, 2.35, "Receive steering baseline"
    )
    header(c, width, height, "Port-aware hashing spreads multiple tunnels",
           "Sorted per-core softirq occupancy; eight-tunnel test")
    box = (36, 31, width - 48, height - 66)
    sx, sy = axes(
        c, box, (1, 40), (0, 100),
        [(1, "1"), (8, "8"), (16, "16"), (24, "24"), (32, "32"), (40, "40")],
        [(0, "0"), (25, "25"), (50, "50"), (75, "75"), (100, "100")],
        "CPU rank by softirq occupancy", "softirq occupancy (%)",
    )
    for values, color, shape in [
        (sd_soft, ORANGE, "circle"), (sdfn_soft, BLUE, "square")
    ]:
        c.setStrokeColor(color)
        c.setLineWidth(1.2)
        points = [(sx(i + 1), sy(value)) for i, value in enumerate(values)]
        for first, second in zip(points, points[1:]):
            c.line(*first, *second)
        for index in [0, 1, 2, 3, 4, 7, 15, 23, 31, 39]:
            marker(c, *points[index], color, shape, 2.1, fill=False)
    marker(c, 78, height - 34, ORANGE, "circle", 2.1)
    marker(c, 78, height - 42, BLUE, "square", 2.1)
    c.setFont(FONT, 6.0)
    c.setFillColor(BLACK)
    c.drawString(84, height - 36, "default sd: 4.08-4.13 Gb/s")
    c.drawString(84, height - 44, "port-aware sdfn: 8.99 Gb/s")
    finish(c)


def figure_wake_delay() -> None:
    rows = [
        row for row in read_csv(DATA / "decsweep_20260706_0321.csv")
        if row["status"] == "ok" and row["condition"] in {"off", "both"}
    ]
    require(len(rows) == 50, "decrypt-delay valid row count")
    groups: dict[tuple[int, str], list[float]] = defaultdict(list)
    for row in rows:
        groups[(int(row["delay_ns"]) // 1000, row["condition"])].append(
            100 * float(row["wasted_frac"])
        )
    delays = [0, 1, 2, 5, 10]
    require(all(len(groups[(delay, cond)]) == 5
                for delay in delays for cond in ("off", "both")),
            "decrypt-delay cell size")

    c, width, height = new_pdf(
        "wake_delay_response.pdf", 3.35, 2.45,
        "Wake-side decrypt-delay response"
    )
    header(c, width, height, "Wake suppression follows decrypt delay",
           "All points shown; line is median and whisker is IQR")
    box = (36, 31, width - 48, height - 67)
    sx, sy = axes(
        c, box, (-0.4, 10.4), (0, 40),
        [(delay, str(delay)) for delay in delays],
        [(0, "0"), (10, "10"), (20, "20"), (30, "30"), (40, "40")],
        "injected decrypt delay (us)", "wasted polls (%)",
    )
    for cond, color, shape, offset in [
        ("off", ORANGE, "circle", -0.07),
        ("both", BLUE, "square", 0.07),
    ]:
        medians = []
        for delay in delays:
            values = groups[(delay, cond)]
            q1, median, q3 = (
                percentile(values, 0.25),
                percentile(values, 0.50),
                percentile(values, 0.75),
            )
            medians.append((delay, median))
            x = sx(delay + offset)
            c.setStrokeColor(color)
            c.setLineWidth(1.0)
            c.line(x, sy(q1), x, sy(q3))
            c.line(x - 2, sy(q1), x + 2, sy(q1))
            c.line(x - 2, sy(q3), x + 2, sy(q3))
            for rep, value in enumerate(values):
                jitter = (rep - 2) * 0.035
                marker(c, sx(delay + offset + jitter), sy(value),
                       color, shape, 1.6, fill=False)
        c.setStrokeColor(color)
        c.setLineWidth(1.35)
        for first, second in zip(medians, medians[1:]):
            c.line(sx(first[0] + offset), sy(first[1]),
                   sx(second[0] + offset), sy(second[1]))
    legend(c, [("off", ORANGE, "circle"), ("both wake changes", BLUE, "square")],
           63, height - 35, spacing=70)
    finish(c)


def parse_cost_file(path: Path) -> tuple[float, float]:
    text = path.read_text(encoding="utf-8")
    count_match = re.search(r"@wasted:\s+(\d+)", text)
    ns_match = re.search(r"@wasted_ns:\s+(\d+)", text)
    require(count_match is not None and ns_match is not None,
            f"cost fields missing in {path}")
    count = int(count_match.group(1))
    total_ns = int(ns_match.group(1))
    return total_ns / count / 1000, total_ns / (30 * 1e9)


def figure_poll_cost() -> None:
    valid = [
        (0, "off", DATA / "costacct_20260706_0613/bpf_d0_off.txt"),
        (0, "both", DATA / "costacct_20260706_0539/bpf_d0_both.txt"),
        (0, "both", DATA / "costacct_20260706_0613/bpf_d0_both.txt"),
        (10, "off", DATA / "costacct_20260706_0539/bpf_d10000_off.txt"),
        (10, "off", DATA / "costacct_20260706_0613/bpf_d10000_off.txt"),
        (10, "both", DATA / "costacct_20260706_0539/bpf_d10000_both.txt"),
    ]
    groups: dict[tuple[int, str], list[tuple[float, float]]] = defaultdict(list)
    for delay, cond, path in valid:
        groups[(delay, cond)].append(parse_cost_file(path))
    close(groups[(0, "off")][0][1], 0.0218907747, 1e-7,
          "native stock wasted-poll CE")

    c, width, height = new_pdf(
        "empty_poll_cost.pdf", 3.35, 2.35, "Empty-poll cost accounting"
    )
    header(c, width, height, "Wasted polls consume little CPU",
           "Valid BPF windows; durations include kretprobe overhead")
    panels = [
        ((35, 34, 78, height - 72), 1.6, "mean duration (us)", 0),
        ((150, 34, width - 162, height - 72), 0.025, "", 1),
    ]
    for box, ymax, ylabel, value_index in panels:
        sx, sy = axes(
            c, box, (-0.5, 1.5), (0, ymax),
            [(0, "0 us"), (1, "10 us")],
            ([(0, "0"), (0.4, "0.4"), (0.8, "0.8"),
              (1.2, "1.2"), (1.6, "1.6")]
             if ymax > 1 else
             [(0, "0"), (0.005, ".005"), (0.010, ".010"),
              (0.015, ".015"), (0.020, ".020"), (0.025, ".025")]),
            "", ylabel,
        )
        for cond, color, shape, offset in [
            ("off", ORANGE, "circle", -0.10),
            ("both", BLUE, "square", 0.10),
        ]:
            means = []
            for xindex, delay in enumerate([0, 10]):
                values = [item[value_index] for item in groups[(delay, cond)]]
                means.append(stats.mean(values))
                for rep, value in enumerate(values):
                    jitter = (rep - (len(values) - 1) / 2) * 0.045
                    marker(c, sx(xindex + offset + jitter), sy(value),
                           color, shape, 2.0, fill=False)
            c.setStrokeColor(color)
            c.setLineWidth(1.2)
            c.line(sx(0 + offset), sy(means[0]),
                   sx(1 + offset), sy(means[1]))
    marker(c, 53, height - 38, ORANGE, "circle", 2.1)
    marker(c, 87, height - 38, BLUE, "square", 2.1)
    c.setFont(FONT, 6.0)
    c.setFillColor(BLACK)
    c.drawString(59, height - 40, "off")
    c.drawString(93, height - 40, "both")
    c.setFont(BOLD, 6.3)
    c.drawCentredString(150 + (width - 162) / 2, height - 40,
                       "aggregate busy CE")
    finish(c)


def figure_blocking() -> None:
    rows = [
        row for row in read_csv(DATA / "stallclass_20260710_0332.csv")
        if row["class"] == "uncrypt"
    ]
    require(len(rows) == 9, "E11-C UNCRYPTED row count")
    groups: dict[int, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        groups[int(row["delay_ns"]) // 1000].append(row)
    require(all(len(groups[delay]) == 3 for delay in (0, 5, 10)),
            "E11-C repetitions per delay")

    c, width, height = new_pdf(
        "classified_blocking.pdf", 3.35, 2.35,
        "Classified ordered-head blocking"
    )
    header(c, width, height, "Ordered-head stalls last tens of microseconds",
           "UNCRYPTED class; three 30-s repetitions per delay")
    panel_width = (width - 73) / 2
    specs = [
        ((36, 34, panel_width, height - 72),
         "episodes", 320000, "episodes / window",
         [(0, "0"), (80000, "80k"), (160000, "160k"),
          (240000, "240k"), (320000, "320k")]),
        ((53 + panel_width, 34, panel_width, height - 72),
         "mean_us", 110, "mean duration (us)",
         [(0, "0"), (25, "25"), (50, "50"), (75, "75"), (100, "100")]),
    ]
    for box, metric, ymax, ylabel, yticks in specs:
        sx, sy = axes(
            c, box, (-0.6, 10.6), (0, ymax),
            [(0, "0"), (5, "5"), (10, "10")], yticks,
            "injected delay (us)", ylabel,
        )
        medians = []
        for delay in (0, 5, 10):
            values = [float(row[metric]) for row in groups[delay]]
            medians.append((delay, stats.median(values)))
            for rep, value in enumerate(values):
                marker(c, sx(delay + (rep - 1) * 0.17), sy(value),
                       BLUE, "circle", 2.0, fill=False)
        c.setStrokeColor(BLUE)
        c.setLineWidth(1.25)
        for first, second in zip(medians, medians[1:]):
            c.line(sx(first[0]), sy(first[1]), sx(second[0]), sy(second[1]))
        for delay, value in medians:
            marker(c, sx(delay), sy(value), BLUE, "diamond", 2.7)
    finish(c)


def draw_delta_panel(c: canvas.Canvas, box, deltas: list[float],
                     summary: dict[str, float | int], ylabel: str,
                     favorable: str, title: str, subtitle: str,
                     ylim: tuple[float, float], yticks: list[tuple[float, str]]) -> None:
    sx, sy = axes(
        c, box, (0.5, len(deltas) + 0.5), ylim,
        [(index, str(index)) for index in range(1, len(deltas) + 1)],
        yticks, "paired block", ylabel,
    )
    c.setFillColor(PALE_BLUE)
    c.rect(box[0], sy(float(summary["lo"])), box[2],
           sy(float(summary["hi"])) - sy(float(summary["lo"])),
           stroke=0, fill=1)
    c.setStrokeColor(BLACK)
    c.setDash(3, 2)
    c.line(box[0], sy(0), box[0] + box[2], sy(0))
    c.setDash()
    c.setStrokeColor(BLUE)
    c.setLineWidth(1.3)
    c.line(box[0], sy(float(summary["mean"])),
           box[0] + box[2], sy(float(summary["mean"])))
    for index, value in enumerate(deltas, 1):
        good = value > 0 if favorable == "up" else value < 0
        c.setStrokeColor(MID)
        c.setLineWidth(0.65)
        c.line(sx(index), sy(0), sx(index), sy(value))
        marker(c, sx(index), sy(value), BLUE if good else ORANGE,
               "circle" if good else "square", 2.5)
    c.setFillColor(BLACK)
    c.setFont(BOLD, 7.6)
    c.drawCentredString(box[0] + box[2] / 2, box[1] + box[3] + 13, title)
    c.setFont(FONT, 6.2)
    c.setFillColor(MID)
    c.drawCentredString(box[0] + box[2] / 2, box[1] + box[3] + 4, subtitle)


def figure_gate_a() -> None:
    csv_path = DATA / "confirm_20260716_090437.csv"
    analysis = DATA / "confirm_20260716_090437.analysis.txt"
    table, blocks = paired_table(csv_path, 12)
    gbps = paired_deltas(table, blocks, "gbps")
    cpu = paired_deltas(table, blocks, "total_busy_ce")
    gstat = parse_primary(analysis, "gbps")
    cstat = parse_primary(analysis, "total_busy_ce")
    close(stats.mean(gbps), float(gstat["mean"]), 0.00006, "Gate A throughput mean")
    close(stats.mean(cpu), float(cstat["mean"]), 0.00006, "Gate A CPU mean")
    close(float(gstat["pct"]), 1.96, 0.001, "Gate A throughput percent")
    close(float(cstat["pct"]), -3.66, 0.001, "Gate A CPU percent")
    require(sum(value > 0 for value in gbps) == 9, "Gate A throughput signs")
    require(sum(value < 0 for value in cpu) == 12, "Gate A CPU signs")

    c, width, height = new_pdf(
        "gate_a_paired.pdf", 7.0, 2.75, "Gate A paired confirmation"
    )
    header(c, width, height, "Uncapped single-tunnel confirmation",
           "steal4 - off within each randomized block; band is paired-bootstrap CI95")
    panel_width = (width - 96) / 2
    draw_delta_panel(
        c, (43, 34, panel_width, height - 82), gbps, gstat,
        "throughput difference (Gb/s)", "up",
        "Throughput (co-primary)",
        "+1.96%; p=0.0103; 9/12 favorable",
        (-0.08, 0.26),
        [(-0.05, "-.05"), (0, "0"), (0.05, ".05"), (0.10, ".10"),
         (0.15, ".15"), (0.20, ".20"), (0.25, ".25")],
    )
    draw_delta_panel(
        c, (62 + panel_width, 34, panel_width, height - 82), cpu, cstat,
        "total busy CPU difference (CE)", "down",
        "Total busy CPU (co-primary)",
        "-3.66%; p=0.000488; 12/12 favorable",
        (-0.30, 0.04),
        [(-0.30, "-.30"), (-0.25, "-.25"), (-0.20, "-.20"),
         (-0.15, "-.15"), (-0.10, "-.10"), (-0.05, "-.05"), (0, "0")],
    )
    finish(c)


def figure_gate_b() -> None:
    csv_path = DATA / "fixedload_cpu_20260718_024625.csv"
    analysis = DATA / "fixedload_cpu_20260718_024625.analysis.txt"
    table, blocks = paired_table(csv_path, 8)
    deltas = paired_deltas(table, blocks, "total_busy_ce")
    summary = parse_primary(analysis, "total_busy_ce")
    close(stats.mean(deltas), float(summary["mean"]), 0.00006, "Gate B CPU mean")
    close(float(summary["pct"]), -1.17, 0.001, "Gate B CPU percent")
    require(sum(value < 0 for value in deltas) == 3, "Gate B favorable blocks")
    loads = [float(row["load_window_gbps"]) for row in table.values()]
    close(min(loads), 3.8012, 0.00001, "Gate B minimum load")
    close(max(loads), 3.8027, 0.00001, "Gate B maximum load")

    c, width, height = new_pdf(
        "gate_b_matched.pdf", 7.0, 2.85, "Gate B matched-load confirmation"
    )
    header(c, width, height, "Matched-load CPU confirmation",
           "Exact delivered load at left; paired steal4 - off CPU contrast at right")
    left_width = (width - 105) * 0.45
    left_box = (48, 35, left_width, height - 83)
    sx, sy = axes(
        c, left_box, (-0.5, 3.5), (3.7999, 3.8030),
        [(0, "off"), (1, "both"), (2, "steal4"), (3, "bsteal4")],
        [(3.8000, "3.8000"), (3.8010, "3.8010"), (3.8015, "3.8015"),
         (3.8020, "3.8020"), (3.8025, "3.8025"), (3.8030, "3.8030")],
        "condition", "delivered load (Gb/s)",
    )
    c.setStrokeColor(BLACK)
    c.setDash(3, 2)
    c.line(left_box[0], sy(3.8), left_box[0] + left_box[2], sy(3.8))
    c.setDash()
    conds = [
        ("off", ORANGE, "circle"), ("both", GREEN, "triangle"),
        ("steal4", BLUE, "square"), ("bsteal4", PURPLE, "diamond"),
    ]
    for xindex, (cond, color, shape) in enumerate(conds):
        values = [float(table[(block, cond)]["load_window_gbps"]) for block in blocks]
        for rep, value in enumerate(values):
            jitter = (rep - 3.5) * 0.035
            marker(c, sx(xindex + jitter), sy(value), color, shape, 2.0,
                   fill=False)
    c.setFillColor(BLACK)
    c.setFont(BOLD, 7.6)
    c.drawCentredString(
        left_box[0] + left_box[2] / 2, left_box[1] + left_box[3] + 13,
        "Load validity"
    )
    c.setFont(FONT, 6.2)
    c.setFillColor(MID)
    c.drawCentredString(
        left_box[0] + left_box[2] / 2, left_box[1] + left_box[3] + 4,
        "3.8012-3.8027 Gb/s across 32 runs"
    )

    right_x = 73 + left_width
    right_box = (right_x, 35, width - right_x - 28, height - 83)
    draw_delta_panel(
        c, right_box, deltas, summary,
        "total busy CPU difference (CE)", "down",
        "Primary paired CPU contrast",
        "-0.047 CE; CI95 [-0.245,+0.134]; p=0.6562; 3/8 favorable",
        (-0.65, 0.40),
        [(-0.6, "-.6"), (-0.4, "-.4"), (-0.2, "-.2"),
         (0, "0"), (0.2, ".2"), (0.4, ".4")],
    )
    finish(c)


FIGURES = {
    "steering": figure_steering,
    "wake": figure_wake_delay,
    "cost": figure_poll_cost,
    "blocking": figure_blocking,
    "gate-a": figure_gate_a,
    "gate-b": figure_gate_b,
}


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--all", action="store_true",
                       help="generate all article figures")
    group.add_argument("--figure", choices=sorted(FIGURES),
                       help="generate one figure")
    args = parser.parse_args()
    selected = FIGURES if args.all else {args.figure: FIGURES[args.figure]}
    for name, function in selected.items():
        function()
        print(f"{name}: generated")


if __name__ == "__main__":
    main()
