import Foundation
import zlib

enum BackupError: LocalizedError {
    case invalidArchive, unsupportedArchive, tooLarge, invalidData, checksum, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "バックアップのZIP構造またはパスが不正です。"
        case .unsupportedArchive: return "このアプリが作成した無圧縮ZIP形式のバックアップを選択してください。暗号化・ZIP64・再圧縮したファイルは未対応です。"
        case .tooLarge: return "バックアップが上限を超えています（合計200MB、ファイル1万件まで）。"
        case .invalidData: return "バックアップのデータや参照関係が不正です。元のデータは保持されています。"
        case .checksum: return "バックアップのチェックサムが一致しません。"
        case .unsupportedVersion: return "このバックアップのバージョンは未対応です。"
        }
    }
}

// A bounded ZIP profile: stored files, UTF-8 names, no encryption, descriptors or ZIP64.
// Reading validates every record in memory before any filesystem write occurs.
struct StoredZIP {
    static let maximumBytes = 200_000_000
    static let maximumFiles = 10_000
    static let maximumEntryBytes = 50_000_000
    static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ UInt32.max
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func write(_ files: [String: Data]) throws -> Data {
        guard files.count <= maximumFiles else { throw BackupError.tooLarge }
        var archive = Data(), directory = Data()
        let paths = files.keys.sorted { a, b in
            if a == "manifest.json" { return b != a }
            if b == "manifest.json" { return false }
            return a < b
        }
        for path in paths {
            guard validPath(path), let name = path.data(using: .utf8), name.count <= 65535,
                  let bytes = files[path] else { throw BackupError.invalidArchive }
            guard bytes.count <= maximumEntryBytes, archive.count + bytes.count + directory.count + name.count * 2 + 100 <= maximumBytes else { throw BackupError.tooLarge }
            let checksum = crc32(bytes), offset = UInt32(archive.count), size = UInt32(bytes.count)
            archive.appendLE(UInt32(0x04034b50)); archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x800)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(33)) // 1980-01-01
            archive.appendLE(checksum); archive.appendLE(size); archive.appendLE(size)
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0)); archive.append(name); archive.append(bytes)
            directory.appendLE(UInt32(0x02014b50)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x800)); directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(33))
            directory.appendLE(checksum); directory.appendLE(size); directory.appendLE(size)
            directory.appendLE(UInt16(name.count)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt32(0)); directory.appendLE(offset)
            directory.append(name)
        }
        let offset = UInt32(archive.count), size = UInt32(directory.count)
        archive.append(directory)
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(files.count)); archive.appendLE(UInt16(files.count))
        archive.appendLE(size); archive.appendLE(offset); archive.appendLE(UInt16(0))
        guard archive.count <= maximumBytes else { throw BackupError.tooLarge }
        return archive
    }
    static func read(_ archiveData: Data) throws -> [String: Data] {
        let data = Data(archiveData)
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        guard data.count >= 22 else { throw BackupError.invalidArchive }
        let end = data.count - 22
        guard (try data.uint32(end)) == 0x06054b50, (try data.uint16(end + 4)) == 0, (try data.uint16(end + 6)) == 0,
              (try data.uint16(end + 20)) == 0 else { throw BackupError.unsupportedArchive }
        let count = Int((try data.uint16(end + 10)))
        guard count <= maximumFiles else { throw BackupError.tooLarge }
        guard (try data.uint16(end + 8)) == count else { throw BackupError.invalidArchive }
        let start = Int((try data.uint32(end + 16))), length = Int((try data.uint32(end + 12)))
        guard start + length == end else { throw BackupError.invalidArchive }
        var position = start, localEnd = 0, total = 0
        var files: [String: Data] = [:]
        for _ in 0..<count {
            guard position + 46 <= end, (try data.uint32(position)) == 0x02014b50 else { throw BackupError.invalidArchive }
            let flags = (try data.uint16(position + 8)), method = (try data.uint16(position + 10))
            let size = Int((try data.uint32(position + 24))), packed = Int((try data.uint32(position + 20)))
            let nameLength = Int((try data.uint16(position + 28)))
            guard flags == 0 || flags == 0x800, method == 0,
                  (try data.uint16(position + 30)) == 0, (try data.uint16(position + 32)) == 0, (try data.uint16(position + 34)) == 0,
                  ((try data.uint32(position + 38)) >> 16) & 0xf000 != 0xa000 else { throw BackupError.unsupportedArchive }
            guard size <= maximumEntryBytes, total + size <= maximumBytes else { throw BackupError.tooLarge }
            guard packed == size, position + 46 + nameLength <= end,
                  let path = String(data: data.subdata(in: (position + 46)..<(position + 46 + nameLength)), encoding: .utf8),
                  validPath(path), files[path] == nil else { throw BackupError.invalidArchive }
            let local = Int((try data.uint32(position + 42)))
            guard local == localEnd, local + 30 + nameLength + size <= start,
                  (try data.uint32(local)) == 0x04034b50,
                  (try data.uint16(local + 6)) == flags, (try data.uint16(local + 8)) == method,
                  (try data.uint32(local + 14)) == (try data.uint32(position + 16)), (try data.uint32(local + 18)) == packed,
                  (try data.uint32(local + 22)) == size, (try data.uint16(local + 26)) == nameLength, (try data.uint16(local + 28)) == 0,
                  data.subdata(in: (local + 30)..<(local + 30 + nameLength)) == Data(path.utf8) else { throw BackupError.invalidArchive }
            let bytes = data.subdata(in: (local + 30 + nameLength)..<(local + 30 + nameLength + size))
            guard crc32(bytes) == ((try data.uint32(position + 16))) else { throw BackupError.checksum }
            files[path] = bytes; total += size
            localEnd = local + 30 + nameLength + size; position += 46 + nameLength
        }
        guard position == end, localEnd == start else { throw BackupError.invalidArchive }
        return files
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var bytes = value.littleEndian
        Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
    func uint16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw BackupError.invalidArchive }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func uint32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw BackupError.invalidArchive }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
}

