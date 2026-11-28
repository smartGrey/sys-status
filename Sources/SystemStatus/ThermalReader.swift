import Foundation
import IOKit

/// Read-only SMC commands. Sensor identifiers and the controller ABI are hardware specific.
/// Cache key metadata per connection, and skip unknown formats and unsupported chips.
final class ThermalReader {
    private var connection: io_connect_t = 0
    private struct Key {
        let code: UInt32
        let size: UInt32
        let type: UInt32
    }
    private var available: [StatusMetric: [Key]] = [:]
    private var fanKeys: [Key?]?
    private let chip = systemString("machdep.cpu.brand_string")

    func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        available.removeAll()
        fanKeys = nil
    }
    deinit { close() }

    private func connect() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    private func key(_ name: String) -> Key? {
        let code = Self.fourCC(name)
        guard let bytes = request(code, command: 9, size: 0) else { return nil }
        return bytes.withUnsafeBytes {
            Key(code: code, size: $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self),
                type: $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self))
        }
    }

    private func value(_ key: Key) -> Double? {
        guard (1...4).contains(key.size), let data = request(key.code, command: 5, size: key.size) else { return nil }
        return data.withUnsafeBytes { buffer in
            switch (key.type, key.size) {
            case (Self.fourCC("flt "), 4): return Double(buffer.loadUnaligned(fromByteOffset: 48, as: Float.self))
            case (Self.fourCC("sp78"), 2): return Double(Int16(bigEndian: buffer.loadUnaligned(fromByteOffset: 48, as: Int16.self))) / 256
            case (Self.fourCC("fpe2"), 2): return Double(UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: 48, as: UInt16.self))) / 4
            case (Self.fourCC("ui8 "), 1): return Double(buffer[48])
            default: return nil
            }
        }
    }

    func temperature(_ metric: StatusMetric) -> Double? {
        guard connect() else { return nil }
        if available[metric] == nil { available[metric] = sensorNames(metric).compactMap(key) }
        let values = (available[metric] ?? []).compactMap(value).filter { $0 > 0 && $0 < 130 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func fanSpeeds() -> [Int?] {
        guard connect() else { return [] }
        if fanKeys == nil {
            guard let count = key("FNum").flatMap(value), (0...10).contains(count) else { return [] }
            fanKeys = (0..<Int(count)).map { key("F\($0)Ac") }
        }
        return (fanKeys ?? []).map { sensor in
            guard let speed = sensor.flatMap(value), (0...30000).contains(speed) else { return nil }
            return Int(speed.rounded())
        }
    }

    private func sensorNames(_ metric: StatusMetric) -> [String] {
        if metric == .batteryTemperature { return ["TB0T", "TB1T", "TB2T"] }
        // M1–M4 families use different keys even where the enclosure is the same.
        let cpu: String, gpu: String
        if chip.hasPrefix("Apple M1") {
            cpu = "Tp09 Tp0T Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b"
            gpu = "Tg05 Tg0D Tg0L Tg0T"
        } else if chip.hasPrefix("Apple M2") {
            cpu = "Tp1h Tp1t Tp1p Tp1l Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j"
            gpu = "Tg0f Tg0j"
        } else if chip.hasPrefix("Apple M3") {
            cpu = "Te05 Te0L Te0P Te0S Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E"
            gpu = "Tf14 Tf18 Tf19 Tf1A Tf24 Tf28 Tf29 Tf2A"
        } else if chip.hasPrefix("Apple M4") {
            cpu = "Te05 Te0S Te09 Te0H Tp01 Tp05 Tp09 Tp0D Tp0V Tp0Y Tp0b Tp0e"
            gpu = "Tg0K Tg0L Tg0d Tg0e Tg0j Tg0k " + (chip == "Apple M4" ? "Tg0G Tg0H" : "Tg1U Tg1k")
        } else { return [] }
        return (metric == .cpuTemperature ? cpu : gpu).split(separator: " ").map(String.init)
    }
    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private func request(_ code: UInt32, command: UInt8, size: UInt32) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: code, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
        }
        input[42] = command
        var output = [UInt8](repeating: 0, count: 80)
        var length = output.count
        let result = IOConnectCallStructMethod(connection, 2, input, input.count, &output, &length)
        guard result == KERN_SUCCESS, length == output.count, output[40] == 0 else { return nil }
        return output
    }
}

func systemString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
    return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
