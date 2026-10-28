# AI Memory Lab — On-Device AI Memory Management Demo

Demo app for my article/talk **"On-Device AI Memory Management: Running**  
**Multi-Task Models Within iOS Resource Limits"**.

One shared frozen base model (`mlx-community/Qwen3-1.7B-4bit`) serves three
capabilities — summarize, classify, extract — through LoRA adapters that hot-swap
on the live model. A naive mode loads one full model instance per task for
comparison. Everything runs on-device from the app bundle, airplane-mode safe.

## Build and run

Requirements:

- Xcode 26.6+ (built and verified with 26.6 / iOS 26.5 SDK)
- An Apple-silicon Mac for the training step
- An iPhone (8 GB RAM recommended; iPhone 15 Pro or later if you also want the
  Apple Intelligence reference section)

One-time setup:

```sh
# 1. model weights (~940 MB, gitignored — restores into app/Resources/)
./scripts/fetch-model.sh

# 2. measurement rules (no model load)
python3 scripts/check-measure-rules.py

# 3. regenerate the Xcode project after changing project.yml (needs xcodegen)
cd app && xcodegen generate
```

Run:

1. Open `app/AIMemoryLab.xcodeproj`, set your signing team.
2. Select your iPhone. Use Product > Profile, or stop the debugger before Run Scenarios.
3. Shared mode: tap **Preload**, then a task button. The base loads once. The adapter name changes per task.
4. Naive mode: tap **Reset** if you already preloaded, switch the mode, tap **Prepare**. Prepare loads no model. The first tap of each task loads that instance only.

The three task adapters ship in `app/Resources/adapters/` (trained artifacts,
committed). Retrain them with the configs in `training/` (see below).

## Repo layout

| Path | What it is |
|---|---|
| `app/` | SwiftUI app (XcodeGen project) |
| `app/Sources/AppModel.swift` | Runtime: shared base + adapter switching, naive mode |
| `app/Sources/Benchmark.swift` | Scenarios + JSON results (handoff §10, §14) |
| `app/Sources/Memory.swift` | `phys_footprint` reader (the jetsam metric) |
| `app/Sources/Signposts.swift` | Lifecycle signposts for Instruments |
| `training/` | Dataset generator + mlx-lm QLoRA configs |
| `docs/` | Feasibility research, design decisions, environment record |
| `benchmarks/` | Analysis tooling (charts from exported JSON) |
| `presentation/` | Slide numbers provenance |

## Training the adapters

```sh
cd training
python3 -m venv .venv && ./.venv/bin/pip install mlx-lm
./.venv/bin/python make_dataset.py          # seeded synthetic data, 3 tasks
./.venv/bin/mlx_lm.lora --config classify.yaml
./.venv/bin/mlx_lm.lora --config summarize.yaml
./.venv/bin/mlx_lm.lora --config extract.yaml
cp adapters/{classify,summarize,extract}/{adapter_config.json,adapters.safetensors} \
   ../app/Resources/adapters/<task>/        # keep dir layout per task
```

QLoRA against the exact 4-bit checkpoint the app ships (rank 8, scale 20, last
16 layers, loss masked to the answer). Output is the MLX-native
`adapter_config.json` + `adapters.safetensors` pair that Swift
`LoRAContainer.from(directory:)` reads directly — no conversion step.

## Measurement notes

- Published memory metric: `task_vm_info.phys_footprint` (jetsam-enforced,
  includes Metal/GPU allocations). See
  `docs/research/memory-and-instruments.md` for why this and not `resident_size`.
- Benchmark JSON exports via the share sheet in-app; charts:
  `python3 benchmarks/analysis/plot.py <json...>`.
- Simulator numbers are not valid memory numbers. Final measurements come from
  a physical iPhone, debugger detached, airplane mode on.

## Known limitations

- Synthetic training data: adapter outputs are template-shaped, good enough for
  the demo, not for production quality.
- Adapter behavior on-device is verified manually, not by unit tests.
- The Apple Foundation Models section is in the app. It runs the system model
  only and is not part of the MLX memory chart. The MLXFoundationModels bridge
  stays out. See `docs/decisions.md` (D7).

## License

This repo is MIT. See `LICENSE`.

The base model `mlx-community/Qwen3-1.7B-4bit` is Apache-2.0 and is not in git.
The adapters in `app/Resources/adapters/` were trained on that checkpoint.
https://www.apache.org/licenses/LICENSE-2.0
