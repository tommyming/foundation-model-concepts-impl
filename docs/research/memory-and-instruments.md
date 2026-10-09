# iOS memory measurement APIs + Instruments workflow (Xcode 26.x)

Research task 4 of 4 — supporting the iOSConf SG demo feasibility assessment (three independent
model instances vs one shared base + hot-swapped LoRA adapters, MLX on a physical iPhone).

- **Researched:** 2026-10-09, against the *current* state (October 2026).
- **Local environment:** Xcode 26.6 (build 17F113), iPhoneOS 26.5 SDK, selected via `xcode-select`.
- **Claim labels:**
  - `[documented]` — backed by a cited Apple source (doc article, SDK header doc comment, WWDC transcript, or Apple TN).
  - `[verified]` — checked on this machine (Xcode 26.6 / iOS 26.5 SDK / `xctrace` CLI output quoted below).
  - `[inferred]` — reasoned from documented behavior, not directly doc-backed. Treat as needing empirical confirmation on the demo device.

---

## TL;DR for the demo

| Decision | Recommendation |
|---|---|
| Headline memory metric | `task_vm_info.phys_footprint` (sampled at signpost boundaries) — `[documented]` it is the metric jetsam enforces and the Xcode gauge shows |
| Peak metric | `task_vm_info.ledger_phys_footprint_peak` (lifetime high-water) **plus** a ~50 ms poller around each measured phase for per-phase peaks |
| Limit / headroom | `os_proc_available_memory()` (== `task_vm_info.limit_bytes_remaining`) |
| Latency marks | `OSSignposter` with `category: .pointsOfInterest` → visible by default in Instruments' Points of Interest track |
| Final numbers | Physical device, Release-style profiling build (Product > Profile / Instruments), never the simulator, never a debugger-attached debug run |

---

## (a) Programmatic memory metrics in Swift

### a.1 `task_vm_info` via `mach_task_info()` — exact fields and definitions

