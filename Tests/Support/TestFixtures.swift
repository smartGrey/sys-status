import AppKit
import XCTest

extension XCTestCase {
    @MainActor
    func waitUntil(timeout: Duration = .seconds(2), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func addSite(_ type: String, in root: NSView) throws {
        let popup = try XCTUnwrap(view(root) { (p: NSPopUpButton) in p.title == "新增站点" })
        let menu = try XCTUnwrap(popup.menu)
        let item = try XCTUnwrap(menu.item(withTitle: type))
        menu.performActionForItem(at: menu.index(of: item))
    }

    @MainActor
    func view<T: NSView>(_ root: NSView, matching predicate: (T) -> Bool) -> T? {
        if let match = root as? T, predicate(match) { return match }
        for child in root.subviews {
            if let match = view(child, matching: predicate) { return match }
        }
        return nil
    }

    func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "NetRateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

extension XCTestCase {
    func isolatedDefaults() throws -> UserDefaults {
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        return defaults
    }
}
