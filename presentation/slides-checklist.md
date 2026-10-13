# Slide checklist

20-minute talk, ~15 slides. Each slide lists what it needs and where the asset
comes from. Nothing goes on a slide without an entry in `numbers.md`.

Legend for sources:
- **P5 JSON** = benchmark JSON exported from the app (share sheet), analyzed by `benchmarks/analysis/plot.py`
- **Instr** = Instruments trace from a physical iPhone (signposts already in the app)
- **Docs** = files in this repo
- **Shot** = screenshot from the demo device

| # | Slide | Needs | Source |
|---|---|---|---|
| 1 | Title: "On-Device AI Memory Management" | App name + one-line thesis | Docs: README |
| 2 | The problem: every AI feature owns a model | Naive architecture diagram (3 features → 3 full models) | Draw once, reuse in #4/#10 |
| 3 | What it costs: memory | Chart A (naive line only), peak footprint number | P5 JSON, scenario `sequential-three-tasks`, architecture `naive-independent` |
| 4 | What it costs: the phone's limit | Jetsam limit vs 3-instance footprint number + a jetsam crash screenshot if captured | P5 JSON + device console log |
| 5 | The idea: frozen base + adapters | Shared architecture diagram (base + AdapterManager + 3 LoRAs) | Same diagram family as #2 |
| 6 | LoRA in one slide | Rank-8 delta sketch; "20 MB vs 968 MB" and "3×20 MB vs 2×968 MB" | Docs: findings.md item 6 (measured); adapter file sizes in `app/Resources/adapters/` |
| 7 | Apple ships this pattern | System model (~3B, OS-owned); `SystemLanguageModel.Adapter` exists but closed; availability check code snippet | Docs: research/foundation-models.md (b)(c); Xcode screenshot optional |
| 8 | The demo app | Two-mode screenshot (Naive / Shared) with adapter state visible | Shot: app, shared mode mid-sequence |
| 9 | LIVE DEMO (3–4 min) | Stage 1 native → Stage 2 naive → Stage 3 shared; airplane mode on; prerecorded fallback ready | Docs: demo-script.md |
| 10 | Result: memory over time | Chart A, both architectures overlaid, tasks annotated | P5 JSON × 2 runs (one per mode); plot.py |
| 11 | Result: latency breakdown | Chart B: adapter switch / TTFT / generation stacked | P5 JSON, shared mode |
| 12 | Switch cost detail | Median switch ms + "no app restart" claim; adapter state machine mini-diagram | P5 JSON `adapterSwitchMs`, scenario `adapter-thrashing` |
| 13 | What surprised us | (a) adapter 20 MB not 2 MB (all-linear keys); (b) footprint after reset: allocator cache keeps X MB (Risk B); (c) thinking-mode TTFT trap | Docs: findings.md; measure (b) in Reset scenario |
| 14 | When caching pays | Thrashing vs repeated-task numbers; cache break-even in switches/day | P5 JSON scenarios `adapter-thrashing` + `repeated-same-task` |
| 15 | Rules for apps + close | 3 rules (features request capabilities; one owner for model lifetime; measure footprint not resident); closing line "airplane mode" | Docs: decisions.md, numbers.md |

## Numbers to fill before slide-making (from device runs)

Run the app's **Run Scenarios** once per mode (iterations = 5), share both JSON
files out, then `plot.py` writes Charts A and B. These are the numbers slides
3, 4, 10, 11, 12, 13(b), 14 need — each must land in `presentation/numbers.md`
with its source file:

1. Naive peak footprint, A→B→C, median of 5
2. Shared peak footprint, A→B→C, median of 5
3. Median adapter switch (unload+load), from thrashing scenario
4. TTFT: warm same-task vs first-after-switch
5. Base cold load time (from Preload; log line "Base model load completed")
6. Footprint before/after Unload/Reset (allocator cache retention)
7. Per-adapter disk size (already known: ~20 MB each)

## Screenshots / traces to capture

- App: shared mode with adapter=classify mid-sequence (slide 8)
- Instruments: one Points of Interest trace showing BaseLoad → AdapterSwitch ×2
  → Inference intervals (slide 12 backup + conference fallback)
- Optional: jetsam termination in device console for the 3-instance case (slide 4)

## Slide rules (from decisions.md)

- Never chart Apple's system model against MLX numbers (D5/D6).
- Stage-1 FM segment is a story beat, not a bar (D5).
- Every number names its metric, scenario, device, runs, and source JSON (handoff §22).
- Negative results stay in (slide 13) — integrity rules §24.
