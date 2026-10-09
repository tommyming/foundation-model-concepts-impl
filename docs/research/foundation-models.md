# Research: Apple Foundation Models Framework (on-device LLM path)

- **Task:** 2 of 4 — Apple Foundation Models framework specialization path
- **Date:** 2026-10-09
- **Local toolchain verified:** Xcode 26.6 (Build 17F113) with iOS 26.5 SDK (default `xcodebuild`), plus Xcode 27 and Xcode 27.1 RC (iOS 27.0 / 27.1 SDKs) installed side-by-side on this machine
- **Question this answers:** can the demo's "frozen base model + specialization" story be told Apple-natively, and which parts run on the iOS 26.5 SDK vs require the iOS 27 SDK?

**Claim labels:** `[Apple-documented]` = stated by Apple docs / WWDC / Apple ML Research. `[SDK-verified]` = read directly from the installed SDK swiftinterface (path in Sources). `[inferred]` = my conclusion from evidence, not stated by Apple.

---

## Verdict

VERDICT Apple-native reference demo: possible-scoped-down

- The Apple-native section **can be built and run today on Xcode 26.6 / iOS 26.5 SDK**: sessions on the frozen system model, availability gating, guided/structured output (`@Generable`/`@Guide`), tool calling, streaming, and context/token introspection (runtime iOS 26.4+). This demonstrates "one frozen shared model, specialized per task by prompt-level context" — Apple's sanctioned specialization surface. `[Apple-documented]`
- The **adapter half of the thesis cannot be demoed Apple-natively**: Apple's tech report says the framework "exposes … LoRA adapter fine-tuning" `[Apple-documented, [7]]` and a public `SystemLanguageModel.Adapter` API has existed since iOS 26.0 `[SDK-verified]`, but it is **absent from developer documentation, has no WWDC coverage, and there is no documented tooling, file format, or training API to author adapters** — third parties cannot ship system-model adapters today `[inferred]`. The live adapter hot-swap experiment stays in the MLX Swift path, exactly as the handoff (§2, §16) anticipated.
- iOS 27 SDK extras (Dynamic Profiles, image input, PCC model, `LanguageModel` provider protocol incl. `MLXLanguageModel`/`CoreAILanguageModel`) would strengthen the section but require Xcode 27 + an iOS 27 device.

---

## (a) Public API surface for the on-device LLM

All symbols below verified in the iOS 26.5 SDK swiftinterface (`[SDK-verified]`, Source S1) unless marked iOS 27 (Source S2), and cross-checked against Apple docs `[Apple-documented]`.

