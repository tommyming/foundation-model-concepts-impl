# Instruments workflow for Xcode 26.6

This is the procedure for a new trace of AI Memory Lab. This repository does not contain a `.trace` file. Do not cite a trace that you have not saved yourself.

Toolchain record: Xcode 26.6 (build 17F113), iOS 26.5 SDK. See `docs/environment.md` and `docs/feasibility.md`. Template names below come from `docs/research/memory-and-instruments.md`, checked on that Xcode.

Use a physical iPhone. A simulator trace is not a memory result. See `README.md`.

## Signposts that exist today

`app/Sources/Signposts.swift` creates one poster.

- Subsystem: `com.iosconf.aimemorylab`
- Category: `ModelManager`

That category is not `.pointsOfInterest`. Filter `os_signpost` on this subsystem and this category. Do not assume the Points of Interest instrument shows these names.

The app emits the names below. The handoff list (adapter load, adapter activation, adapter unload) is not what the code emits. `ClearContext` is an extra event in `AppModel.clearContext()`. It is not one of the six lifecycle names, and it is real.

| Name | Kind | Call site | What it brackets |
|---|---|---|---|
| `BaseLoad` | Interval | `AppModel.loadBase()` | `makeContainer()` for the shared base. `loadBase()` returns with no interval unless the mode is shared, the state is `.idle`, and no container is resident. After `Reset`, Preload emits `BaseLoad` again. |
| `AdapterSwitch` | Interval | `activateAdapter(for:)` | Unload of the previous adapter, then load of the next, inside `container.update`. Not the file parse. Not the new `ChatSession`. Absent when the active adapter did not change. |
| `Inference` | Interval | `perform` | The `streamResponse` loop. It starts after the switch or the naive load. |
| `FirstToken` | Event | Inside `Inference` | First stream chunk. No duration. This event matches the `ttftMs` clock. Both start at inference start. |
| `NaiveLoad` | Interval | Naive branch of `prepareRun` | `makeContainer()` for a task that has no container yet. Absent on reuse. Prepare does not emit it. |
| `Reset` | Event | `AppModel.reset()` | Emitted after the references are cleared. No duration. Does not call `Memory.clearCache()`. |
| `ClearContext` | Event | `AppModel.clearContext()` | New sessions only. Models stay resident. The active adapter does not change. |

None of these intervals carry a metadata string. The track shows the name only.

A shared-mode task change emits `AdapterSwitch`, then `Inference`, then `FirstToken` inside `Inference`. The same task again emits `Inference` and `FirstToken` only. Prepare in naive mode emits nothing. The first naive run of a task emits `NaiveLoad`, then `Inference`, then `FirstToken`.

## Points of Interest is an instrument

Points of Interest is an instrument you add. It is not a template name.

On Xcode 26.6, `xctrace record --template 'Points of Interest'` fails. VM Tracker and Foundation Models are also instrument names, not template names. Source: `docs/research/memory-and-instruments.md`.

In the template chooser, start from Blank, Logging, or Game Memory. Then click the add button (+) and add instruments.

Add these:

1. Add `os_signpost`. The Logging template already includes it. Filter subsystem `com.iosconf.aimemorylab` and category `ModelManager`.
2. Add Points of Interest. Add it with the + button. Do not select it as the template.
3. Add Allocations and VM Tracker when the template does not already include them. Game Memory already includes the memory set described in the research note.

The current poster category is `ModelManager`. Points of Interest shows the `.pointsOfInterest` category by default. If the names are missing from that track, read them from `os_signpost`. Do not change the category in this doc. The code owns the category.

## Foundation Models does not profile MLX

The Foundation Models instrument profiles Apple's Foundation Models framework. It does not profile MLX.

`BaseLoad`, `AdapterSwitch`, `NaiveLoad`, `Inference`, `FirstToken`, `Reset`, and `ClearContext` will not appear in that instrument. Those names come from `OSSignposter` in this app. Read them on `os_signpost`.

The app does call the system model. `app/Sources/FoundationModelsSection.swift` runs one guided extraction. That call can appear in the Foundation Models instrument. It is not an MLX load and it is not a bar on the MLX memory chart. This repo does not contain that trace either.

Use `os_signpost`, Allocations, VM Tracker, and a Metal instrument for MLX. The research note names Metal Application, Metal System Trace, and the Game Memory template for that GPU work.

