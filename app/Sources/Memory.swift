// task_vm_info reader: phys_footprint (the jetsam metric) + lifetime peak.
// Metric definitions: see docs/research/memory-and-instruments.md.

import Foundation

struct MemorySnapshot: Codable, Sendable {
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let residentBytes: UInt64

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
        return MemorySnapshot(physicalFootprintBytes: 0, peakPhysicalFootprintBytes: 0, residentBytes: 0)
    }
    return MemorySnapshot(
        physicalFootprintBytes: info.phys_footprint,
        peakPhysicalFootprintBytes: UInt64(bitPattern: info.ledger_phys_footprint_peak),
        residentBytes: UInt64(info.resident_size))
}
