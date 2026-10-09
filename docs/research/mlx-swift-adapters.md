# MLX Swift LoRA Adapter Hot-Swap — Feasibility Research (Risk A)

**Research date:** 2026-10-09 · **Environment target:** Xcode 26.6, iOS 26.5 SDK, macOS 26.6
**Scope:** one frozen LLM base model in MLX Swift on iOS + three LoRA adapters (summarize / classify / extract) activated and deactivated at runtime, vs. a naive three-model-instance mode.
**Method:** primary-source review of `ml-explore/mlx-swift`, `ml-explore/mlx-swift-lm`, `ml-explore/mlx-swift-examples`, `ml-explore/mlx-lm` at `main` as of Oct 2026 (file-level source reads, not just docs).

---

## 0. TL;DR

True adapter hot-swap — load the base model once, then load/unload/re-apply LoRA adapters on the live model without reconstructing it — **is supported by first-party Apple/ml-explore code** in the `mlx-swift-lm` package (`Libraries/MLXLMCommon/Adapters/LoRA/`), including a documented "Hot-swap Adapters" recipe in the repo's own skill reference. [documented]

```swift
let adapter = try LoRAContainer.from(directory: adapterDir)   // parse config + weights only
await container.update { context in                           // container = your one ModelContainer
    try? adapter.load(into: context.model)                    // Linear -> LoRALinear in place
}
// ... generate ...
await container.update { context in
    adapter.unload(from: context.model)                       // restore original layers
}
```

---

## 1. Ecosystem state as of October 2026 (read this first — big restructure)

The 2024-era layout you may remember is gone. Verified from the repos at `main` today:

- `ml-explore/mlx-swift-extras` **no longer exists** — `https://github.com/ml-explore/mlx-swift-extras` returns 404, and a GitHub repo search for `mlx-swift-extras` returns zero results. Any tutorial citing `MLXNNExtras`, `loraLinear()`, or `LoRAUtilities` from extras describes dead code. [documented]
- `ml-explore/mlx-swift` (core) contains **no LoRA code** — the full recursive tree of `Source/` has zero files matching `lora` (only `MLXNN/Linear.swift`, `Quantized.swift`, etc.). LoRA is *not* in core MLXNN today. [documented]
- `MLXLLM`, `MLXLMCommon`, `MLXVLM`, `MLXEmbedders` **moved out of `mlx-swift-examples`** into a dedicated libraries repo, **`ml-explore/mlx-swift-lm`** (v3.x on `main`). The examples README states: "`MLXLMCommon`, `MLXLLM`, `MLXVLM` and `MLXEmbedders` have moved to a new repository containing only reusable libraries: mlx-swift-lm." [documented]
  - Source: https://github.com/ml-explore/mlx-swift-examples/blob/main/README.md
- All adapter machinery lives in **`mlx-swift-lm` → `Libraries/MLXLMCommon/Adapters/`** (LoRAContainer, LoRA+Layers, DoRA+Layers, LoRAModel, PEFTAdapter, ModelAdapter, ModelAdapterFactory, ModelAdapterTypeRegistry), with training support in `Libraries/MLXLLM/LoraTrain.swift` and `Lora+Data.swift`. [documented]
- The old names from the task brief do **not** exist in the current API surface: there is no `loraLinear()` free function, no `loadLoRAWeights`, and no `quantizedModelLoading` in any of the four repos reviewed. The equivalent entry points are `LoRALinear.from(linear:rank:scale:dropout:)` (which internally dispatches `QuantizedLinear` → `QLoRALinear`) and `LoRAContainer.load(into:)`. [documented]
- Package versions/platforms (all verified from `Package.swift` files):
  - `mlx-swift-lm`: swift-tools 6.2, platforms **iOS 17+ / macOS 14+ / tvOS 17+ / visionOS 1+**, depends on `mlx-swift` `0.32.3..<0.33.0`. The adapter files contain no `#if os(...)` conditionals, so the load/unload path builds for iOS. [documented]
  - `mlx-swift`: swift-tools 6.3, same platform floors; products `MLX`, `MLXRandom`, `MLXNN`, `MLXOptimizers`, `MLXFFT`, `MLXLinalg`, `MLXFast`. [documented]
  - Sources: https://github.com/ml-explore/mlx-swift-lm/blob/main/Package.swift · https://github.com/ml-explore/mlx-swift/blob/main/Package.swift