## Record a trace

Final memory numbers need the debugger detached. Product > Profile builds the profiling configuration and starts the app under Instruments with no debugger. Source for that workflow: `docs/research/memory-and-instruments.md`. A normal Run from Xcode attaches the debugger. Do not publish memory numbers from that run.

Before you record:

1. Connect a physical iPhone with a cable.
2. Unlock the iPhone.
3. Trust the computer.
4. Enable airplane mode for a final run.
5. Leave Low Power Mode off. `docs/environment.md` already records that item as OFF.
6. Check that the phone is not under thermal pressure. Record the thermal state in `docs/environment.md`. It is still TBD.
7. Turn Malloc Stack Logging off in the scheme diagnostics.
8. Fill the device rows in `docs/environment.md`. They are still TBD.

Then:

1. Open `app/AIMemoryLab.xcodeproj` in Xcode 26.6.
2. Select the physical iPhone as the run destination.
3. Do not select a simulator.
4. Choose Product > Profile.
5. Select Blank, Logging, or Game Memory.
6. Do not select Points of Interest as a template.
7. Click +.
8. Add `os_signpost` if the template does not include it.
9. Add the Points of Interest instrument.
10. Add Allocations and VM Tracker if you did not start from Game Memory.
11. Do not add the Foundation Models instrument for the MLX marks. Add it only if you also tap Extract with System Model.
12. Start the recording.
13. Leave the mode on Shared Base + Adapters.
14. Tap Preload. That emits `BaseLoad`.
15. Tap Summarize. That emits `AdapterSwitch`, then `Inference`, then `FirstToken`.
16. Tap Summarize again. The active adapter did not change. This tap must not emit `AdapterSwitch`.
17. Tap Classify, then Extract. Each change emits `AdapterSwitch`.
18. Tap Clear Context. That emits `ClearContext`. The base stays loaded.
19. Tap Unload / Reset. That emits `Reset`.
20. Select Naive. If a model was still resident, the picker emits `Reset` before the mode changes.
21. Tap Prepare. That emits no load signpost. Zero models are loaded.
22. Tap Summarize. That emits `NaiveLoad`, then `Inference`, then `FirstToken`.
23. Tap Summarize again. This tap must not emit `NaiveLoad`.
24. Tap Classify, then Extract. Each first visit emits `NaiveLoad`.
25. Stop the recording.

The research note also recommends Deferred Mode in the recorder settings, to lower overhead. Use it for a measurement run.

Run Scenarios emits a different order. Each `cold-start` pass calls `reset()` (`Reset`), then `loadBase()` or `prepareNaive()`, then `clearContext()` (`ClearContext`), then the task. Only the shared path emits `BaseLoad` there. See `docs/architecture.md` and `benchmarks/README.md`.

Optional command, from the flag pattern in `docs/research/memory-and-instruments.md`. Replace the device name. This command is not a record that already exists.

```sh
xcrun xctrace record \
  --device-name "YOUR_IPHONE_NAME" \
  --template Logging \
  --instrument "Points of Interest" \
  --attach AIMemoryLab \
  --time-limit 120s \
  --output aimemorylab.trace
```

`--template Logging` is a template. `--instrument "Points of Interest"` adds an instrument. The process name is `AIMemoryLab` (`PRODUCT_NAME` in `app/AIMemoryLab.xcodeproj`).

## Save the trace

1. Stop the recording if it is still running.
2. Choose File > Save.
3. Instruments writes a `.trace` bundle.
4. Keep that bundle outside this repo, or zip it before you move it. A `.trace` bundle is a directory.
5. Do not commit it as a stand-in for a device number. `presentation/numbers.md` takes numbers from benchmark JSON, not from an unsaved trace.

To list tables in a trace you already saved:

```sh
xcrun xctrace export --input aimemorylab.trace --toc
```

That command reads a file you pass in. It does not prove that `aimemorylab.trace` is in this repo. It is not.

## What this procedure does not produce

- It does not fill `presentation/numbers.md`.
- It does not create `benchmarks/results/`.
- It does not replace the in-app phase-peak poll. That poll is `PhasePeakSampler` in `app/Sources/Memory.swift`.
- It does not show MLX signposts inside the Foundation Models instrument.
