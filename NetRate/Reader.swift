import Darwin
import Foundation

struct InterfaceReader {
    private var buffer = Data(count: 8192)

    mutating func sample() -> Snapshot? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 {
            var length = buffer.count
            let result = buffer.withUnsafeMutableBytes {
                sysctl(&mib, UInt32(mib.count), $0.baseAddress, &length, nil, 0)
            }
            if result == 0 {
                let links = buffer.withUnsafeBytes { Self.decode(UnsafeRawBufferPointer(rebasing: $0[..<length])) }
                return links.map { Snapshot(time: ProcessInfo.processInfo.systemUptime, links: $0) }
            }
            guard errno == ENOMEM, sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return nil }
            buffer = Data(count: length + 2048)
        }
        return nil
    }

    // RTM_IFINFO2 has a fixed header followed by the interface's sockaddr_dl.
    static func decode(_ bytes: UnsafeRawBufferPointer) -> [LinkID: LinkCounters]? {
        var links: [LinkID: LinkCounters] = [:]
        var start = 0
        let headerSize = MemoryLayout<if_msghdr2>.size
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
        while start < bytes.count {
            guard bytes.count - start >= 4 else { return nil }
            let length = Int(bytes.loadUnaligned(fromByteOffset: start, as: UInt16.self))
            guard length >= 4, length <= bytes.count - start else { return nil }
            defer { start += length }
            guard bytes[start + 2] == RTM_VERSION else { return nil }
            guard bytes[start + 3] == RTM_IFINFO2 else { continue }
            guard length >= headerSize + dataOffset else { return nil }
            let header = bytes.loadUnaligned(fromByteOffset: start, as: if_msghdr2.self)
            let address = start + headerSize
            let addressSize = Int(bytes[address])
            guard bytes[address+1] == AF_LINK, addressSize >= dataOffset, addressSize <= length-headerSize else { return nil }
            let count = Int(bytes[address+5]) // sdl_nlen
            guard count > 0, count <= addressSize-dataOffset else { return nil }
            let nameStart = address + dataOffset
            let name = String(decoding: bytes[nameStart..<nameStart+count], as: UTF8.self)
            let data = header.ifm_data
            let changed = data.ifi_lastchange
            let seconds = UInt64(UInt32(truncatingIfNeeded: changed.tv_sec))
            let microseconds = UInt64(UInt32(truncatingIfNeeded: changed.tv_usec))
            links[LinkID(index: header.ifm_index, name: name)] = LinkCounters(
                received: .init(bytes: data.ifi_ibytes, packets: data.ifi_ipackets),
                sent: .init(bytes: data.ifi_obytes, packets: data.ifi_opackets),
                lastChange: (seconds << 32) | microseconds,
                bitsPerSecond: data.ifi_baudrate
            )
        }
        return links
    }
}
