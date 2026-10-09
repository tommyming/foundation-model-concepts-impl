# Model Candidates — MLX Swift on iPhone + mlx-lm LoRA Training Path

**Research task 3 of 4 — status of the ecosystem as of October 9, 2026.**
All facts below were verified against primary sources (GitHub source code, HF model cards / API metadata) on this date. File sizes are the exact `model.safetensors` / repo sizes reported by the Hugging Face API, in decimal GB. Items marked *(estimate)* still need on-device measurement per the handoff's measurement protocol.

---

## TL;DR

- **Recommended base model: `mlx-community/Qwen3-1.7B-4bit`** — 0.97 GB 4-bit weights, Apache-2.0, first-class Swift support (named `LLMRegistry` preset), mature Python LoRA path, and adequate instruction following (IFEval 74.0 in non-thinking mode). Disable its "thinking" mode for a fast-TTFT live demo.
- **Training: `mlx_lm.lora`** (mlx-lm v0.31.3, now a standalone repo `ml-explore/mlx-lm`). Defaults: LoRA rank 8, scale 20.0, dropout 0.0, last 16 layers, 1000 iterations, batch 4, lr 1e-5. Output = `adapters/` dir with `adapter_config.json` + `adapters.safetensors` (≈ 2–20 MB per adapter).
- **iOS: no conversion needed.** Swift `LoRAContainer.from(directory:)` in `ml-explore/mlx-swift-lm` reads *exactly* the files Python writes, and supports runtime `load` / `unload` / `fuse` / toggle — i.e. true adapter hot-swapping on device. Ship each adapter directory as a bundle resource.
- **Ecosystem restructuring warning (Oct 2026):** `mlx_lm` moved out of `ml-explore/mlx` into its own repo; the Swift LM stack moved from `mlx-swift-examples/Libraries` into a new repo `ml-explore/mlx-swift-lm` (current release **3.32.3**, Sept 30 2026, built on mlx-swift 0.32.3). Older blog posts pointing at `python/mlx_lm/LORA.md` in the mlx repo and `MLXLMCommon` in mlx-swift-examples are stale.

---

## 1. Ecosystem state (verified Oct 9, 2026)

