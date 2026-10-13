# Findings

Running record, handoff §26. Labels: [measured] on device, [measured-mac] on this
Mac, [documented] from sources, [inferred] reasoning, [pending] to measure.

## Established during Phase 0–3 build

1. **The 2024-era MLX Swift tutorials are dead code.** `mlx-swift-extras` is
   deleted; `loraLinear()`/`loadLoRAWeights` do not exist. The live stack is
   `ml-explore/mlx-swift-lm` (v3.32.3, MLXLLM + MLXLMCommon). [documented]
2. **True adapter hot-swap is a first-party API**: `LoRAContainer.from(directory:)`
   parses weights as data; `load(into:)`/`unload(from:)` do in-place module-tree
   surgery on a live model. Qwen3 conforms to `LoRAModel` at 3.32.3 (verified in
   `Libraries/MLXLLM/Models/Qwen3.swift`). [documented]
3. **The iOS 26.5 SDK cannot compile mlx-swift-lm's MLXHuggingFace product**
   (FoundationModelsIntegration trait references iOS 27 symbols absent from the
   26.5 SDK). Linking only MLXLLM + MLXLMCommon sidesteps it — SwiftPM builds
   the closure of linked products only. [measured-mac, build verified]
4. **A ~50-line wrapper around swift-transformers replaces the hub tokenizer
   loader** for bundle-only loading; no network path in the app. [measured-mac]
5. **Xcode 26 ships the Metal compiler as a separate download.** MLX's .metal
   kernels fail until `xcodebuild -downloadComponent MetalToolchain` (687.9 MB).
   [measured-mac]
6. **One QLoRA adapter (rank 8, all-linear keys, last 16 of 28 layers) is
   ~20 MB** for Qwen3-1.7B — vs 968 MB for the full 4-bit model. Three adapters
   ≈ 60 MB ≈ 6% of one extra model instance. [measured-mac, training artifacts]
7. **mlx-lm on system Python 3.9 installs an older mlx (0.29.3) but trains
   QLoRA fine** and writes the standard MLX-native adapter format the Swift
   side expects. [measured-mac]

## Open items (device runs pending)

- Adapter switch latency (`unload`+`load` on device) — [pending]
- TTFT warm vs after-switch — [pending]
- Whether three naive instances fit under jetsam with the increased-memory
  entitlement on an 8 GB device, and the real footprint curve — [pending]
- Footprint after Unload/Reset: how much stays in MLX's allocator cache
  (Risk B) — [pending]. `Memory.cacheLimit`/`clearCache()` controls exist;
  app does not call them yet.
- Whether `/no_think` reliably suppresses reasoning tokens in Swift (training
  data includes it for summarize/extract; classify's label-only output makes
  it moot there) — [pending]

## Surprises so far

- The adapter-size estimate from research (~2 MB, q/v-only keys) was low: the
  mlx-lm default omits `keys`, which adapts ALL linear layers (~5M params,
  20 MB). We kept defaults for Swift-side parity (`loraDefaultKeys` = all).
