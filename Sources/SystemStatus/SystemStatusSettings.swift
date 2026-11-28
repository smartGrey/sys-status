import Foundation

enum ResourceModule: String, CaseIterable, Codable, Identifiable {
    case battery, memory, disk, temperature, compute, audio
    var id: Self { self }
    var title: String {
        switch self {
        case .battery: "电池"
        case .memory: "内存"
        case .disk: "启动盘"
        case .temperature: "温度"
        case .compute: "算力"
        case .audio: "音频设备"
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
        case .cpuTemperature: "C温"
        case .gpuTemperature: "G温"
        case .batteryTemperature: "池温"
        }
    }
    var isTemperature: Bool { self == .cpuTemperature || self == .gpuTemperature || self == .batteryTemperature }
}

/// Display order includes the battery badge. Only text indicators have a palette and a metric to sample.
enum StatusIndicator: Hashable, RawRepresentable, Codable {
    case battery
    case metric(StatusMetric)

    init?(rawValue: String) {
        if rawValue == "battery" { self = .battery }
        else if let metric = StatusMetric(rawValue: rawValue) { self = .metric(metric) }
        else { return nil }
    }
    var rawValue: String {
        switch self {
        case .battery: "battery"
        case .metric(let metric): metric.rawValue
        }
    }
    var title: String {
        switch self {
        case .battery: "电池"
        case .metric(let metric): metric.title
        }
    }
}

struct SystemStatusSettings: Codable, Equatable {
    var version = 1
    var enabled = false
    var metrics: [StatusIndicator] = [.battery]
    // Optional keys keep existing version-one documents readable.
    var inactiveMetricOrder: [StatusIndicator]?
    var metricColors: [String: MetricColor]?
    var inactiveMetrics: [StatusIndicator] {
        var seen = Set(metrics)
        let all = [.battery] + StatusMetric.allCases.map(StatusIndicator.metric)
        return ((inactiveMetricOrder ?? []) + all).filter { seen.insert($0).inserted }
    }
    func canMoveIndicator(_ indicator: StatusIndicator) -> Bool {
        metrics.count != 1 || metrics.first != indicator
    }
    func color(for metric: StatusMetric) -> MetricColor {
        metricColors?[metric.rawValue] ?? .standard(for: metric)
    }
    var modules = ResourceModule.allCases
    var hidden: Set<ResourceModule> = []
    var width: Double = SystemPanelLayout.defaultWidth
    var height: Double = SystemPanelLayout.heightToFit(width: SystemPanelLayout.defaultWidth)
    static let minimum = CGSize(width: 292, height: 190)

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        metrics = try values.decode([StatusIndicator].self, forKey: .metrics)
        inactiveMetricOrder = try values.decodeIfPresent([StatusIndicator].self, forKey: .inactiveMetricOrder)
        // Older documents never listed the battery; it was always drawn first.
        if !metrics.contains(.battery), inactiveMetricOrder?.contains(.battery) != true {
            metrics.insert(.battery, at: 0)
        }
        metricColors = try values.decodeIfPresent([String: MetricColor].self, forKey: .metricColors)
        width = try values.decode(Double.self, forKey: .width)
        height = try values.decode(Double.self, forKey: .height)

        let order = try values.decode([String].self, forKey: .modules)
        let hiddenIDs = try values.decode([String].self, forKey: .hidden)
        // Before the compute card existed, CPU owned its position and visibility.
        let inheritCPU = order.contains("cpu") && !order.contains(ResourceModule.compute.rawValue)
        func cards(_ ids: [String], for key: CodingKeys) throws -> [ResourceModule] {
            try ids.compactMap { id in
                if id == "cpu" { return inheritCPU ? .compute : nil }
                guard let card = ResourceModule(rawValue: id) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                           debugDescription: "Unknown resource card: \(id)")
                }
                return card
            }
        }
        modules = try cards(order, for: .modules)
        hidden = Set(try cards(hiddenIDs, for: .hidden))
    }

    mutating func normalize() {
        var seenMetrics: Set<StatusIndicator> = []
        metrics = metrics.filter { seenMetrics.insert($0).inserted }
        if metrics.isEmpty { metrics = [.battery] }
        if inactiveMetricOrder != nil || !metrics.contains(.battery) { inactiveMetricOrder = inactiveMetrics }
        var seenModules: Set<ResourceModule> = []
        modules = (modules + ResourceModule.allCases).filter { seenModules.insert($0).inserted }
        width = max(Self.minimum.width, width)
        height = max(Self.minimum.height, height)
    }
}

