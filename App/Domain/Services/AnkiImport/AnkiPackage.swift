import Foundation
import CryptoKit
import libzstd
import zlib

final class AnkiReadBudget {
    private let deadline = Date().addingTimeInterval(20)
    private var expanded = 0
    func check() throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw AnkiImportError.budget }
    }
    func consume(_ count: Int) throws {
        try check()
        guard count <= StoredZIP.maximumBytes - expanded else { throw BackupError.tooLarge }
        expanded += count
    }
}

// Minimal protobuf wire reader. No generated code or arbitrary object decoding.
struct AnkiProto {
    enum Value { case number(UInt64), bytes(Data), fixed }
    let fields: [Int: [Value]]
    init(_ bytes: Data, budget: AnkiReadBudget? = nil) throws {
        let data = Data(bytes)
        guard data.count <= 5_000_000 else { throw BackupError.tooLarge }
        var offset = 0, fields: [Int: [Value]] = [:], count = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for byteIndex in 0..<10 {
                guard offset < data.count else { throw AnkiImportError.database }
                let byte = data[offset]; offset += 1
                guard byteIndex < 9 || byte <= 1 else { throw AnkiImportError.database }
                value |= UInt64(byte & 127) << (byteIndex * 7)
                if byte & 128 == 0 { return value }
            }
            throw AnkiImportError.database
        }
        while offset < data.count {
            try budget?.check(); count += 1
            guard count <= 100_000 else { throw BackupError.tooLarge }
            let key = try varint(), field = key >> 3
            guard field > 0, field <= 536_870_911 else { throw AnkiImportError.database }
            let value: Value
            switch key & 7 {
            case 0: value = .number(try varint())
            case 2:
                let length = try varint()
                guard length <= UInt64(data.count - offset) else { throw AnkiImportError.database }
                value = .bytes(data.subdata(in: offset..<offset + Int(length))); offset += Int(length)
            case 1, 5:
                let length = key & 7 == 1 ? 8 : 4
                guard length <= data.count - offset else { throw AnkiImportError.database }
                offset += length; value = .fixed
            default: throw AnkiImportError.database
            }
            fields[Int(field), default: []].append(value)
        }
        self.fields = fields
    }
    func number(_ id: Int, default value: UInt64 = 0) throws -> UInt64 {
        guard let values = fields[id] else { return value }
        guard values.count == 1, case .number(let number) = values[0] else { throw AnkiImportError.database }
        return number
    }
    func bytes(_ id: Int, default value: Data = Data()) throws -> Data {
        guard let values = fields[id] else { return value }
        guard values.count == 1, case .bytes(let bytes) = values[0] else { throw AnkiImportError.database }
        return bytes
    }
    func string(_ id: Int) throws -> String {
        guard let text = String(data: try bytes(id), encoding: .utf8), !text.contains("\0") else { throw AnkiImportError.database }
        return text
    }
}

enum AnkiZstd {
    static func decode(_ data: Data, limit: Int, budget: AnkiReadBudget) throws -> Data {
        try budget.check()
        guard data.prefix(4) == Data([0x28, 0xb5, 0x2f, 0xfd]), let stream = ZSTD_createDStream() else { throw AnkiImportError.database }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0,
              ZSTD_isError(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 23)) == 0 else { throw AnkiImportError.database }
        let maximum = min(limit, max(1_000_000, data.count * 200))
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        try data.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: data.count, pos: 0)
            var remaining = 1
            while remaining > 0 {
                try budget.check()
                let previous = input.pos
                var written = 0
                remaining = buffer.withUnsafeMutableBytes { destination in
                    var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let status = ZSTD_decompressStream(stream, &output, &input)
                    written = output.pos; return status
                }
                guard ZSTD_isError(remaining) == 0 else { throw AnkiImportError.database }
                guard written <= maximum - result.count else { throw BackupError.tooLarge }
                try budget.consume(written)
                result.append(contentsOf: buffer.prefix(written))
                guard remaining == 0 || input.pos > previous || written > 0 else { throw AnkiImportError.database }
                if remaining == 0 { guard input.pos == input.size else { throw AnkiImportError.database } }
            }
        }
        return result
    }
}

