import AppKit
import XCTest

final class NetRateTests: XCTestCase {
    private func counters(
        received: UInt64,
        sent: UInt64,
        receivedPackets: UInt64 = 0,
        sentPackets: UInt64 = 0,
        lastChange: UInt64 = 0,
        bitsPerSecond: UInt64 = 0
    ) -> LinkCounters {
        LinkCounters(
            received: .init(bytes: received, packets: receivedPackets),
            sent: .init(bytes: sent, packets: sentPackets),
            lastChange: lastChange,
            bitsPerSecond: bitsPerSecond
        )
    }

    func testFormatting() {
        for (rate, expected) in [(0.0,"0B"), (36,"36B"), (999.5,"1K"), (2400,"2K"),
                                 (999600,"1M"), (1.4e6,"1.4M"), (2e6,"2M"),
                                 (9.96e6,"10M"), (82.3e6,"82M"), (1.4e9,"1.4G")] {
            let text = RateText(rate)
            XCTAssertEqual(text.value + text.unit, expected)
        }
        XCTAssertEqual(RateText(nil).value, "—")
    }

    func testInterfacesAndBaseline() {
        let wifi = LinkID(index: 1, name: "en0")
        let peer = LinkID(index: 2, name: "awdl0")
        let proxy = LinkID(index: 3, name: "lo0")
        let vpn = LinkID(index: 4, name: "utun0")
        var meter = TrafficMeter()
        func read(_ time: Double, _ totals: [LinkID: UInt64]) -> Speed? {
            meter.measure(Snapshot(time: time, links: totals.mapValues { counters(received: $0, sent: $0*2) }))
        }
        XCTAssertNil(read(0,[wifi:100,proxy:200,vpn:200]))
        XCTAssertEqual(read(2,[wifi:150,peer:5000,proxy:600,vpn:700])?.upload,50)
        XCTAssertEqual(read(3,[wifi:160,peer:5020])?.download,30)
        XCTAssertEqual(read(4,[wifi:1,peer:5022])?.download,2)
        XCTAssertEqual(read(5,[wifi:1])?.download,0)
        XCTAssertNil(read(24,[wifi:5555]))
        XCTAssertNil(meter.measure(nil))
        XCTAssertNil(read(26,[wifi:9999]))
        XCTAssertEqual(read(27,[wifi:9999])?.upload,0)
    }

    func testInterfaceReplacementAnd64BitCounters() {
        let oldID = LinkID(index: 14, name: "en0")
        let newID = LinkID(index: 24, name: "en0")
        let total: UInt64 = 1 << 42
        var meter = TrafficMeter()
        func sample(_ time: Double, _ id: LinkID, _ bytes: UInt64) -> Speed? {
            meter.measure(Snapshot(time: time, links: [id: counters(received: bytes, sent: 0)]))
        }
        XCTAssertNil(sample(0, oldID, total))
        XCTAssertEqual(sample(1.25, oldID, total + 1250)?.download, 1000)
        XCTAssertNil(sample(2.25, newID, total + 8000))
        XCTAssertEqual(sample(3.25, newID, total + 9000)?.download, 1000)
        let reset = sample(4.25, newID, 0)
        XCTAssertNil(reset?.download)
        XCTAssertEqual(reset?.upload, 0)
        XCTAssertEqual(sample(5.25, newID, 12)?.download, 12)
    }

    func testTruncatedDarwinCountersWrapIndependently() {
        let wifi = LinkID(index: 1, name: "en0")
        let modulus: UInt64 = 1 << 32
        var meter = TrafficMeter()
        func sample(_ time: Double, _ counters: LinkCounters) -> Speed? {
            meter.measure(Snapshot(time: time, links: [wifi: counters]))
        }
        XCTAssertNil(sample(0, counters(
            received: modulus - 4096, sent: modulus - 8192,
            receivedPackets: 1 << 32, sentPackets: 100)))
        let receiveWrap = sample(1.25, counters(
            received: 2048, sent: modulus - 4096,
            receivedPackets: (1 << 32) + 8, sentPackets: 105))
        XCTAssertEqual(receiveWrap?.download, 6144 / 1.25)
        XCTAssertEqual(receiveWrap?.upload, 4096 / 1.25)
        let sendWrap = sample(2.25, counters(
            received: 3072, sent: 1024,
            receivedPackets: (1 << 32) + 10, sentPackets: 110))
        XCTAssertEqual(sendWrap?.download, 1024)
        XCTAssertEqual(sendWrap?.upload, 5120)
    }

