# Train the three adapters

This directory trains the summarize, classify, and extract adapters for `mlx-community/Qwen3-1.7B-4bit`. The app reads the two output files directly. There is no conversion step.

The dataset is synthetic. `training/make_dataset.py` builds it. The seed is `20261013` (`random.seed` in that file). The same seed yields the same files.

Shipped copies already live in `app/Resources/adapters/<task>/`. Retrain only when you intend to replace them.

## Regenerate the data

Run this from `training/`:

```sh
python3 -m venv .venv
./.venv/bin/pip install mlx-lm
./.venv/bin/python make_dataset.py
```

`make_dataset.py` writes chat-format JSONL:

- `training/data/classify/train.jsonl` and `valid.jsonl`
- `training/data/summarize/train.jsonl` and `valid.jsonl`
- `training/data/extract/train.jsonl` and `valid.jsonl`

Each task gets 600 train rows and 100 valid rows. Each row is `messages` with system, user, and assistant. The system strings match `AITask.instructions` in `app/Sources/AppModel.swift`.

`training/data/` is gitignored. Regenerate it on the machine that trains. Do not treat a missing `data/` directory as a lost corpus. The generator is the source.

The text is template-shaped. It is enough for the demo. It is not a production dataset. `README.md` states the same limit.

## The three configs

Train each file from `training/` with the venv on `PATH`:

```sh
./.venv/bin/mlx_lm.lora --config classify.yaml
./.venv/bin/mlx_lm.lora --config summarize.yaml
./.venv/bin/mlx_lm.lora --config extract.yaml
```

| File | Task | Data | Adapter output |
|---|---|---|---|
| `training/classify.yaml` | classify | `./data/classify` | `./adapters/classify` |
| `training/summarize.yaml` | summarize | `./data/summarize` | `./adapters/summarize` |
| `training/extract.yaml` | extract | `./data/extract` | `./adapters/extract` |

All three configs set the same training values:

| Key | Value |
|---|---|
| `model` | `mlx-community/Qwen3-1.7B-4bit` |
| `fine_tune_type` | `lora` |
| `num_layers` | 16 (last 16 blocks) |
| `iters` | 600 |
| `batch_size` | 4 |
| `learning_rate` | 1e-5 |
| `mask_prompt` | true (loss on the answer only) |
| `lora_parameters.rank` | 8 |
| `lora_parameters.scale` | 20.0 |
| `lora_parameters.dropout` | 0.0 |

mlx-lm stores `scale`, not `alpha`. Do not write an `alpha` key. The shipped `adapter_config.json` files record `scale` 20.0 and `rank` 8.

`keys` is omitted on purpose. See the next section.

The `model` value is the 4-bit repo the app ships. That choice makes the run QLoRA. A bf16 repo would be plain LoRA. Do not point these configs at a different checkpoint. The adapter must match the weights in the app.

`num_layers: 16` adapts the last 16 blocks. The classify config comment says Qwen3-1.7B has 28 blocks. That layer count is also in `docs/research/model-candidates.md`.

`training/adapters/` is gitignored. mlx-lm also writes checkpoint files such as `0000100_adapters.safetensors`. Those files are not the app payload.

The app download is pinned to commit `3b1b1768f8f8cf8351c712464f906e86c2b8269e` in `scripts/fetch-model.sh` and `docs/environment.md`. The shipped `adapter_config.json` records the repo id, not that commit. Do not treat a later `main` training run as the same bytes.

This README does not pin an mlx-lm version. `docs/findings.md` records that an older mlx build still wrote the MLX-native pair the app reads.

## What the default adapts

mlx-lm adapts every linear layer in scope when `keys` is omitted. That is the default. It is also the Swift default (`loraDefaultKeys`). The configs omit `keys` so the two sides match.

The research estimate of about 2 MB assumed `q_proj` and `v_proj` only. That estimate is not this repo. `docs/findings.md` records the correction.

Each shipped `adapters.safetensors` is 19,947,012 bytes on disk (about 20 MB). The three tasks are the same size. That number is a file size on disk. It is not `phys_footprint` and not a device measurement.

## Copy the adapter into the app

Copy only `adapter_config.json` and `adapters.safetensors`. Leave the numbered checkpoints in `training/adapters/`.

From `training/`:

```sh
for task in classify summarize extract; do
  cp "adapters/$task/adapter_config.json" \
     "adapters/$task/adapters.safetensors" \
     "../app/Resources/adapters/$task/"
done
```

One task, written out:

```sh
cp adapters/classify/adapter_config.json \
   adapters/classify/adapters.safetensors \
   ../app/Resources/adapters/classify/
```

Repeat that shape for `summarize` and `extract`. The destination layout is:

```text
app/Resources/adapters/<task>/adapter_config.json
app/Resources/adapters/<task>/adapters.safetensors
```

`LoRAContainer.from(directory:)` in the app reads those two names. Do not rename them. Do not fuse the adapter into the base. The live demo switches adapters. A fused model cannot switch.

Rebuild the app after the copy. `app/project.yml` packages `Resources/adapters` as a folder resource so the directory layout survives in the bundle.