enum BatteryPowerMode: Int, Sendable {
    case automatic = 0
    case low = 1
    case high = 2

    static func fromLiveSettings(_ output: String) -> Self? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "powermode", fields.count == 2, let value = Int(fields[1]) {
                return Self(rawValue: value)
            }
        }
        return nil
    }
}

struct BatteryReading: Equatable, Sendable {
    var percent: Int?
    var connected = false
    var charging = false
    var full = false
    var minutes: Int?
    var watts: Double?
    var adapterWatts: Int?
    var powerMode = BatteryPowerMode.automatic
    var lowPower: Bool { powerMode == .low }
    var currentCapacity: Int?
    var fullCapacity: Int?
    var designCapacity: Int?
    var cycles: Int?
    var health: Int?
    // The charger can report "charging" while the battery is supplementing a weak adapter.
    var isDischargingOnAdapter: Bool { connected && !full && (watts ?? 0) <= -0.5 }
    var isActivelyCharging: Bool { connected && charging && !full && !isDischargingOnAdapter }

    var statusBarWatts: Int? {
        guard let watts, abs(watts) >= 0.5 else { return nil }
        guard isDischargingOnAdapter || (isActivelyCharging && watts > 0) else { return nil }
        return Int(watts.rounded())
    }

    var source: String {
        guard connected else { return "电池供电" }
        if full { return "已充满" }
        if isDischargingOnAdapter { return "已接电 · 电池放电" }
        return isActivelyCharging ? "正在充电" : "已接电 · 未充电"
    }
    var timeLabel: String {
        guard isActivelyCharging || !connected else { return full ? "已充满" : "未在充电" }
        guard let minutes, minutes >= 0 else { return "估算中" }
        return String(format: "%d 小时 %02d 分", minutes/60, minutes%60)
    }
}
struct CoreLoad: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case performance = "性能核", efficiency = "能效核", unknown = "核心" }
    let id: Int
    let kind: Kind
    let usage: Double?
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
    var computePhase = 0
    var gpuCores: Int?
    var gpuUsage: Double?
    var neuralCores: Int?
    var neuralActivity: Double?
    var memory: MemoryReading?
    var disk: DiskReading?
    var fans: [Int?] = []
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
    var batteryInStatusBar: Bool
    var needsBattery: Bool
    var batteryDetail: Bool
    var batteryPanel: Bool
    var thermalPanel: Bool
    var audioPanel: Bool
    var cores: Bool
    init(_ settings: SystemStatusSettings, panelVisible: Bool, details: Bool) {
        metrics = settings.enabled ? Set(settings.metrics.compactMap {
            if case .metric(let metric) = $0 { return metric }
            return nil
        }) : []
        let visible = settings.enabled && panelVisible ? Set(settings.modules).subtracting(settings.hidden) : []
        thermalPanel = visible.contains(.temperature)
        audioPanel = visible.contains(.audio)
        cores = visible.contains(.compute)
        batteryPanel = visible.contains(.battery)
        batteryInStatusBar = settings.enabled && settings.metrics.contains(.battery)
        needsBattery = batteryPanel || batteryInStatusBar
        batteryDetail = batteryPanel && details
        if cores { metrics.insert(.cpu) }
        if visible.contains(.memory) { metrics.insert(.memory) }
        if visible.contains(.disk) { metrics.insert(.disk) }
        if visible.contains(.temperature) { metrics.formUnion([.cpuTemperature, .gpuTemperature, .batteryTemperature]) }
    }
    func interval(charging: Bool) -> TimeInterval? {
        if metrics.contains(.cpu) { return 1 }
        if metrics.contains(.memory) || metrics.contains(where: \.isTemperature) || batteryPanel || (needsBattery && charging) { return 3 }
        return metrics.contains(.disk) ? 30 : nil
    }
}
