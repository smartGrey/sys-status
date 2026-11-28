import Foundation

enum ResourceModule: String, CaseIterable, Codable, Identifiable {
    case battery, cpu, memory, disk, temperature
    var id: Self { self }
    var title: String {
        switch self {
        case .battery: "电池"
        case .cpu: "CPU"
        case .memory: "内存"
        case .disk: "启动盘"
        case .temperature: "温度"
        }
    }
}

enum StatusMetric: String, CaseIterable, Codable, Identifiable {
    case cpu, memory, disk, cpuTemperature, gpuTemperature, batteryTemperature
    var id: Self { self }
    var title: String {
        switch self {
        case .cpu: "CPU 占用率"
        case .memory: "内存用量"
        case .disk: "启动盘可用空间"
        case .cpuTemperature: "CPU 温度"
        case .gpuTemperature: "GPU 温度"
        case .batteryTemperature: "电池温度"
        }
    }
    var abbreviation: String {
        switch self {
        case .cpu: "C"
        case .memory: "M"
        case .disk: "D"
        case .cpuTemperature: "CPU温"
        case .gpuTemperature: "GPU温"
        case .batteryTemperature: "电池温"
        }
    }
    var isTemperature: Bool { self == .cpuTemperature || self == .gpuTemperature || self == .batteryTemperature }
}

struct SystemStatusSettings: Codable, Equatable {
    var version = 1
    var enabled = false
    var metrics: [StatusMetric] = []
    var modules = ResourceModule.allCases
    var hidden: Set<ResourceModule> = []
    var width: Double = 580
    var height: Double = 380
    static let minimum = CGSize(width: 292, height: 190)

    mutating func normalize() {
        var seenMetrics: Set<StatusMetric> = []
        metrics = metrics.filter { seenMetrics.insert($0).inserted }
        var seenModules: Set<ResourceModule> = []
        modules = (modules + ResourceModule.allCases).filter { seenModules.insert($0).inserted }
        width = max(Self.minimum.width, width)
        height = max(Self.minimum.height, height)
    }
}

struct BatteryReading: Equatable, Sendable {
    var percent: Int?
    var connected = false
    var charging = false
    var full = false
    var minutes: Int?
    var watts: Double?
    var currentCapacity: Int?
    var fullCapacity: Int?
    var designCapacity: Int?
    var cycles: Int?
    var health: Int?
    var source: String { connected ? (charging ? "正在充电" : full ? "已充满" : "已接电 · 未充电") : "电池供电" }
    var timeLabel: String {
        guard charging || !connected else { return full ? "已充满" : "未在充电" }
        guard let minutes, minutes >= 0 else { return "估算中" }
        return String(format: "%d 小时 %02d 分", minutes/60, minutes%60)
    }
}
struct CoreLoad: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case performance = "性能核", efficiency = "能效核", unknown = "核心" }
    let id: Int
    let kind: Kind
    let usage: Double
}
struct MemoryReading: Equatable, Sendable {
    var used: UInt64
    var total: UInt64
    var pressure: Int?
    var swap: UInt64?
    var pressureText: String {
        switch pressure { case 1: "正常"; case 2: "较高"; case 4: "紧张"; default: "—" }
    }
}
struct DiskReading: Equatable, Sendable {
    var available: UInt64
    var total: UInt64
}
struct SystemReading: Equatable, Sendable {
    var hasBattery: Bool?
    var battery: BatteryReading?
    var cpu: Double?
    var cores: [CoreLoad] = []
    var memory: MemoryReading?
    var disk: DiskReading?
    var temperatures: [StatusMetric: Double] = [:]

    func statusValue(_ metric: StatusMetric) -> String {
        switch metric {
        case .cpu: return cpu.map { "\(Int($0.rounded()))%" } ?? "—"
        case .memory: return memory.flatMap { $0.total > 0 ? "\(Int((100 * Double($0.used) / Double($0.total)).rounded()))%" : nil } ?? "—"
        case .disk: return disk.map { String(format: "%.0fG", Double($0.available)/1e9) } ?? "—"
        default: return temperatures[metric].map { "\(Int($0.rounded()))°" } ?? "—"
        }
    }
}

struct ResourceDemand: Equatable, Sendable {
    var metrics: Set<StatusMetric>
    var batteryDetail: Bool
    var batteryPanel: Bool
    var cores: Bool
    init(_ settings: SystemStatusSettings, panelVisible: Bool, details: Bool) {
        metrics = settings.enabled ? Set(settings.metrics) : []
        let visible = settings.enabled && panelVisible ? Set(settings.modules).subtracting(settings.hidden) : []
        cores = visible.contains(.cpu)
        batteryPanel = visible.contains(.battery)
        batteryDetail = batteryPanel && details
        if cores { metrics.insert(.cpu) }
        if visible.contains(.memory) { metrics.insert(.memory) }
        if visible.contains(.disk) { metrics.insert(.disk) }
        if visible.contains(.temperature) { metrics.formUnion([.cpuTemperature, .gpuTemperature, .batteryTemperature]) }
    }
    func interval(charging: Bool) -> TimeInterval? {
        if metrics.contains(.cpu) { return 1 }
        if metrics.contains(.memory) || metrics.contains(where: \.isTemperature) || batteryPanel || charging { return 3 }
        return metrics.contains(.disk) ? 30 : nil
    }
}
