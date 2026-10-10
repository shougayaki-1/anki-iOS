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
        guard store.isFileDescendant(of: root), FileManager.default.fileExists(atPath: store.path) else { throw BackupError.invalidData }
        return store
    }
    func restorationStore(id: UUID) -> URL {
        canonicalStore.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("Restores/\(id.uuidString)/Study.store")
    }
    func activate(id: UUID) throws {
        let value = Pointer(schemaVersion: 1, relativePath: "Restores/\(id.uuidString)/Study.store")
        try JSONEncoder().encode(value).write(to: pointer, options: .atomic)
    }
}

extension URL {
    // Directory URL paths can retain a trailing slash on iOS. Compare resolved
    // components so that slash spelling and /var aliases do not reject children.
    func isFileDescendant(of root: URL) -> Bool {
        guard isFileURL, root.isFileURL else { return false }
        let parent = root.resolvedFileLocation.pathComponents
        let child = resolvedFileLocation.pathComponents
        return child.count > parent.count && child.starts(with: parent)
    }
    private var resolvedFileLocation: URL {
        // resolvingSymlinksInPath may leave a nonexistent final path unchanged.
        // Resolve its nearest existing ancestor before appending missing names.
        var ancestor = self
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.pathComponents.count > 1 {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for name in missing.reversed() { result.appendPathComponent(name) }
        return result
    }
}
