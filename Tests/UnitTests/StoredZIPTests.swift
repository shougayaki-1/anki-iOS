import XCTest
@testable import AnkiIOS

final class StoredZIPTests: XCTestCase {
    func testStoredZIPRoundTripAndKnownCRC() throws {
        let files = ["manifest.json": Data("manifest".utf8), "data.json": Data("json".utf8), "media/東京.jpg": Data((0...255).map(UInt8.init))]
        let archive = try StoredZIP.write(files)
        XCTAssertEqual(try StoredZIP.read(archive), files)
        XCTAssertEqual(StoredZIP.crc32(Data("123456789".utf8)), 0xcbf43926)
        let prefixed = Data([0, 1, 2]) + archive
        XCTAssertEqual(try StoredZIP.read(prefixed.dropFirst(3)), files)
    }
    func testTraversalDuplicateIntegrityCompressionAndSymlinksRejected() throws {
        for path in ["../data", "/data", "a/../../data", "C:/data", "a\\data", "a//data", "a/./data", "a/"] {
            XCTAssertThrowsError(try StoredZIP.write([path: Data()]))
        }
        let archive = try StoredZIP.write(["aa/x": Data("body".utf8)])
        let central = archive.count - 22 - 50
        var traversal = archive
        traversal.replaceSubrange(30..<34, with: Data("../x".utf8))
        traversal.replaceSubrange((central + 46)..<(central + 50), with: Data("../x".utf8))
        XCTAssertThrowsError(try StoredZIP.read(traversal))
        var corrupt = archive; corrupt[34] ^= 1
        XCTAssertThrowsError(try StoredZIP.read(corrupt))
        var compressed = archive; compressed[8] = 8; compressed[central + 10] = 8
        XCTAssertThrowsError(try StoredZIP.read(compressed))
        var symlink = archive; symlink[central + 41] = 0xa0
        XCTAssertThrowsError(try StoredZIP.read(symlink))
        var bomb = archive
        bomb.replaceSubrange((central + 24)..<(central + 28), with: [255, 255, 255, 255])
        XCTAssertThrowsError(try StoredZIP.read(bomb))
        var descriptor = archive; descriptor[central + 8] |= 8
        XCTAssertThrowsError(try StoredZIP.read(descriptor))
    }
    func testTruncationAndRandomInvalidBytesNeverEscapeBounds() throws {
        let valid = try StoredZIP.write(["data.json": Data("payload".utf8)])
        for count in 0..<valid.count { XCTAssertThrowsError(try StoredZIP.read(valid.prefix(count))) }
        var seed: UInt64 = 12345
        for count in 0..<500 {
            let bytes = (0..<(count % 100)).map { _ -> UInt8 in
                seed = seed &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: seed >> 32)
            }
            XCTAssertThrowsError(try StoredZIP.read(Data(bytes)))
        }
        let files = Dictionary(uniqueKeysWithValues: (0...10000).map { ("\($0)", Data()) })
        XCTAssertThrowsError(try StoredZIP.write(files))
    }
    func testBackupMediaPathsRetainLegacyJPEGAndUsePNGExtension() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        XCTAssertEqual(BackupArchive.mediaPath(id), "media/00000000-0000-0000-0000-000000000011.jpg")
        XCTAssertEqual(BackupArchive.mediaPath(id, mediaType: "image/jpeg"), BackupArchive.mediaPath(id))
        XCTAssertEqual(BackupArchive.mediaPath(id, mediaType: "image/png"), "media/00000000-0000-0000-0000-000000000011.png")
        XCTAssertEqual(ImageEncodingPolicy.maximumBytes, 20_000_000)
        XCTAssertEqual(ImageEncodingPolicy.maximumPixels, 40_000_000)
    }
}


extension StoredZIPTests {
    func testDeflateIsOptInBoundedAndChecksIntegrity() throws {
        let fixture = Data(base64Encoded: "UEsDBBQAAAAIACNzS12fB9o8EwAAABEAAAALAAAAcGF5bG9hZC50eHRzSU3LSSxJTVFIzs8rSc0rKQYAUEsBAhQDFAAAAAgAI3NLXZ8H2jwTAAAAEQAAAAsAAAAAAAAAAAAAAIABAAAAAHBheWxvYWQudHh0UEsFBgAAAAABAAEAOQAAADwAAAAAAA==")!
        XCTAssertThrowsError(try StoredZIP.read(fixture))
        XCTAssertEqual(try StoredZIP.read(fixture, allowDeflate: true)["payload.txt"], Data("Deflated contents".utf8))
        var broken = fixture; broken[45] ^= 0xff
        XCTAssertThrowsError(try StoredZIP.read(broken, allowDeflate: true))
        XCTAssertThrowsError(try StoredZIP.inflateZIP(Data([3, 0]), size: 50_000_001))
        XCTAssertThrowsError(try StoredZIP.inflateZIP(Data([3, 0]), size: 2_000_000))
        XCTAssertThrowsError(try StoredZIP.inflateZIP(Data([1, 2, 3]), size: 10))
    }
}
