import Foundation

/// Locates tokenizer files only within the explicitly selected model's cache
/// namespace. This is acquisition staging, not verification or authenticity.
/// A tokenizer found for another model must never satisfy this lookup.
public enum WhisperTokenizerLocator: Sendable {
    public static func locate(model: ModelIdentifier, roots: [URL]? = nil) -> URL? {
        let name: String
        switch model {
        case .whisperTiny: name = "whisper-tiny"
        case .whisperBase: name = "whisper-base"
        case .whisperSmall: name = "whisper-small"
        default: return nil
        }
        let fm = FileManager.default
        for root in roots ?? defaultRoots(fm: fm) {
            // swift-transformers' HubApi layout (with or without models/).
            for relative in ["openai/\(name)", "models/openai/\(name)"] {
                let candidate = root.appendingPathComponent(relative)
                if containsTokenizer(candidate) { return candidate }
            }
            // Python Hub layout: select refs/main, never an arbitrary old
            // snapshot. If no ref exists, accept only one unambiguous snapshot.
            let repository = root.appendingPathComponent("models--openai--\(name)")
            let snapshots = repository.appendingPathComponent("snapshots")
            let reference = repository.appendingPathComponent("refs/main")
            if fm.fileExists(atPath: reference.path) {
                guard let metadata = try? reference.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    metadata.isRegularFile == true, let bytes = metadata.fileSize, bytes > 0, bytes <= 128,
                    let data = try? Data(contentsOf: reference), data.count <= 128,
                    let text = String(data: data, encoding: .utf8)
                else { continue }
                let revision = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard [40, 64].contains(revision.count), revision.allSatisfy({ $0.isHexDigit }) else { continue }
                let candidate = snapshots.appendingPathComponent(revision)
                if containsTokenizer(candidate) { return candidate }
            } else if let entries = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) {
                let candidates = entries.filter { containsTokenizer($0) }
                if candidates.count == 1 { return candidates[0] }
            }
        }
        return nil
    }

    private static func defaultRoots(fm: FileManager) -> [URL] {
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        candidates.append(home.appendingPathComponent(".cache/huggingface/hub"))
        candidates.append(home.appendingPathComponent("Documents/huggingface/models"))
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("ZephyrFlow/Models"))
            candidates.append(appSupport.appendingPathComponent("huggingface"))
        }
        return candidates
    }

    private static func containsTokenizer(_ directory: URL) -> Bool {
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            let file = directory.appendingPathComponent(name)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true, (values.fileSize ?? 0) > 0
            else { return false }
        }
        return true
    }
}
