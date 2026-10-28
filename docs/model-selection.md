# Model selection

Decision: ship `mlx-community/Qwen3-1.7B-4bit`. License: Apache-2.0.

The comparison below is a short extract of `docs/research/model-candidates.md` (sources checked 2026-10-09). It is not a copy of that note. Phone-RAM estimates in that note are not repeated here. They are not device measurements.

## Candidate models

| Model id | Parameter count | Quantization | Approximate size | License | MLX compatibility | Adapter support | Observed device performance |
|---|---|---|---|---|---|---|---|
| `mlx-community/Qwen3-1.7B-4bit` | 1.7B | 4-bit | 0.97 GB weights (968,080,210 bytes) | Apache-2.0 | Named preset `qwen3_1_7b_4bit`. `model_type` `qwen3`. | Shipped. This app loads it. | not measured on device yet |
| `mlx-community/Qwen3-0.6B-4bit` | 0.6B | 4-bit | 0.34 GB weights (335,450,584 bytes) | Apache-2.0 | Named preset `qwen3_0_6b_4bit`. `model_type` `qwen3`. | Path exists. Not shipped. | not measured on device yet |
| `mlx-community/Llama-3.2-1B-Instruct-4bit` | 1.24B | 4-bit | 0.70 GB weights (695,283,921 bytes) | Llama 3.2 Community License | Named preset `llama3_2_1B_4bit`. `model_type` `llama`. | Path exists. Not shipped. | not measured on device yet |
| SmolLM2-1.7B-Instruct | 1.7B | No checked 4-bit repo | No checked 4-bit file size | Apache-2.0 | No preset. `model_type` `llama` on the ungated conversion. | Not shipped. | not measured on device yet |
| `mlx-community/SmolLM3-3B-4bit` | 3.08B | 4-bit | 1.75 GB repo storage | Apache-2.0 | Named preset `smollm3_3b_4bit`. `model_type` `smollm3`. | Path exists. Not shipped. | not measured on device yet |
| `mlx-community/gemma-3-1b-it-qat-4bit` | 1.0B | 4-bit QAT | 0.73 GB weights (732,577,304 bytes) | Gemma Terms of Use | Named preset `gemma3_1B_qat_4bit`. `model_type` `gemma3_text`. | Path exists. Not shipped. | not measured on device yet |
| `mlx-community/Qwen3.5-2B-4bit` | 2.27B | 4-bit | 1.74 GB repo storage | Apache-2.0 | Named preset `qwen3_5_2b_4bit`. `model_type` `qwen3_5`. | Path exists. Not shipped. | not measured on device yet |
| `mlx-community/LFM2-1.2B-4bit` | 1.24B | 4-bit | 0.66 GB repo storage | LFM 1.0 (`license: other`) | Named preset `lfm2_1_2b_4bit`. `model_type` `lfm2`. | Path exists. Not shipped. | not measured on device yet |
| `mlx-community/gemma-4-e2b-it-4bit` | 5.1B total / 2B effective | 4-bit | 7.16 GB repo storage | Apache-2.0 on Google's Gemma 4 page. HF metadata still tags `gemma`. | Named preset `gemma4_e2b_it_4bit`. `model_type` `gemma4`. | Path exists. Not shipped. | not measured on device yet |

The canonical `mlx-community/SmolLM2-1.7B-Instruct-4bit` repo returned HTTP 401 on 2026-10-09. That is why the size cell has no file size.

## Parameter count

The demo needs a small instruct model, not a large one. The shortlist is 0.6B to 3B, plus Gemma 4 E2B, which is heavier than that band. The selected model is 1.7B (28 layers in the research note).

Parameter count is not a device speed result.

## Quantization

Every shipped candidate in the table is a 4-bit MLX repo, except SmolLM2, which has no checked 4-bit repo. Gemma 3 1B is 4-bit QAT. The app ships the 4-bit Qwen3 repo and trains QLoRA against that same repo. See `training/README.md`.

`docs/environment.md` records the quantization as 4-bit groupwise, as shipped by mlx-community. The exact group size is the file in the bundle, not a number restated here.

## Approximate size

Sizes in the table are weight-file sizes or repo-storage sizes from the Hugging Face metadata cited in `docs/research/model-candidates.md`. They are not resident memory and not `phys_footprint`.

The selected weights file is 0.97 GB (968,080,210 bytes) in that note. `README.md` describes the download as about 940 MB. `scripts/fetch-model.sh` downloads commit `3b1b1768f8f8cf8351c712464f906e86c2b8269e`. The same commit is in `docs/environment.md`.

Each shipped adapter file is about 20 MB on disk. That fact is in `training/README.md`. It is not a device footprint.