| Capability | Exact API | Since | Notes |
|---|---|---|---|
| Module | `import FoundationModels` | iOS/macOS/visionOS 26.0 | Framework ships in the OS SDK; tvOS unavailable. watchOS: FM arrives in watchOS 27 via Private Cloud Compute `[Apple-documented, [5]]` |
| Session object | `LanguageModelSession` (`init(model:tools:instructions:)`, `init(model:tools:transcript:)`) | 26.0 | Lightweight handle; no model weights in your process |
| System model | `SystemLanguageModel.default`, `init(useCase:guardrails:)`; `UseCase.general` / `.contentTagging` | 26.0 | Single shared on-device model (~3B params `[Apple-documented, [7]]`) |
| Availability | `SystemLanguageModel.availability: .available \| .unavailable(UnavailableReason)`; reasons: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`; `isAvailable` | 26.0 | Model is an OS asset downloaded when Apple Intelligence is enabled |
| Locale | `supportedLanguages`, `supportsLocale(_:)` | 26.0 | Language gating (see (c)) |
| Text generation | `session.respond(to:options:) async throws -> Response<String>`; `PromptBuilder` trailing closure; `streamResponse(to:) -> ResponseStream` (async sequence of partials) | 26.0 | Response exposes `.content`; stream snapshots expose `.content` as `PartiallyGenerated` |
| Guided / structured output | `@Generable` macro (structs/enums), `@Guide(description:)` property macro, `GenerationGuide` (range/count constraints), `respond(to:generating: Content.Type) -> Response<Content>`, `respond(to:schema: GenerationSchema)`, `GeneratedContent` (+ `init(json:)`), `DynamicGenerationSchema` | 26.0 | Constrained sampling against a Swift type schema `[Apple-documented, [4]]` |
| Tool calling | `Tool` protocol (`call(arguments:) async throws -> some PromptRepresentable`), `@Tool` macro; tools passed via `init(tools:)`; tool args can themselves be `@Generable` with guides | 26.0 | `[Apple-documented, [4]]` |
| Instructions | `Instructions` / `InstructionsBuilder`, or plain `String` in init | 26.0 | Session-level system prompt |
| Generation options | `GenerationOptions(sampling:temperature:maximumResponseTokens:)`; `SamplingMode.greedy`, `.random(topK:)`, `.random(probabilityThreshold:)` | 26.0 | |
| Context introspection | `model.contextSize: Int` (4096 on iOS 26 model; 8192 on the iOS 27 model `[Apple-documented, [5]]`); `model.tokenCount(for:)` for prompts / instructions / tools / schemas / transcript entries | iOS 26.4 | `[Apple-documented, [6]]` — use to adapt to hardware |
| Errors | e.g. guardrail violations, context limits, tool errors via thrown `Error`s from `respond` | 26.0 | Refined guardrails (fewer false positives) in 26.4 and again in iOS 27 `[Apple-documented, [5][6]]` |
| **iOS 27 additions** | `LanguageModel` provider protocol (+ `LanguageModelExecutor`), `PrivateCloudComputeLanguageModel`, `ContextOptions(reasoningLevel:)`, `Attachment`/`ImageAttachment`, `LanguageModelSession.DynamicProfile`/`Profile` (+ `.model()`/`.reasoningLevel()` modifiers), `Usage`/`QuotaUsage` token & quota introspection, system tools (`OCRTool`, `BarcodeReaderTool`, Spotlight search tool), `TranscriptErrorHandlingPolicy`, `SessionProperty` | 27.0 (27.1 SDK carries ~241 `@available(iOS 27…)` symbols) | See (f). ~227 symbols remain `@available(iOS 26…)` — additive, nothing removed `[SDK-verified, S2]` |

Sample code / articles: trip-planner sample for WWDC25 259 `[4]`; iOS 27 "Origami" dynamic-profiles sample `[5][6]`.

---

## (b) Does Apple expose a custom-adapter / fine-tuning / LoRA API for the system model?

**Short answer: there is a real, public-in-SDK adapter API — `SystemLanguageModel.Adapter` — and Apple's tech report says the framework "exposes … LoRA adapter fine-tuning", but it is undocumented and unusable by third parties today. No documented fine-tuning/LoRA API exists in iOS 26 or iOS 27.**

1. **Apple's own claim** — "Apple Intelligence Foundation Language Models Tech Report 2025" (published July 2025): "A new Swift-centric Foundation Models framework exposes guided generation, constrained tool calling, and **LoRA adapter fine-tuning**, allowing developers to integrate these capabilities with a few lines of code." `[Apple-documented, [7]]`
2. **The actual API, verified in both local SDKs** (present since iOS 26.0, unchanged through iOS 27.1) `[SDK-verified, S1/S2]`:
   ```swift
   extension SystemLanguageModel {
     public struct Adapter {
       public var creatorDefinedMetadata: [String: Any] { get }
     }
   }
   extension SystemLanguageModel.Adapter {
     public init(fileURL: URL) throws          // load an adapter from disk
     public init(name: String) throws          // load a named/system adapter
     public func compile() async throws
     public static func compatibleAdapterIdentifiers(name: String) -> [String]
     public static func removeObsoleteAdapters() throws
     // AssetError cases: invalidAsset, invalidAdapterName, compatibleAdapterNotFound
   }
   // and: SystemLanguageModel(adapter: Adapter, guardrails: Guardrails)
   ```
   The iOS 27.1 SDK additionally references `Adapter.isCompatible(BackgroundAssets.AssetPack)` internally (silgen symbol), i.e. adapters are distributed as BackgroundAssets asset packs. `[SDK-verified, S2]`
3. **Why it is not a usable path for the demo:** `SystemLanguageModel.Adapter` does **not appear anywhere in developer.apple.com documentation** (absent from the framework's documentation symbol index, fetched 2026-10-09), is not covered in any WWDC25/26 session, and there is **no public adapter file-format spec, no training/conversion tooling, and no API to create adapters** — only to load them. `[inferred]` from documented absence; treat as reserved for Apple- or MDM-distributed assets. Shipping against it would be a doc-less-API risk for App Review. `[inferred]`
4. **What Apple documents as the app-level specialization story instead:** instructions, `@Guide`-constrained schemas (guided generation), tools, and (iOS 27) Dynamic Profiles that swap instructions/tools/model per mode within a single session. `[Apple-documented, [4][5]]` — these are *prompt/context-level* specialization of the frozen model, not weight-level adapters.
5. **iOS 27's `LanguageModel` protocol is model substitution, not specialization**: it lets any local or server model (Apple's `CoreAILanguageModel`, `MLXLanguageModel`, Anthropic/Google packages) back a `LanguageModelSession`. It does not fine-tune or adapt the system model. `[Apple-documented, [5][9]]`

**Demo mapping:** Apple's platform design (frozen system model + LoRA adapters) is real and publicly acknowledged `[7]`, the loading API exists in the SDK `[SDK-verified]`, but the adapter-creation pipeline is closed. The demo should state this explicitly and run the actual adapter experiment in MLX Swift.

---

## (c) OS, device, and RAM requirements (Apple Intelligence gating)

| Requirement | Value | Source |
|---|---|---|
| OS (framework) | iOS/iPadOS 26.0+, macOS 26.0+, visionOS 26.0+; watchOS 27.0+ (PCC only); tvOS unavailable | `[SDK-verified, S1/S2]` |
| OS (context/token APIs) | iOS 26.4+ (`.contextSize`, `tokenCount(for:)`, refreshed on-device model) | `[Apple-documented, [6]]` |
| OS (iOS 27 APIs) | iOS 27.0+ runtime; requires building with iOS 27 SDK (Xcode 27) | `[SDK-verified, S2]` |
| iPhone | iPhone 15 Pro / 15 Pro Max (A17 Pro) and later — incl. iPhone 16/16e, iPhone 17 family | `[Apple-documented, [8]]` |
| iPad | iPad Pro (M1+), iPad Air (M1+), iPad mini (A17 Pro) | `[Apple-documented, [8]]` |
| Mac | MacBook Air / Pro, iMac, Mac mini (M1+); Mac Studio (M1 Max+); Mac Pro (M2 Ultra); (the A18 Pro MacBook also listed) | `[Apple-documented, [8]]` |
| Apple Vision Pro | M2 and later | `[Apple-documented, [8]]` |
| Language gating | Siri **and** device language set to one of: Chinese (Simplified/Traditional), Danish, Dutch, English, French, German, Italian, Japanese, Korean, Norwegian, Portuguese, Spanish, Swedish, Turkish, Vietnamese | `[Apple-documented, [8]]` |
| Apple Intelligence toggle | Must be enabled (else `appleIntelligenceNotEnabled`); model asset must be downloaded (else `modelNotReady`) | `[Apple-documented, S1]` |
| RAM | **No official RAM figure is published.** Every device on the supported list has ≥ 8 GB RAM (iPhone 15 Pro = 8 GB) | `[inferred]` |
| Developer entitlements | None for the on-device model. PCC (iOS 27) requires the `com.apple.developer.private-cloud-compute` entitlement; no API-key/auth setup; free daily quota for apps with < 2M first-time downloads, higher for iCloud+ users | `[Apple-documented, [1][5][11]]` |
| Xcode | Xcode 26.x to build against iOS 26 SDK; Xcode 27 for iOS 27-only symbols | `[SDK-verified, S1/S2]` |

---

## (d) Minimal working example — availability check + guided/structured output

Compiles against the **iOS 26.5 SDK (Xcode 26.6)**; runs on any Apple Intelligence device on iOS 26.0+ (26.4+ for the token-count line). Signatures verified against S1.

```swift
import FoundationModels

