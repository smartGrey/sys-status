import AppKit

enum SiteFormField: Hashable {
    case address, port, codes, personalName(ProbeLane, String), number(ProbeLane, String, Int)

    var lane: ProbeLane? {
        switch self {
        case .address, .port, .codes: nil
        case let .personalName(lane, _), let .number(lane, _, _): lane
        }
    }
}

struct SiteInputError: LocalizedError {
    let field: SiteFormField
    let cause: Error
    var errorDescription: String? { (field.lane.map { $0.title + "探测强度：" } ?? "") + cause.localizedDescription }
}

// Keep the original text, including incomplete numbers and URLs, while rows are folded or off screen.
struct StrengthInput: Equatable {
    let id: String
    var name: String
    var numbers: [String]

    init(_ strength: ProbeStrength) {
        id = strength.id
        name = strength.name
        let v = strength.values
        numbers = [v.interval, v.warning, v.cutoff, v.capacity].map(String.init)
    }

    func strength(for lane: ProbeLane) throws -> ProbeStrength {
        let numbers = try numbers.enumerated().map { column, text in
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else {
                throw SiteInputError(field: .number(lane, id, column), cause: SiteConfigurationError.invalidNumber)
            }
            return value
        }
        let values = StrengthValues(interval: numbers[0], warning: numbers[1], cutoff: numbers[2], capacity: numbers[3])
        do { try values.parameters().validate() }
        catch { throw SiteInputError(field: .number(lane, id, 2), cause: error) }
        return ProbeStrength(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), values: values)
    }
}

struct SiteForm: Equatable {
    var name: String
    var address: String
    var method: ProbeMethod
    var codes: String
    var port = ""
    var personal: [ProbeLane: [StrengthInput]]

    init(_ site: ProbeSite) {
        name = site.name
        switch site.endpoint {
        case let .https(url): address = url.absoluteString
        case let .tcp(host, number):
            address = host
            if number > 0 { port = String(number) }
        }
        method = site.method
        codes = site.isBuiltIn ? "204" : site.statusCodes.text
        personal = Dictionary(uniqueKeysWithValues: site.lanes.map { ($0, site[strength: $0].personal.map(StrengthInput.init)) })
    }
}

final class SiteDraft {
    private(set) var source: ProbeSite
    private var savedForm: SiteForm
    var form: SiteForm
    var expanded = false
    var openLanes = Set<ProbeLane>()
    var id: String { source.id }
    var isDirty: Bool { form != savedForm }

    init(_ site: ProbeSite) {
        source = site
        form = SiteForm(site)
        savedForm = form
    }

    func markCommitted(_ site: ProbeSite) {
        source = site
        if let url = site.endpoint.httpsURL { form.address = url.absoluteString }
        savedForm = form
    }

    static func new(type: ProbeSiteType = .https) -> SiteDraft {
        let endpoint: ProbeEndpoint = type == .https ? .https(URL(string: "about:blank")!) : .tcp(host: "", port: 0)
        var site = ProbeSite(id: UUID().uuidString, name: "", endpoint: endpoint, enabled: false)
        site[strength: .daily] = LaneStrength(enabled: false, selectedID: "balanced")
        site[strength: .fresh] = LaneStrength(selectedID: "balanced")
        let draft = SiteDraft(site)
        draft.form.address = ""
        return draft
    }

    // Menu writes own the live selection. A draft owns only the endpoint, ordering and personal library.
    @discardableResult
    func sync(_ live: ProbeSite) -> Bool {
        source = live
        var restored = false
        for lane in live.lanes {
            let selection = live[strength: lane]
            if protectsSelection(lane),
               let selected = selection.personal.first(where: { $0.id == selection.selectedID }),
               form.personal[lane]?.contains(where: { $0.id == selected.id }) != true {
                form.personal[lane, default: []].append(StrengthInput(selected))
                restored = true
            }
        }
        return restored
    }

    func build() throws -> ProbeSite {
        var site = source
        if site.endpoint.type == .tcp {
            let host: String
            do { host = try ProbeEndpoint.tcpHost(form.address) }
            catch { throw SiteInputError(field: .address, cause: error) }
            let number = form.port.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = UInt16(number), port > 0 else {
                throw SiteInputError(field: .port, cause: SiteConfigurationError.invalidPort)
            }
            site.endpoint = .tcp(host: host, port: port)
            let label = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
            site.name = label.isEmpty ? host : label
        } else if !site.isBuiltIn {
            let codes: StatusCodes
            do { codes = try StatusCodes(form.codes) }
            catch { throw SiteInputError(field: .codes, cause: error) }
            let endpoint: ProbeSite
            do {
                endpoint = try ProbeSite.custom(id: id, name: form.name, address: form.address, enabled: site.enabled, statusCodes: codes)
            } catch { throw SiteInputError(field: .address, cause: error) }
            site.name = endpoint.name
            site.endpoint = endpoint.endpoint
            site.method = form.method
            site.statusCodes = endpoint.statusCodes
        }
        for lane in site.lanes {
            site[strength: lane].personal = try (form.personal[lane] ?? []).map { try $0.strength(for: lane) }
            site[strength: lane].selectedID = selectedID(lane)
            do { try site[strength: lane].validate(for: lane) }
            catch let issue as InvalidStrengthIdentity {
                throw SiteInputError(field: .personalName(lane, issue.id), cause: issue)
            }
        }
        try site.validate()
        return site
    }

    func selectedID(_ lane: ProbeLane) -> String {
        let selection = source[strength: lane]
        // The file still requires a valid selection when a probe is stopped.
        if !protectsSelection(lane), selection.personal.contains(where: { $0.id == selection.selectedID }),
           form.personal[lane]?.contains(where: { $0.id == selection.selectedID }) != true {
            return "balanced"
        }
        return selection.selectedID
    }

    private func protectsSelection(_ lane: ProbeLane) -> Bool {
        source.endpoint.type == .tcp ? source.enabled : source[strength: lane].enabled
    }

    func canRemoveStrength(_ id: String, lane: ProbeLane) -> Bool {
        !protectsSelection(lane) || source[strength: lane].selectedID != id
    }

    func selected(_ lane: ProbeLane) -> ProbeStrength? {
        let id = selectedID(lane)
        if let builtIn = lane.strengths.first(where: { $0.id == id }) { return builtIn }
        return try? form.personal[lane]?.first { $0.id == id }?.strength(for: lane)
    }

    var title: String {
        if !form.name.isEmpty { return form.name }
        if source.endpoint.type == .tcp, !form.address.isEmpty { return form.address }
        return (try? ProbeEndpoint.parseHTTPS(form.address))?.host ?? "新增站点"
    }
}
