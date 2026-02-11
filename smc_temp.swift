import Foundation
import IOKit

// Use IOHIDEventSystem to read temperature from AppleARMPMUTempSensor devices.
// These are HID "temperature" events exposed on Apple Silicon.

// Private IOHIDEventSystem headers we access via dlsym
typealias IOHIDEventSystemClientCreateFunc = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
typealias IOHIDEventSystemClientSetMatchingFunc = @convention(c) (AnyObject, CFDictionary) -> Void
typealias IOHIDEventSystemClientCopyServicesFunc = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
typealias IOHIDServiceClientCopyPropertyFunc = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
typealias IOHIDServiceClientCopyEventFunc = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
typealias IOHIDEventGetFloatValueFunc = @convention(c) (AnyObject, UInt32) -> Double

let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)!

let clientCreate = unsafeBitCast(
    dlsym(handle, "IOHIDEventSystemClientCreate"),
    to: IOHIDEventSystemClientCreateFunc.self
)
let clientSetMatching = unsafeBitCast(
    dlsym(handle, "IOHIDEventSystemClientSetMatching"),
    to: IOHIDEventSystemClientSetMatchingFunc.self
)
let clientCopyServices = unsafeBitCast(
    dlsym(handle, "IOHIDEventSystemClientCopyServices"),
    to: IOHIDEventSystemClientCopyServicesFunc.self
)
let serviceProperty = unsafeBitCast(
    dlsym(handle, "IOHIDServiceClientCopyProperty"),
    to: IOHIDServiceClientCopyPropertyFunc.self
)
let serviceCopyEvent = unsafeBitCast(
    dlsym(handle, "IOHIDServiceClientCopyEvent"),
    to: IOHIDServiceClientCopyEventFunc.self
)
let eventGetFloat = unsafeBitCast(
    dlsym(handle, "IOHIDEventGetFloatValue"),
    to: IOHIDEventGetFloatValueFunc.self
)

// kIOHIDEventTypeTemperature = 15
let kIOHIDEventTypeTemperature: Int64 = 15
// Field: kIOHIDEventFieldTemperatureLevel = 0xf << 16 | 0
let kIOHIDEventFieldTemperatureLevel: UInt32 = (15 << 16) | 0

// Create IOHID client
guard let systemRef = clientCreate(kCFAllocatorDefault) else {
    fputs("error: could not create IOHIDEventSystemClient\n", stderr)
    exit(1)
}
let system = systemRef.takeRetainedValue()

// Match temperature sensors
let matching: [String: Any] = [
    "PrimaryUsagePage": 0xFF00,
    "PrimaryUsage": 5
]
clientSetMatching(system, matching as CFDictionary)

guard let servicesRef = clientCopyServices(system) else {
    fputs("error: no HID services found\n", stderr)
    exit(1)
}
let services = servicesRef.takeRetainedValue() as [AnyObject]

struct TempReading {
    let name: String
    let temp: Double
}

var readings: [TempReading] = []

for service in services {
    // Get product name
    guard let nameRef = serviceProperty(service, "Product" as CFString) else { continue }
    let name = nameRef.takeRetainedValue() as! String

    // Copy temperature event
    guard let eventRef = serviceCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
    let event = eventRef.takeRetainedValue()

    let temp = eventGetFloat(event, kIOHIDEventFieldTemperatureLevel)

    if temp > 0 && temp < 150 {
        readings.append(TempReading(name: name, temp: temp))
    }
}

// Categorize by name pattern
// On Apple Silicon, "PMU tdie*" sensors are SoC die temps (CPU+GPU share the die).
// There's no separate GPU temp sensor exposed via HID — GPU shares die temps.
var dieTemps: [Double] = []

for r in readings {
    let lower = r.name.lowercased()
    if lower.contains("tdie") || lower.contains("die") {
        dieTemps.append(r.temp)
    }
}

// Fallback: use any reading that looks like a chip temp
if dieTemps.isEmpty {
    for r in readings {
        let lower = r.name.lowercased()
        if lower.contains("pmu") && !lower.contains("tcal") && !lower.contains("battery") && !lower.contains("nand") {
            dieTemps.append(r.temp)
        }
    }
}

// Last resort: use all non-battery temps
if dieTemps.isEmpty {
    for r in readings {
        let lower = r.name.lowercased()
        if !lower.contains("battery") && !lower.contains("nand") && !lower.contains("gas gauge") {
            dieTemps.append(r.temp)
        }
    }
}

if !dieTemps.isEmpty {
    let avg = dieTemps.reduce(0, +) / Double(dieTemps.count)
    let max = dieTemps.max()!
    // Report as both CPU and GPU since they share the SoC die
    print(String(format: "CPU_TEMP_AVG=%.1f", avg))
    print(String(format: "CPU_TEMP_MAX=%.1f", max))
    print(String(format: "GPU_TEMP_AVG=%.1f", avg))
    print(String(format: "GPU_TEMP_MAX=%.1f", max))
}

// Debug: print all readings if -v flag
if CommandLine.arguments.contains("-v") {
    print("\nAll sensors:")
    for r in readings.sorted(by: { $0.name < $1.name }) {
        print(String(format: "  %@: %.1f°C", r.name, r.temp))
    }
}
