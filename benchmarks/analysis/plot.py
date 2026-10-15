#!/usr/bin/env python3
"""Render the talk charts from benchmark JSON exported by the app.

Usage: python3 plot.py result1.json [result2.json ...] [--out dir]
       python3 plot.py --selftest

Chart A plots the median phasePeakMB at each step of sequential-three-tasks.
Chart B plots the median switch, time-to-first-token, and remaining generation
at each step of the shared-adapter sequential scenario.
"""

import argparse
import json
from pathlib import Path
from statistics import median


def load(path: Path):
    data = json.loads(path.read_text())
    return data["runs"], data["environment"]


def sequential(all_runs, architecture):
    runs = [
        r for r in all_runs
        if r["scenario"] == "sequential-three-tasks" and r["architecture"] == architecture
    ]
    for run in runs:
        for step in run["steps"]:
            if "phasePeakMB" not in step:
                raise SystemExit(f"{architecture} step has no phasePeakMB; refuse to plot memoryAfterMB")
    return runs


def median_by_step(runs, value):
    width = len(runs[0]["steps"])
    if any(len(r["steps"]) != width for r in runs):
        raise SystemExit("sequential runs do not have the same step count")
    labels = [s["task"] for s in runs[0]["steps"]]
    columns = []
    for i in range(width):
        columns.append(median(value(r["steps"][i]) for r in runs))
    return labels, columns


def chart_a(all_runs, out: Path, plt):
    fig, ax = plt.subplots(figsize=(8, 4.5))
    drew = False
    for arch, color in (("naive-independent", "tab:red"), ("shared-adapter", "tab:green")):
        runs = sequential(all_runs, arch)
        if not runs:
            continue
        labels, ys = median_by_step(runs, lambda s: s["phasePeakMB"])
        xs = list(range(1, len(labels) + 1))
        ax.plot(xs, ys, marker="o", label=f"{arch} (n={len(runs)})", color=color)
        for x, label, y in zip(xs, labels, ys):
            ax.annotate(label, (x, y), textcoords="offset points", xytext=(0, 8), ha="center", fontsize=8)
        drew = True
    if not drew:
        print("no sequential runs; skipping chart A")
        return
    ax.set_xlabel("step (sequential A -> B -> C)")
    ax.set_ylabel("median phase peak phys_footprint (MB)")
    ax.set_title("Chart A: process footprint, same workload")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out / "chart-a-memory.png", dpi=200)


def chart_b(all_runs, out: Path, plt):
    runs = sequential(all_runs, "shared-adapter")
    if not runs:
        print("no shared-adapter sequential runs; skipping chart B")
        return
    labels, switch = median_by_step(runs, lambda s: s["adapterSwitchMs"] or 0)
    _, ttft = median_by_step(runs, lambda s: s["ttftMs"] or 0)
    _, rest = median_by_step(runs, lambda s: max(s["totalMs"] - (s["ttftMs"] or 0), 0))

    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar(labels, switch, label="adapter switch")
    ax.bar(labels, ttft, bottom=switch, label="time to first token")
    ax.bar(labels, rest, bottom=[a + b for a, b in zip(switch, ttft)], label="remaining generation")
    ax.set_ylabel("median ms")
    ax.set_title(f"Chart B: latency breakdown (shared base + adapters, n={len(runs)})")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out / "chart-b-latency.png", dpi=200)


def _selftest():
    assert median([1, 3, 2]) == 2
    assert median([1, 2, 3, 4]) == 2.5
    runs = [
        {"steps": [{"task": "a", "phasePeakMB": 10}, {"task": "b", "phasePeakMB": 40}]},
        {"steps": [{"task": "a", "phasePeakMB": 30}, {"task": "b", "phasePeakMB": 20}]},
        {"steps": [{"task": "a", "phasePeakMB": 20}, {"task": "b", "phasePeakMB": 60}]},
    ]
    _, peaks = median_by_step(runs, lambda s: s["phasePeakMB"])
    assert peaks == [20, 40], peaks
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json", nargs="*", type=Path)
    ap.add_argument("--out", type=Path, default=Path("presentation/figures"))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        _selftest()
        return
    if not args.json:
        raise SystemExit("pass JSON files, or --selftest")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    args.out.mkdir(parents=True, exist_ok=True)
    all_runs = []
    for p in args.json:
        runs, env = load(p)
        all_runs += runs
        print(f"{p}: {len(runs)} recorded runs, device={env['device']}")
    chart_a(all_runs, args.out, plt)
    chart_b(all_runs, args.out, plt)
    print(f"charts -> {args.out}/chart-a-memory.png, chart-b-latency.png")


if __name__ == "__main__":
    main()