struct AnkiPackageContents {
    let database: Data
    let version: Int
    let media: [String: Data]
}

enum AnkiPackage {
    static func read(_ data: Data, budget: AnkiReadBudget) throws -> AnkiPackageContents {
        let files: [String: Data]
        do { files = try AnkiPackageZIP.read(data, budget: budget) }
        catch BackupError.unsupportedArchive { throw AnkiImportError.unsupported("Anki ZIPの暗号化・ZIP64・未対応の圧縮方法や特殊ファイルには対応していません。") }
        let version: Int
        if let meta = files["meta"] {
            guard meta.count <= 1024 else { throw AnkiImportError.database }
            let proto = try AnkiProto(meta, budget: budget)
            guard Set(proto.fields.keys) == [1] else { throw AnkiImportError.database }
            let value = try proto.number(1)
            guard (1...3).contains(value) else { throw AnkiImportError.unsupported("Ankiパッケージのmetaバージョンが未対応です。") }
            version = Int(value)
        } else {
            guard files["collection.anki21b"] == nil else { throw AnkiImportError.unsupported("最新Ankiパッケージのmetaがありません。旧形式のダミーDBは取り込みません。") }
            version = files["collection.anki21"] == nil ? 1 : 2
        }
        let names = [1: "collection.anki2", 2: "collection.anki21", 3: "collection.anki21b"]
        guard let packedDB = files[names[version]!], let packedMedia = files["media"],
              version == 3 || files["collection.anki21b"] == nil,
              version != 1 || files["collection.anki21"] == nil,
              version != 3 || files["collection.anki21"] == nil else { throw AnkiImportError.database }
        let database = version == 3 ? try AnkiZstd.decode(packedDB, limit: 50_000_000, budget: budget) : packedDB
        let mapping: [(String, String, Int?, Data?)]
        if version == 3 {
            let entries = try AnkiProto(AnkiZstd.decode(packedMedia, limit: 5_000_000, budget: budget), budget: budget)
            guard Set(entries.fields.keys).isSubset(of: [1]) else { throw AnkiImportError.database }
            mapping = try (entries.fields[1] ?? []).enumerated().map { index, value in
                guard case .bytes(let bytes) = value else { throw AnkiImportError.database }
                let entry = try AnkiProto(bytes, budget: budget)
                guard Set(entry.fields.keys).isSubset(of: [1, 2, 3, 255]) else { throw AnkiImportError.database }
                let name = try entry.string(1), size = try entry.number(2), checksum = try entry.bytes(3)
                let number = try entry.number(255, default: UInt64(index))
                guard size <= 20_000_000, number < 9996, checksum.count == 20 else { throw AnkiImportError.database }
                return (String(number), name, Int(size), checksum)
            }
        } else {
            mapping = try legacyMap(packedMedia).map { ($0.key, $0.value, nil, nil) }
        }
        guard mapping.count <= 9996 else { throw BackupError.tooLarge }
        var usedNames = Set<String>(), usedKeys = Set<String>(), media: [String: Data] = [:]
        for (key, name, size, checksum) in mapping {
            try budget.check()
            guard !key.isEmpty, key.utf8.allSatisfy({ (48...57).contains($0) }),
                  StoredZIP.validPath(name), !name.contains("/"), name.count <= 1000,
                  usedKeys.insert(key).inserted,
                  usedNames.insert(name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))).inserted,
                  let packed = files[key] else { throw AnkiImportError.database }
            let bytes = version == 3 ? try AnkiZstd.decode(packed, limit: 20_000_000, budget: budget) : packed
            if let size, let checksum {
                guard bytes.count == size, Data(Insecure.SHA1.hash(data: bytes)) == checksum else { throw BackupError.checksum }
            }
            media[name] = bytes
        }
        let allowed: Set<String> = ["meta", "media", "collection.anki2", "collection.anki21", "collection.anki21b"]
        guard files.keys.allSatisfy({ allowed.contains($0) || usedKeys.contains($0) }) else { throw AnkiImportError.database }
        return AnkiPackageContents(database: database, version: version, media: media)
    }
    // Decode the legacy string map without silently accepting duplicate JSON keys.
    private static func legacyMap(_ data: Data) throws -> [String: String] {
        guard data.count <= 5_000_000 else { throw BackupError.tooLarge }
        var offset = 0, result: [String: String] = [:]
        func whitespace() { while offset < data.count && [9, 10, 13, 32].contains(data[offset]) { offset += 1 } }
        func expect(_ byte: UInt8) throws {
            whitespace(); guard offset < data.count, data[offset] == byte else { throw AnkiImportError.database }; offset += 1
        }
        func string() throws -> String {
            whitespace(); let start = offset; try expect(34)
            var escaped = false
            while offset < data.count {
                let byte = data[offset]; offset += 1
                if !escaped && byte == 34 { return try JSONDecoder().decode(String.self, from: data.subdata(in: start..<offset)) }
                if !escaped && byte == 92 { escaped = true } else { escaped = false }
            }
            throw AnkiImportError.database
        }
        try expect(123); whitespace()
        if offset < data.count, data[offset] != 125 {
            while true {
                let key = try string(); try expect(58); let value = try string()
                guard result[key] == nil, result.count < 9996 else { throw AnkiImportError.database }
                result[key] = value; whitespace()
                guard offset < data.count else { throw AnkiImportError.database }
                if data[offset] == 125 { break }; try expect(44)
            }
        }
        try expect(125); whitespace(); guard offset == data.count else { throw AnkiImportError.database }
        return result
    }
}

