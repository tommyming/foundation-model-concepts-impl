# Demo script — live segment (2.5–4 minutes)

Three-stage arc per `docs/decisions.md` (D4, D5). Stage 1 needs an Apple
Intelligence device; stages 2–3 run from this app.

## Before the talk

- Device charged, cooled, airplane mode ON, brightness fixed.
- App installed, not yet launched. Weights bundled (fetch-model + rebuild).
- Prerecorded Instruments trace + benchmark charts on the laptop as fallback.
- If showing stage 1: Apple Intelligence enabled, system model asset
  downloaded (check before going offline).

## Stage 1 — Native (~30 s)

1. Availability check on the system model. `.available`.
2. One guided extraction on the frozen system model. Same note as the talk.
3. Say: "The OS owns that model. My app owns none of it. Now let's own one."

Fallback: skip to stage 2, show stage 1 from the prerecorded trace.

## Stage 2 — Bundled, naive (~60 s)

1. Mode: **Naive**.
2. Run **Summarize**. Point at "resident: summarize".
3. Run **Classify**. Resident list grows to two. Point at the footprint number.
4. Run **Extract**. Three instances resident. Read the footprint aloud.
5. Say: "Ownership is the cost."

## Stage 3 — Bundled, shared (~90 s)

1. **Unload / Reset**. Mode: **Shared Base + Adapters**.
2. **Preload**. Base becomes resident once.
3. Run **Summarize** → adapter: summarize. Read the switch time and TTFT.
4. Run **Classify** → base stays, adapter changes.
5. Run **Extract** → repeat.
6. Show the memory-over-time chart: same sequence, both architectures.
7. Say: "Ownership with discipline. One base, three adapters that cost
   megabytes, not gigabytes."

## Closing line

"Every number you saw was measured on one iPhone with airplane mode on."

## Rules

- Never wait through a cold start on stage. Cold-start comparisons come from
  the prerecorded charts.
- If anything stalls, skip to the charts. The charts carry the claim.
