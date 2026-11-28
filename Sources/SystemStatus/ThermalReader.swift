import Foundation
import IOKit

/// Read-only SMC commands. Sensor identifiers and the controller ABI are hardware specific.
/// Cache key metadata per connection, and skip unknown formats and unsupported chips.
final class ThermalReader {
    private var connection: io_connect_t = 0
    private struct Key {
        let code: UInt32
        let size: UInt32
    }
    private var available: [StatusMetric: [Key]] = [:]
    private let chip = systemString("machdep.cpu.brand_string")

    func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        available.removeAll()
    }
    deinit { close() }

    func temperature(_ metric: StatusMetric) -> Double? {
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        }
        if available[metric] == nil {
            available[metric] = sensorNames(metric).compactMap { name in
                let code = Self.fourCC(name)
                guard let bytes = request(code, command: 9, size: 0) else { return nil }
                let length = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
                let type = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
                guard (length == 4 && type == Self.fourCC("flt ")) || (length == 2 && type == Self.fourCC("sp78")) else { return nil }
                return Key(code: code, size: length)
            }
        }
        let values: [Double] = (available[metric] ?? []).compactMap { key in
            guard let data = request(key.code, command: 5, size: key.size) else { return nil }
            let value: Double = data.withUnsafeBytes { buffer in
                if key.size == 4 { return Double(buffer.loadUnaligned(fromByteOffset: 48, as: Float.self)) }
                return Double(Int16(bigEndian: buffer.loadUnaligned(fromByteOffset: 48, as: Int16.self))) / 256
            }
            return value.isFinite && value > 0 && value < 130 ? value : nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
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