## 2. (a) Can one base model be loaded once, then adapters activated/deactivated at runtime?

**Yes — supported, first-party, on the live model object.** The mechanics:

1. **Load base once.** `LLMModelFactory.shared.loadContainer(from:using:configuration:)` (or `#huggingFaceLoadModelContainer(configuration:)` macro) returns a `ModelContainer` that owns the model + tokenizer behind a serialized-access context. The container — not the model — is the long-lived object your app holds. [documented: `Libraries/MLXLMCommon/ModelContainer.swift`, `Documentation.docc/using.md`]
2. **Load adapter as data only.** `LoRAContainer.from(directory:)` reads `adapter_config.json` + `adapters.safetensors` and returns a value-type container of adapter parameters. It does **not** touch the model, does not need the model, and can be called before/without any model. [documented: `LoRAContainer.swift`]
3. **Activate = in-place module-tree surgery, not model reconstruction.** `adapter.load(into: model)` walks `model`'s `loraLayers`, and for each child matching the configured keys replaces `Linear`/`QuantizedLinear` with `LoRALinear`/`QLoRALinear` via `Module.update(modules:)`, then loads the adapter weights with `model.update(parameters:verify:.noUnusedKeys)`. The model object, its tokenizer, and all untouched modules stay identical. [documented: `LoRAContainer.swift`, `replaceLayers(in:layers:keys:transforming:)`]
4. **Deactivate = reverse surgery.** `adapter.unload(from: model)` replaces each `LoRALayer` with `lora.reverted()` — a fresh `Linear`/`QuantizedLinear` **sharing the original weight arrays** — restoring the exact pre-adapter topology. [documented: `LoRAContainer.swift`, `reverted()` default impl in `LoRAModel.swift`]
5. **There is even a no-structure-change toggle.** Every adapter layer has `loraEnabled: Bool`; `Module.setLoRAEnabled(false)` makes all `LoRALayer`s behave as plain base layers (the LoRA term is skipped in `callAsFunction`) without removing them from the tree. This exists for speculative decoding's draft/verify toggling; it is also the fastest "deactivate" for a demo (zero allocation, zero trace invalidation). [documented: `LoRAModel.swift` (`LoRALayer.loraEnabled`, `Module.setLoRAEnabled`), `LoRA+Layers.swift`]
6. **Scoped application.** `model.perform(with: adapter) { … }` loads an adapter, runs your closure (sync or async), and unloads in a `defer` — ideal for a per-task demo ("classify with adapter X for this one call"). [documented: `Adapters/ModelAdapter.swift`]
7. **Lifecycle hook.** `LanguageModel.prepare()` is documented as "Build derived state after checkpoint **or adapter topology updates** and before the model is used for inference," and the convenience wrappers (`model.load(adapter:)` etc.) call it automatically via `prepareInferenceState`. `replaceLayers` also calls `model.invalidateCompiledTraces()` because compiled traces capture the module tree. [documented: `LanguageModel.swift`, `InferenceState.swift`, `LoRAContainer.swift`]

The repo's own skill doc has a literal **"Hot-swap Adapters"** section showing `adapter1.unload(from:)` → `adapter2.load(into:)` in sequence. [documented: `skills/mlx-swift-lm/references/lora-adapters.md`]

**Caveats that matter for the demo:**
- The model type must conform to `LoRAModel` (usually a 4-line extension: `loraLayers = model.layers`). Verified conformance in-tree for `LlamaModel` (also backs Mistral); tests exercise Qwen3.5 QLoRA and Gemma4 LoRA, so coverage across the ~60 architectures in `MLXLLM/Models/` is broad, but each model opts in individually — check your specific model file. [documented for Llama/Gemma4/Qwen3.5; "broad coverage" is inferred]
- Loading adapter B while adapter A is still loaded does not error: `createReplacementLayer` matches `LoRALinear as Linear`, so B's layer replaces A's (sharing the base weight) and A's contribution is silently discarded. Correct pattern is `unload` → `load`, or `perform(with:)`. [inferred from `LoRAContainer.load(into:)` + `LoRALinear.from` source]
- KV cache entries computed under adapter A are stale under adapter B; start a fresh cache/session (new `ChatSession`/`newCache`) after a swap. [inferred — no explicit doc found; `newCache`/`prepare` semantics imply it]
- Swap cost = tree surgery over adapted layers + `update(parameters:)` + trace invalidation; no file I/O if the `LoRAContainer` was preloaded. Fast enough for a live demo; not a per-token operation. [inferred from source]

