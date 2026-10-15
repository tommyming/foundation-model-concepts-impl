# Architecture

This note describes the runtime in `app/Sources`. It does not describe a device run. No memory number and no latency number in this file came from an iPhone.

The handoff suggested separate types such as `ModelManager` and `AdapterManager`. The app does not use those types. `AppModel` in `app/Sources/AppModel.swift` owns both MLX modes.

Two names for each MLX mode:

| Talk / UI | Code | Benchmark JSON `architecture` |
|---|---|---|
| Shared Base + Adapters | `AppModel.Mode.sharedBase` | `shared-adapter` |
| Naive | `AppModel.Mode.naive` | `naive-independent` |

The mode picker calls `switchMode(to:)`. If the state is not `.idle`, or any model is resident, that call runs `reset()` before the mode changes. Shared containers and naive containers do not stay resident together through the picker.

## Shared mode and naive mode

Shared mode keeps one base model. Naive mode keeps one full model instance per task that has run.

Shared mode (`sharedBase`):

- The idle button is Preload. It calls `loadBase()`.
- `loadBase()` returns immediately unless the mode is shared, the state is `.idle`, the shared container is nil, and `naiveContainers` is empty.
- It loads one `ModelContainer` from the bundle directory `Qwen3-1.7B-4bit`.
- `AppModel` caches one `LoRAContainer` per task in `adapters`.
- One `ChatSession` sits on that container. A switch replaces the session.
- The UI shows the active adapter name and the last switch time.

Naive mode (`naive`):

- The idle button is Prepare. It calls `prepareNaive()`.
- `prepareNaive()` sets `.ready` with zero models loaded. It does not call `makeContainer()`.
- The first run of a task calls `makeContainer()` and stores that container in `naiveContainers`.
- The matching `ChatSession` is stored in `naiveSessions`.
- `residentInstances` records the task.
- A later run of the same task reuses that session.
- `reset()` is the only release. A new task does not unload an old one.
- `prepareRun` throws `sharedModelStillResident` if the shared container is still set. The picker path resets first, so a normal mode change does not hit that error.

Both loaders call `makeContainer()`. That function reads `Bundle.main` resource `Qwen3-1.7B-4bit` and uses `BundleTokenizerLoader`. There is no hub download at runtime. `scripts/fetch-model.sh` copies the weights into `app/Resources/Qwen3-1.7B-4bit` before the build. That script uses the Hugging Face `main` revision. `docs/environment.md` still has the commit as TBD.

Task buttons and Run Scenarios stay disabled until the state is `.ready`. See `app/Sources/ContentView.swift`.

`runSequence` runs summarize, then classify, then extract. `runRepeated` runs summarize three times. `clearContext()` builds new sessions and does not unload models. It does not change `activeAdapter`.

Generation settings are `GenerateParameters(maxTokens: 256, temperature: 0)` on `AppModel.genParams`.

## Who owns the model

The app owns the MLX weights. The operating system does not.

- The weights and the three adapter directories ship in the app bundle.
- Shared mode: `AppModel` owns one `ModelContainer` until `reset()`.
- Naive mode: `AppModel` owns one `ModelContainer` per task that has run, until `reset()`.
- A task does not own a private copy in shared mode. It receives a switch onto the one container.
- `switchMode(to:)` drops the previous owner before the other mode can load.

The system-model section is separate. `app/Sources/FoundationModelsSection.swift` checks `SystemLanguageModel.default` and runs one guided extraction. The OS owns that model. The section does not load MLX weights. The UI says it is not part of the MLX memory chart. `app/project.yml` weak-links `FoundationModels.framework`. That section records no footprint and no latency. Do not put it on the MLX chart. `docs/decisions.md` (D5) is the ownership story.

`app/project.yml` sets `com.apple.developer.kernel.increased-memory-limit` to true. The entitlement is on. Its effect on a device is not measured. Do not hide it when you publish a naive-mode number.

## Adapter switch rules

`activateAdapter(for:)` in `app/Sources/AppModel.swift` is the switch. It runs only in shared mode.

1. If `activeAdapter` is already that task, return nil. Do not unload. Do not load. Do not build a new session.
2. Parse `LoRAContainer.from(directory:)` once per task and cache it. The directory is `adapters/<task>` in the bundle. Parse sits outside the timed switch.
3. Unload the previous adapter before the load. Inside `container.update`, the code calls `old?.unload(from: context.model)` and then `adapter.load(into: context.model)`.
4. After a successful switch, `rebuildSession(for:)` builds a new `ChatSession`. The KV cache must not span an adapter boundary.
5. The code does not call `fuse`, `setLoRAEnabled`, or `perform(with:)`.

`clearContext()` also builds a new session. It does not unload the adapter and it does not count as a switch.

The session instructions come from `AITask.instructions`. Those strings match `SYSTEMS` in `training/make_dataset.py`. Summarize and extract end with `/no_think`. Classify does not. The app does not pass `enable_thinking=false` into the chat template. Whether `/no_think` suppresses reasoning tokens on device is not measured. See `docs/findings.md`.

## Published metric

