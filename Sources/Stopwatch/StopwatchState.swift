import Foundation

enum StopwatchMode: String, Codable {
    case exclusive, parallel
}

enum StopwatchAction: UInt32, CaseIterable {
    case switchFocus = 1
    case toggle

    var title: String { self == .switchFocus ? "切换" : "启停" }
}

struct StopwatchShortcuts: Codable, Equatable {
    private var switchFocus: ShortcutBinding?
    private var toggle: ShortcutBinding?

    subscript(_ action: StopwatchAction) -> ShortcutBinding? {
        get { action == .switchFocus ? switchFocus : toggle }
        set {
            switch action {
            case .switchFocus: switchFocus = newValue
            case .toggle: toggle = newValue
            }
        }
    }
}

struct StopwatchEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var elapsed: TimeInterval

    init(name: String) {
        id = UUID()
        self.name = name
        elapsed = 0
    }
}

struct StopwatchSettings: Codable, Equatable {
    let version: Int
    var enabled = false
    var entries: [StopwatchEntry]
    var focus: UUID
    var mode: StopwatchMode = .exclusive
    var shortcuts = StopwatchShortcuts()

    init() {
        let first = StopwatchEntry(name: "秒表1")
        version = 1
        entries = [first]
        focus = first.id
    }

    var isValid: Bool {
        let ids = Set(entries.map(\.id))
        let keys = StopwatchAction.allCases.compactMap { shortcuts[$0] }
        return version == 1 && (1...StopwatchState.maximumCount).contains(entries.count)
            && ids.count == entries.count && ids.contains(focus)
            && entries.allSatisfy {
                $0.name == StopwatchState.cleanedName($0.name)
                    && $0.elapsed.isFinite && $0.elapsed >= 0
            }
            && keys.allSatisfy(\.isValidForStopwatch) && Set(keys).count == keys.count
    }
}

struct StopwatchReading: Equatable, Identifiable {
    let id: UUID
    let name: String
    let seconds: Int
    let isRunning: Bool
    let canReset: Bool

    var time: StopwatchTime { StopwatchTime(seconds: seconds) }
}

struct StopwatchTime {
    let seconds: Int

    var full: String {
        "\(Self.pair(seconds / 3600)):\(Self.pair(seconds / 60 % 60)):\(Self.pair(seconds % 60))"
    }

    var total: String { "\(seconds)s" }

    var compact: String {
        if seconds < 60 { return total }
        if seconds < 3600 { return "\(seconds / 60)m\(Self.pair(seconds % 60))s" }
        return "\(seconds / 3600)h\(Self.pair(seconds / 60 % 60))m"
    }

    private static func pair(_ number: Int) -> String { number < 10 ? "0\(number)" : String(number) }
}

struct StopwatchPresentation: Equatable {
    let readings: [StopwatchReading]
    let focus: UUID
    let mode: StopwatchMode
    let modeHint: String?
    let shortcuts: StopwatchShortcuts
}

struct StopwatchState: Equatable {
    static let maximumCount = 3
    static let nameLimit = 5

    private(set) var settings: StopwatchSettings
    private var started: [UUID: TimeInterval] = [:]
    private var requestedExclusive = false

    init(settings: StopwatchSettings = StopwatchSettings()) {
        self.settings = settings
    }

    var hasRunningEntries: Bool { !started.isEmpty }

    func needsSave(comparedTo previous: Self) -> Bool {
        settings != previous.settings || started != previous.started
    }

    private var modeHint: String? {
        guard requestedExclusive, started.count > 1 else { return nil }
        return "请先暂停 \(started.count - 1) 个秒表"
    }

    func presentation(at now: TimeInterval) -> StopwatchPresentation {
        let readings = settings.entries.map { entry in
            let duration = elapsed(entry, at: now)
            let isRunning = started[entry.id] != nil
            return StopwatchReading(id: entry.id, name: entry.name,
                                    seconds: Int(exactly: duration.rounded(.down)) ?? Int.max,
                                    isRunning: isRunning, canReset: isRunning || duration > 0)
        }
        return StopwatchPresentation(readings: readings, focus: settings.focus, mode: settings.mode,
                                     modeHint: modeHint, shortcuts: settings.shortcuts)
    }

    func snapshot(at now: TimeInterval) -> StopwatchSettings {
        var copy = settings
        for index in copy.entries.indices {
            copy.entries[index].elapsed = elapsed(settings.entries[index], at: now)
        }
        return copy
    }

