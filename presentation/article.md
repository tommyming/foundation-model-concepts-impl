# One Base Model, Many Tasks: On-Device AI Memory Management on iOS

*Companion article for the iOSConf SG 2027 talk "On-Device AI Memory Management: Running Multi-Task Models Within iOS Resource Limits."*

---

Here is a pattern spreading through iOS apps right now. The team ships an AI summarizer, so they bundle a model. Next quarter they add a classifier, so they bundle another model. Then an extractor, a recommender, a rewriter. Each feature owns its own model file, its own runtime, its own memory. Nobody planned this. Each decision was locally reasonable. On a phone, the bill arrives fast.

This article walks through the alternative we built as a working demo. One frozen base model stays resident in memory. Three task-specific LoRA adapters hot-swap on it in milliseconds. A naive three-model mode exists purely to show what the old pattern costs. Everything runs on-device, from the app bundle, with airplane mode on.

## The arithmetic that motivates everything

Our demo uses `mlx-community/Qwen3-1.7B-4bit` — a 1.7-billion-parameter model, 4-bit quantized, 968 MB on disk. Small by modern standards, and still enough for instruction following when a LoRA adapter does the task shaping.

The comparison:

| Architecture | What sits in memory | Weights total |
|---|---|---|
| Naive: one model per feature | 3 × 968 MB | ~2.9 GB |
| Shared: one base + three adapters | 968 MB + 3 × 20 MB | ~1.03 GB |

One adapter is about 2% of the base model. All three together cost about 6% of a single extra model instance. That ratio is the whole talk.

## What a LoRA adapter actually is

A LoRA (Low-Rank Adaptation) adapter freezes the base model and learns a small delta. For each adapted weight matrix, it learns two thin matrices — rank 8 in our case — whose product approximates the change the task needs. At inference, the layer computes `base(x) + scale · B(A(x))`. The base weights never change.

We train each adapter against the exact 4-bit checkpoint the app ships, which makes it QLoRA. The adapter learns the task on top of the quantized weights the user's phone will actually run.

The output of training is two small files:

```text
adapters/classify/
  adapter_config.json    934 bytes
  adapters.safetensors   19.9 MB
```

Twenty megabytes turns a general model into a classifier. Another twenty makes it a summarizer. A third makes it an extractor. The specialization is data, not architecture.

## Apple already runs this pattern

The system-level precedent matters, so the demo opens with it.

Apple's Foundation Models framework exposes one frozen, OS-owned ~3B-parameter model. Every app on the phone shares that single copy. Apps request capabilities — guided generation with `@Generable`, tool calls, structured output — and never touch the model's lifetime. The operating system loads it, evicts it under pressure, and updates it with the OS. The app's memory footprint stays clean of model weights entirely.

Apple's own July 2025 tech report names the mechanism. The framework "exposes guided generation, constrained tool calling, and LoRA adapter fine-tuning." Dig into the SDK and you find `SystemLanguageModel.Adapter`. It is a real, public-in-SDK type with `init(fileURL:)` and `compile()`, present since iOS 26.0 — and completely undocumented. There is no public file format, no training tool, no authoring pipeline. Third parties can load adapters that Apple ships, and nothing more.

So the architecture is confirmed at the platform level, but the adapter half is closed to apps. That is the gap the demo fills on our own stack.

## Building it in MLX Swift

The custom runtime uses MLX Swift, Apple's array framework for Apple silicon. Two things anyone starting in 2026 should know, because most tutorials online are wrong about both:

**The ecosystem moved.** The 2024-era layout is gone. `mlx-swift-extras` is deleted. The old entry points — `loraLinear()`, `loadLoRAWeights` — do not exist. The language-model stack (`MLXLLM`, `MLXLMCommon`) now lives in its own repository, `ml-explore/mlx-swift-lm`, which also absorbed the Python-side conventions. Any blog post pointing you at the old repos describes dead code.

**Hot-swapping is first-party.** You do not need to rebuild the model or fuse weights to switch tasks. The flow in our `ModelManager`:

```swift
// Once, at startup: load the base model from the app bundle.
let container = try await loadModelContainer(
    from: bundledModelDir, using: BundleTokenizerLoader())

// Per task switch: unload the old adapter, load the new one,
// on the live model. No reconstruction.
await container.update { context in
    oldAdapter?.unload(from: context.model)   // Linear restored in place
    try newAdapter.load(into: context.model)  // Linear -> LoRALinear, shared base weights
}
```

