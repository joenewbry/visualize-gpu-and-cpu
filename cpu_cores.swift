import Darwin
import Foundation

/// Read per-CPU tick counts via Mach host_processor_info().
func getPerCoreTicks() -> [(user: Int64, system: Int64, idle: Int64, nice: Int64)]? {
    var numCPUs: natural_t = 0
    var cpuInfo: processor_info_array_t?
    var numCPUInfo: mach_msg_type_number_t = 0

    let result = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &numCPUs,
        &cpuInfo,
        &numCPUInfo
    )

    guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }

    var cores: [(user: Int64, system: Int64, idle: Int64, nice: Int64)] = []
    for i in 0..<Int(numCPUs) {
        let offset = Int(CPU_STATE_MAX) * i
        cores.append((
            user:   Int64(info[offset + Int(CPU_STATE_USER)]),
            system: Int64(info[offset + Int(CPU_STATE_SYSTEM)]),
            idle:   Int64(info[offset + Int(CPU_STATE_IDLE)]),
            nice:   Int64(info[offset + Int(CPU_STATE_NICE)])
        ))
    }

    vm_deallocate(
        mach_task_self_,
        vm_address_t(bitPattern: info),
        vm_size_t(Int(numCPUInfo) * MemoryLayout<integer_t>.size)
    )

    return cores
}

guard let sample1 = getPerCoreTicks() else {
    fputs("error: could not read CPU info\n", stderr)
    exit(1)
}

// Sample for 500ms to measure delta
usleep(500_000)

guard let sample2 = getPerCoreTicks() else {
    fputs("error: could not read CPU info\n", stderr)
    exit(1)
}

for i in 0..<sample1.count {
    let dUser   = sample2[i].user   - sample1[i].user
    let dSystem = sample2[i].system - sample1[i].system
    let dIdle   = sample2[i].idle   - sample1[i].idle
    let dNice   = sample2[i].nice   - sample1[i].nice
    let total   = dUser + dSystem + dIdle + dNice

    let pct: Double
    if total > 0 {
        pct = Double(dUser + dSystem + dNice) * 100.0 / Double(total)
    } else {
        pct = 0.0
    }
    print(String(format: "CORE%d=%.1f", i, pct))
}