// Import ZIPs are separate from the strict backup profile. No archive paths reach disk.
struct ImageImportZIP {
    static func read(_ data: Data) throws -> [String: Data] {
        guard data.count <= 200_000_000 else { throw BackupError.tooLarge }
        guard data.count >= 22 else { throw BackupError.invalidArchive }
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
            (try? data.uint32($0)) == 0x06054b50 && Int((try? data.uint16($0 + 20)) ?? 0) + $0 + 22 == data.count
        }) else { throw BackupError.invalidArchive }
        let count = Int(try data.uint16(end + 10))
        guard count <= 1000 else { throw BackupError.tooLarge }
        guard try data.uint16(end + 4) == 0, (try data.uint16(end + 6)) == 0,
              (try data.uint16(end + 8)) == count else { throw BackupError.unsupportedArchive }
        let start = Int(try data.uint32(end + 16)), length = Int(try data.uint32(end + 12))
        guard start + length == end else { throw BackupError.invalidArchive }
        var position = start, total = 0
        var files: [String: Data] = [:], names = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard position + 46 <= end, try data.uint32(position) == 0x02014b50 else { throw BackupError.invalidArchive }
            let flags = try data.uint16(position + 8), method = try data.uint16(position + 10)
            let checksum = try data.uint32(position + 16)
            let packed = Int(try data.uint32(position + 20)), size = Int(try data.uint32(position + 24))
            let nameLength = Int(try data.uint16(position + 28)), extra = Int(try data.uint16(position + 30)), comment = Int(try data.uint16(position + 32))
            let next = position + 46 + nameLength + extra + comment
            guard flags & ~UInt16(0x808) == 0, method == 0 || method == 8,
                  try data.uint16(position + 34) == 0,
                  ((try data.uint32(position + 38)) >> 16) & 0xf000 != 0xa000 else { throw BackupError.unsupportedArchive }
            guard size <= 20_000_000, total + size <= 200_000_000,
                  size <= max(1, packed) * 100 else { throw BackupError.tooLarge }
            guard next <= end, let path = String(data: data.subdata(in: position + 46..<position + 46 + nameLength), encoding: .utf8) else { throw BackupError.invalidArchive }
            try validateExtra(data, range: position + 46 + nameLength..<position + 46 + nameLength + extra)
            let directory = path.hasSuffix("/")
            let clean = directory ? String(path.dropLast()) : path
            guard StoredZIP.validPath(clean), names.insert(clean.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw BackupError.invalidArchive }
            let local = Int(try data.uint32(position + 42))
            guard local + 30 <= start, try data.uint32(local) == 0x04034b50,
                  (try data.uint16(local + 6)) == flags, (try data.uint16(local + 8)) == method,
                  (try data.uint16(local + 26)) == nameLength else { throw BackupError.invalidArchive }
            let localExtra = Int(try data.uint16(local + 28)), begin = local + 30 + nameLength + localExtra
            guard begin + packed <= start,
                  data.subdata(in: local + 30..<local + 30 + nameLength) == Data(path.utf8) else { throw BackupError.invalidArchive }
            try validateExtra(data, range: local + 30 + nameLength..<begin)
            var finish = begin + packed
            if flags & 8 == 0 {
                guard try data.uint32(local + 14) == checksum, (try data.uint32(local + 18)) == packed,
                      (try data.uint32(local + 22)) == size else { throw BackupError.invalidArchive }
            } else {
                if (try? data.uint32(finish)) == 0x08074b50 { finish += 4 }
                guard finish + 12 <= start, try data.uint32(finish) == checksum,
                      (try data.uint32(finish + 4)) == packed, (try data.uint32(finish + 8)) == size else { throw BackupError.invalidArchive }
                finish += 12
            }
            ranges.append(local..<finish)
            let compressed = data.subdata(in: begin..<begin + packed)
            let bytes = method == 0 ? compressed : try inflate(compressed, size: size)
            guard bytes.count == size, StoredZIP.crc32(bytes) == checksum else { throw BackupError.checksum }
            if directory { guard bytes.isEmpty else { throw BackupError.invalidArchive } }
            else { files[path] = bytes }
            total += size; position = next
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard position == end, sorted.first?.lowerBound == 0, sorted.last?.upperBound == start,
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.upperBound == $1.lowerBound }) else { throw BackupError.invalidArchive }
        return files
    }
    private static func validateExtra(_ data: Data, range: Range<Int>) throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard offset + 4 <= range.upperBound else { throw BackupError.invalidArchive }
            let identifier = try data.uint16(offset), size = Int(try data.uint16(offset + 2))
            guard identifier != 1 else { throw BackupError.unsupportedArchive } // ZIP64
            offset += 4 + size
            guard offset <= range.upperBound else { throw BackupError.invalidArchive }
        }
    }
    private static func inflate(_ compressed: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw BackupError.invalidArchive }
        defer { inflateEnd(&stream) }
        var output = Data(count: size + 1)
        let status = compressed.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size + 1)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else { throw BackupError.invalidArchive }
        output.removeLast(); return output
    }
}
