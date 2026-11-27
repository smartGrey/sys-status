import Darwin
import Foundation

struct FileIssues {
    private(set) var count = 0
    private(set) var first: String?

    mutating func record(_ path: String, _ error: Error) {
        count += 1
        if first == nil { first = "\(path)：\(error.localizedDescription)" }
    }
}

struct FileToolError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct MacFileCleanup {
    var finderRecords = 0
    var appleDoubleFiles = 0
    var total: Int { finderRecords + appleDoubleFiles }
    var issues = FileIssues()
}

// Foundation's directory enumerator hides AppleDouble files on macOS. Keep an open
// parent descriptor while visiting each entry, including on removable/network volumes.
enum DirectoryFiles {
    static func systemError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    static func walk(_ root: URL, skipDirectory: (String) -> Bool = { _ in false },
                     visitDirectory: (String) -> Void = { _ in },
                     onError: (String, Error) -> Void,
                     visit: (Int32, String, String) throws -> Void) throws {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        func scan(_ descriptor: Int32, relative: String) throws {
            guard descriptor >= 0 else { throw systemError() }
            guard let listing = fdopendir(descriptor) else {
                let error = systemError()
                close(descriptor)
                throw error
            }
            defer { closedir(listing) } // Also closes descriptor.
            while true {
                errno = 0
                guard let entry = readdir(listing) else {
                    if errno != 0 {
                        let error = systemError()
                        onError(relative.isEmpty ? root.lastPathComponent : relative, error)
                    }
                    return
                }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) {
                    String(validatingCString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                guard let name else {
                    onError(relative, FileToolError("有文件名无法读取。"))
                    continue
                }
                guard name != ".", name != ".." else { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                do {
                    var type = Int32(entry.pointee.d_type)
                    if type == DT_UNKNOWN {
                        var info = stat()
                        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError() }
                        type = Int32((info.st_mode & S_IFMT) >> 12)
                    }
                    switch type {
                    case DT_DIR where !skipDirectory(name):
                        visitDirectory(path)
                        try scan(openat(descriptor, name, flags), relative: path)
                    case DT_REG:
                        try visit(descriptor, name, path)
                    default: break // Includes symbolic links, sockets and devices.
                    }
                } catch {
                    onError(path, error)
                }
            }
        }
        try scan(open(root.path, flags), relative: "")
    }

    // O_NOFOLLOW_ANY also protects git-listed paths containing intermediate symlinks.
    static func regularFile(at path: String, in parent: Int32, flags: Int32 = O_NOFOLLOW_ANY) throws -> FileHandle? {
        let fd = openat(parent, path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | flags)
        guard fd >= 0 else {
            if errno == ELOOP { return nil }
            throw systemError()
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError() }
        return (info.st_mode & S_IFMT) == S_IFREG ? handle : nil
    }

    static func cleanMacFiles(in root: URL) throws -> MacFileCleanup {
        var result = MacFileCleanup()
        try walk(root, onError: { result.issues.record($0, $1) }) { parent, name, _ in
            guard name == ".DS_Store" || name.hasPrefix("._") else { return }
            if name != ".DS_Store" {
                guard let file = try regularFile(at: name, in: parent),
                      let header = try file.read(upToCount: 26), header.count == 26,
                      header.starts(with: [0x00, 0x05, 0x16, 0x07]),
                      header[4] == 0, [1, 2].contains(header[5]),
                      header[6] == 0, header[7] == 0 else { return }
                // A complete AppleDouble header includes a table of 12-byte entry descriptors.
                let entries = Int(header[24]) * 256 + Int(header[25])
                var inspected = stat(), current = stat()
                guard fstat(file.fileDescriptor, &inspected) == 0,
                      fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError() }
                guard entries > 0, inspected.st_size >= 26 + entries * 12 else { return }
                guard current.st_dev == inspected.st_dev, current.st_ino == inspected.st_ino else {
                    throw FileToolError("文件已更换，已跳过。")
                }
            }
            // unlinkat with flags=0 cannot recursively remove a directory.
            guard unlinkat(parent, name, 0) == 0 else { throw systemError() }
            if name == ".DS_Store" { result.finderRecords += 1 }
            else { result.appleDoubleFiles += 1 }
        }
        return result
    }
}