// 1. The frozen, OS-managed system model — shared by all apps.
let model = SystemLanguageModel.default

// 2. Gate on Apple Intelligence (device, toggle, downloaded asset).
guard model.availability == .available else {
    switch model.availability {
    case .unavailable(let reason):
        // reason: .deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady
        fatalError("System model unavailable: \(reason)")
    default: fatalError("unreachable")
    }
}

// 3. Define a structured output type — the "specialization" is the schema,
//    guides, instructions and tools you attach to the frozen model.
@Generable
struct NoteExtraction {
    @Guide(description: "People mentioned in the note, or empty")
    var people: [String]
    @Guide(description: "One of: technology, business, science, culture, other")
    var category: String
    @Guide(description: "Concrete action items, or empty")
    var actionItems: [String]
}

// 4. A session is cheap; the OS loads/evicts the model itself.
let session = LanguageModelSession(
    instructions: "You extract structured data from notes. Be concise."
)

let note = """
Sara wants the Q3 forecast slides before Friday. Ping Acme Corp about
the renewal, and book the lab for the antenna test.
"""

// 5. Guided generation: the model's sampling is constrained to the schema.
let response = try await session.respond(to: note, generating: NoteExtraction.self)
print(response.content.category)     // e.g. "business"
print(response.content.actionItems)  // e.g. ["Ping Acme Corp ...", "Book the lab ..."]