`LoRAContainer.from(directory:)` parses the adapter as plain data — you can hold all three parsed containers ready, so a switch costs no file I/O. `load(into:)` performs in-place surgery on the module tree: each adapted `Linear` becomes a `LoRALinear` that *shares* the base weight arrays and adds the small A/B matrices. `unload(from:)` reverses it. The model object, tokenizer, and untouched layers stay identical throughout.

Three rules the APIs do not enforce for you, which the demo's manager does:

1. **Unload before load.** Loading adapter B over adapter A does not error — it silently discards A's contribution.
2. **Fresh KV cache after a swap.** Keys and values computed under adapter A are stale under B.
3. **Per-task system prompts** must match what each adapter was trained on.

There is also a zero-cost toggle, `setLoRAEnabled(false)`. It skips the LoRA math while the layers stay in the tree — useful for A/B demonstration, not for reclaiming memory.

## The demo: same note, three owners

The app tells the ownership story in three stages, deliberately reusing the same input note and the same three tasks:

1. **Native.** One `LanguageModelSession` on Apple's frozen system model. One guided extraction. The app owns none of it.
2. **Bundled, naive.** The same tasks, now on models the app owns — one full instance per feature. The resident list grows to three, and the footprint number climbs with each tap.
3. **Bundled, shared.** One base, three adapters, hot-swapped without an app restart. The base stays resident. Only the adapter name changes.

Stage 2 and stage 3 run in the same process under the same metric, so they chart together. Stage 1 is a story beat and never appears on the memory chart. The system model is a different model in a different process, and pretending otherwise would be a false comparison.

## Measuring honestly

Three measurement decisions worth stealing for any on-device benchmark:

**Publish `phys_footprint`, not `resident_size`.** Footprint is the metric jetsam enforces and the Xcode gauge shows. On Apple silicon it includes dirty CPU *and* GPU memory — which is where MLX's Metal-backed tensors live. `resident_size` overcounts clean mapped pages and misses private Metal allocations entirely. An app that mmaps a 968 MB safetensors file sees resident memory inflated by file-cache pages that cost the process nothing.

**Simulator numbers are not numbers.** macOS never jetsams the simulator process. The gauge stays green at memory levels that would kill the app on device. Final measurements come from a physical iPhone, debugger detached, airplane mode on.

**Protocol beats discipline.** One warm-up run, five measured, median and range reported, environment recorded — device, OS, model revision, adapter revisions, thermal state. The demo app automates this and exports JSON with the metadata attached. Our article and slides cite that JSON. Nothing is hand-typed.

*(Editor's note: device measurements — switch latency, time-to-first-token, footprint curves for both architectures — are being captured at the time of this draft. Placeholder values will be replaced with the exported JSON results and archived in the repo's `presentation/numbers.md`.)*

## What surprised us

The negative and unexpected results are the interesting ones, so they stay in the talk:

- **The adapters are 20 MB, not 2 MB.** Our estimate assumed q/v-projection targeting only. The default in mlx-lm — and, for parity, the Swift default — adapts *all* linear layers in the last 16 transformer blocks. Roughly 5M parameters per adapter. Still cheap, just bigger than advertised.
- **Memory does not return when you release it.** MLX keeps freed buffers in a recycling cache (`Memory.cacheLimit` / `Memory.clearCache()` exist to control it). "Object released" and "footprint dropped" are different moments. How different, on device, is one of the measurements we export.
- **macOS kills long GPU work when the machine is in use.** Training runs died mid-flight with `kIOGPUCommandBufferCallbackErrorImpactingInteractivity` — the interactivity watchdog. Checkpoint resume let both training runs survive the watchdog and finish on the next attempt. That lesson transfers to any long-running on-device ML work.
- **Xcode 26 ships the Metal compiler as a separate download.** MLX's `.metal` kernels fail to build until you run `xcodebuild -downloadComponent MetalToolchain`. Not documented anywhere you would look first.

## The rule the demo argues for

Neither mode in the demo is "the right answer" in general. The rule is about ownership:

> AI features should request capabilities. They should not independently own expensive model resources.

When the platform owns the model — Foundation Models, the OS-managed case — it enforces the discipline for you. When your app owns the model, that discipline becomes your job. The job has three parts: one owner for the base model's lifetime, adapters as explicit loadable resources, and every transition measured. The `ModelManager` actor in the demo is that discipline, written down in about 200 lines of Swift.

One base model. Many tasks. Megabytes, not gigabytes.

---

*The demo app, training pipeline, research notes, and measurement protocol are open in the companion repository. Every number cited here traces to a file in `presentation/numbers.md`.*
