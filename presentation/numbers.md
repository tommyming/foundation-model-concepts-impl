# Presentation numbers

Every number on a slide names its source here (handoff §22). No fabricated
values. Fill in from exported benchmark JSON.

Template per number:

```
## <metric name>
Value: XXX <unit>
Metric definition: <exact API / instrument>
Scenario: <name from Benchmark.swift>
Architecture: <shared-adapter | naive-independent>
Device: <from docs/environment.md>
OS: <from docs/environment.md>
Model revision: <from docs/environment.md>
Runs: N (warm-up 1 + measured N)
Statistic: median (range in parentheses)
Source: benchmarks/results/<file>.json
```

## Pending measurements (fill after a physical iPhone run)

No value below is measured. Do not write a slide number from this list.
Do not invent MB or ms values. `benchmarks/results/` is empty until a device run.

`app/Sources/Benchmark.swift` now exports the fields the measurement fix required. The names below are those JSON keys. A device file does not exist yet, so every value stays unmeasured.

| Field | Definition | Value |
|---|---|---|
| `phasePeakMB` | Max `task_vm_info.phys_footprint` polled about every 50 ms during the step (`PhasePeakSampler`). Not the lifetime ledger. On scenario `cold-start`, the JSON value is also the max with the base-load sampler. | not measured |
| `lifetimePeakMB` | `task_vm_info.ledger_phys_footprint_peak` at step end. Process lifetime. It does not reset per phase, and `reset()` does not clear it. | not measured |
| `adapterSwitchMs` | Unload plus load only. A separate field from `ttftMs`. Nil when the adapter did not change. | not measured |
| `ttftMs` | Inference start to the first token. Excludes switch time and model load. The `FirstToken` signpost uses this same clock. | not measured |
| Cold start | Scenario name `cold-start`. There is no `coldStartMs` key. Load time is `modelLoadMs` on that step. Shared: `loadDuration` from `loadBase()`. Naive: `makeContainer()` for the first summarize instance. | not measured |

`totalMs` is inference start to stream end. It also excludes switch time and model load. Do not add `adapterSwitchMs` into `ttftMs` or `totalMs` when you fill a slide.

These comparisons stay unmeasured until a device JSON file exists:

- Shared-adapter `phasePeakMB` for summarize, then classify, then extract
- Naive `phasePeakMB` for the same sequence
- `ttftMs` on a warm same-task step versus `ttftMs` after a switch
- Adapter memory delta on apply versus remove
- `phys_footprint` after Unload / Reset (MLX allocator cache, Risk B)
