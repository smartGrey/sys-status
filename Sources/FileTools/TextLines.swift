import Foundation

// Newlines in ASCII-compatible text are single bytes. UTF-16/32 use full code
// units; retain an incomplete unit and a trailing CR across read boundaries.
enum TextLines {
    private struct Format {
        let width: Int
        let littleEndian: Bool
        let bom: Int

        init(_ prefix: Data) {
            if prefix.starts(with: [0xff, 0xfe, 0, 0]) { (width, littleEndian, bom) = (4, true, 4) }
            else if prefix.starts(with: [0, 0, 0xfe, 0xff]) { (width, littleEndian, bom) = (4, false, 4) }
            else if prefix.starts(with: [0xff, 0xfe]) { (width, littleEndian, bom) = (2, true, 2) }
            else if prefix.starts(with: [0xfe, 0xff]) { (width, littleEndian, bom) = (2, false, 2) }
            else { (width, littleEndian, bom) = (1, false, prefix.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0) }
        }

        func header(_ data: Data) -> String {
            let bytes = data.dropFirst(bom)
            switch width {
            case 2: return String(data: bytes, encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian) ?? ""
            case 4: return String(data: bytes, encoding: littleEndian ? .utf32LittleEndian : .utf32BigEndian) ?? ""
            default: return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    // nil means binary or deliberately excluded. Only a small header is decoded.
    static func count(_ file: FileHandle, includeHeader: ((String) -> Bool)? = nil) throws -> Int? {
        var chunk = try file.read(upToCount: 8192) ?? Data()
        let format = Format(chunk)
        if chunk.starts(with: "%PDF-".utf8) || chunk.starts(with: "bplist00".utf8) { return nil }
        if let includeHeader, !includeHeader(format.header(chunk)) { return nil }

        var lines = 0
        var hasTrailingText = false
        var previousCR = false
        var carry = Data()
        var offset = format.bom
        while !chunk.isEmpty {
            if !carry.isEmpty {
                carry.append(chunk)
                chunk = carry
                carry = Data()
            }
            let end = chunk.count - (chunk.count - offset) % format.width
            let isText = chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
                var index = offset
                while index < end {
                    var unit = UInt32(bytes[index])
                    if format.width > 1 {
                        for byte in 1..<format.width {
                            let next = UInt32(bytes[index + byte])
                            if format.littleEndian { unit |= next << (8 * byte) }
                            else { unit = (unit << 8) | next }
                        }
                    }
                    switch unit {
                    case 13: lines += 1
                    case 10: if !previousCR { lines += 1 }
                    case 0..<9, 14..<27, 28..<32: return false
                    default: break
                    }
                    previousCR = unit == 13
                    hasTrailingText = unit != 10 && unit != 13
                    index += format.width
                }
                return true
            }
            guard isText else { return nil }
            if end < chunk.count { carry = Data(chunk[end...]) }
            offset = 0
            chunk = try file.read(upToCount: 64 * 1024) ?? Data()
        }
        guard carry.isEmpty else { return nil }
        return lines + (hasTrailingText ? 1 : 0)
    }
}
