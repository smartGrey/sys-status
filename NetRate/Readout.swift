import Foundation

struct RateText: Equatable {
    let value: String
    let unit: String

    init(_ rate: Double?) {
        guard let rate, rate.isFinite, rate >= 0 else {
            value = "—"
            unit = ""
            return
        }
        let units = ["B","K","M","G"]
        var index = 0
        var scaled = rate
        while scaled.rounded() >= 1000 && index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        let tenths = index >= 2 && scaled < 10
        let rounded = tenths ? (scaled * 10).rounded() / 10 : scaled.rounded()
        value = rounded >= 1000 ? "999" : String(format: rounded == rounded.rounded() ? "%.0f" : "%.1f",
                                                locale: Locale(identifier: "en_US_POSIX"), rounded)
        unit = units[index]
    }

    var spoken: String {
        guard !unit.isEmpty else { return "等待采样" }
        return "每秒 " + value + " " + unit + (unit == "B" ? "" : "B")
    }
}