// 6. (iOS 26.4+) Budget context explicitly.
print(try await model.tokenCount(for: note), "of", model.contextSize, "tokens")
```

Streaming variant: `for try await partial in session.streamResponse(to: note, generating: NoteExtraction.self) { ... }` — snapshots expose `.content` as `PartiallyGenerated`. Tool-calling variant (same SDK):

```swift
struct WeatherTool: Tool {
    let description = "Current weather for a location"
    @Generable struct Arguments { @Guide(description: "A city name") var city: String }
    func call(arguments: Arguments) async throws -> some PromptRepresentable {
        "<weather for \(arguments.city)>"
    }
}
// LanguageModelSession(tools: [WeatherTool()], instructions: ...)
```

Reference sample: Apple's trip-planner app `[4]` (WWDC25 session 259) shows the same pattern end-to-end with streaming, tools, and deterministic sampling.

---

## (e) Model lifecycle & residency: Foundation Models vs app-managed MLX

| Dimension | Foundation Models framework | MLX Swift (app-managed) |
|---|---|---|
| Who owns the weights | Apple / the OS; distributed as an OS asset with Apple Intelligence | Your app — you bundle or download weights |
| Who loads the model | The OS, on demand, when sessions need it; `modelNotReady` until the asset is downloaded | Your code (`ModelFactory.loadHub`, etc.) — you decide when |
| Where it runs / memory attribution | Outside your process; model memory is not part of your app's footprint `[inferred from Apple-documented OS-asset/session model, [1][2]]` | In-process; allocations and Metal buffers are your app's memory |
| Eviction / unload | OS-managed under memory pressure; the app has no unload API | You control release; allocator/Metal caches may delay reclamation (demo Risk B) |
| Sharing | One copy of the model shared system-wide across apps `[Apple-documented, [2]]` | Per-process; two apps (or two instances) duplicate weights unless the OS shares clean file-backed pages (demo Risk C) |
| Model choice | One frozen system model (~3B, 4k ctx iOS 26 / 8k ctx iOS 27); iOS 27 adds `LanguageModel` providers (PCC, CoreAI, MLX, third-party) | Any GGUF/safetensors model, any quantization, fine-tuned or LoRA-adapted |
| Specialization | Prompt-level only for apps: instructions, guides/schemas, tools, Dynamic Profiles (27). Adapter loading API exists but is closed (see (b)) | Full control: LoRA load/activate/deactivate, adapter caches — the demo's Mode 2 |
| Context & caching | Session transcript; 4,096-token window per session on iOS 26 `[Apple-documented, [12]]`; KV-cache reuse internal to the OS model (2-bit QAT + KV-cache sharing in model design `[7]`) | You manage KV cache growth, context truncation, memory |
| Availability failures | Runtime gating (device/toggle/language/asset) — must be handled in UI | Deterministic once shipped; gated only by device RAM/storage |
| Instrumentation | Foundation Models instrument in Instruments: prompts, tool calls, latency, token consumption `[Apple-documented, [13][16]]` | Your own signposts + Allocations/VM Tracker/Metal System Trace |
| Updates | Model changes under you on OS updates (26.4 model refresh, iOS 27 new model) — Apple says re-test prompts `[Apple-documented, [6]]` | Frozen with your shipped model revision |

Key talking point for the talk: with FM, "AI features request capabilities; the OS owns the resource" is enforced by the platform; with MLX, that discipline is the app's job — which is exactly what the demo's ModelManager actor recreates.

---

## (f) What's new in iOS 27 SDK / Foundation Models vs iOS 26 (and Xcode gating)

From WWDC26 session 241 `[5]`, the Foundation Models updates page `[6]`, and the SDK diff `[SDK-verified, S1 vs S2]` (0 symbols removed; ~240 new `@available(iOS 27…)` symbols):

| Change | What it is | Needs Xcode 27 + iOS 27 device? |
|---|---|---|
| New on-device model | Rebuilt base model, better logic/tool calling; context 8,192 tokens (was 4,096) | Model itself is server-side of the API — no code change needed; new-model behavior only on iOS 27 |
| Vision / image input | `Attachment`/`ImageAttachment` in prompts (UIImage, NSImage, CGImage, CIImage, CVPixelBuffer, file URL; any size) | Yes — iOS 27 SDK symbols |
| Private Cloud Compute | `PrivateCloudComputeLanguageModel` (32k ctx, reasoning levels), no auth/keys; watchOS 27 support; entitlement + quota (free < 2M first-time downloads) | Yes |
| Model abstraction layer | `LanguageModel` protocol; open-source `CoreAILanguageModel` (ANE) and `MLXLanguageModel` (GPU) packages; Anthropic/Google Swift packages; `LanguageModelExecutor` for authoring providers | Yes (session API accepts `some LanguageModel`) |
| Usage introspection | `response.usage` — input/output/cached/reasoning token counts; `QuotaUsage` | Yes |
| System tools | `OCRTool`, `BarcodeReaderTool` (Vision-backed); Spotlight search tool (local RAG) | Yes |
| Dynamic Profiles | `LanguageModelSession.DynamicProfile` — declarative swap of instructions/tools/model per mode in one session (`.model()`, `.reasoningLevel()` modifiers) | Yes |
| Context/token APIs | `contextSize`, `tokenCount(for:)` — shipped in **iOS 26.4**, usable from Xcode 26 SDKs | No — works on iOS 26.5 SDK |
| Evaluations framework | New Swift framework to measure intelligence-feature quality | Yes (framework itself ships in 27 SDKs) |
| Tooling | `fm` CLI and Foundation Models Python SDK (`apple_fm_sdk`) on macOS 27 | Yes (macOS 27) |
| Open source | Core framework open-sourced (runs wherever Swift does, incl. Linux); "Foundation Models utilities" package (transcript management, skills API, Chat-Completions model) | No — Swift packages, SDK-independent |
| Instruments | Enhanced Foundation Models instrument (latency, prompts, output, tools) `[16]` | Template ships with Xcode 27 |

**Xcode 27 is required** to compile any iOS 27-only symbol (Dynamic Profiles, attachments, PCC, `LanguageModel` providers, usage…). Everything in section (d) compiles on **Xcode 26.6 / iOS 26.5 SDK** today.

### Demo scoping: iOS 26.5 SDK vs iOS 27 SDK

| Demo element | iOS 26.5 SDK (current default) | iOS 27 SDK (Xcode 27/27.1 RC installed) |
|---|---|---|
| Frozen-model session, availability gating, guided extraction (summarize/classify/extract) | ✅ | ✅ |
| Tool calling, streaming, deterministic sampling | ✅ | ✅ |
| Token/context budgeting | ✅ (runtime 26.4+) | ✅ |
| Content tagging mini-feature | ✅ | ✅ |
| Adapter story | Explain + cite tech report + show `SystemLanguageModel.Adapter` signature; cannot load custom adapters | Same — still closed in 27.1 |
| Dynamic Profiles (mode switching in one session — nice thesis parallel) | ❌ | ✅ |
| Image input, PCC reasoning, `MLXLanguageModel` inside FM sessions | ❌ | ✅ |

---

## Sources

Fetched / verified 2026-10-09.

1. Apple Developer Documentation — Foundation Models framework: https://developer.apple.com/documentation/foundationmodels (docs JSON symbol index; `SystemLanguageModel.Adapter` absent from it)
2. WWDC25 session 286 — "Meet the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2025/286/
3. WWDC25 session 301 — "Deep dive into the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2025/301/
4. WWDC25 session 259 + sample — "Adding intelligent app features with generative models" (trip-planner sample): https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models
5. WWDC26 session 241 — "What's new in the Foundation Models framework" (transcript): https://developer.apple.com/videos/play/wwdc2026/241/
6. Apple Developer — "Foundation Models updates": https://developer.apple.com/documentation/Updates/FoundationModels
7. Apple ML Research — "Apple Intelligence Foundation Language Models Tech Report 2025" (paper, published July 2025): https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025 — ~3B-param on-device model, KV-cache sharing, 2-bit QAT, PT-MoE server model, "Foundation Models framework exposes guided generation, constrained tool calling, and LoRA adapter fine-tuning"
8. Apple — Apple Intelligence page (device + language requirements, footnotes; also support.apple.com/121115): https://www.apple.com/apple-intelligence/
9. WWDC26 session 339 — "Bring an LLM provider to the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2026/339/
10. WWDC26 session 242 — "Build agentic app experiences with the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2026/242/
11. WWDC26 session 319 — "Build with the new Apple Foundation Model on Private Cloud Compute": https://developer.apple.com/videos/play/wwdc2026/319/
12. Apple Developer — "Managing the context window": https://developer.apple.com/documentation/foundationmodels/managing-the-context-window
13. Apple Developer — "Analyzing the runtime performance of your Foundation Models app": https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app
14. WWDC26 session 243 — "Debug and profile agentic app experiences with Instruments": https://developer.apple.com/videos/play/wwdc2026/243/
15. Apple ML Research — "Apple Intelligence Foundation Language Models" (July 2024): https://machinelearning.apple.com/research/apple-intelligence-foundation-language-models
16. WWDC26 videos index (session list): https://developer.apple.com/videos/wwdc2026/

Local SDK evidence (swiftinterfaces, read directly):

- **S1** — `/Applications/Xcode-26.6.app/.../iPhoneOS26.5.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface` (1,501 lines; `SystemLanguageModel.Adapter` at lines 652–700)
- **S2** — `/Applications/Xcode-27.1-RC.app/.../iPhoneOS27.1.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface` (type diff vs S1: +65 types incl. `LanguageModel`, `PrivateCloudComputeLanguageModel`, `DynamicProfile`, `Attachment`, `Usage`, `QuotaUsage`, `ContextOptions`; 0 removals; 227 × iOS 26 vs 241 × iOS 27 availability annotations)
