# Demo design decisions

Date: 2026-10-12. Status: accepted.
Source: design discussion after Phase 0. See `docs/feasibility.md` for the research base.
These decisions extend the handoff plan. They do not change the build order.

## D1 — Apple section uses Foundation Models only

The Apple-native section uses the Foundation Models framework. CoreAI stays out of the app, the benchmarks, and the slides.

Reasons:

- The CoreAI public API selects a compute unit and runs inference functions. It does not switch a task adapter. Verified against the iOS 27.1 SDK on 2026-10-12.
- Phase 0 did not study CoreAI in depth.
- The handoff caps the size of the Apple section.

One spoken sentence is permitted: iOS 27 also ships a lower runtime named CoreAI, and this demo does not use it.

## D2 — Build target for the Apple section

Build the Foundation Models section with Xcode 27.1 RC and the iOS 27.1 SDK. The owner dropped the iOS-version gate on 2026-10-12. Only the hardware gate remains.

| Requirement | Value |
|---|---|
| Device | iPhone 15 Pro or later |
| Chip | A17 Pro or later |
| RAM | 8 GB or more |
| Apple Intelligence | Enabled, model asset downloaded |
| Language | Siri and device language both supported |

One device serves both sections, Apple and MLX.

## D3 — Completely on-device

Removed entirely:

- Private Cloud Compute. No entitlement, no network path.
- Remote `LanguageModel` providers. The Anthropic and Google packages are out.
- Runtime model downloads from the hub.

Required:

- The base model ships in the app bundle. `mlx-community/Qwen3-1.7B-4bit` is 0.97 GB.
- All adapter directories ship in the app bundle.
- Every load uses the local bundle path.
- The demo runs in airplane mode.

The Apple Intelligence asset must download before airplane mode. Check availability in the app. Show `modelNotReady` when the asset is missing.

Talk line earned by construction: we measured every number on one iPhone with airplane mode on.

## D4 — Opening beat

The demo opens with the system model. About 30 seconds. Three beats:

1. Show the availability check.
2. Run one guided extraction on the frozen system model. Use the same note as the rest of the talk.
3. Deliver the pivot line: the OS owns that model, and the app owns none of it.

Fallback: when availability fails on stage, skip to the MLX demo and show the Apple segment from the prerecorded trace.

## D5 — Three-stage arc

| Stage | Runtime | Ownership story |
|---|---|---|
| 1 Native | System model, session API | The platform already shares one frozen model |
| 2 Bundled, naive | Three features, three full instances | Ownership is the cost |
| 3 Bundled, shared | One base, three adapters, hot-swapped | Ownership with discipline |

The same note and the same three tasks run in all stages. Only the ownership changes.

Chart rule: chart stages 2 and 3 together only. Both run in-process under the same metric. Stage 1 is a story beat, never a bar on the memory chart.

Ownership table for the slide:

| | Apple Intelligence | Bundled model |
|---|---|---|
| Who owns the weights | The OS | Your app |
| Counts in app process memory | No | Yes |
| You control load and unload | No | Yes |
| Adapter swap | Not available | The core claim |
| What you measure | Latency only | Memory and latency |

## D6 — Foundation Models speed measurement

Show two numbers. Keep them separate.

Loading shadow:

- The OS owns the load, so no direct load time exists.
- Time the first request after the model becomes ready. Use `streamResponse`. The gap from call to first partial is the cold time-to-first-token.
- Run a second request the same way. That gap is warm.
- The difference is the wake-up cost. Claim it in those words.

Tokens per second:

1. Stream one response.
2. Timestamp the first partial and the last.
3. Count output tokens. On an iOS 27 device, `response.usage` gives the exact count. On iOS 26, approximate with `model.tokenCount(for:)`.
4. Divide tokens by elapsed generation time.

Protocol: about five runs, report the median, airplane mode, thermal check.

Rules:

- Never chart Foundation Models tokens per second against MLX. The system model is about 3B parameters served by the OS. The demo base is 1.7B served by MLX. A speed race invites a fair-comparison objection.
- Capture one Foundation Models instrument trace. The time-to-first-token lanes are better evidence than the in-app timer.
- A cold system model can stall on stage. The prerecorded fallback is mandatory.

## D7 — MLXFoundationModels bridge, optional

`mlx-swift-lm` 3.32.3 ships `MLXFoundationModels`. It wraps an MLX model as a Foundation Models language model.

Status: optional, Phase 7 material. Use it only after a check shows that guided generation works through a custom provider.

The bridge never carries the adapter experiment. The session wrapper exposes no adapter control.

## D8 — SystemLanguageModel.Adapter stays excluded

The type exists in the iOS 26.5 and iOS 27.1 SDKs. It has no documentation, no public format, and no authoring tool. Do not build on it. Mention it as evidence that Apple uses the same frozen-model-plus-adapter idea. Carried from Phase 0.

## Effects on the plan

- Phase 1 change: the baseline app loads the model from the bundle, never from the hub.
- The phase order is otherwise unchanged.
- `docs/demo-script.md`, written in Phase 7, records the three-stage arc and the opening beat.