`task_info(target, TASK_VM_INFO, ...)` fills a `task_vm_info` struct. The struct is declared in
`<mach/task_info.h>`; every field below is quoted from the iOS 26.5 SDK header, and each field also
has its own Apple doc page under
[`task_vm_info_data_t`](https://developer.apple.com/documentation/kernel/task_vm_info_data_t)
(e.g. [`phys_footprint`](https://developer.apple.com/documentation/kernel/task_vm_info_data_t/1553210-phys_footprint),
[`ledger_phys_footprint_peak`](https://developer.apple.com/documentation/kernel/task_vm_info_data_t/3181862-ledger_phys_footprint_peak)).
The `task_info` call itself is documented at
[`task_info`](https://developer.apple.com/documentation/kernel/1537934-task_info) — note Apple calls
it "an expensive call" compared to `os_proc_available_memory()` `[documented]`.

Relevant fields (struct comments verbatim from the SDK header; rev = struct revision marker):

| Field | Header comment / meaning |
|---|---|
| `virtual_size` | "virtual memory size (bytes)" — address space, not physical `[documented]` |
| `resident_size` | "resident memory size (bytes)" — pages physically in RAM (incl. clean/file-backed) |
| `resident_size_peak` | "peak resident size (bytes)" — high-water of `resident_size` only |
| `internal` / `internal_peak` | internally-managed (heap/dirty-anonymous) bytes, current / peak |
| `external` / `external_peak` | externally-backed (file-mapped) bytes, current / peak |
| `reusable` / `reusable_peak` | pages reusable/purgeable-clean |
| `purgeable_volatile_*` | purgeable memory in volatile state (pmap/resident/virtual) |
| `compressed` / `compressed_peak` / `compressed_lifetime` | pages currently / ever compressed |
| `phys_footprint` (rev1) | physical footprint in bytes — **the jetsam metric** (see §b) |
| `ledger_phys_footprint_peak` (rev3) | lifetime peak of the phys_footprint ledger |
| `ledger_purgeable_nonvolatile*` | nonvolatile purgeable charged to footprint |
| `ledger_tag_network_*`, `ledger_tag_media_*`, `ledger_tag_graphics_*`, `ledger_tag_neural_*` | footprint broken out by kernel memory tag; graphics/neural rows cover GPU/ANE-class tagged allocations |
| `limit_bytes_remaining` (rev4) | bytes left before this process hits its current memory limit |
| `decompressions` (rev5), `ledger_swapins` (rev6), `ledger_tag_neural_nofootprint_total/peak` (rev7) | newer counters |

All fields above are present in the iOS 26.5 SDK header `[verified]`. The rev3+ ledger fields date
to the macOS 10.15 / iOS 13 SDK era per their doc pages `[documented]`; iOS 26 devices accept the
full `TASK_VM_INFO_COUNT` `[verified]` (always check the `kern_return_t`).

**Swift (compile-verified against the iOS 26.5 SDK, `arm64-apple-ios17.0`):**

```swift
import Darwin

struct MemorySnapshot {
    let physicalFootprint: UInt64       // task_vm_info.phys_footprint
    let peakPhysicalFootprint: UInt64   // task_vm_info.ledger_phys_footprint_peak
    let residentSize: UInt64            // task_vm_info.resident_size
    let limitBytesRemaining: UInt64     // task_vm_info.limit_bytes_remaining
}

func readTaskVMInfo() -> MemorySnapshot? {
    var info = task_vm_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
    let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    return MemorySnapshot(
        physicalFootprint: info.phys_footprint,
        peakPhysicalFootprint: UInt64(bitPattern: info.ledger_phys_footprint_peak),
        residentSize: info.resident_size,
        limitBytesRemaining: info.limit_bytes_remaining)
}
```

`os_proc_available_memory`'s header states the relationship explicitly: the value it returns
"is equivalent to the task_vm_info.limit_bytes_remaining field" and `task_info()` "will return
information such as your phys_footprint, which is used to calculate the return of this function"
`[documented, <os/proc.h> header doc]`.

### a.2 Sampling PEAK footprint over an interval

1. **Lifetime peak, no polling:** `task_vm_info.ledger_phys_footprint_peak` (above), or the
   equivalent `rusage_info_current.ri_lifetime_max_phys_footprint` from
   `proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT /* = V6 */, ...)` — Apple presented exactly this
   code pair ("Current and peak footprint") in WWDC22 session 10106 `[documented]`.
   Caveat: it is a **lifetime, monotonically increasing** high-water with no public reset
   `[inferred from field naming + no reset API]`, so it answers "worst ever in this process," not
   "peak during phase 2."
   - iOS gotcha `[verified]`: the iOS SDK's `<sys/resource.h>` defines the flavors and
     `rusage_info_current` but does **not** declare the `proc_pid_rusage` prototype (macOS gets it
     from `<libproc.h>`); Apple's own slide re-declares it by hand on iOS. In Swift you'd need a
     tiny C shim. The `task_vm_info` route needs no shim and compiles directly — prefer it.
2. **Per-interval peak:** poll `phys_footprint` on a background task between signposts. Poll
   sparingly — `task_info` is "expensive" per Apple `[documented]`; 20–50 Hz is plenty for
   second-scale model loads `[inferred]`. Compile-verified:

```swift
func samplePeakFootprint(until end: ContinuousClock.Instant,
                         every: Duration = .milliseconds(50)) async -> UInt64 {
    var peak: UInt64 = 0
    while ContinuousClock.now < end {
        if let s = readTaskVMInfo() { peak = max(peak, s.physicalFootprint) }
        try? await Task.sleep(for: every)
    }
    return peak
}
```

3. **Cross-checks:** the Xcode memory gauge shows "the app's current memory use, along with the
   highest value seen" `[documented, Gathering information about memory use]`, and jetsam reports
   carry `lifetimeMax` (lifetime peak pages) `[documented, jetsam reports article]`. Use them as
   sanity checks, not as the recorded numbers.

### a.3 `os_proc_available_memory()`

Declared in `<os/proc.h>`: `API_UNAVAILABLE(macos) API_AVAILABLE(ios(13.0), tvos(13.0), watchos(6.0))`
`[verified in SDK header; doc page: os_proc_available_memory]`.
Apple's definition `[documented]`:

> "The returned value corresponds to the current memory limit minus the memory footprint of your app
> at the time of the function call. Your app's memory footprint consists of the data that you
> allocated in RAM, and that must stay in RAM (or the equivalent) at all times."

- Returns `0` "if the calling process isn't an app, or if the process has already exceeded its
  memory limit" `[documented]`.
- Snapshot only: "Use the returned value as advisory information only and don't cache it"; limits
  "can change during the app life cycle and don't necessarily correspond to the amount of physical
  memory available on the device" `[documented]`.
- Cheaper than `task_info()` for pure headroom checks `[documented]`.

### a.4 Jetsam / memory-limit querying

- **No public "get my limit" API.** Derive it: `limit ≈ phys_footprint + limit_bytes_remaining`
  (equivalently `+ os_proc_available_memory()`) `[documented sum, os/proc.h; the derivation is
  standard practice → inferred arithmetic on documented values]`.
- **Exceeding the limit** → `EXC_RESOURCE` exception and/or jetsam termination with reason
  `per-process-limit` ("The process crossed the resident memory limit imposed by the system on all
  apps") `[documented, WWDC18 416 + Identifying high-memory use with jetsam event reports]`.
- **Jetsam reports** (`.jetsam`/`.ips` under Settings > Privacy & Security > Analytics Data):
  JSON with header `pageSize` (e.g. 16384), `largestProcess`, and per-process entries with `rpages`
  (pages used = bytes / pageSize), `lifetimeMax`, `states`, `reason`
  `[documented, Identifying high-memory use with jetsam event reports]`. Extensions have much lower
  limits `[documented]`.
- **Raising the limit:** the `com.apple.developer.kernel.increased-memory-limit` entitlement
  (iOS 15+) lets core features exceed the default limit on supported devices; Apple says to verify
  actual headroom with `os_proc_available_memory()` after adding it
  `[documented, entitlement page]`. Relevant if the 3×-instances configuration needs it.
- **Production/CI metrics:** `XCTMemoryMetric(application:)` in performance XCTests reports memory
  averages and fails on baseline regressions; memgraphs come along automatically in the xcresult
  `[documented, WWDC21 10180]`. MetricKit covers field telemetry `[documented, WWDC21 10180 refs]`.

---

## (b) Which single metric for the naive-vs-shared comparison — and why

**Report `phys_footprint` (with `ledger_phys_footprint_peak` / polled phase peaks). Report
`resident_size` only as a secondary transparency column, never as the headline.**

1. **It is the metric the system grades you against.** "Memory footprint is the primary and
   universal metric on Apple platforms to determine your … actual memory use. … It's used for
   memory limit enforcement" `[documented, WWDC22 10106]`. Jetsam's `per-process-limit` and the
   Xcode memory gauge ("the value that the system grades you against" since Xcode 10) both key off
   footprint `[documented, WWDC18 416; jetsam article]`. A demo claim like "3× instances would be
   killed on an 8 GB iPhone but shared-base fits" is *defensible only* in footprint terms.
2. **Footprint = dirty + compressed (+swapped), and it includes CPU *and* GPU objects on Apple
   silicon.** "On devices with Apple silicon, accessed Metal resources also fall into this
   [dirty] category, this is because CPU and GPU share the same pool of fast unified memory"
   `[documented, WWDC22 10106]`. For MLX (Metal-backed tensors in shared storage) that means model
   weights show up in footprint `[inferred from the documented principle]`.
3. **Metal/GPU/IOKit allocations that `resident_size` misses.**
   - Metal resources allocated with `MTLStorageMode.private` are not CPU-accessible: they live in
     IOKit/driver accounting (the IOAccelerator/IOSurface categories), are visible to the Metal
     debugger's Memory viewer as tracked allocations, and count against footprint, while the
     Allocations *instrument* explicitly "doesn't include private Metal resources"
     `[documented, WWDC22 10106 + Metal Analyzing memory usage]`. Private-resource bytes are not
     mapped into the process address space, so they do not appear in the process's
     `resident_size` `[inferred — assembled from the documented private-storage and IOAccelerator
     facts]`. `task_vm_info` exposes tagged slices of this via
     `ledger_tag_graphics_footprint*` / `ledger_tag_neural_*` `[documented fields]`.
   - Compressed pages: "your game will still get charged for their uncompressed size" in footprint
     `[documented, WWDC22 10106]`, while those pages are no longer physically resident → they
     vanish from `resident_size` `[inferred]`.
4. **What `resident_size` over-counts:** clean pages. "Read-only files mapped from disk … The
   system can empty or reload them from disk at any time, so they don't count towards your …
   memory footprint. However, they may be resident on memory" `[documented, WWDC22 10106]`;
   vmmap's resident column "includes clean pages such as executables and memory mapped files"
   `[documented, WWDC22 10106]`. An MLX app that mmaps `.safetensors` weight files will see
   resident_size inflated by file-cache pages that cost the process nothing
   `[inferred for MLX's mmap usage; the clean-page principle is documented]`.
5. **Volatile Metal resources:** "The operating system doesn't count volatile memory in your app's
   total memory footprint" `[documented, Metal Analyzing memory usage]` — so footprint quietly
   ignores purgeable/volatile GPU memory; don't be surprised if the Metal debugger's nonvolatile
   total matches footprint better than its total-resources number.

**Fairness protocol for the demo:** sample `phys_footprint` at each signpost boundary (before/after
base load, adapter load, activation, inference), record per-phase polled peaks, report lifetime
`ledger_phys_footprint_peak` as the worst-case, and keep `resident_size` in a footnote with the
caveats above. Same device, same OS build, airplane mode, screen on, thermal check
(`[documented]` Foundation Models profiling article explicitly tells you to check the device isn't
under thermal pressure before recording — the same discipline applies here).

---

## (c) Debugger distortion: how numbers differ with a debugger attached

What is safe to claim, with labels:

- **Simulator numbers are meaningless for memory claims.** "When you run your app in the simulator,
  the memory gauge always stays in the green (safe) region because macOS doesn't issue memory
  warnings or out-of-memory terminations … memory use in the green region of the gauge in the
  simulator doesn't necessarily mean that your app's memory use is within safe limits"
  `[documented, Gathering information about memory use]`; WWDC18 416's demo showed a 7.7 GB
  simulator high-water that would have been killed on device `[documented]`. Final numbers must
  come from the physical iPhone.
- **Diagnostics options change the allocator.** With Malloc Stack Logging on, heap allocations move
  into the `MallocStackLoggingLiteZone` and WWDC21 shows that zone dominating dirty memory in
  memgraph analysis; MSL is exactly what Xcode's scheme Diagnostics tab turns on, and what XCTest
  auto-enables for its memgraphs `[documented, WWDC21 10180 + WWDC22 10106]`. Enable it for
  debugging, disable it for measurement runs.
- **Debug-build configuration differs from profiling configuration.** Xcode's Profile action uses
  the Release-style profiling configuration, and Instruments records that build
  `[documented that Product > Profile builds & runs the profiling configuration — see the
  Foundation Models profiling article's flow; the optimizer/allocator consequences for memory are
  inferred]`. Debug (−Onone) builds can transiently hold more memory.
- **A debugger-attached run is not a clean run.** With LLDB attached the process runs with Xcode's
  debugging support (debug dylibs/main-thread checker per scheme settings, breakpoint
  suspension that can pin transient allocations) — treat gauge numbers seen while debugging as
  indicative only, and never as published numbers `[inferred; no Apple doc quantifies it]`.
  `os_proc_available_memory()` additionally returns `0` for processes that aren't apps
  `[documented]` — i.e., measure *inside the app process*, not from a CLI tool you attached to.

**How to get final, detached numbers `[documented where noted]`:**

1. **Product > Profile (⌘I)** from Xcode: builds the profiling (Release) configuration, launches
   under Instruments with **no debugger** `[documented workflow]`. This is the sanctioned path for
   latency + trace capture.
2. **Run without the debugger from Xcode:** Scheme > Run action > uncheck *Debug executable* —
   the app launches from Xcode with no LLDB session `[inferred: scheme-editor UI label; the
   checkbox's existence is Xcode UI, not something I could cite a doc page for]`.
3. **In-app self-measurement:** the app itself samples `task_vm_info` and logs via `os_log`/signpost
   metadata — works in any launch mode including TestFlight/ad hoc, which is the most honest
   "demo-day" configuration `[inferred workflow built on documented APIs]`.
4. **Automation:** `xcodebuild` performance tests with `XCTMemoryMetric` + baseline regression
   checking `[documented, WWDC21 10180]`, and `xctrace record` scripts (§d) that launch/attach
   without Xcode's debugger `[verified CLI; documented in WWDC22 10106]`.

---

## (d) Instruments in Xcode 26.6

### What actually ships (verified vs assumed)

Verified locally on Xcode 26.6 via `xcrun xctrace list templates` / `list instruments`:

- **Standard templates (26) `[verified]`:** Activity Monitor, **Allocations**, Animation Hitches,
  App Launch, Audio System Trace, CPU Counters, CPU Profiler, **Core ML**, Data Persistence,
  File Activity, **Game Memory**, Game Performance, Game Performance Overview, **Leaks**,
  **Logging**, **Metal System Trace**, Network, Power Profiler, Processor Trace, RealityKit Trace,
  **Swift Concurrency**, **SwiftUI**, **System Trace**, Tailspin, **Time Profiler**, (and
  `VM Tracker`-family coverage via instruments below). `Metal System Trace` was additionally
  record-tested via CLI `[verified]`.
- **Relevant instruments `[verified via xctrace list instruments]`:** **Allocations**,
  **Leaks**, **VM Tracker**, **Points of Interest**, **os_signpost**, **os_log**,
  **stdout/stderr**, **Foundation Models**, **Metal Application**, **Metal GPU Counters**,
  **Metal Resource Events**, **Metal Performance Overview**, **GPU**, **Neural Engine**,
  **Core ML**, **Virtual Memory Trace**, **Sampler**, **Hangs**, **Swift Tasks/Actors**, etc.
- **Naming gotcha `[verified]`:** "Points of Interest", "VM Tracker", and "Foundation Models" are
  *instrument* names, not CLI template names — `xctrace record --template 'Points of Interest'`
  fails; you start from a template (or Blank in the GUI) and **add instruments**. The CLI supports
  this directly: `xctrace record --template Logging --instrument 'Points of Interest' …`
  `[verified flag exists; record-tested for templates]`.
- **GUI-only templates `[documented]`:** the template chooser additionally offers **Blank**
  (add instruments via the + button — WWDC25 312 demos this exact flow) and **Foundation Models**
  (the Foundation Models profiling article walks Template Selection → Foundation Models).
- **Foundation Models instrument/template — exists** `[verified instrument + documented GUI
  template]`. Lanes: Session, Request, Instructions, **Model Inference**, Tool, **Model Loading**;
  inspector shows Total Duration, Response Duration, **Time to First Token**, and token metrics
  (total/consumed/generated/cached) `[documented, Analyzing the runtime performance of your
  Foundation Models app + TN3193]`. **Critical caveat for us:** it profiles the *FoundationModels
  framework* (Apple's on-device model). MLX loads are invisible to it `[inferred]` — for MLX we use
  POI signposts + Allocations/VM Tracker/Metal instruments, while Foundation Models remains useful
  if the demo contrasts Apple's system model. WWDC26 session 243 ("Debug and profile agentic app
  experiences with Instruments") is the current deep-dive `[documented to exist]`.
- **Assumed/unverified here:** nothing above; the only assumption flagged is that GUI template
  categories match the 26 CLI templates + Blank + Foundation Models — the GUI chooser itself was
  not enumerated programmatically `[inferred]`.

### What each relevant template/instrument gives you

| Tool | Use for | Notes / citation |
|---|---|---|
| **Allocations** | Heap + anonymous VM allocation counts/sizes over time; "All Heap & Anonymous VM" | Misses private Metal resources `[documented, WWDC22 10106]`; IOAccelerator rows ≈ Metal resources, IOSurface ≈ drawables `[documented]` |
| **VM Tracker** | Footprint composition: "Dirty Size = non-compressed dirty; Swapped Size = compressed or swapped" `[documented]` | The dirty+swapped sum is the footprint the system charges `[documented]` |
| **Game Memory** | One-stop bundle: Allocations + Metal Resource Events + VM Tracker + Virtual Memory Trace + Metal Application + GPU `[documented, WWDC22 10106]` | Best single template for the MLX demo even outside games `[inferred]` |
| **Points of Interest / os_signpost** | Your signpost intervals on a timeline | See below |
| **Metal System Trace** | GPU command execution, per-frame Metal cost | Template verified recordable `[verified]` |
| **Core ML / Neural Engine** | Apple-framework model work | Will not attribute MLX GPU compute to a "model" `[inferred]` |
| **Leaks** | Leak/retain-cycle detection | Post-run check that adapters actually deallocate in the 3× teardown case |
| **Logging** | os_log + os_signpost + stdout/stderr in one record `[verified template]` | Lightweight default for demo-day capture |
| **Foundation Models** | Apple FM framework only | See caveat above |

### os_signpost / OSSignposter intervals in Points of Interest

- Signposts are emitted through the unified logging system and "Instruments displays signpost data
  visually in a timeline"; Apple's instruction is to record them with the `os_signpost`
  instrument `[documented, OSSignposter page]`. Using
  `OSSignposter(subsystem:category: .pointsOfInterest)` puts intervals in the **Points of Interest**
  track that "Instruments includes … by default" `[documented, WWDC25 308]`.
- Workflow inside Instruments `[documented, WWDC25 308]`: find your phase in the Points of
  Interest track → secondary-click the region → *Set Inspection Range* → detail views below
  (call trees, tables) now cover exactly that interval. The WWDC25 308 session does precisely this
  to bound a measured region.
- Intervals pair begin/end via an `OSSignpostID` + `OSSignpostIntervalState`; `emitEvent` marks
  durationless points (first token); `withIntervalSignpost` wraps a closure
  `[documented, OSSignposter page]`. Metadata strings (e.g. `"adapter=travel"`) appear in the
  track/table `[documented; format shown in WWDC25 308 sample code]`.

### Capturing from a physical iPhone (checklist)

Preconditions `[documented where cited]`:

1. Physical device, USB-connected, **unlocked once since boot**; trust the computer.
2. Developer Mode enabled + Developer settings trust (iOS 16+ gating for dev-signed apps and
   tracing) `[inferred as current iOS requirement; the "Developer section" toggles are also
   referenced in WWDC25 308 for Processor Trace on iPhone]`.
3. Xcode > Window > Devices and Simulators shows the iPhone; build the app for the device with a
   dev profile.
4. **No debugger**: use Product > Profile (⌘I) → template chooser (device + app preselected), or
   launch the app yourself and record with attach (below).
5. Before recording, confirm the device isn't under thermal pressure or busy
   `[documented, Foundation Models profiling article]`; airplane mode + fixed brightness for
   reproducibility `[inferred discipline]`.
6. Prefer **Deferred Mode** in recorder settings for lower overhead on automated runs
   `[documented, WWDC25 308]`.
7. Record → run the demo script (base load → adapter swap → inference) → Stop.
8. Save the trace (File > Save → `.trace` bundle) `[inferred UI path; trace bundles are the
   Instruments document format and xctrace consumes them — verified]`.

CLI (automation-friendly, all flags verified in `xctrace --help` output; pattern matches Apple's
WWDC22 sample `[documented]`):

```sh
xcrun xctrace record --device-name "iPhone" \
    --template 'Game Memory' \
    --instrument 'Points of Interest' \
    --attach "MemoryDemo" \
    --time-limit 120s \
    --output demo-run.trace
```

### Saving / exporting traces for later presentation

- `.trace` bundles reopen in Instruments for the talk; keep them with the repo's artifacts (they are
  directories — zip for transfer) `[inferred]`.
- Export tables to XML for post-processing `[verified flags; documented usage in xctrace help]`:

```sh
xcrun xctrace export --input demo-run.trace --toc                 # list tables/schemas
xcrun xctrace export --input demo-run.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-interval"]' \
    --output intervals.xml
```

- From a Metal GPU capture: File > Export (GPU trace) and Editor > Export Memory Report (CSV of the
  Memory viewer table) `[documented, Metal Analyzing memory usage]`.
- Memgraphs (`leaks $PID --outputGraph x.memgraph`, or Xcode's Debug Memory Graph → File > Export
  Memory Graph) for object-level diffs between the two architectures, analyzed with
  `vmmap --summary`, `footprint`, `heap`, `leaks --traceTree`, `malloc_history`
  `[documented, WWDC18 416 + WWDC21 10180 + WWDC22 10106]`.

---

## (e) OSSignposter snippet for the demo phases

Compile-verified (iOS 26.5 SDK, arm64). Marks: base model load, adapter load, adapter activation,
inference start, first token, inference end.

```swift
import OSLog

/// Demo-wide signposter. The .pointsOfInterest category is the one Instruments
/// shows in the Points of Interest track by default.  [documented: WWDC25 308]
enum Perf {
    static let signposter = OSSignposter(
        subsystem: "com.iosconfsg.memorydemo",
        category: .pointsOfInterest)
}

@MainActor
func runMeasuredPhase(loadBase: () throws -> Void,
                      loadAdapter: (String) throws -> Void,
                      activateAdapter: (String) throws -> Void,
                      stream: (String) -> AsyncThrowingStream<String, Error>) async throws {
    let signposter = Perf.signposter
    let id = signposter.makeSignpostID()

    // 1. Base model load (interval).
    let baseState = signposter.beginInterval("BaseModelLoad", id: id)
    try loadBase()
    signposter.endInterval("BaseModelLoad", baseState)

    for adapter in ["travel", "cooking", "medical"] {
        // 2. Adapter load (interval, labeled by adapter).
        let loadState = signposter.beginInterval("AdapterLoad", id: id, "adapter=\(adapter)")
        try loadAdapter(adapter)
        signposter.endInterval("AdapterLoad", loadState)

        // 3. Adapter activation (interval — the hot-swap cost).
        let actState = signposter.beginInterval("AdapterActivation", id: id, "adapter=\(adapter)")
        try activateAdapter(adapter)
        signposter.endInterval("AdapterActivation", actState)

        // 4–6. Inference start / first token (point event) / inference end.
        let infState = signposter.beginInterval("Inference", id: id, "adapter=\(adapter)")
        var tokens = 0
        var firstTokenSeen = false
        for try await _ in stream(adapter) {
            tokens += 1
            if !firstTokenSeen {
                firstTokenSeen = true
                signposter.emitEvent("FirstToken", id: id)   // instant, no duration
            }
        }
        signposter.endInterval("Inference", infState,
                               "\(tokens, privacy: .public) tokens")
    }
}
```

Notes: interval names must be `StaticString` literals so begin/end pair cheaply; `beginInterval`
returns state you must pass to the matching `endInterval` `[documented, OSSignposter page]`.
Also bracket each phase with `readTaskVMInfo()` calls and log the same values as signpost metadata
(e.g. `"fp=\(snapshot.physicalFootprint)"`) so memory and latency land on one timeline
`[inferred workflow]`.

---

## Instruments capture checklist (demo rehearsal)

1. ☐ Physical iPhone, unlocked, Developer Mode on, USB connected.
2. ☐ Record device model, OS build, free disk, battery > 80%, airplane mode, fixed brightness.
3. ☐ App built for profiling (Release-style); diagnostics (Malloc Stack Logging etc.) OFF for the
   measured run.
4. ☐ Choose capture: Product > Profile → *Game Memory* template (or Logging + added instruments),
   plus *Points of Interest*; Deferred Mode on.
5. ☐ Confirm POI track shows your six marks during a smoke run; secondary-click region → Set
   Inspection Range works.
6. ☐ Record the scripted run: base load → 3× adapter load/activation → inference; repeat 3–5×.
7. ☐ Stop, save `.trace`; export tables via `xctrace export --toc/--xpath`.
8. ☐ Cross-check in-app numbers: `phys_footprint` samples, `ledger_phys_footprint_peak`,
   `os_proc_available_memory()` logged to os_log and captured in the same trace.
9. ☐ Confirm no jetsam report was generated during the run (Settings > Privacy & Security >
   Analytics Data).
10. ☐ Repeat once with debugger-free cold launch from Home screen for the "published" numbers.

---

## Sources (all Apple)

**Documentation articles / symbol pages**
- os_proc_available_memory — https://developer.apple.com/documentation/os/os_proc_available_memory (iOS 13+; definition; 0-return cases; "don't cache")
- OSSignposter — https://developer.apple.com/documentation/os/ossignposter (iOS 15+; beginInterval/endInterval/emitEvent/withIntervalSignpost; os_signpost instrument)
- task_info — https://developer.apple.com/documentation/kernel/1537934-task_info ("expensive")
- task_vm_info_data_t — https://developer.apple.com/documentation/kernel/task_vm_info_data_t ; phys_footprint — …/task_vm_info_data_t/1553210-phys_footprint ; ledger_phys_footprint_peak — …/task_vm_info_data_t/3181862-ledger_phys_footprint_peak
- Xcode: Gathering information about memory use — https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use (gauge current+high-water; simulator stays green; Diagnostics/Malloc Stack; Allocations instrument)
- Xcode: Identifying high-memory use with jetsam event reports — https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports (pageSize/rpages/lifetimeMax/reasons)
- Entitlement: increased-memory-limit — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit (iOS 15+)
- Metal: Analyzing memory usage (Memory viewer) — https://developer.apple.com/documentation/xcode/analyzing-memory-usage (volatile vs footprint; private storage; GPU trace & CSV export)
- FoundationModels: Analyzing the runtime performance of your Foundation Models app — https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app (Foundation Models template; lanes; TTFT; thermal check)
- TN3193: Managing the on-device foundation model's context window — https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window (adding the Foundation Models instrument to a Blank trace)

**WWDC sessions (transcripts consulted)**
- WWDC18 416 — iOS Memory Deep Dive — https://developer.apple.com/videos/play/wwdc2018/416/ (footprint = dirty+compressed; gauge semantics; EXC_RESOURCE; VM Tracker; simulator caveat)
- WWDC21 10180 — Detect and diagnose memory issues — https://developer.apple.com/videos/play/wwdc2021/10180/ (XCTMemoryMetric; vmmap swapped=compressed; MSL zones; memgraph tools)
- WWDC22 10106 — Profile and optimize your game's memory — https://developer.apple.com/videos/play/wwdc2022/10106/ (footprint is primary/universal, includes CPU+GPU; Metal dirty via unified memory; clean resident-not-footprint; uncompressed charging; os_proc_available_memory; proc_pid_rusage + ri_lifetime_max_phys_footprint code; Game Memory template; xctrace CLI; mmap tagging)
- WWDC25 308 — Optimize CPU performance with Instruments — https://developer.apple.com/videos/play/wwdc2025/308/ (points-of-interest category default; POI track → inspection range; Deferred Mode; OSSignposter sample code)
- WWDC25 312 — Improve memory usage and performance with Swift — https://developer.apple.com/videos/play/wwdc2025/312/ (Blank template + add-instrument flow)
- WWDC26 243 — Debug and profile agentic app experiences with Instruments — https://developer.apple.com/videos/play/wwdc2026/243/ (current Foundation Models tooling; existence verified, not transcribed here)

**SDK headers read on this machine (iOS 26.5 SDK, Xcode 26.6)** `[verified]`
- `usr/include/mach/task_info.h` — task_vm_info struct + revision counts
- `usr/include/os/proc.h` — os_proc_available_memory declaration + full header doc
- `usr/include/os/signpost.h` — os_signpost interval scopes
- `usr/include/sys/resource.h` (iOS) vs `usr/include/libproc.h` (macOS) — proc_pid_rusage prototype presence

**Local CLI verification (Xcode 26.6, 17F113)** `[verified]`
- `xcrun xctrace list templates` (26 standard templates), `xcrun xctrace list instruments`
  (Points of Interest / VM Tracker / Foundation Models / os_signpost / Metal family present)
- `xcrun xctrace record/export --help` (device/attach/instrument/time-limit/output; --toc/--xpath)
- Template-name acceptance test: 'Metal System Trace' records; 'Points of Interest' /
  'VM Tracker' / 'Foundation Models' are instrument names only
- Swift compile checks (arm64-apple-ios17.0, iphoneos SDK): task_vm_info reader, peak poller,
  OSSignposter demo snippet
