# Benchmarks

Run the scenarios on a physical iPhone. Export the JSON from the app. Copy that file into `benchmarks/results/`. Then run `benchmarks/analysis/plot.py`.

Simulator numbers are not valid. macOS does not jetsam the simulator. Do not copy a simulator export into `benchmarks/results/`. Do not plot it.

`benchmarks/results/` is empty until a device run. The directory is not in the repo today. Create it when you copy the first JSON file. Do not commit a hand-written JSON file.

No chart in this repo is a device result until that copy exists. `presentation/numbers.md` stays unmeasured until then.

## Scenarios

`Benchmark.scenarios` in `app/Sources/Benchmark.swift` is the list the app runs, in this order:

| JSON `scenario` | Task order | Reset? |
|---|---|---|
| `cold-start` | summarize | Yes. `prepareColdStart` calls `reset()`, then loads only what this mode needs. |
| `sequential-three-tasks` | summarize, classify, extract | No. Models left by `cold-start` stay resident. |
| `repeated-same-task` | summarize, summarize, summarize | No. |
| `adapter-thrashing` | summarize, classify, summarize, extract, summarize, classify | No. |

Only `cold-start` resets. A naive `sequential-three-tasks` step does not start from an empty process if `cold-start` already loaded summarize. Read `modelLoadMs` on that step. Nil means the instance was already resident.

The app runs one warm-up pass per scenario and does not record it. It then records `measured` passes. The stepper in `app/Sources/ContentView.swift` allows 1 to 5. The handoff protocol asks for 5 measured passes. Set the stepper to 5 for a protocol run.

Each pass calls `clearContext()` before the tasks. That builds new sessions. It does not unload models.

One export is one architecture. `runAll` reads `model.mode` once and writes either `shared-adapter` or `naive-independent` on every run in that file. Export once in each mode. Pass both files to `plot.py`.

## Run on a physical iPhone

Final numbers need the debugger detached, airplane mode on, and the device rows in `docs/environment.md` filled. Those device rows are still TBD. A Run from Xcode attaches the debugger. Product > Profile does not. Do not publish a debugger-attached export.

1. Install AI Memory Lab on the iPhone. See `README.md`.
2. Enable airplane mode.
3. Open the app with the debugger detached.
4. Select Shared Base + Adapters or Naive. The picker calls `switchMode(to:)` and resets if a model is resident.
5. In shared mode, tap Preload. In naive mode, tap Prepare. Do not look for Preload in naive mode.
6. Wait until the state is Ready. Prepare reaches Ready with zero models loaded.
7. Leave the input note unchanged if this file must match another run. The default string is in `app/Sources/ContentView.swift`.
8. Set Measured iterations to 5 for a protocol run.
9. Tap Run Scenarios.
10. Wait until the progress text is `done`.

`cold-start` resets again inside `runAll`. You do not tap Reset yourself for that scenario. Shared `cold-start` calls `loadBase()`. Naive `cold-start` calls `prepareNaive()`, then the summarize step loads the first instance. The code throws if a naive cold start already has a model loaded.

Generation settings are temperature 0 and `maxTokens` 256 (`AppModel.genParams`).

## Export the JSON

The app writes the file before the share sheet appears.

- Directory on device: Application Support `benchmarks/`
- File name: `benchmark-<timestamp>.json`
- Encoder: `Benchmark.runAll` in `app/Sources/Benchmark.swift`
- UI: the share link `Last result: <filename>` in `app/Sources/ContentView.swift`

Tap that share link. Save the file to the Mac (AirDrop or Files).

Current keys:

- `environment.device`, `environment.os`, `environment.model`, `environment.adapters`
- `environment.debuggerAttached` — true when the process is traced (`P_TRACED`). Do not publish a file where this is true.
- `runs[].scenario`, `runs[].architecture`, `runs[].measuredIteration`
- `runs[].thermalState` — `ProcessInfo.thermalState.rawValue`, captured at the start of each iteration
- `steps[].task`
- `steps[].adapterSwitchMs` — unload plus load. Nil if the adapter did not change. Not inside `ttftMs`.
- `steps[].modelLoadMs` — naive `makeContainer()` when that task was not resident. On shared `cold-start`, this is `loadDuration` from `loadBase()`.
- `steps[].ttftMs` — inference start to first token. Excludes switch time and model load.
- `steps[].totalMs` — inference start to stream end. Excludes switch time and model load.
- `steps[].memoryBeforeMB`, `steps[].memoryAfterMB` — `phys_footprint` samples
- `steps[].phasePeakMB` — max polled `phys_footprint` for the step. On `cold-start`, also the max with the base-load sampler.
- `steps[].lifetimePeakMB` — `ledger_phys_footprint_peak` at step end. Process lifetime. `reset()` does not clear it.
- `steps[].inputTokens` — `GenerateCompletionInfo.totalPromptTokenCount`. Nil if the stream ended before the info event.
- `steps[].outputTokens` — `GenerateCompletionInfo.generationTokenCount`. Same nil rule.

There is no `peakFootprintMB` key and no `coldStartMs` key. Cold start is the scenario name `cold-start`, plus `modelLoadMs` on that step.

## Copy it into the repo

From the repo root, after the JSON file is on the Mac:

```sh
mkdir -p benchmarks/results
cp /path/to/benchmark-YYYY-MM-DDTHH-MM-SSZ.json benchmarks/results/
```

Replace the source path with the file you exported. `benchmarks/results/` stays empty until this copy. Do not invent a file to make the plot command succeed.

## Plot

`benchmarks/analysis/plot.py` reads one or more JSON files. It needs matplotlib (`pip install matplotlib`). Run it from the repo root so the default output path resolves.

```sh
python3 benchmarks/analysis/plot.py benchmarks/results/*.json --out presentation/figures
```

The script writes:

- `presentation/figures/chart-a-memory.png` — median `phasePeakMB` at each step of `sequential-three-tasks`, one line per architecture. The script refuses a file that has no `phasePeakMB`. It does not plot `memoryAfterMB` or `lifetimePeakMB`.
- `presentation/figures/chart-b-latency.png` — median `adapterSwitchMs`, `ttftMs`, and `totalMs - ttftMs` at each step of the shared-adapter sequential scenario. A null `ttftMs` stops the script. It is not plotted as 0.

Chart A skips an architecture that has no sequential runs. Pass both exports if you want both lines.

Chart B does not plot `cold-start` and does not plot `modelLoadMs`. The stack matches the current clocks: switch time is not inside `ttftMs` or `totalMs`. See `app/Sources/AppModel.swift`.

The script prints the `device` string from each file. Check that string against `docs/environment.md` before you keep the PNG.
