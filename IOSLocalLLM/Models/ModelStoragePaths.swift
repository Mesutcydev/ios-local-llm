import Foundation

// Adapted from OnDevice Core (MIT; see LICENSE and Docs/COREAI_COMPARISON.md).
enum ModelStoragePaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var modelRoots: [URL] {
        ["LLMModels", "HFModels", "GGUFModels"].map {
            documents.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Resolve symlinks as well as `..`; a lexical prefix is insufficient.
    static func isInside(root: URL, _ url: URL) -> Bool {
        guard root.isFileURL, url.isFileURL else { return false }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// Persisted absolute URLs survive backups, but container UUIDs do not.
    /// Keep recovery limited to a model's original root and folder name.
    static func recoveredModelDirectory(for storedURL: URL, roots: [URL] = modelRoots) -> URL? {
        guard storedURL.isFileURL else { return nil }
        let fm = FileManager.default
        func existingDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if roots.contains(where: { isInside(root: $0, storedURL) }), existingDirectory(storedURL) {
            return storedURL
        }
        let components = storedURL.standardizedFileURL.pathComponents
        guard components.count >= 3, components[components.count - 3] == "Documents",
              let root = roots.first(where: { $0.lastPathComponent == components[components.count - 2] }) else {
            return nil
        }
        let candidate = root.appendingPathComponent(storedURL.lastPathComponent, isDirectory: true)
        return isInside(root: root, candidate) && existingDirectory(candidate) ? candidate : nil
    }
}
