// task_vm_info reader: phys_footprint (the jetsam metric) + lifetime peak.
// Metric definitions: see docs/research/memory-and-instruments.md.
//
// phase peak is the max phys_footprint sampled during one load, switch, or
// inference phase. It is not ledger_phys_footprint_peak, which is process lifetime.

import Foundation
import os

struct MemorySnapshot: Codable, Sendable {
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64

    var physicalFootprintMB: Double { Double(physicalFootprintBytes) / 1_048_576 }
    var peakPhysicalFootprintMB: Double { Double(peakPhysicalFootprintBytes) / 1_048_576 }
}

func readMemory() -> MemorySnapshot {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else {
        return MemorySnapshot(physicalFootprintBytes: 0, peakPhysicalFootprintBytes: 0)
    }
    return MemorySnapshot(
        physicalFootprintBytes: info.phys_footprint,
        peakPhysicalFootprintBytes: UInt64(bitPattern: info.ledger_phys_footprint_peak))
}

/// Polls phys_footprint about every 50 ms. The result is a phase peak, not the lifetime ledger peak.
final class PhasePeakSampler: @unchecked Sendable {
    private let peak = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var task: Task<Void, Never>?

    func start() {
        sample()
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { break }
                self?.sample()
            }
        }
    }

    func stop() async -> Double {
        task?.cancel()
        await task?.value
        task = nil
        sample()
        let bytes = peak.withLock { $0 }
        return Double(bytes) / 1_048_576
    }

    private func sample() {
        let bytes = readMemory().physicalFootprintBytes
        peak.withLock { value in
            if bytes > value { value = bytes }
        }
    }
}
