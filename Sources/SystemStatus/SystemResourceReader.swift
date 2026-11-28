import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Serial ownership of CPU baselines, the SMC connection and per-source refresh deadlines.
actor SystemResourceReader {
    private var reading = SystemReading()
    private var previousCPU: [[UInt32]]?
    private var lastDemand: ResourceDemand?
    private var lastRead: [String: TimeInterval] = [:]
    private lazy var coreKinds = Self.readCoreKinds()
    private let thermal = ThermalReader()
    private var health: Int?
    private let host = mach_host_self()
    deinit { mach_port_deallocate(mach_task_self_, host) }

    func sample(_ demand: ResourceDemand, powerChanged: Bool = false) -> SystemReading {
        let now = ProcessInfo.processInfo.systemUptime
        let old = lastDemand
        lastDemand = demand
        func due(_ key: String, every seconds: Double, force: Bool = false) -> Bool {
            guard force || now - (lastRead[key] ?? -.infinity) >= seconds else { return false }
            lastRead[key] = now
            return true
        }

        if due("battery", every: demand.batteryPanel || reading.battery?.charging == true ? 3 : .infinity,
               force: old == nil || powerChanged || old?.batteryPanel != demand.batteryPanel || old?.batteryDetail != demand.batteryDetail) {
            readBattery(demand)
        }
        if demand.batteryDetail, reading.battery != nil, due("health", every: 1800) {
            health = Self.readHealth()
            reading.battery?.health = health
        }
        if demand.metrics.contains(.cpu) {
            if old?.metrics.contains(.cpu) != true { previousCPU = nil }
            if due("cpu", every: 0.85, force: previousCPU == nil) { readCPU(showCores: demand.cores) }
        } else { previousCPU = nil; reading.cpu = nil; reading.cores = [] }
        if demand.metrics.contains(.memory), due("memory", every: 2.8, force: old?.metrics.contains(.memory) != true) {
            reading.memory = readMemory()
        }
        if demand.metrics.contains(.disk), due("disk", every: 29, force: old?.metrics.contains(.disk) != true) {
            var disk = statfs()
            if statfs("/System/Volumes/Data", &disk) == 0 {
                let size = UInt64(disk.f_bsize)
                reading.disk = DiskReading(available: disk.f_bavail * size, total: disk.f_blocks * size)
            } else { reading.disk = nil }
        }
        if !demand.cores { reading.cores = [] }
        if !demand.metrics.contains(.memory) { reading.memory = nil }
        if !demand.metrics.contains(.disk) { reading.disk = nil }
        let sensors = demand.metrics.filter(\.isTemperature)
        if sensors.isEmpty {
            if !reading.temperatures.isEmpty || old?.metrics.contains(where: \.isTemperature) == true { thermal.close(); reading.temperatures = [:] }
        } else if due("temperature", every: 2.8, force: sensors != old?.metrics.filter(\.isTemperature)) {
            reading.temperatures = Dictionary(uniqueKeysWithValues: sensors.compactMap { sensor in
                thermal.temperature(sensor).map { (sensor, $0) }
            })
        }
        return reading
    }

    private func readBattery(_ demand: ResourceDemand) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            reading.battery = nil
            return
        }
        let internalBattery = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }.first { $0["Type"] as? String == "InternalBattery" }
        reading.hasBattery = internalBattery != nil
        guard let data = internalBattery else { reading.battery = nil; return }
        var battery = BatteryReading()
        battery.percent = (data["Current Capacity"] as? Int).flatMap { (0...100).contains($0) ? $0 : nil }
        battery.connected = data["Power Source State"] as? String == "AC Power"
        battery.charging = data["Is Charging"] as? Bool == true
        battery.full = data["Is Charged"] as? Bool == true || (battery.connected && !battery.charging && battery.percent == 100)
        battery.minutes = (data[battery.charging ? "Time to Full Charge" : "Time to Empty"] as? Int).flatMap {
            (0..<65535).contains($0) ? $0 : nil
        }
        if battery.charging || demand.batteryPanel {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func property(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                let raw = property("BatteryData") as? [String: Any]
                if let mw = raw?["BatteryPower"] as? NSNumber {
                    battery.watts = Double(mw.int64Value) / 1000
                } else if let mv = property("Voltage") as? NSNumber, let ma = property("InstantAmperage") as? NSNumber {
                    battery.watts = Double(mv.int64Value) * Double(ma.int64Value) / 1_000_000
                }
                if let w = battery.watts, !w.isFinite || abs(w) > 500 { battery.watts = nil }
                if demand.batteryDetail {
                    battery.currentCapacity = (raw?["AppleRawCurrentCapacity"] ?? property("AppleRawCurrentCapacity")) as? Int
                    battery.fullCapacity = (raw?["FullChargeCapacity"] ?? property("AppleRawMaxCapacity")) as? Int
                    battery.designCapacity = (raw?["DesignCapacity"] ?? property("DesignCapacity")) as? Int
                    battery.cycles = property("CycleCount") as? Int
                    battery.health = health
                }
            }
        }
        reading.battery = battery
    }

    /// macOS reports a calibrated health percentage independently of the instantaneous capacities.
    /// Only the expanded details request it. Cache it between detail requests.
    private static func readHealth() -> Int? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json", "-timeout", "5"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["SPPowerDataType"] as? [[String: Any]] else { return nil }
            for entry in entries {
                if let values = entry["sppower_battery_health_info"] as? [String: Any],
                   let text = values["sppower_battery_health_maximum_capacity"] as? String {
                    return Int(text.filter(\.isNumber))
                }
            }
        } catch {}
        return nil
    }

    private func readCPU(showCores: Bool) {
        var pointer: processor_info_array_t?, length: mach_msg_type_number_t = 0, count: natural_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &pointer, &length) == KERN_SUCCESS,
              let pointer else { previousCPU = nil; reading.cpu = nil; reading.cores = []; return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: pointer), vm_size_t(Int(length) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        guard Int(length) >= Int(count) * states else { previousCPU = nil; reading.cpu = nil; reading.cores = []; return }
        let ticks = (0..<Int(count)).map { core in
            (0..<states).map { UInt32(bitPattern: pointer[core * states + $0]) }
        }
        let old = previousCPU
        previousCPU = ticks
        guard let old, old.count == ticks.count else { reading.cpu = nil; reading.cores = []; return }
        var total: UInt64 = 0, busy: UInt64 = 0
        var cores: [CoreLoad] = []
        for (index, next) in ticks.enumerated() {
            let delta = zip(next, old[index]).map { UInt64($0 &- $1) }
            let all = delta.reduce(0,+), working = all - delta[Int(CPU_STATE_IDLE)]
            total += all
            busy += working
            if showCores {
                cores.append(CoreLoad(id: index, kind: coreKinds[index] ?? .unknown,
                                      usage: all == 0 ? 0 : Double(working) * 100 / Double(all)))
            }
        }
        reading.cpu = total == 0 ? nil : Double(busy) * 100 / Double(total)
        reading.cores = cores
    }

    private static func readCoreKinds() -> [Int: CoreLoad.Kind] {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return [:] }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [Int: CoreLoad.Kind] = [:]
        while case let node = IOIteratorNext(iterator), node != 0 {
            defer { IOObjectRelease(node) }
            let id = IORegistryEntryCreateCFProperty(node, "logical-cpu-id" as CFString, nil, 0)?.takeRetainedValue() as? Int
            let kind = IORegistryEntryCreateCFProperty(node, "cluster-type" as CFString, nil, 0)?.takeRetainedValue() as? Data
            if let id, let first = kind?.first { result[id] = first == 80 ? .performance : first == 69 ? .efficiency : .unknown }
        }
        return result
    }

    private func readMemory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        var level: Int32 = 0, levelSize = MemoryLayout<Int32>.size
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        let gotLevel = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
        let gotSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        return MemoryReading(used: min(total, UInt64(max(0, pages)) * UInt64(getpagesize())), total: total,
                             pressure: gotLevel ? Int(level) : nil, swap: gotSwap ? swap.xsu_used : nil)
    }
}
