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

1. Scroll to **On-device Foundation Models**. Availability must read available.
2. Tap **Extract with System Model**. Use the same note as the rest of the talk.
3. Say: "The OS owns that model. My app owns none of it. Now let's own one."

Fallback: skip to stage 2, show stage 1 from the prerecorded trace.

## Stage 2 — Bundled, naive (~60 s)

1. Switch the mode to **Naive**. That resets any shared model.
2. Tap **Prepare**. No model is loaded yet.
3. Run **Summarize**. Point at "resident: summarize".
4. Run **Classify**. Resident list grows to two. Point at the footprint number.
5. Run **Extract**. Three instances resident. Read the footprint aloud.
6. Say: "Ownership is the cost."

## Stage 3 — Bundled, shared (~90 s)

1. Switch the mode to **Shared Base + Adapters**. That resets the naive instances.
2. Tap **Preload**. The base becomes resident once.
3. Tap **Run Sequence**, or tap **Summarize**, **Classify**, then **Extract** if you want to narrate each switch.
4. On the first task, read the switch time and the time to first token.
5. On the next tasks, point out that the base stays loaded and only the adapter name changes.
6. Show the memory-over-time chart: same sequence, both architectures.
7. Say: "Ownership with discipline. One base, three adapters that cost
   megabytes, not gigabytes."

## Closing line

"Every number you saw was measured on one iPhone with airplane mode on."

## Rules

- Never wait through a cold start on stage. Cold-start comparisons come from
  the prerecorded charts.
- If anything stalls, skip to the charts. The charts carry the claim.
