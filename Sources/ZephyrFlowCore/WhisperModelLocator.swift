import Foundation

/// Locates on-disk WhisperKit model folders (no network).
public enum WhisperModelLocator: Sendable {
    public static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        roots.append(home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml"))
        roots.append(home.appendingPathComponent(".cache/huggingface/hub"))
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(appSupport.appendingPathComponent("ZephyrFlow/Models"))
            roots.append(appSupport.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml"))
            roots.append(appSupport.appendingPathComponent("argmaxinc/whisperkit-coreml"))
        }
        return roots
    }

    /// Returns directory URL if a usable model folder exists.
    public static func locate(_ model: ModelIdentifier) -> URL? {
        guard model.isWhisperKit, let folder = model.whisperKitFolderName else { return nil }
        let fm = FileManager.default

        for root in candidateRoots() {
            let direct = root.appendingPathComponent(folder)
            if isLikelyModelDir(direct) { return direct }

            // HF hub layout: models--argmaxinc--whisperkit-coreml/snapshots/.../openai_whisper-tiny
            if root.lastPathComponent == "hub" || root.path.contains("huggingface") {
                if let found = findNamedFolder(named: folder, under: root, fm: fm) {
                    return found
                }
            }
        }
        return nil
    }

    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true,
                let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    public static func readiness(for model: ModelIdentifier) -> ModelReadiness {
        if !model.isWhisperKit {
            return .notApplicable
        }
        if let url = locate(model) {
            return ModelReadiness(state: .ready, bytesOnDisk: directorySize(url))
        }
        return ModelReadiness(state: .missing)
    }

    // MARK: - Private

    private static func isLikelyModelDir(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // WhisperKit Core ML bundles usually contain .mlmodelc or config.json
        let fm = FileManager.default
        if let kids = try? fm.contentsOfDirectory(atPath: url.path) {
            if kids.contains(where: { $0.hasSuffix(".mlmodelc") || $0 == "config.json" || $0.hasSuffix(".json") }) {
                return true
            }
            // Non-empty folder with substantial size
            if directorySize(url) > 1_000_000 { return true }
        }
        return false
    }

    private static func findNamedFolder(named: String, under root: URL, fm: FileManager) -> URL? {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var depth = 0
        for case let url as URL in enumerator {
            depth += 1
            if depth > 5000 { break }
            if url.lastPathComponent == named, isLikelyModelDir(url) {
                return url
            }
        }
        return nil
    }
}
