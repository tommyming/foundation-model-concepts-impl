# Phase 0 feasibility

Date: 2026-10-09.

Accepted design decisions that extend this research live in `docs/decisions.md`.

This note records the Phase 0 probe for the iOSConf SG 2027 demo. It is a research record. It is not product code.

Evidence lives in:

- `docs/research/mlx-swift-adapters.md`
- `docs/research/foundation-models.md`
- `docs/research/model-candidates.md`
- `docs/research/memory-and-instruments.md`

## Verdict

The demo is feasible. The core experiment does not need a substitute architecture.

You can load one frozen base model in MLX Swift on iOS. You can then load and unload LoRA adapters on that live model. Apple ships this path in `ml-explore/mlx-swift-lm`. You do not rebuild the model for a swap. You do not fuse the adapter for the live path.

Python `mlx_lm.lora` writes `adapter_config.json` and `adapters.safetensors`. Swift `LoRAContainer.from(directory:)` reads those same files.

## Local toolchain

Checked on this machine on 2026-10-09.

| Item | Value |
|---|---|
| Active Xcode | 26.6, build 17F113 |
| Active iOS SDK | iOS 26.5 |
| Also installed | Xcode 27 (iOS 27.0 SDK), Xcode 27.1 RC (iOS 27.1 SDK) |
| `FoundationModels.framework` | Present in the iOS 26.5 SDK and the iOS 27.1 SDK |
| Foundation Models instrument | Present in Xcode 26.6 as an instrument name, not as a template file |
| Foundation Models template file | Present in Xcode 27 and Xcode 27.1 RC Instruments |

The Foundation Models instrument profiles Apple's framework. It does not profile MLX.

## Risk results

| Handoff risk | Result | Evidence |
|---|---|---|
| A. Adapter hot-swap | Supported | `docs/research/mlx-swift-adapters.md` |
| B. Memory return after unload | Measurable. Not yet measured on a phone. | `docs/research/memory-and-instruments.md` |
| C. Shared pages between model instances | Still open. Measure before you claim duplication. | Not proven by this probe |
| D. Adapter quality | Training path exists. Quality is a later gate. | `docs/research/model-candidates.md` |
| E. Conference thermals | Protocol exists. Keep live cold starts prerecorded. | Handoff section 25, plus the memory note |
| Apple-native adapter demo | Possible only in a reduced form | `docs/research/foundation-models.md` |

## What the probe proved

1. True hot-swap is a first-party API. Use `LoRAContainer.from(directory:)`, `model.load(adapter:)`, `model.unload(adapter:)`, `model.perform(with:)`, and `setLoRAEnabled`.
2. The live Swift package is `ml-explore/mlx-swift-lm` release 3.32.3. `mlx-swift-extras` is deleted. `loraLinear()` and `loadLoRAWeights` no longer exist.
3. Adapter layers share the base weight arrays. A rank-8 adapter is about 10 to 20 MB on a 7B model. A 1.7B demo base should stay in the tens of MB per adapter.
4. The recommended base is `mlx-community/Qwen3-1.7B-4bit`. It is 0.97 GB, Apache-2.0, and it has a named Swift preset.
5. Disable Qwen3 thinking mode, or time-to-first-token will be too slow for a live demo.
6. The Apple reference section can show a frozen system model plus guided output on Xcode 26.6 today.
7. Publish `task_vm_info.phys_footprint`. It is the jetsam metric. It includes dirty CPU and GPU memory on Apple silicon.

## What the probe did not prove

These items do not block the architecture. Do not treat them as measured facts.

- Peak memory, time-to-first-token, and adapter-switch time on a physical iPhone.
- Whether MLX maps the same weight file into more than one model instance.
- When `phys_footprint` falls after `unload` and `Memory.clearCache()`.
- Whether the Swift chat template accepts `enable_thinking=false`. The fallback is `/no_think` in the system prompt.

## Gate before you train adapters

The LoRA tests in `mlx-swift-lm` cover Llama, Gemma 4, and Qwen3.5. They do not explicitly cover Qwen3.

Check that the Qwen3 model type conforms to `LoRAModel` before you train three adapters. If it does not, check `Qwen3-0.6B-4bit` the same way, or move to a verified family. Do not train first and discover the mismatch later.

## Apple reference section

You can build `LanguageModelSession` with `@Generable` and `@Guide` on the iOS 26.5 SDK. Runtime still needs an Apple Intelligence device.

`SystemLanguageModel.Adapter` exists in the iOS 26.5 and iOS 27.1 SDKs. Apple's July 2025 tech report names LoRA fine-tuning. There is no public file format, no training tool, and no documentation. Do not build the live swap on that type.

iOS 27 adds Dynamic Profiles, image input, Private Cloud Compute, and the `LanguageModel` provider protocol. Those symbols need Xcode 27.

