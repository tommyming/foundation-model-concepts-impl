// Benchmark scenarios (handoff §10) + machine-readable JSON output (§14).

import Darwin
import Foundation

struct BenchmarkStep: Codable {
    let task: String
    let adapterSwitchMs: Double?
    let modelLoadMs: Double?
    let ttftMs: Double?
    let totalMs: Double
    let memoryBeforeMB: Double
    let memoryAfterMB: Double
    /// Max phys_footprint sampled during this step. Not the process lifetime peak.
    let phasePeakMB: Double
    /// ledger_phys_footprint_peak at the end of the step.
    let lifetimePeakMB: Double
    let inputTokens: Int?
    let outputTokens: Int?
}

struct BenchmarkRun: Codable {
    let scenario: String
    let architecture: String
    let measuredIteration: Int
    let thermalState: Int
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
        let debuggerAttached: Bool
    }
}

enum Benchmark {
    static let coldStartName = "cold-start"

    /// Scenario task sequences, handoff §10. Cold start is first and is the only scenario that resets.
    static let scenarios: [(name: String, tasks: [AITask])] = [
        (coldStartName, [.summarize]),
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
            let coldStart = scenario.name == coldStartName
            for iteration in 0...measured {
                let thermalState = ProcessInfo.processInfo.thermalState.rawValue
                if iteration == 0 {
                    progress("warm-up \(scenario.name)")
                } else {
                    progress("run \(iteration)/\(measured) \(scenario.name)")
                }
                if coldStart {
                    try await prepareColdStart(model)
                }
                model.clearContext()
                var steps: [BenchmarkStep] = []
                for task in scenario.tasks {
                    model.run(task: task, input: input)
                    while model.isBusy {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    if let err = model.errorText {
                        throw NSError(domain: "benchmark", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: err])
                    }
                    guard let m = model.lastMetrics else { continue }
                    let load = coldStart && model.mode == .sharedBase ? model.loadDuration : m.modelLoad
                    if coldStart, load == nil {
                        throw NSError(domain: "benchmark", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "Cold start did not record load time"])
                    }
                    let phasePeak = coldStart
                        ? max(m.phasePeakMB, model.lastLoadPhasePeakMB)
                        : m.phasePeakMB
                    steps.append(BenchmarkStep(
                        task: m.task.rawValue,
                        adapterSwitchMs: m.adapterSwitch.map(ms),
                        modelLoadMs: load.map(ms),
                        ttftMs: m.firstToken.map(ms),
                        totalMs: ms(m.total),
                        memoryBeforeMB: m.memoryBefore.physicalFootprintMB,
                        memoryAfterMB: m.memoryAfter.physicalFootprintMB,
                        phasePeakMB: phasePeak,
                        lifetimePeakMB: m.memoryAfter.peakPhysicalFootprintMB,
                        inputTokens: m.inputTokens,
                        outputTokens: m.outputTokens))
                }
                if iteration > 0 {
                    runs.append(BenchmarkRun(
                        scenario: scenario.name, architecture: architecture,
                        measuredIteration: iteration, thermalState: thermalState,
                        steps: steps))
                }
            }
        }

        let report = BenchmarkReport(
            environment: .init(
                device: utsname().machineDescription(),
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                model: "mlx-community/Qwen3-1.7B-4bit",
                adapters: "summarize,classify,extract (rank 8, 16 layers)",
                debuggerAttached: debuggerAttached()),
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

    /// Reset, then load only what the current mode needs. Does not run inference.
    @MainActor
    private static func prepareColdStart(_ model: AppModel) async throws {
        model.reset()
        switch model.mode {
        case .sharedBase:
            await model.loadBase()
        case .naive:
            model.prepareNaive()
        }
        if let err = model.errorText {
            throw NSError(domain: "benchmark", code: 2,
                userInfo: [NSLocalizedDescriptionKey: err])
        }
        guard model.state == .ready else {
            throw NSError(domain: "benchmark", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cold start did not reach ready"])
        }
        if model.mode == .naive, model.baseLoaded || !model.residentInstances.isEmpty {
            throw NSError(domain: "benchmark", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Naive cold start loaded a model before summarize"])
        }
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

private func debuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}

private extension utsname {
    func machineDescription() -> String {
        var s = self
        return withUnsafeBytes(of: &s.machine) { ptr in
            String(decoding: ptr.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
