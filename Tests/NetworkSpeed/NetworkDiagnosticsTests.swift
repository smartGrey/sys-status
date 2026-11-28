import AppKit
import XCTest
@testable import StatusBarCore

@MainActor
final class NetworkDiagnosticsTests: XCTestCase {
    func testWirelessBarsHaveHysteresisAndResetOnDisconnect() {
        func level(_ value: Int, _ previous: Int? = nil) -> Int? {
            WirelessLink(status: .connected, rssi: value, previousBars: previous).bars
        }
        XCTAssertEqual([-80, -71, -62, -48].map { level($0) }, [1, 2, 3, 4])
        XCTAssertEqual(level(-56, 4), 4)
        XCTAssertEqual(level(-58, 4), 3)
        XCTAssertEqual(level(-55, 3), 3)
        XCTAssertEqual(level(-53, 3), 4)
        XCTAssertEqual(level(-85, 4), 1)
        XCTAssertEqual(level(-48, 1), 4)
        XCTAssertNil(level(0))
        XCTAssertNil(WirelessLink(status: .disconnected, previousBars: 3).bars)
    }

    func testDirectionalOutputUsesDecimalBytesAndReadsErrorsEvenOnExitZero() {
        func decode(_ json: String, _ direction: BandwidthDirection = .download, exit: Int32 = 0) -> BandwidthOutcome {
            BandwidthOutcome.decode(Data(json.utf8), exitCode: exit, direction: direction)
        }
        XCTAssertEqual(decode(#"{"dl_throughput":1000000000}"#), .measured(125))
        XCTAssertEqual(decode(#"{"ul_throughput":80000000}"#, .upload), .measured(10))
        XCTAssertEqual(decode(#"{"ul_throughput":80000000}"#), .failed(.noMeasurement))
        XCTAssertEqual(decode(#"{"dl_throughput":0}"#), .failed(.noMeasurement))
        XCTAssertEqual(decode(#"{"dl_throughput":10}"#, exit: 1), .failed(.tool(domain: nil, code: 1)))
        XCTAssertEqual(decode(#"{"error_domain":"NetworkQualityErrorDomain","error_code":1003,"status_code":413}"#),
                       .failed(.http(413)))
        XCTAssertEqual(decode(#"{"error_domain":"NSURLErrorDomain","error_code":-1009}"#), .failed(.offline))
    }

    func testPublishesDownloadBeforeUploadAndKeepsItOnHTTPFailure() async throws {
        var directions: [BandwidthDirection] = []
        var children: [Process] = []
        let test = BandwidthTest { direction in
            if let old = children.last { XCTAssertFalse(old.isRunning) }
            directions.append(direction)
            let process = direction == .download
                ? self.output(#"{"dl_throughput":16000000}"#)
                : self.output(#"{"error_code":1003,"status_code":413}"#)
            children.append(process)
            return process
        }
        var states: [BandwidthTest.State] = []
        var busy: [Bool] = []
        test.changed = { [weak test] in
            guard let test else { return }
            states.append(test.state)
            busy.append(test.busy)
        }
        test.start()
        test.start()
        try await waitUntil { !test.busy }
        XCTAssertEqual(directions, [.download, .upload])
        XCTAssertEqual(busy, [true, true, false])
        XCTAssertEqual(states.dropLast(), [.running(.download, download: nil), .running(.upload, download: .measured(2))])
        let reading = try result(test)
        XCTAssertEqual(reading.download, .measured(2))
        XCTAssertEqual(reading.upload, .failed(.http(413)))
        XCTAssertTrue(reading.hasFailures)
    }

    func testConfirmedOfflineSkipsUpload() async throws {
        var directions: [BandwidthDirection] = []
        let test = BandwidthTest { direction in
            directions.append(direction)
            return self.output(#"{"error_domain":"NSURLErrorDomain","error_code":-1009}"#)
        }
        test.start()
        try await waitUntil { !test.busy }
        XCTAssertEqual(directions, [.download])
        let reading = try result(test)
        XCTAssertEqual(reading.download, .failed(.offline))
        XCTAssertEqual(reading.upload, .skipped)
    }

    func testTimeoutReapsDownloadBeforeMeasuringUpload() async throws {
        let stalled = sleepProcess()
        let test = BandwidthTest(phaseTimeout: .milliseconds(200)) { direction in
            if direction == .download { return stalled }
            XCTAssertFalse(stalled.isRunning)
            return self.output(#"{"ul_throughput":8000000}"#)
        }
        test.start()
        try await waitUntil(timeout: .seconds(5)) { !test.busy }
        let reading = try result(test)
        XCTAssertEqual(reading.download, .failed(.timedOut))
        XCTAssertEqual(reading.upload, .measured(1))
    }

    func testCancellationAndNetworkChangeDiscardResultsAndAllowRestart() async throws {
        var directions: [BandwidthDirection] = []
        let first = sleepProcess()
        let secondUpload = sleepProcess()
        let test = BandwidthTest { direction in
            directions.append(direction)
            switch directions.count {
            case 1: return first
            case 3: return secondUpload
            default: return self.output(#"{"dl_throughput":16000000,"ul_throughput":8000000}"#)
            }
        }
        test.start()
        test.cancel()
        XCTAssertEqual(test.state, .cancelling)
        XCTAssertTrue(test.busy)
        test.start()
        try await waitUntil(timeout: .seconds(4)) { !test.busy }
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(test.state, .idle)
        XCTAssertEqual(directions, [.download])

        test.start()
        try await waitUntil { test.state == .running(.upload, download: .measured(2)) }
        let panel = NetworkPanel(bandwidth: test)
        panel.networkChanged()
        XCTAssertEqual(test.state, .cancelling)
        XCTAssertTrue(test.busy)
        try await waitUntil(timeout: .seconds(4)) { !test.busy }
        XCTAssertFalse(secondUpload.isRunning)
        XCTAssertEqual(test.state, .idle)

        test.start()
        try await waitUntil { !test.busy }
        let reading = try result(test)
        XCTAssertEqual(reading.download, .measured(2))
        XCTAssertEqual(reading.upload, .measured(1))
        panel.networkChanged()
        XCTAssertEqual(test.state, .idle)
    }

    func testFailedLaunchLeavesProbesAvailable() throws {
        let test = BandwidthTest { _ in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/no-such-network-tool")
            return p
        }
        test.start()
        XCTAssertFalse(test.busy)
        let reading = try result(test)
        XCTAssertEqual(reading.download, .failed(.unavailable))
        XCTAssertEqual(reading.upload, .failed(.unavailable))
    }

    private func result(_ test: BandwidthTest) throws -> BandwidthResult {
        let reading: BandwidthResult? = if case .complete(let result) = test.state { result } else { nil }
        return try XCTUnwrap(reading, "Missing completed result: \(test.state)")
    }

    private func output(_ json: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/echo")
        p.arguments = [json]
        return p
    }

    private func sleepProcess() -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        return p
    }

    func testBandwidthButtonKeepsPreviewOpenAndResultSurvivesClosing() async throws {
        let test = BandwidthTest { _ in
            self.output(#"{"dl_throughput":80000000,"ul_throughput":20000000}"#)
        }
        let model = NetworkPanel(bandwidth: test)
        let entry = StatusEntry()
        let shell = StatusPanelShell(item: entry.item, content: model.panelContent)
        model.keepOpen = { shell.keepPreviewOpen() }
        defer { shell.stop(); entry.removeForExit() }
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = CGRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 44, height: 20)
        shell.start()
        shell.show(under: anchor, within: screen.visibleFrame)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "网络状况" && $0.isVisible })
        let root = try XCTUnwrap(panel.contentView)
        let button = try XCTUnwrap(view(root) { (b: NSButton) in b.title == "公网测速" })
        XCTAssertTrue(shell.previewing)
        button.performClick(nil)
        XCTAssertTrue(shell.opened)
        shell.hide()
        try await waitUntil { !test.busy }
        shell.show(under: anchor, within: screen.visibleFrame)
        let rates = try XCTUnwrap(view(root) { (f: NSTextField) in f.stringValue.contains("10 MB/s") })
        XCTAssertTrue(rates.stringValue.contains("2.5 MB/s"))
        model.networkChanged()
        XCTAssertEqual(test.state, .idle)
    }

    func testPartialResultShowsHTTPStatusAndRetry() {
        let card = HoverCard()
        let result = BandwidthResult(download: .measured(10), upload: .failed(.http(413)), date: Date())
        card.showDiagnostics(.init(), .complete(result))
        _ = card.update(ConnectivityState(), availableHeight: 300)
        XCTAssertNotNil(view(card) { (b: NSButton) in b.title == "重试测速" })
        let rates = view(card) { (f: NSTextField) in f.stringValue.contains("HTTP 413") }
        XCTAssertTrue(rates?.stringValue.contains("10 MB/s") == true)
    }

    func testCompactHeaderKeepsBothUnitsAndOnlyScrollsWhenNeeded() throws {
        let card = HoverCard()
        let wireless = WirelessLink(status: .connected, rssi: -70, transmitMbps: 960)
        let result = BandwidthResult(download: .measured(46.7), upload: .measured(8.2), date: Date())
        card.showDiagnostics(wireless, .complete(result))
        let summary = try XCTUnwrap(view(card) { (_: NetworkSummary) in true })
        for (width, overflows) in [(540.0, false), (320.0, true)] {
            card.frame.size = card.update(.init(), availableHeight: 300, availableWidth: width)
            card.layoutSubtreeIfNeeded()
            XCTAssertEqual(summary.hasHorizontalScroller, overflows)
            let rates = try XCTUnwrap(view(summary) { (field: NSTextField) in field.stringValue.hasPrefix("↓") })
            XCTAssertEqual(rates.stringValue.components(separatedBy: " MB/s").count, 3)
        }
    }

    func testHeaderReadoutsStayOnTheirBaselineAsValuesChange() throws {
        let card = HoverCard()
        let summary = try XCTUnwrap(view(card) { (_: NetworkSummary) in true })
        card.frame.size = card.update(.init(), availableHeight: 300)

        func rowYs(_ wireless: WirelessLink, _ state: BandwidthTest.State) -> [CGFloat] {
            card.showDiagnostics(wireless, state)
            card.layoutSubtreeIfNeeded()
            return summary.documentView?.subviews.compactMap { item in
                guard let label = item as? NSTextField, !label.isHidden else { return nil }
                return label.frame.minY
            } ?? []
        }

        let waiting = rowYs(.init(), .running(.download, download: nil))
        let wireless = WirelessLink(status: .connected, rssi: -51, transmitMbps: 960)
        let result = BandwidthResult(download: .measured(46.7), upload: .measured(8.2), date: Date())
        let measured = rowYs(wireless, .complete(result))
        XCTAssertEqual(waiting.count, 3)
        XCTAssertEqual(waiting, measured)
        if let first = measured.first { XCTAssertTrue(measured.allSatisfy { $0 == first }) }
    }
}
