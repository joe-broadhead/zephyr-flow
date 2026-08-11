import Foundation

/// Round-6 B4: locates the WhisperKit tokenizer directory (tokenizer.json +
/// configuration files) on disk. WhisperKit stores the tokenizer separately
/// from the model in its Hub cache; the acquisition pipeline stages a private
/// copy so verified loading never falls back to a Hub download.
public enum WhisperTokenizerLocator: Sendable {
    public static func locate() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        // Common WhisperKit / HF hub tokenizer locations.
        candidates.append(home.appendingPathComponent(".cache/huggingface/hub"))
        candidates.append(home.appendingPathComponent("Documents/huggingface/models"))
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("ZephyrFlow/Models"))
            candidates.append(appSupport.appendingPathComponent("huggingface"))
        }
        for root in candidates {
            if let found = findTokenizerDir(under: root, fm: fm) {
                return found
            }
        }
        return nil
    }

    private static func findTokenizerDir(under root: URL, fm: FileManager) -> URL? {
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var depth = 0
        for case let url as URL in enumerator {
            depth += 1
            if depth > 5000 { break }
            guard url.lastPathComponent != "snapshots",
                let kids = try? fm.contentsOfDirectory(atPath: url.path)
            else { continue }
            // A directory holding tokenizer.json (with or without friends).
            if kids.contains("tokenizer.json") || kids.contains("vocab.json") {
                if kids.contains("tokenizer.json") || kids.contains("merges.txt") {
                    return url
                }
            }
        }
        return nil
    }
}
