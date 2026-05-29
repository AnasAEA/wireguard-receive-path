#!/usr/bin/env python3
"""Print one-line metrics for a single measurement directory (for the sweep).

Output: a CSV fragment
    tput_gbps,wasted_s,useful_s,total_s,netrx_ms_s,p50_ms,p99_ms,p999_ms,max_ms

Usage: analyze_one.py <run_dir>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze_runs import throughput_gbps, gro_stats, latencies_ms, pct  # noqa: E402


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_one.py <run_dir>", file=sys.stderr)
        sys.exit(1)
    d = sys.argv[1]
    t = throughput_gbps(d)
    w, u, tot, ms = gro_stats(d)
    lat = sorted(latencies_ms(d))
    p50 = pct(lat, 50); p99 = pct(lat, 99); p999 = pct(lat, 99.9)
    mx = lat[-1] if lat else float("nan")
    print(f"{t:.3f},{w:.0f},{u:.0f},{tot:.0f},{ms:.1f},"
          f"{p50:.3f},{p99:.3f},{p999:.3f},{mx:.3f}")


if __name__ == "__main__":
    main()
