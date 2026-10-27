# Environment record

Fill in per benchmark session; every published number names this file (handoff §3, §11).

| Item | Value |
|---|---|
| Date | TBD |
| macOS version | 26.6.2 (25G83) |
| Xcode version | 26.6 (17F113) |
| Swift version | 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101), from `xcrun swift --version` |
| iOS SDK | 26.5 |
| Device model | TBD |
| Device OS | TBD |
| Device storage free | TBD |
| Battery state | TBD (>= 80%, not charging preferred) |
| Low Power Mode | OFF |
| Thermal state | TBD (nominal required) |
| Debugger attached | NO (final numbers) |
| Airplane mode | ON |
| MLX Swift (mlx-swift-lm) | 3.32.3 |
| mlx-swift | 0.32.x (see app/AIMemoryLab.xcodeproj Package.resolved) |
| Base model | mlx-community/Qwen3-1.7B-4bit @ commit 3b1b1768f8f8cf8351c712464f906e86c2b8269e |
| Quantization | 4-bit groupwise (as shipped by mlx-community) |
| Adapters | classify/summarize/extract, rank 8, scale 20, last 16 layers, QLoRA vs same 4-bit repo, iters 600, batch 4, lr 1e-5, mask-prompt on |
| Generation settings | temperature 0, maxTokens 256 |
| Benchmark input | the default note in ContentView (fixed string) |