| Piece | Where it lives now | Version checked | Notes |
|---|---|---|---|
| Python LoRA trainer | [`ml-explore/mlx-lm`](https://github.com/ml-explore/mlx-lm) (standalone repo) | latest release **v0.31.3** (2026-04-22); docs fetched from `main` | `mlx_lm.lora` CLI; `mlx_lm/LORA.md`; `examples/lora_config.yaml` |
| Swift LM packages (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, …) | [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) | latest release **3.32.3** (2026-09-30) | LoRA runtime in `Libraries/MLXLMCommon/Adapters/LoRA/`; on-device trainer in `Libraries/MLXLLM/LoraTrain.swift`; model registry in `Libraries/MLXLLM/LLMModelFactory.swift` |
| Example apps | [`ml-explore/mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples) | `main` | `Applications/LLMBasic` (minimal loader, defaults to `LLMRegistry.gemma3_1B_qat_4bit`), `Applications/LoRATrainingExample` (on-device LoRA training), `MLXChatExample`, `LLMEval` |
| Apple Foundation Models bridge | `ml-explore/mlx-swift-lm` → `Libraries/MLXFoundationModels` | added in 3.32.3 (PR #334) | "MLX-backed FoundationModels LanguageModel" — directly relevant to handoff §16; integration tests gated on the iOS 27 SDK |

There are **two registries** on the Swift side (both in `LLMModelFactory.swift`):

1. `LLMTypeRegistry` — maps `config.json`'s `model_type` string (e.g. `qwen3`, `llama`, `gemma3_text`, `smollm3`, `qwen3_5`, `gemma4`) to a Swift model implementation. This is the authoritative "is it loadable in MLX Swift" check.
2. `LLMRegistry` — named `ModelConfiguration` presets (e.g. `LLMRegistry.qwen3_1_7b_4bit`). Any *unknown* HF id whose `model_type` is registered still loads via `ModelConfiguration(id:)`.

---

## 2. (a) Candidate shortlist

### Comparison table

| Model (instruct) | Params | 4-bit weights (GB) | Phone-side memory incl. KV + overhead *(estimate)* | License / redistribution | In Swift `LLMRegistry`? | `model_type` (Swift loadable) | Python mlx-lm | Instruction-following reputation |
|---|---|---|---|---|---|---|---|---|
| **Qwen3-1.7B** → `mlx-community/Qwen3-1.7B-4bit` | 1.7B (1.4B non-emb; 2.0B incl. embeddings); 28 layers, GQA 16Q/8KV | **0.97 GB** (968,080,210 B) | ≈ 1.3–1.6 GB @ ≤4k ctx | **Apache-2.0** — bundle freely with license text | ✅ `qwen3_1_7b_4bit` | `qwen3` ✅ | ✅ `qwen3.py` | IFEval **74.0** no-think (per SmolLM3 card's comparison table); strong "human preference alignment" claims on card |
| **Qwen3-0.6B** → `mlx-community/Qwen3-0.6B-4bit` | 0.6B; 28 layers | **0.34 GB** (335,450,584 B) | ≈ 0.5–0.8 GB | Apache-2.0 | ✅ `qwen3_0_6b_4bit` | `qwen3` ✅ | ✅ (it is the **default `--model` in `mlx_lm.lora`'s `CONFIG_DEFAULTS`**) | Weakest IF of the shortlist; fine as a smoke-test model |
| **Llama 3.2 1B Instruct** → `mlx-community/Llama-3.2-1B-Instruct-4bit` | 1.24B; 16 layers | **0.70 GB** (695,283,921 B) | ≈ 1.0–1.3 GB | **Llama 3.2 Community License** — redistribution allowed with: license copy shipped, "Built with Llama" displayed, attribution notice, AUP compliance, ≥700M-MAU clause (EU restriction applies only to the *multimodal* Llama 3.2 models) | ✅ `llama3_2_1B_4bit` | `llama` ✅ | ✅ `llama.py`; the shipped `examples/lora_config.yaml` trains on `Llama-3.2-1B-Instruct-bf16` | Solid general-purpose 1B; no reasoning mode to disable; custom-license friction for a shipped demo |
| **SmolLM2-1.7B-Instruct** | 1.7B; 24 layers | ≈ 1.0 GB *(estimate — must self-quantize; see note)* | ≈ 1.3–1.6 GB | Apache-2.0 | ⚠️ no preset, but the MLX conversion's `model_type` is `llama` (verified in `mlx-community/SmolLM2-1.7B-Instruct/config.json`) so it loads via the llama path | `llama` ✅ | ✅ (llama arch) | Good IF for its size per HF's SmolLM2 blog; only 8k context; **superseded** |
| **SmolLM3-3B** → `mlx-community/SmolLM3-3B-4bit` | 3.08B | **1.75 GB** (repo storage) | ≈ 2.2–2.6 GB | Apache-2.0 | ✅ `smollm3_3b_4bit` | `smollm3` ✅ | ✅ `smollm3.py` | **Best IFEval of the compared set: 76.7** (no-think) vs Qwen3-1.7B 74.0, Qwen2.5-3B 65.6, Llama3.1-3B 71.6 (numbers from HF's own SmolLM3 card) |
| **Gemma 3 1B it (QAT)** → `mlx-community/gemma-3-1b-it-qat-4bit` | 1.0B; 28 layers | **0.73 GB** (732,577,304 B) | ≈ 1.0–1.4 GB | **Gemma Terms of Use** — redistribution permitted with notice file ("Gemma is provided under and subject to the Gemma Terms of Use…"), use restrictions passed through, modified-file notices | ✅ `gemma3_1B_qat_4bit` — this is the default model in the official `LLMBasic` example | `gemma3_text` ✅ | ✅ `gemma3_text.py` | QAT 4-bit ≈ bf16 quality per Google; adequate IF at 1B; upstream `google/gemma-3-1b-it` is HF-gated (the mlx-community mirror is not) |
| **Qwen3.5-2B** (Feb 2026) → `mlx-community/Qwen3.5-2B-4bit` | 2.27B (omni VLM arch) | **1.74 GB** (repo storage) | ≈ 2.2–2.6 GB | Apache-2.0 | ✅ `qwen3_5_2b_4bit` | `qwen3_5` ✅ | ✅ `qwen3_5.py` | Newest generation; **defaults to non-thinking** (template emits empty `<think>` unless `enable_thinking=true`); very popular (4M downloads); heavier + multimodal baggage |
| **LFM2-1.2B** → `mlx-community/LFM2-1.2B-4bit` | 1.24B (hybrid conv+attention, edge-native) | **≈ 0.63 GB** (repo 0.66 GB) | ≈ 0.9–1.2 GB | ⚠️ custom **LFM 1.0** license (`license: other`) — review terms before bundling | ✅ `lfm2_1_2b_4bit` | `lfm2` ✅ | ✅ `lfm2.py` | Designed for edge TTFT; least mainstream tooling/validation of the shortlist |
| **Gemma 4 E2B it** (Apr 2026) → `mlx-community/gemma-4-e2b-it-4bit` | 5.1B total / 2B effective (per-layer embeddings, VLM) | multi-GB (repo storage 7.16 GB) | ≈ 3.5–5 GB | **Apache-2.0** per Google's "Gemma 4 license" page (which is literally the Apache 2.0 text) — note the HF mirror metadata still tags it `gemma` | ✅ `gemma4_e2b_it_4bit` | `gemma4` ✅ | ✅ `gemma4.py` | Phone-designed MatFormer-class model, but far too heavy for this memory-focused demo |

Note on SmolLM2 quant availability: the canonical `mlx-community/SmolLM2-1.7B-Instruct-4bit` repo returns HTTP 401 as of Oct 9, 2026 (removed/private); the ungated fp16 conversion `mlx-community/SmolLM2-1.7B-Instruct` remains. You can self-quantize with `mlx_lm.convert -q`, but there is little reason to prefer SmolLM2 over SmolLM3.

### Phone-side memory math *(estimates — measure per handoff §11–12)*

- 4-bit weights ≈ 0.56 bytes/param + tokenizer/runtime overhead. MLX's own `LoRATrainingExample` README states a 7B 4-bit model needs "a little over 4 GB" to load *and train* — scaling from that, a 1.7B 4-bit model lands ≈ 1.2–1.6 GB resident for inference.
- KV cache (fp16) grows with context: Qwen3-1.7B (GQA 8 KV heads × 128 dim × 28 layers) ≈ 117 MB @ 2k tokens, 235 MB @ 4k. Llama-3.2-1B ≈ 33 MB @ 2k (8×64×16 layers).
- The demo's contrast story on an 8 GB iPhone: naive mode (3 × full model) ≈ 4+ GB vs shared-base mode ≈ 1.1–1.6 GB + ~10 MB/adapter. Also set `Memory.cacheLimit` and consider the Increased Memory Limit entitlement (both are what the official LLMBasic example does).
- Thinking modes inflate TTFT: Qwen3 0.6B/1.7B ship with thinking **enabled by default**; use the hard switch `enable_thinking=False` (or soft `/no_think`) documented on the Qwen3 card. SmolLM3 defaults thinking **on** too (`/no_think` or `enable_thinking=False`). Qwen3.5-2B defaults **off**. Llama 3.2 and Gemma 3 1B have no thinking mode at all.

---

## 3. (b) LoRA training path with mlx-lm (exact, current)

### 3.1 Install

```sh
pip install "mlx-lm[train]"     # v0.31.3 current as of Oct 2026
```

> The `python -m mlx_lm.lora …` spelling still works but prints a deprecation notice; prefer `mlx_lm.lora …`.

### 3.2 Dataset format

Directory containing `train.jsonl` (required), `valid.jsonl` (optional but recommended), `test.jsonl` (for `--test`). Chat format — one example per line:

```jsonl
{"messages": [{"role": "system", "content": "You are a precise summarizer. Output only the summary."}, {"role": "user", "content": "<article text...>"}, {"role": "assistant", "content": "<reference summary...>"}]}
```

Also supported: `tools`, `completions` (`{"prompt": ..., "completion": ...}`), and raw `text`. The format is auto-detected per file. HF-hosted datasets work via `--data mlx-community/wikisql` or an `hf_dataset:` YAML block. Pass `--mask-prompt` to compute loss on the assistant completion only (recommended for the classify/extract adapters — with `chat` data, the final message is treated as the completion).

### 3.3 Train one adapter (CLI)

```sh
mlx_lm.lora \
    --model mlx-community/Qwen3-1.7B-4bit \
    --train \
    --data ./data/summarize \
    --adapter-path ./adapters/summarize \
    --iters 1000 \
    --num-layers 16 \
    --batch-size 4 \
    --learning-rate 1e-5 \
    --mask-prompt
```

Because `--model` points at a 4-bit repo this is **QLoRA** automatically (pass a bf16 repo for plain LoRA). This matters for demo parity: the adapter is trained against *exactly* the quantized weights you will ship.

### 3.4 Or use the YAML config (only way to set LoRA params on the CLI path)

```yaml
# summarize.yaml
model: "mlx-community/Qwen3-1.7B-4bit"
train: true
fine_tune_type: lora            # lora | dora | full
data: "./data/summarize"
adapter_path: "./adapters/summarize"
num_layers: 16                  # adapt the LAST 16 of 28 layers (-1 = all)
iters: 1000
batch_size: 4
learning_rate: 1e-5
mask_prompt: true
lora_parameters:
  keys: ["self_attn.q_proj", "self_attn.v_proj"]   # omit → ALL linear/embedding layers in scope (matches Swift default)
  rank: 8
  scale: 20.0                   # mlx-lm uses "scale", NOT "alpha"
  dropout: 0.0
```

```sh
mlx_lm.lora --config summarize.yaml
```

### 3.5 Defaults (verified in `mlx_lm/lora.py` `CONFIG_DEFAULTS` + `examples/lora_config.yaml`)

| Knob | Default | Note |
|---|---|---|
| `fine_tune_type` | `lora` | `dora` and `full` also supported |
| `num_layers` | **16** | last N transformer blocks; Qwen3-1.7B has 28 total |
| `iters` | 1000 | LORA.md's walkthrough uses `--iters 600` |
| `batch_size` | 4 | |
| `learning_rate` | 1e-5 | optimizer default `adam` (`adamw`, `muon`, `sgd`, `adafactor` available) |
| LoRA `rank` / `scale` / `dropout` | **8 / 20.0 / 0.0** | effective ΔW scale = scale/rank = 2.5 |
| LoRA `keys` | *unset* → all Linear/QuantizedLinear/Embedding layers in the last `num_layers` blocks | the example YAML pins `q_proj`+`v_proj` for small adapters |
| `max_seq_length` | 2048 | keep article/summary pairs under this |
| `adapter_path` | `adapters` | |

### 3.6 Rough training budget for a small task adapter

- Dataset: ~500–2,000 curated examples per task is plenty for visibly different demo behavior (handoff Risk D: don't over-invest).
- `--iters 600–1000` at batch 4 = 2,400–4,000 samples seen ≈ 2–8 epochs over 500 examples. Watch validation loss every 200 steps; stop when it plateaus.
- On an Apple-silicon Mac a 0.6–1.7B QLoRA run at these settings takes minutes, not hours (LORA.md reports ~250 tok/s training throughput even for 7B on M1 Max).

### 3.7 Expected adapter size on disk *(estimate)*

`adapters.safetensors` holds only `lora_a`/`lora_b` (plus `m` for DoRA). For Qwen3-1.7B (hidden 2048), rank 8, last 16 layers:

- `q_proj`+`v_proj` keys → ≈ 0.9M params → **≈ 2–4 MB**
- all-linear keys (default) → ≈ 5M params → **≈ 10–20 MB**

Three adapters ≈ 6–60 MB total — negligible next to the 0.97 GB base, which is exactly the demo's point.

### 3.8 Sanity-check the adapter before iOS

```sh
mlx_lm.generate \
    --model mlx-community/Qwen3-1.7B-4bit \
    --adapter-path ./adapters/summarize \
    --prompt "<same prompt format the app will use>"
```

(`mlx_lm.lora --test --adapter-path …` computes test perplexity instead.)

### 3.9 Bonus: on-device training exists in Swift

`ml-explore/mlx-swift-lm` ships `LoRATrain` (`Libraries/MLXLLM/LoraTrain.swift`) plus the `LoRATrainingExample` app — the same iterate-batch/train-loop ported to Swift. Not needed for the demo (train on the Mac), but it is a citable proof that the adapter format and math are identical on both sides.

---

## 4. (c) Export & load on iOS

### 4.1 What training produces

```
adapters/summarize/
├── adapter_config.json      # {"fine_tune_type":"lora","num_layers":16,"lora_parameters":{"rank":8,"scale":20.0,"dropout":0.0,"keys":[...]}}
└── adapters.safetensors     # tensors named e.g. ...layers.15.self_attn.q_proj.lora_a / lora_b
```

(Note: the weights file is `adapters.safetensors` — plural — and the config uses `scale`, not `alpha`.)

### 4.2 Swift loads them directly — no fuse step required

`LoRAContainer.from(directory:)` in `mlx-swift-lm` (`Libraries/MLXLMCommon/Adapters/LoRA/LoRAContainer.swift`) reads **exactly** `adapter_config.json` + `adapters.safetensors` — the same two files Python writes. The Python↔Swift adapter format is interchangeable by design (`LoRAConfiguration` is documented as "compatible with `adapter_config.json` created during training using MLX libraries"; QLoRA on quantized bases is supported via `QLoRALinear`, with tests like `Qwen35QLoRATests`).

Runtime API (all verified in source):

```swift
import MLXLLM
import MLXLMCommon

// 1. Load base once (LLMBasic-style)
let container = try await LLMModelFactory.shared.loadContainer(
    from: #hubDownloader(),
    using: #huggingFaceTokenizerLoader(),
    configuration: LLMRegistry.qwen3_1_7b_4bit
)

// 2. Hot-swap adapters inside the model actor
let adapter = try LoRAContainer.from(directory: summarizeAdapterURL)
await container.update { context in
    try? adapter.load(into: context.model)      // replaces Linear → LoRALinear, loads weights
}
// …generate…
await container.update { context in
    adapter.unload(from: context.model)          // restores original layers
}
// or toggle without restructuring layers (built for speculative decoding, fine for a quick A/B):
context.model.setLoRAEnabled(false)
```

- `adapter.fuse(with:)` exists but **do not fuse** for this demo — fusion bakes ΔW into the base weights and destroys the ability to switch tasks at runtime. Fuse is only for shipping a single task as one static model.
- `LLMModelFactory.shared.loraMetadata(configurationData:)` reports layer count + default target keys from `config.json` without loading weights — handy for validating a bundled model/adapter pairing at app startup.
- Adapters apply by `num_layers`-suffix + module keys, so **adapter and base must be trained against the same architecture** (same layer count / GQA geometry). Pin the exact HF revision of `mlx-community/Qwen3-1.7B-4bit` in `training/README.md` and in the app.

### 4.3 Shipping in an iOS app bundle

- Put each trained directory under e.g. `app/Resources/Adapters/summarize/{adapter_config.json, adapters.safetensors}` and locate it with `Bundle.main.url(forResource:withExtension:subdirectory:)` (or `Bundle.module` for SPM targets). Precedent: the official `LoRATrainingExample` bundles its `Data/lora` directory from `$SRCROOT` into the build; adapter dirs are just two small files, so this is trivial.
- Base model options: (1) bundle the 0.97 GB quantized model directory (offline, deterministic, license-clean under Apache-2.0 — include the license text) and load it from the bundle URL; or (2) keep LLMBasic's hub-download flow with the app's Documents directory for development. For the conference build, bundle it — no network dependency onstage.
- Keep `Memory.cacheLimit` modest (LLMBasic uses 20 MB) and add the Increased Memory Limit entitlement to survive peak allocations during the naive (3-model) mode.

### 4.4 Fuse path, for completeness

```sh
mlx_lm.fuse --model mlx-community/Qwen3-1.7B-4bit \
    --adapter-path ./adapters/summarize \
    --save-path ./fused/summarize       # also supports --export-gguf
```

Only relevant if a fallback single-task build is ever needed.

---

## 5. (d) Recommendation

**Use `mlx-community/Qwen3-1.7B-4bit` as the shared frozen base, with three rank-8 q/v LoRA adapters trained via `mlx_lm.lora` (QLoRA against the same 4-bit repo) and hot-swapped in Swift via `LoRAContainer`.**

Rationale, weighted for a *live phone demo* (reliability > intelligence):

1. **Fast TTFT & memory**: 0.97 GB weights ≈ 1.3–1.6 GB resident — small enough for the shared-base mode to look great next to 3× naive instances on an 8 GB iPhone, while 28 layers × GQA keeps prompt prefill quick. Disable thinking (`enable_thinking=false` — the branch is present in the shipped `tokenizer_config.json` chat template; the Qwen3 card documents both the hard switch and the `/no_think` soft switch) or generation will burn hundreds of tokens "thinking" before the first visible output. *(Verify the Swift tokenizer exposes the kwarg at implementation time; fallback = append `/no_think` to the system prompt, which the same template supports.)*
2. **Most permissive license that meets the bar**: Apache-2.0 (Qwen3 LICENSE). Ship weights + adapters inside the app with a license file and zero branding obligations — unlike Llama 3.2 ("Built with Llama" + license-pass-through + AUP) or Gemma 3 (notice file + use restrictions). SmolLM3 matches Apache-2.0 but costs 1.8× the memory.
3. **Best-supported path end-to-end**: `qwen3` is registered in both the Swift `LLMTypeRegistry` and `LLMRegistry` (named preset), is a first-class mlx-lm model (`qwen3.py`), and the mlx-lm LoRA CLI's own default model is Qwen3-0.6B — i.e. the exact family the toolchain is smoke-tested on. QLoRA-on-4-bit and runtime unload/toggle are covered by upstream tests.
4. **Adequate instruction following**: IFEval 74.0 in non-thinking mode (Hugging Face's SmolLM3 comparison table) — and the demo's LoRA adapters do the task-shaping anyway, so base-model intelligence is not the bottleneck.

**Alternates, in order:**
- **`mlx-community/Qwen3-0.6B-4bit`** (0.34 GB) — if memory or thermals get tight; also the smoothest mlx-lm default. Accept weaker base behavior and lean harder on the adapters.
- **`mlx-community/SmolLM3-3B-4bit`** (1.75 GB, Apache-2.0) — if output quality demos matter more than the memory-contrast story; best IFEval (76.7) of the set; disable thinking.
- **`mlx-community/gemma-3-1b-it-qat-4bit`** (0.73 GB) — the "official example" pick (it is LLMBasic's default) with QAT quality; costs you the Gemma license notice obligations.

**Explicitly rejected here:** Llama 3.2 1B (license friction for a redistributed demo app, though technically excellent), SmolLM2 (superseded, no accessible canonical 4-bit MLX repo, no Swift preset), LFM2-1.2B (custom license, least ecosystem validation), Qwen3.5-2B / Gemma-4-E2B (both fine software, but heavier multimodal architectures that blur the memory story).

---

## 6. Open items for other tasks

- Measure, don't assume: TTFT/peak-memory for Qwen3-1.7B-4bit with thinking off, adapter switch latency (`unload`+`load` vs `setLoRAEnabled`), and KV growth — per handoff §10–12.
- Verify the Swift `applyChatTemplate` path for `enable_thinking=false` (or adopt the `/no_think` system-prompt fallback) on the pinned model revision.
- Pin revisions: record exact HF commit SHAs for the base repo and each adapter in `docs/environment.md` (e.g. Qwen3-1.7B-4bit @ `3b1b1768…` as of this research).
- The `mlx-swift-lm` `MLXFoundationModels` library (new in 3.32.3) is the modern hook for the Apple Foundation Models side-demo in handoff §16 — evaluate separately.

## 7. Sources (all retrieved Oct 9, 2026)

- **mlx-lm** (Python trainer): repo <https://github.com/ml-explore/mlx-lm>; `mlx_lm/LORA.md`; `examples/lora_config.yaml`; `mlx_lm/lora.py` (CONFIG_DEFAULTS); `mlx_lm/tuner/utils.py` (`linear_to_lora_layers`, `load_adapters`); release v0.31.3 <https://github.com/ml-explore/mlx-lm/releases/tag/v0.31.3>.
- **mlx-swift-lm** (Swift runtime): repo <https://github.com/ml-explore/mlx-swift-lm>; `Libraries/MLXLLM/LLMModelFactory.swift` (`LLMTypeRegistry`, `LLMRegistry`); `Libraries/MLXLLM/LoraTrain.swift`; `Libraries/MLXLMCommon/Adapters/LoRA/{LoRAContainer,LoRAModel}.swift`; `Libraries/MLXLLM/Documentation.docc/using-model.md`; `skills/mlx-swift-lm/references/lora-adapters.md`; release 3.32.3 <https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3>.
- **mlx-swift-examples**: `Applications/LLMBasic/{README.md,ChatModel.swift}`; `Applications/LoRATrainingExample/README.md` — <https://github.com/ml-explore/mlx-swift-examples>.
- **Model cards / metadata (Hugging Face API + cards)**: [Qwen/Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) (params/arch/thinking switches/best practices); [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) (968,080,210 B); [mlx-community/Qwen3-0.6B-4bit](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) (335,450,584 B); [mlx-community/Llama-3.2-1B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) (695,283,921 B; full Llama 3.2 Community License text in card); [mlx-community/gemma-3-1b-it-qat-4bit](https://huggingface.co/mlx-community/gemma-3-1b-it-qat-4bit) (732,577,304 B); [mlx-community/SmolLM3-3B-4bit](https://huggingface.co/mlx-community/SmolLM3-3B-4bit) (1.75 GB); [HuggingFaceTB/SmolLM3-3B](https://huggingface.co/HuggingFaceTB/SmolLM3-3B) (IFEval comparison table, /think//no_think); [mlx-community/LFM2-1.2B-4bit](https://huggingface.co/mlx-community/LFM2-1.2B-4bit) (0.66 GB, license `other`/lfm1.0); [Qwen/Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B) + [mlx-community/Qwen3.5-2B-4bit](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit) (1.74 GB, default non-thinking template); [mlx-community/gemma-4-e2b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) (7.16 GB repo); [mlx-community/SmolLM2-1.7B-Instruct](https://huggingface.co/mlx-community/SmolLM2-1.7B-Instruct) (`config.json` → `model_type: llama`).
- **Licenses**: [Gemma Terms of Use](https://ai.google.dev/gemma/terms) (incl. redistribution conditions §3.1) and [Gemma 4 license = Apache 2.0](https://ai.google.dev/gemma/apache_2), both last modified 2026-04-01; Apache-2.0 and Llama 3.2 texts via the HF cards above.
