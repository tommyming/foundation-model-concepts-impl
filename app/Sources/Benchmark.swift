// Benchmark scenarios (handoff §10) + machine-readable JSON output (§14).

import Foundation

struct BenchmarkStep: Codable {
    let task: String
    let adapterSwitchMs: Double?
    let modelLoadMs: Double?
    let ttftMs: Double?
    let totalMs: Double
    let memoryBeforeMB: Double
    let memoryAfterMB: Double
    let peakFootprintMB: Double
}

struct BenchmarkRun: Codable {
    let scenario: String
    let architecture: String
    let measuredIteration: Int
    let steps: [BenchmarkStep]
}

struct BenchmarkReport: Codable {
    let environment: EnvironmentInfo
    let runs: [BenchmarkRun]

    struct EnvironmentInfo: Codable {
        let device: String
        let os: String
        let model: String
        let adapters: String
    }
}

enum Benchmark {
    /// Scenario task sequences, handoff §10.
    static let scenarios: [(name: String, tasks: [AITask])] = [
        ("sequential-three-tasks", [.summarize, .classify, .extract]),
        ("repeated-same-task", [.summarize, .summarize, .summarize]),
        ("adapter-thrashing", [.summarize, .classify, .summarize, .extract, .summarize, .classify]),
    ]

    /// Runs all scenarios: one warm-up iteration plus `measured` recorded ones.
    /// Returns a file URL for sharing. Progress is reported per scenario.
    @MainActor
    static func runAll(
        model: AppModel, input: String, measured: Int,
        progress: @escaping (String) -> Void
    ) async throws -> URL {
        var runs: [BenchmarkRun] = []
        let architecture = model.mode == .sharedBase ? "shared-adapter" : "naive-independent"

        for scenario in scenarios {
            for iteration in 0...measured {
                if iteration == 0 {
                    progress("warm-up \(scenario.name)")
                } else {
                    progress("run \(iteration)/\(measured) \(scenario.name)")
                }
                var steps: [BenchmarkStep] = []
                for task in scenario.tasks {
                    model.run(task: task, input: input)
                    // Run to completion on the main actor's model.
                    while model.isBusy {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    if let err = model.errorText {
                        throw NSError(domain: "benchmark", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: err])
                    }
                    guard let m = model.lastMetrics else { continue }
                    steps.append(BenchmarkStep(
                        task: m.task.rawValue,
                        adapterSwitchMs: m.adapterSwitch.map(ms),
                        modelLoadMs: m.modelLoad.map(ms),
                        ttftMs: m.firstToken.map(ms),
                        totalMs: ms(m.total),
                        memoryBeforeMB: m.memoryBefore.physicalFootprintMB,
                        memoryAfterMB: m.memoryAfter.physicalFootprintMB,
                        peakFootprintMB: m.memoryAfter.peakPhysicalFootprintMB))
                }
                if iteration > 0 {
                    runs.append(BenchmarkRun(
                        scenario: scenario.name, architecture: architecture,
                        measuredIteration: iteration, steps: steps))
                }
            }
        }

        let report = BenchmarkReport(
            environment: .init(
                device: utsname().machineDescription(),
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                model: "mlx-community/Qwen3-1.7B-4bit",
                adapters: "summarize,classify,extract (rank 8, 16 layers)"),
            runs: runs)

        let dir = URL.applicationSupportDirectory
            .appending(component: "benchmarks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appending(component: "benchmark-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url)
        return url
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

private extension utsname {
    func machineDescription() -> String {
        var s = self
        return withUnsafeBytes(of: &s.machine) { ptr in
            String(decoding: ptr.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