## 3. (b) Exact types and APIs (all in `mlx-swift-lm`, module `MLXLMCommon` unless noted)

Paths below are relative to https://github.com/ml-explore/mlx-swift-lm/tree/main

| Type / API | What it is | File |
|---|---|---|
| `LoRAConfiguration` | `Sendable, Codable` struct mirroring `adapter_config.json`: `num_layers`, `fine_tune_type` (`.lora`/`.dora`), `lora_parameters {rank=8, scale=10, dropout=0, keys?}` | `Libraries/MLXLMCommon/Adapters/LoRA/LoRAContainer.swift` |
| `LoRAContainer` | `struct … ModelAdapter, @unchecked Sendable`; holds `configuration` + `parameters: ModuleParameters` (eval'd at init, safe across threads) | same |
| `LoRAContainer.from(directory:)` | loads `adapter_config.json` + `adapters.safetensors` via `MLX.loadArrays(url:)` | same |
| `LoRAContainer.from(model:configuration:)` | training entry: freezes base, injects fresh (random-init) adapter layers, returns container whose `parameters` are the trainable set | same |
| `LoRAContainer.fromPEFT(directory:numLayers:)` | loads HF `peft`-format adapters (`adapter_config.json` + `adapter_model.safetensors`), renames `base_model.model.*.lora_A.weight`→`*.lora_a`, transposes to MLX layout, computes `scale = lora_alpha / r`. LORA only; throws on `use_dora=true` | `…/Adapters/LoRA/PEFTAdapter.swift` |
| `LoRAContainer.load(into:)` / `fuse(with:)` / `unload(from:)` | low-level apply / permanent merge / restore | `LoRAContainer.swift` |
| `ModelAdapter` | protocol: `load(into:)`, `fuse(with:)`, `unload(from:)` | `…/Adapters/ModelAdapter.swift` |
| `LanguageModel.load(adapter:)` / `fuse(with:)` / `unload(adapter:)` | preferred wrappers — run the adapter then `prepareInferenceState` to rebuild derived state | `ModelAdapter.swift` |
| `LanguageModel.perform(with:) { }` (sync + async) | scoped apply → run → auto-unload | `ModelAdapter.swift` |
| `LoRAModel` | per-model conformance: `loraLayers: [Module]`, `loraDefaultKeys` (default = all `Linear` keys under `loraLayers`, "aligned with mlx-lm Python logic") | `…/Adapters/LoRA/LoRAModel.swift` |
| `LoRAModelMetadata` + `ModelTypeRegistry.loraMetadata(configurationData:)` | inspect layer count & default keys without loading weights | `LoRAModel.swift` |
| `LoRALayer` | protocol: `fused() -> Module`, `reverted() -> Module`, `loraEnabled: Bool` toggle | `LoRAModel.swift` |
| `LoRALinear` / `QLoRALinear` | `LoRALinear: Linear, LoRALayer` (params `lora_a` `[in,r]`, `lora_b` `[r,out]`); `QLoRALinear: QuantizedLinear` for quantized bases. `LoRALinear.from(linear:rank:scale:dropout:)` auto-dispatches quantized layers to `QLoRALinear` | `…/Adapters/LoRA/LoRA+Layers.swift` |
| `DoRALinear` / `QDoRALinear` | DoRA variants adding `m` (magnitude) parameter | `…/Adapters/LoRA/DoRA+Layers.swift` |
| `Module.setLoRAEnabled(_:)` | walk submodules, toggle every `LoRALayer` | `LoRAModel.swift` |
| `LoRATrain` (module `MLXLLM`) | training loop: `LoRATrain.train(model:train:validate:optimizer:tokenizer:parameters:progress:)`, `saveLoRAWeights(model:url:)`, `evaluate` | `Libraries/MLXLLM/LoraTrain.swift` |
| `ModelAdapterTypeRegistry` | registry of `(adapterType) -> (URL) throws -> ModelAdapter` creators | `…/Adapters/ModelAdapterTypeRegistry.swift` |
| `ModelContainer` / `ModelContext` | serialized model access: `container.perform { ctx in … }`, `container.update { ctx in … }` | `Libraries/MLXLMCommon/ModelContainer.swift` |
| `LLMModelFactory.shared.loadContainer(from:using:configuration:)`, `LLMRegistry` | one-time base model load | `Libraries/MLXLLM/LLMModelFactory.swift` |

**How adapter application mutates the module tree** (`LoRAContainer.load(into:)`):
1. `let layers = lora.loraLayers.suffix(configuration.numLayers)` — only the last N transformer blocks are candidates (mlx-lm parity).
2. For each candidate layer, `namedModules()` filtered by `keys` (from config, else `loraDefaultKeys`).
3. Matching children are transformed (`Linear`→`LoRALinear`/`DoRALinear`; `QuantizedLinear` handled inside `.from`), then `layer.update(modules: .unflattened(update))` swaps them **in place**.
4. `model.update(parameters: parameters, verify: .noUnusedKeys)` fills `lora_a`/`lora_b` — verification fails loudly if the adapter's keys don't match the model.
5. `model.invalidateCompiledTraces()` + (via the `LanguageModel` wrapper) `prepare()` / `prepareInferenceState`.
[documented: `LoRAContainer.swift` lines implementing `load(into:)` and `replaceLayers`] — note there is no separate "quantizedModelLoading" API; quantization is handled by the layer-class dispatch inside `LoRALinear.from`.

## 4. (c) Swift package products to import

```swift
dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
    // only if you use the MLXHuggingFace macro integration:
    .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
]

.target(name: "DemoApp", dependencies: [
    .product(name: "MLXLLM", package: "mlx-swift-lm"),        // model impls, LLMRegistry, LLMModelFactory, LoRATrain
    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),   // LoRAContainer, ModelAdapter, ModelContainer, ChatSession
    .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),// #hubDownloader() / #huggingFaceTokenizerLoader() macros (optional)
    .product(name: "HuggingFace", package: "swift-huggingface"),       // with the macro integration
    .product(name: "Tokenizers", package: "swift-transformers"),
    // pulled transitively; import only if you touch these directly:
    // .product(name: "MLX", package: "mlx-swift"),           // MLXArray, MLX.loadArrays, Memory
    // .product(name: "MLXNN", package: "mlx-swift"),         // Module, Linear, QuantizedLinear
    // .product(name: "MLXRandom", package: "mlx-swift"),     // only when creating NEW adapters programmatically
    // .product(name: "MLXOptimizers", package: "mlx-swift"), // only for on-device training (Adam etc.)
])
```
[documented: `mlx-swift-lm/Package.swift` products; `README.md` Package.swift sample; `Documentation.docc/using.md`]

Do **not** add `mlx-swift-examples` (no longer ships these libraries) or `mlx-swift-extras` (deleted). [documented]

## 5. (d) File format / naming the Swift API expects

**MLX-native format** (what `LoRAContainer.from(directory:)` hardcodes — both file names are non-negotiable):
```
<adapter-dir>/
  adapter_config.json      # LoRAConfiguration JSON
  adapters.safetensors     # flat keys: "<layer-path>.lora_a" [in, r], "<layer-path>.lora_b" [r, out]
```
`adapter_config.json`:
```json
{ "fine_tune_type": "lora", "num_layers": 28,
  "lora_parameters": { "rank": 16, "scale": 20.0, "dropout": 0.05,
    "keys": ["self_attn.q_proj", "self_attn.v_proj"] } }
```
- This is exactly what Python `mlx_lm.lora` writes: "By default, the adapter config and learned weights are saved in `adapters/`" (override with `--adapter-path`); resume with `--resume-adapter-file <path_to_adapters.safetensors>`; generate with `mlx_lm.generate --adapter-path <path_to_adapters>`; `mlx_lm.fuse` reads `adapters/` by default. HF repos in the MLX ecosystem keep this under an `adapters/` subdirectory — point `from(directory:)` at that subdirectory. [documented: `LoRAContainer.swift`; https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md]
- `dropout` is training-only; `ModelContext` puts the model in eval mode so it is deterministic at inference. [documented: skill reference + `LoRATrain`]
- `keys` are matched relative to each entry of `loraLayers` (e.g. `"self_attn.q_proj"`), not absolute model paths. [documented: `LoRAContainer.replaceLayers` + PEFTAdapter's `stripLayerPrefix` comment]

**PEFT format** (what `LoRAContainer.fromPEFT(directory:)` accepts):
```
<adapter-dir>/
  adapter_config.json      # {"peft_type":"LORA","r":128,"lora_alpha":512,"lora_dropout":0,
                           #  "target_modules":["o_proj"],"use_dora":false}
  adapter_model.safetensors  # "base_model.model.<path>.lora_A.weight" [r,in], ".lora_B.weight" [out,r]
```
Loader strips the `base_model.model.` prefix, renames to `lora_a`/`lora_b`, transposes, and computes `scale = lora_alpha / r`. So adapters trained with HF `peft`/`transformers` on the *same base checkpoint* load directly in Swift. [documented: `PEFTAdapter.swift`, header dated 5/21/26]

**DoRA:** MLX-native `fine_tune_type: "dora"` plus an `m` (magnitude) tensor per adapted module; PEFT import of DoRA throws `unsupportedAdapterType`. [documented: `DoRA+Layers.swift`, `PEFTAdapter.swift`]

**Scale semantics pitfall:** MLX-native configs store `scale` directly (default 10.0, mlx-lm convention); PEFT stores `alpha` and the loader derives `scale = alpha/r`. Don't hand-write an MLX config using alpha. [documented]

## 6. (e) Memory behavior

**Applying an adapter allocates new arrays per target module — but never copies base weights:**
- `LoRALinear.init` calls `super.init(weight: linear.weight, bias: linear.bias)` — MLXArray is a reference handle, so the replacement layer **shares** the base weight/bias storage. `QLoRALinear` additionally shares `scales`/`biases`. [documented: `LoRA+Layers.swift`]
- New allocations per adapted module: `loraA [inputDim, rank]` + `loraB [rank, outputDim]` (+ magnitude `m [outputDim]` for DoRA) and a `Dropout` module. The old `Linear` shell is released. [documented]
- The container's `parameters: ModuleParameters` are the safetensors values, `eval()`'d once at init; `model.update(parameters:)` binds them into the tree — array copy-on-write means container and tree share storage at inference time. Steady-state cost ≈ one copy of the adapter weights + tiny per-module overhead. [documented for the calls; COW-sharing is inferred from MLXArray semantics]
- Documented sizing: "For rank=8 on a 7B model: ~10–20MB additional memory." For a 3–4B demo base, three rank-8/16 adapters are tens of MB total — versus gigabytes for the naive three-instance mode. [documented (skill reference) for the 7B figure; demo extrapolation is arithmetic]
- `load(into:)` init also allocates random A / zero B before `update(parameters:)` overwrites them (visible in `LoRALinear.init`), so a brief transient exists; loading pre-built `LoRAContainer`s avoids file I/O at swap time. [documented for init; transient-peak note inferred]

**Deactivation and freeing:**
- `unload(from:)` → `reverted()` constructs a fresh `Linear`/`QuantizedLinear` sharing the same base arrays; the removed `LoRALinear` and its `lora_a`/`lora_b` become unreachable and are freed by ARC + MLX's allocator. [documented for the topology change; actual reclamation semantics below]
- MLX keeps *recycled* buffers in a pool: freed buffers may linger as `cacheMemory` (observable via `Memory.snapshot()`). On iOS (jetsam) you can bound/reclaim it with `Memory.cacheLimit` / `Memory.clearCache()` — "Adjusting the cache limit is especially advantageous on devices with memory limits (e.g. iOS devices where jetsam limits apply)." [documented: `mlx-swift/Source/MLX/Memory.swift`]
- Alternative that frees *nothing but costs nothing*: `setLoRAEnabled(false)` skips the LoRA math while A/B stay resident — good for a quick A/B toggle in the demo; use `unload` when you actually want the memory back. [documented toggle; usage advice inferred]
- No adapter-weight caching layer exists beyond the `LoRAContainer` values you hold yourself — preloading all three containers up front is the "cache" (three adapter-weight sets stay resident; swap then costs no I/O). [inferred from API shape]

**Other documented caches/state affected:** compiled traces are invalidated on any layer replacement (`replaceLayers` → `invalidateCompiledTraces()`); derived inference state rebuilt via `prepare()`; generation-time wired memory is budgeted via `WiredMemoryTicket`/policies (iOS-relevant, orthogonal to adapters). [documented: `LoRAContainer.swift`, `InferenceState.swift`, `skills/mlx-swift-lm/references/wired-memory.md`]

## 7. (f) Is anything blocked?

Nothing blocks true hot-swap — the API is purpose-built for it (`perform(with:)` exists precisely for transient application). Residual risks to manage in the demo, all minor:
1. **Unload-then-load discipline** (loading B over A silently discards A). [inferred]
2. **Fresh KV cache / ChatSession after a swap** to avoid mixing adapter contexts. [inferred]
3. **Model must conform to `LoRAModel`** — verify the exact checkpoint family you ship; Llama/Mistral, Gemma4, Qwen3.5 verified. [documented examples]
4. **Same-base requirement**: adapter `keys`/`num_layers` must match the base architecture or `update(parameters:verify:.noUnusedKeys)` throws — which is a *good* loud failure. [documented]
5. Mixed fp16 adapter / bf16 base dtype handling is done for you (output cast to base dtype, per `Qwen35QLoRATests` regression for issue #561). [documented]

**Naive comparison mode** (three independent instances) needs no special support: hold three `ModelContainer`s of the same configuration. [documented container API]

## 8. Provenance of key sources

- `LoRAContainer.swift`, `LoRAModel.swift`, `LoRA+Layers.swift`, `DoRA+Layers.swift` headers: "Created by Ivan Petrukha on 02–03.06.2025" (June 2025). `PEFTAdapter.swift`: "Created by Sachin Desai on 5/21/26". The subsystem is ~16 months mature with an active 2026 maintenance record (fp16/bf16 regression fix for Qwen3.5, dropout validation, spec-decode toggle). [documented]
- In-repo official reference: https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/lora-adapters.md ("Adapters can be loaded, applied, fused, or removed from models at runtime", "Hot-swap Adapters" section, memory table).
- Working end-to-end consumer: https://github.com/ml-explore/mlx-swift-examples/blob/main/Tools/llm-tool/LoraCommands.swift (`lora train|fuse|test|eval` using `LoRAContainer.from`, `model.load(adapter:)`, `model.fuse(with:)`); app example: `Applications/LoRATrainingExample` (macOS-only *training* demo; inference-time adapter use has no such restriction). [documented]
- Regression tests: `Tests/MLXLMTests/Qwen35QLoRATests.swift` (QLoRA over 4-bit quantized model, asserts layers become `QLoRALinear`), `Gemma4LoRATests.swift`, `LoRADropoutTests.swift`, `LoRAModelMetadataTests.swift`. [documented]
- No community/forum sources were needed; all load-bearing claims above are primary-source. [documented]

---

VERDICT Risk A (adapter hot-swap): supported

Concrete API entry points to use:
- `import MLXLLM`, `import MLXLMCommon` (package `mlx-swift-lm` ≥ 3.x; optionally `MLXHuggingFace` + `swift-huggingface`/`swift-transformers` for hub download)
- Load base once: `LLMModelFactory.shared.loadContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: .init(id: "mlx-community/<base>-4bit"))`
- Prepare adapters: `try LoRAContainer.from(directory: adaptersDir)` (MLX-native `adapter_config.json` + `adapters.safetensors`, e.g. produced by `mlx_lm.lora --adapter-path`) or `try LoRAContainer.fromPEFT(directory:)` (HF `peft` format)
- Activate/deactivate on the live model: `try model.load(adapter:)` / `model.unload(adapter:)` / scoped `try model.perform(with: adapter) { … }` (or `container.update { try adapter.load(into: $0.model) }` / `adapter.unload(from:)`); instant toggle: `model.setLoRAEnabled(false)`
- Permanent merge (optional, for export): `try model.fuse(with: adapter)`
- Memory control: preload all `LoRAContainer`s; `Memory.cacheLimit` / `Memory.clearCache()` after unload on iOS