    func testResetIsNotAnInterfaceRollover() {
        let wifi = LinkID(index: 1, name: "en0")
        let modulus: UInt64 = 1 << 32
        var meter = TrafficMeter()
        func sample(_ time: Double, _ counters: LinkCounters) -> Speed? {
            meter.measure(Snapshot(time: time, links: [wifi: counters]))
        }
        XCTAssertNil(sample(0, counters(
            received: modulus - 1024, sent: modulus - 2048,
            receivedPackets: 100, sentPackets: 100)))
        let packetReset = sample(1, counters(
            received: 1024, sent: 1024, receivedPackets: 2, sentPackets: 103))
        XCTAssertNil(packetReset?.download)
        XCTAssertEqual(packetReset?.upload, 3072)
        XCTAssertNil(sample(2, counters(
            received: 2048, sent: 2048, receivedPackets: 10, sentPackets: 104, lastChange: 1)))
        let rebased = sample(3, counters(
            received: 3072, sent: 4096, receivedPackets: 11, sentPackets: 106, lastChange: 1))
        XCTAssertEqual(rebased?.download, 1024)
        XCTAssertEqual(rebased?.upload, 2048)
    }

    func testImplausiblyLargeRolloverIsDiscarded() {
        let wifi = LinkID(index: 1, name: "en0")
        var meter = TrafficMeter()
        _ = meter.measure(Snapshot(time: 0, links: [
            wifi: counters(received: 3 << 30, sent: 1 << 30, receivedPackets: 100)
        ]))
        let speed = meter.measure(Snapshot(time: 0.5, links: [
            wifi: counters(received: 1024, sent: (1 << 30) + 1024, receivedPackets: 101)
        ]))
        XCTAssertNil(speed?.download)
        XCTAssertEqual(speed?.upload, 2048)
    }

    func testPureLoopbackAndTunnelTraffic() {
        let loopback = LinkID(index: 1, name: "lo0")
        let tunnel = LinkID(index: 12, name: "utun0")
        var meter = TrafficMeter()
        _ = meter.measure(Snapshot(time: 1, links: [:]))
        let bytes = counters(received: 4_000_000, sent: 4_000_000)
        let speed = meter.measure(Snapshot(time: 2, links: [loopback: bytes, tunnel: bytes]))
        XCTAssertEqual(speed?.download, 0)
        XCTAssertEqual(speed?.upload, 0)
    }

    @MainActor
    func testDigitContrastAcrossAppearances() throws {
        let image = StatusFace().image(upload: RateText(999000), download: RateText(1.4e6))
        for (name, expected) in [(NSAppearance.Name.aqua, 0.0), (.darkAqua, 1.0), (.aqua, 0.0)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 40,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * 2, height: 40))
                NSGraphicsContext.restoreGraphicsState()
                var solidPixels = 0
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              pixel.alphaComponent > 0.95 else { continue }
                        solidPixels += 1
                        XCTAssertEqual(pixel.redComponent, expected, accuracy: 0.04)
                    }
                }
                XCTAssertGreaterThan(solidPixels, 100)
            }
        }
    }

    func testNativeReaderAndMalformedInput() throws {
        var reader = InterfaceReader()
        let sample = try XCTUnwrap(reader.sample())
        XCTAssertTrue(sample.links.keys.contains { $0.name == "lo0" })
        XCTAssertTrue(sample.links.keys.contains { $0.isExternal })
        for invalid: [UInt8] in [[0], [0,0,5,18], [100,0,5,18]] {
            invalid.withUnsafeBytes { XCTAssertNil(InterfaceReader.decode($0)) }
        }
    }
}
