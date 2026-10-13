#!/usr/bin/env python3
"""Renders the talk charts from benchmark JSON exported from the app.

Usage: python3 plot.py result1.json [result2.json ...] [--out dir]
Needs matplotlib: pip install matplotlib

Chart A: footprint over the sequential scenario, naive vs shared overlaid.
Chart B: latency breakdown (base load / adapter switch / TTFT / generation)
per architecture.
"""

import argparse
import json
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    raise SystemExit("pip install matplotlib first")


def load(path: Path):
    data = json.loads(path.read_text())
    return data["runs"], data["environment"]


def chart_a(all_runs, out: Path):
    """Footprint after each step of sequential-three-tasks, per architecture."""
    fig, ax = plt.subplots(figsize=(8, 4.5))
    for arch, color in (("naive-independent", "tab:red"), ("shared-adapter", "tab:green")):
        runs = [r for r in all_runs if r["scenario"] == "sequential-three-tasks"
                and r["architecture"] == arch]
        if not runs:
            continue
        # median run by total footprint
        run = sorted(runs, key=lambda r: sum(s["memoryAfterMB"] for s in r["steps"]))[len(runs) // 2]
        xs = list(range(1, len(run["steps"]) + 1))
        ys = [s["memoryAfterMB"] for s in run["steps"]]
        ax.plot(xs, ys, marker="o", label=arch, color=color)
        for x, s in zip(xs, run["steps"]):
            ax.annotate(s["task"], (x, s["memoryAfterMB"]), textcoords="offset points",
                        xytext=(0, 8), ha="center", fontsize=8)
    ax.set_xlabel("step (sequential A -> B -> C)")
    ax.set_ylabel("phys_footprint after step (MB)")
    ax.set_title("Chart A: process footprint, same workload")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out / "chart-a-memory.png", dpi=200)


def chart_b(all_runs, out: Path):
    """Stacked latency breakdown for one shared-adapter sequential run."""
    runs = [r for r in all_runs if r["scenario"] == "sequential-three-tasks"
            and r["architecture"] == "shared-adapter"]
    if not runs:
        print("no shared-adapter runs; skipping chart B")
        return
    run = runs[len(runs) // 2]
    tasks = [s["task"] for s in run["steps"]]
    switch = [s["adapterSwitchMs"] or 0 for s in run["steps"]]
    ttft = [s["ttftMs"] or 0 for s in run["steps"]]
    rest = [max(s["totalMs"] - (s["ttftMs"] or 0), 0) for s in run["steps"]]

    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar(tasks, switch, label="adapter switch")
    ax.bar(tasks, ttft, bottom=switch, label="time to first token")
    ax.bar(tasks, rest, bottom=[a + b for a, b in zip(switch, ttft)],
           label="remaining generation")
    ax.set_ylabel("ms")
    ax.set_title("Chart B: latency breakdown (shared base + adapters)")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out / "chart-b-latency.png", dpi=200)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, default=Path("presentation/figures"))
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    all_runs = []
    for p in args.json:
        runs, env = load(p)
        all_runs += runs
        print(f"{p}: {len(runs)} recorded runs, device={env['device']}")
    chart_a(all_runs, args.out)
    chart_b(all_runs, args.out)
    print(f"charts -> {args.out}/chart-a-memory.png, chart-b-latency.png")


if __name__ == "__main__":
    main()