The published metric is `task_vm_info.phys_footprint`.

`readMemory()` in `app/Sources/Memory.swift` reads three fields:

| Field | Snapshot property | Role |
|---|---|---|
| `phys_footprint` | `physicalFootprintBytes` | Published metric. Jetsam uses this value. |
| `ledger_phys_footprint_peak` | `peakPhysicalFootprintBytes` | Lifetime peak of that ledger. It does not reset per phase. `reset()` does not clear it. |
| `resident_size` | `residentBytes` | Read, not published. Do not chart it against footprint. |

The UI label Footprint is `physicalFootprintMB`. The UI label Phase peak is `RunMetrics.phasePeakMB`. The UI label Lifetime peak is the lifetime ledger.

`PhasePeakSampler` polls `phys_footprint` about every 50 ms. A phase peak is the max sample in that window. It is not `ledger_phys_footprint_peak`.

Two samplers exist:

- `loadBase()` samples the shared base load and stores `lastLoadPhasePeakMB`.
- `perform` starts a sampler before `prepareRun`. That window includes the adapter switch or the naive load, and the inference that follows.

Why this metric, and why not `resident_size`, is in `docs/research/memory-and-instruments.md`. Short form: footprint includes dirty CPU and GPU memory on Apple silicon. `resident_size` counts clean mapped pages and misses private Metal memory.

`Memory.cacheLimit` and `Memory.clearCache()` exist in MLX. This app does not call them. `reset()` drops the Swift references and emits `Reset`. It does not clear the MLX allocator cache.

## What the code records today

These are definitions in code. They are not device results.

The inference clock starts after `prepareRun` returns. Switch time and naive load time are not inside `ttftMs` or `totalMs`.

| Record | Where | What the clock or sample actually is |
|---|---|---|
| Base load | `loadDuration`, signpost `BaseLoad` | `makeContainer()` inside `loadBase()`. Shown in the UI. On a `cold-start` shared step, copied into `modelLoadMs`. |
| Adapter switch | `adapterSwitchMs`, signpost `AdapterSwitch` | Unload plus load inside `container.update`. Not the parse. Not `rebuildSession`. Nil when the adapter did not change. |
| Naive instance load | `modelLoadMs`, signpost `NaiveLoad` | `makeContainer()` for a task that has no container yet. Nil on reuse. Also copied to `loadDuration` for the UI. |
| TTFT | `ttftMs`, event `FirstToken` | Inference start to the first stream chunk. Excludes switch time and model load. |
| Inference total | `totalMs`, interval `Inference` | Inference start to the end of the stream. Excludes switch time and model load. |
| Footprint before / after | `memoryBeforeMB`, `memoryAfterMB` | One `phys_footprint` sample before `prepareRun`, and one after the stream. |
| Phase peak | `phasePeakMB` | Max polled `phys_footprint` for that step. On `cold-start`, the JSON value is the max of the step sampler and `lastLoadPhasePeakMB`. |
| Lifetime peak | `lifetimePeakMB` | `ledger_phys_footprint_peak` at step end. Process lifetime. Not a phase peak. |

`app/Sources/Benchmark.swift` writes that JSON. The scenario order is `cold-start`, `sequential-three-tasks`, `repeated-same-task`, `adapter-thrashing`. Only `cold-start` calls `reset()`. Later scenarios keep the models that `cold-start` left resident. Each iteration calls `clearContext()` before the tasks. The warm-up pass is not recorded.

A shared `cold-start` step can hold both `modelLoadMs` (the base load) and `adapterSwitchMs` (none to summarize). Those fields stay separate from `ttftMs`.

## Still unmeasured

Do not treat any item below as a known number.

- Every value in `presentation/numbers.md`. No file exists under `benchmarks/results/`.
- Whether `phys_footprint` falls after `reset()`, and how much MLX cache remains.
- Whether two naive containers share pages for the same weight file.
- Whether three naive instances stay under the jetsam limit on an 8 GB iPhone.
- Whether `/no_think` works in the Swift chat template.
- The pinned Hugging Face commit of `mlx-community/Qwen3-1.7B-4bit`.
- Latency and footprint for the system-model section. That section does not record them.

On-disk adapter size is not a device measurement. Each shipped `adapters.safetensors` is 19,947,012 bytes (about 20 MB) on disk. See `training/README.md`.

Simulator samples are not valid. A debugger-attached run is not a final number. The protocol is in `README.md` and `docs/environment.md`.

## Related files

- `app/Sources/AppModel.swift` — modes, load, switch, session rebuild
- `app/Sources/Memory.swift` — metric reader and phase-peak poller
- `app/Sources/Benchmark.swift` — scenarios and JSON
- `app/Sources/Signposts.swift` — signpost poster
- `app/Sources/ContentView.swift` — Preload, Prepare, Reset, share sheet
- `app/Sources/FoundationModelsSection.swift` — system model, not the MLX chart
- `app/project.yml` — increased-memory-limit entitlement, weak Foundation Models link
- `docs/decisions.md` — ownership story
- `docs/instruments.md` — how to record the signposts
- `presentation/numbers.md` — fields to fill after a device run