## Study list

Study the current repos. Ignore blog posts that cite `mlx-swift-extras`, `loraLinear()`, or `loadLoRAWeights`.

Read the items in order. Each number below is one required study item.

### Before any app code

1. Read the hot-swap recipe at <https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/lora-adapters.md>. Learn `LoRAContainer.from(directory:)`, `load(into:)`, `unload(from:)`, `perform(with:)`, and `setLoRAEnabled`.
2. Read `Libraries/MLXLMCommon/Adapters/LoRA/LoRAContainer.swift` and `Libraries/MLXLMCommon/Adapters/ModelAdapter.swift` in `ml-explore/mlx-swift-lm` release 3.32.3. Learn this rule. Unload adapter A before you load adapter B. Start a new KV cache after each swap.
3. Read `Libraries/MLXLLM/LLMModelFactory.swift` in the same repo. Learn `LLMTypeRegistry`, `LLMRegistry`, and `loadContainer`.
4. Read the Qwen3 model card at <https://huggingface.co/Qwen/Qwen3-1.7B>. Learn the thinking switch. The 4-bit mirror is `mlx-community/Qwen3-1.7B-4bit`.
5. Read WWDC22 session 10106, "Profile and optimize your game's memory" (<https://developer.apple.com/videos/play/wwdc2022/10106/>). Learn why you publish `phys_footprint`. It includes dirty CPU and GPU memory on Apple silicon. `resident_size` counts clean mapped pages and misses private Metal memory.
6. Skim `docs/research/mlx-swift-adapters.md` and `docs/research/model-candidates.md` in this repo. They record the API names and the model table with sources.

### For the single-model baseline

7. Read `Documentation.docc/using.md` in `mlx-swift-lm`. Also read the `LLMBasic` app in `ml-explore/mlx-swift-examples`.
8. Read `Source/MLX/Memory.swift` in `ml-explore/mlx-swift`. Learn `Memory.snapshot()`, `Memory.cacheLimit`, and `Memory.clearCache()`. The cache matters on iOS because jetsam uses footprint, and MLX may keep freed buffers.
9. Read the `OSSignposter` documentation at <https://developer.apple.com/documentation/os/ossignposter>. Also read the Points of Interest instrument. Mark base load, adapter load, adapter activation, first token, and inference end.
10. Read `docs/research/memory-and-instruments.md`. Use `task_vm_info.phys_footprint` for samples. Use `ledger_phys_footprint_peak` for the lifetime peak. Poll about every 50 ms inside a phase if you need a phase peak.

### For adapters

11. Read <https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md> and `examples/lora_config.yaml` in that repo. The trainer is the standalone repo `ml-explore/mlx-lm`. It is not a folder inside `ml-explore/mlx`.
12. Learn these defaults. Rank is 8. Scale is 20.0. The trainer adapts the last 16 layers. Mask the loss to the assistant text. Train QLoRA against the same 4-bit repo you ship. mlx-lm stores `scale`, not `alpha`.
13. Learn the two on-disk formats. The MLX-native format uses `adapter_config.json` plus `adapters.safetensors`. The Hugging Face PEFT format uses `adapter_model.safetensors` and `LoRAContainer.fromPEFT(directory:)`. Ship each adapter directory in the app bundle. Do not fuse adapters for the live demo.

### For the Apple reference section only

14. Read the Foundation Models documentation for `LanguageModelSession`, `@Generable`, and `@Guide`. A minimal example is in `docs/research/foundation-models.md`.
15. Read WWDC25 session 259 for the iOS 26 surface. Read the iOS 27 Foundation Models material only if you build with Xcode 27. New pieces there include Dynamic Profiles, image input, and the `LanguageModel` provider protocol.
16. Do not study `SystemLanguageModel.Adapter` as a build path. It has no public authoring story. Mention it as evidence that Apple uses the same frozen-model-plus-adapter idea.

### For measurement, after the app runs

17. Read "Gathering information about memory use" at <https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use>. Simulator numbers are not valid. Debug-scheme malloc logging is not valid. Publish numbers from a physical iPhone, with the debugger detached, in the profiling configuration.
18. Read TN3193 at <https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window> only for the Apple-native trace. Add the Foundation Models instrument to a blank trace. For MLX, use Points of Interest, Allocations, VM Tracker, and Metal instruments.
19. Read "Identifying high-memory use with jetsam event reports" at <https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports>. Also read the entitlement page at <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit>. You may need that entitlement for the three-instance mode. Record whether you used it. Do not hide it.

## What you can defer

Defer LRU caching, memory-pressure eviction, two-device comparisons, and quantization comparisons. The talk fails if adapter swap or the memory chart is missing. It does not fail if the cache policy is missing.