struct AnkiPackageZIP {
    static func read(_ archive: Data, budget: AnkiReadBudget) throws -> [String: Data] {
        let data = Data(archive)
        guard data.count <= 200_000_000 else { throw BackupError.tooLarge }
        guard data.count >= 22 else { throw BackupError.invalidArchive }
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
            (try? data.ankiUInt32($0)) == 0x06054b50 && Int((try? data.ankiUInt16($0 + 20)) ?? 0) + $0 + 22 == data.count
        }) else { throw BackupError.invalidArchive }
        let count = Int(try data.ankiUInt16(end + 10))
        guard count != 65535, count <= 10000 else { throw BackupError.tooLarge }
        guard try data.ankiUInt16(end + 4) == 0, (try data.ankiUInt16(end + 6)) == 0,
              (try data.ankiUInt16(end + 8)) == count else { throw BackupError.unsupportedArchive }
        let start = Int(try data.ankiUInt32(end + 16)), length = Int(try data.ankiUInt32(end + 12))
        guard start + length == end else { throw BackupError.invalidArchive }
        var position = start, total = 0
        var files: [String: Data] = [:], names = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            try budget.check()
            guard position + 46 <= end, try data.ankiUInt32(position) == 0x02014b50 else { throw BackupError.invalidArchive }
            let flags = try data.ankiUInt16(position + 8), method = try data.ankiUInt16(position + 10)
            let checksum = try data.ankiUInt32(position + 16)
            let packed = Int(try data.ankiUInt32(position + 20)), size = Int(try data.ankiUInt32(position + 24))
            let nameLength = Int(try data.ankiUInt16(position + 28)), extra = Int(try data.ankiUInt16(position + 30)), comment = Int(try data.ankiUInt16(position + 32))
            let next = position + 46 + nameLength + extra + comment
            guard flags & ~UInt16(0x808) == 0, method == 0 || method == 8,
                  try data.ankiUInt16(position + 34) == 0,
                  [UInt32(0), UInt32(0x8000), UInt32(0x4000)].contains(((try data.ankiUInt32(position + 38)) >> 16) & 0xf000) else { throw BackupError.unsupportedArchive }
            guard size <= 50_000_000, total + size <= 200_000_000,
                  size <= max(1_000_000, packed * 200) else { throw BackupError.tooLarge }
            guard next <= end, let path = String(data: data.subdata(in: position + 46..<position + 46 + nameLength), encoding: .utf8) else { throw BackupError.invalidArchive }
            try validateExtra(data, range: position + 46 + nameLength..<position + 46 + nameLength + extra)
            let directory = path.hasSuffix("/")
            let clean = directory ? String(path.dropLast()) : path
            guard StoredZIP.validPath(clean), names.insert(clean.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))).inserted else { throw BackupError.invalidArchive }
            let local = Int(try data.ankiUInt32(position + 42))
            guard local + 30 <= start, try data.ankiUInt32(local) == 0x04034b50,
                  (try data.ankiUInt16(local + 6)) == flags, (try data.ankiUInt16(local + 8)) == method,
                  (try data.ankiUInt16(local + 26)) == nameLength else { throw BackupError.invalidArchive }
            let localExtra = Int(try data.ankiUInt16(local + 28)), begin = local + 30 + nameLength + localExtra
            guard begin + packed <= start,
                  data.subdata(in: local + 30..<local + 30 + nameLength) == Data(path.utf8) else { throw BackupError.invalidArchive }
            try validateExtra(data, range: local + 30 + nameLength..<begin)
            var finish = begin + packed
            if flags & 8 == 0 {
                guard try data.ankiUInt32(local + 14) == checksum, (try data.ankiUInt32(local + 18)) == packed,
                      (try data.ankiUInt32(local + 22)) == size else { throw BackupError.invalidArchive }
            } else {
                guard [UInt32(0), checksum].contains(try data.ankiUInt32(local + 14)),
                      [UInt32(0), UInt32(packed)].contains(try data.ankiUInt32(local + 18)),
                      [UInt32(0), UInt32(size)].contains(try data.ankiUInt32(local + 22)) else { throw BackupError.invalidArchive }
                if (try? data.ankiUInt32(finish)) == 0x08074b50 { finish += 4 }
                guard finish + 12 <= start, try data.ankiUInt32(finish) == checksum,
                      (try data.ankiUInt32(finish + 4)) == packed, (try data.ankiUInt32(finish + 8)) == size else { throw BackupError.invalidArchive }
                finish += 12
            }
            ranges.append(local..<finish)
            let compressed = data.subdata(in: begin..<begin + packed)
            let bytes = method == 0 ? compressed : try inflate(compressed, size: size, budget: budget)
            guard bytes.count == size, StoredZIP.crc32(bytes) == checksum else { throw BackupError.checksum }
            if method == 0 { try budget.consume(bytes.count) }
            try budget.check()
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
            let identifier = try data.ankiUInt16(offset), size = Int(try data.ankiUInt16(offset + 2))
            guard identifier != 1 else { throw BackupError.unsupportedArchive } // ZIP64
            offset += 4 + size
            guard offset <= range.upperBound else { throw BackupError.invalidArchive }
        }
    }
    private static func inflate(_ compressed: Data, size: Int, budget: AnkiReadBudget) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw BackupError.invalidArchive }
        defer { inflateEnd(&stream) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        try compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(compressed.count)
            while true {
                try budget.check()
                let previous = stream.avail_in
                var written = 0
                let status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    written = output.count - Int(stream.avail_out)
                    return status
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw BackupError.invalidArchive }
                guard written <= size - result.count else { throw BackupError.tooLarge }
                try budget.consume(written); result.append(contentsOf: buffer.prefix(written))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, result.count == size else { throw BackupError.invalidArchive }
                    break
                }
                guard written > 0 || previous > stream.avail_in else { throw BackupError.invalidArchive }
            }
        }
        return result
    }
}
private extension Data {
    func ankiUInt16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw BackupError.invalidArchive }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func ankiUInt32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw BackupError.invalidArchive }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
}
