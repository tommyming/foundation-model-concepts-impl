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

## Pending measurements (fill after Phase 5 device runs)

- Shared-adapter peak phys_footprint, A→B→C
- Naive peak phys_footprint, A→B→C
- Median adapter switch cost (unload + load)
- TTFT warm same-task vs after-switch
- Base model cold load time
- Adapter memory delta (apply vs remove)
- Footprint after Unload/Reset (allocator cache behavior — Risk B)