    mutating func setEnabled(_ enabled: Bool, at now: TimeInterval) {
        guard settings.enabled != enabled else { return }
        if !enabled { pauseAll(at: now) }
        settings.enabled = enabled
    }

    mutating func setShortcut(_ shortcut: ShortcutBinding?, for action: StopwatchAction) {
        settings.shortcuts[action] = shortcut
    }

    mutating func select(_ id: UUID) {
        guard settings.entries.contains(where: { $0.id == id }) else { return }
        settings.focus = id
    }

    mutating func add() -> UUID? {
        guard settings.entries.count < Self.maximumCount else { return nil }
        let number = (1...Self.maximumCount).first { candidate in
            !settings.entries.contains(where: { $0.name == "秒表\(candidate)" })
        } ?? settings.entries.count + 1
        let entry = StopwatchEntry(name: "秒表\(number)")
        settings.entries.append(entry)
        settings.focus = entry.id
        return entry.id
    }

    mutating func rename(_ id: UUID, to proposed: String) {
        let name = Self.cleanedName(proposed)
        guard let index = index(of: id) else { return }
        settings.entries[index].name = name
    }

    static func cleanedName(_ name: String) -> String {
        let inline = name.components(separatedBy: .newlines).joined(separator: " ")
        return String(inline.trimmingCharacters(in: .whitespaces).prefix(nameLimit))
            .trimmingCharacters(in: .whitespaces)
    }

    mutating func remove(_ id: UUID) {
        guard settings.entries.count > 1, let index = index(of: id) else { return }
        started.removeValue(forKey: id)
        settings.entries.remove(at: index)
        if settings.focus == id {
            settings.focus = settings.entries[min(index, settings.entries.count - 1)].id
        }
        clearModeHintIfReady()
    }

    mutating func reset(_ id: UUID) {
        guard let index = index(of: id) else { return }
        started.removeValue(forKey: id)
        settings.entries[index].elapsed = 0
        clearModeHintIfReady()
    }

    mutating func setMode(_ mode: StopwatchMode) {
        requestedExclusive = mode == .exclusive && started.count > 1
        if !requestedExclusive { settings.mode = mode }
    }

    mutating func toggle(_ id: UUID, at now: TimeInterval) {
        guard settings.enabled, let index = index(of: id) else { return }
        settings.focus = id
        if started[id] != nil {
            pause(index, at: now)
            clearModeHintIfReady()
        } else {
            if settings.mode == .exclusive { pauseAll(at: now) }
            started[id] = now
        }
    }

    mutating func advance(at now: TimeInterval) {
        guard settings.enabled, settings.entries.count > 1 else { return }
        let handoff = settings.mode == .exclusive && hasRunningEntries
        let current = handoff ? (started.keys.first ?? settings.focus) : settings.focus
        guard let index = index(of: current) else { return }
        let next = settings.entries[(index + 1) % settings.entries.count].id
        if handoff { toggle(next, at: now) } else { select(next) }
    }

    mutating func pauseAll(at now: TimeInterval) {
        for index in settings.entries.indices { pause(index, at: now) }
        clearModeHintIfReady()
    }

    private func index(of id: UUID) -> Int? { settings.entries.firstIndex { $0.id == id } }

    private func elapsed(_ entry: StopwatchEntry, at now: TimeInterval) -> TimeInterval {
        guard let start = started[entry.id] else { return entry.elapsed }
        return min(Double(Int.max), entry.elapsed + max(0, now - start))
    }

    private mutating func pause(_ index: Int, at now: TimeInterval) {
        let entry = settings.entries[index]
        guard started[entry.id] != nil else { return }
        settings.entries[index].elapsed = elapsed(entry, at: now)
        started.removeValue(forKey: entry.id)
    }

    private mutating func clearModeHintIfReady() {
        if started.count < 2 { requestedExclusive = false }
    }
}

struct StopwatchStore {
    let url: URL

    init(url: URL = AppDataFile.stopwatch.url()) {
        self.url = url
    }

    func load() throws -> StopwatchSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return StopwatchSettings()
        }
        let settings = try JSONDecoder().decode(StopwatchSettings.self, from: data)
        guard settings.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return settings
    }

    func save(_ settings: StopwatchSettings) throws {
        try AppDataFile.write(settings, to: url)
    }
}