## License

Apache-2.0 is the license for the selected model. The app may ship the weights with the license text. No branding line is required by that license.

Llama 3.2 Community License allows redistribution with extra duties (license copy, "Built with Llama", attribution, acceptable-use rules). Gemma Terms of Use require a notice file and pass-through of use limits. LFM 1.0 is a custom license. Those three are worse fits for a redistributed demo than Apache-2.0.

SmolLM3 and Qwen3.5 are also Apache-2.0. They lose on size, not on license. Gemma 4 E2B is Apache-2.0 on Google's license page and is too large for this demo.

## MLX compatibility

"MLX compatibility" here means the Swift loader can construct the model. The research note checks two registries in `mlx-swift-lm` 3.32.3:

- `LLMTypeRegistry` maps `config.json` `model_type` to a Swift model.
- `LLMRegistry` holds named presets. A known `model_type` can still load without a preset.

The selected id has both a preset and `model_type` `qwen3`. The app does not use the preset. It loads the bundle directory. See `AppModel.makeContainer()` in `app/Sources/AppModel.swift`.

This target links `MLXLLM` and `MLXLMCommon`. It does not link `MLXHuggingFace`. It also weak-links `FoundationModels.framework` for the system-model section. That section is not the MLX load path. See `app/project.yml` and `app/Sources/FoundationModelsSection.swift`.

A successful Mac build is not a device run. Device load time is not measured on device yet.

## Adapter support

The selected model is the only row this app actually loads with adapters.

- Training writes `adapter_config.json` and `adapters.safetensors`.
- The app reads them with `LoRAContainer.from(directory:)`.
- Three directories ship in `app/Resources/adapters/{classify,summarize,extract}/`.
- `docs/findings.md` records that Qwen3 conforms to `LoRAModel` in mlx-swift-lm 3.32.3.

The YAML files omit `keys`. mlx-lm then adapts all linear layers in the last 16 blocks, not only `q_proj` and `v_proj`. The research note's q/v size estimate is not what this repo shipped.

Other rows have an mlx-lm path in the research note. This app does not ship adapters for them. Do not describe them as measured on device.

`SystemLanguageModel.Adapter` is out of scope. `docs/decisions.md` (D8) excludes it. It is not an MLX adapter format.

## Observed device performance

not measured on device yet

That sentence applies to every row in the table. It also applies to the selected model. This repo has no iPhone trace and no file under `benchmarks/results/`.

Do not fill this section from the research note's resident-memory ranges. Those ranges are marked as estimates in that file. Do not fill it from IFEval or other card scores. Those scores are not this app on a phone.

Card context that is not a device result: the research note cites IFEval 74.0 for Qwen3-1.7B in non-thinking mode, from the SmolLM3 comparison table. SmolLM3's card score in that same table is 76.7. Neither number is a measurement from this repo.

## Final rationale

Use `mlx-community/Qwen3-1.7B-4bit` because the demo needs a reliable on-device base, not a larger model.

1. The weight file is 0.97 GB and the license is Apache-2.0. Both facts are in the research note. Device speed is not measured on device yet.
2. Swift has a named preset and `model_type` `qwen3`. Python mlx-lm has a Qwen3 trainer. QLoRA against the same 4-bit repo is the training path this repo uses.
3. The app already loads this id from the bundle and already ships three adapters for it.
4. Qwen3 thinking mode is on unless the chat template gets `enable_thinking=false`. The pinned `tokenizer_config.json` injects an empty think block only when that flag is false. It does not read `/no_think`. The app passes the flag. Whether the model skips reasoning tokens on device is not measured.

Alternates, in the order from the research note, if a later device run rejects this id:

- `mlx-community/Qwen3-0.6B-4bit` if memory or heat is too high. Weaker base. Same family.
- `mlx-community/SmolLM3-3B-4bit` if output quality matters more than the memory contrast. Larger file. Apache-2.0.
- `mlx-community/gemma-3-1b-it-qat-4bit` if you accept the Gemma notice duties. It is the default in the upstream LLMBasic example.

Rejected for this demo:

- Llama 3.2 1B, because the community license adds redistribution duties.
- SmolLM2, because it is superseded and the canonical 4-bit repo was not readable.
- LFM2-1.2B, because the license is custom and the tooling is the least checked of the set.
- Qwen3.5-2B and Gemma 4 E2B, because the files are large and the architectures are multimodal. They blur the memory story.

Do not train a new base until a device run says this one fails. The gate in `docs/feasibility.md` (Qwen3 must conform to `LoRAModel`) is already recorded as met in `docs/findings.md`.
