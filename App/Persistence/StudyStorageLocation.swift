import Foundation

struct StudyStorageLocation: Sendable {
    let canonicalStore: URL
    static var defaultStore: URL { URL.applicationSupportDirectory.appendingPathComponent("Study/Study.store") }
    var pointer: URL { canonicalStore.deletingPathExtension().appendingPathExtension("active.json") }

    private struct Pointer: Codable { let schemaVersion: Int; let relativePath: String }
    func activeStore() throws -> URL {
        guard FileManager.default.fileExists(atPath: pointer.path) else { return canonicalStore }
        let size = try pointer.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4096 else { throw BackupError.invalidData }
        let value = try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: pointer))
        guard value.schemaVersion == 1 else { throw BackupError.unsupportedVersion }
        let pieces = value.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "Restores", UUID(uuidString: String(pieces[1])) != nil,
              pieces[2] == "Study.store" else { throw BackupError.invalidData }
        let root = canonicalStore.deletingLastPathComponent().resolvingSymlinksInPath()
        let store = root.appendingPathComponent(value.relativePath).resolvingSymlinksInPath()
        guard store.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: store.path) else { throw BackupError.invalidData }
        return store
    }
    func restorationStore(id: UUID) -> URL {
        canonicalStore.deletingLastPathComponent().appendingPathComponent("Restores/\(id.uuidString)/Study.store")
    }
    func activate(id: UUID) throws {
        let value = Pointer(schemaVersion: 1, relativePath: "Restores/\(id.uuidString)/Study.store")
        try JSONEncoder().encode(value).write(to: pointer, options: .atomic)
    }
}
