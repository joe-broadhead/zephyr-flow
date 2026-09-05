#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    final class ProductionOfflineTokenizerTests: XCTestCase {
        private func folder() throws -> URL {
            // Directory enumeration on macOS can return the /private/var
            // spelling even when the caller supplied /var. Compare canonical
            // fixture paths, not two aliases of the same selected directory.
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("zf-tokenizer-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
            return root
        }

        /// Synthetic BPE vocabulary with the existing model's dimensions and
        /// special-token IDs. This is not downloaded data or an inference test.
        private func writeFixture(to folder: URL, wrongEndToken: Bool = false) throws {
            var words = (0..<LocalWhisperModelContract.vocabularySize).map { "synthetic_\($0)" }
            words[0] = "h"
            words[1] = "i"
            // ByteLevel spellings of the UTF-8 bytes for é and U+FFFD.
            words[2] = "Ã"
            words[3] = "©"
            words[4] = "ï"
            words[5] = "¿"
            words[6] = "½"
            for (token, id) in LocalWhisperTokenizer.requiredTokens { words[id] = token }
            if wrongEndToken { words[50_257] = "wrong_end_token" }
            let vocabulary = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element, $0.offset) })
            let configuration: [String: Any] = [
                "tokenizer_class": "WhisperTokenizer", "unk_token": "<|endoftext|>",
                "bos_token": "<|endoftext|>", "eos_token": "<|endoftext|>",
            ]
            let data: [String: Any] = [
                "model": ["type": "BPE", "vocab": vocabulary, "merges": []],
                "pre_tokenizer": ["type": "ByteLevel", "add_prefix_space": false, "use_regex": true],
                "decoder": ["type": "ByteLevel"],
                "added_tokens": [],
            ]
            try JSONSerialization.data(withJSONObject: configuration).write(
                to: folder.appendingPathComponent("tokenizer_config.json"))
            try JSONSerialization.data(withJSONObject: data).write(
                to: folder.appendingPathComponent("tokenizer.json"))
        }

        func testLocalParserLoadsSyntheticVocabularyAndPreservesWordTokens() throws {
            let root = try folder()
            try writeFixture(to: root)
            let tokenizer = try LocalWhisperTokenizer.load(from: root, model: .whisperTiny)
            XCTAssertEqual(tokenizer.convertTokenToId("<|endoftext|>"), 50_257)
            XCTAssertEqual(tokenizer.allLanguageTokens.count, 99)
            XCTAssertEqual(tokenizer.encode(text: "hi"), [0, 1])
            XCTAssertEqual(tokenizer.decode(tokens: [0, 1, 220, 0, 1]), "hi hi")
            let ids = [0, 1, 220, 0, 1]
            let grouped = tokenizer.splitToWordTokens(tokenIds: ids)
            XCTAssertEqual(grouped.wordTokens.flatMap { $0 }, ids)
            XCTAssertEqual(grouped.words.joined(), "hi hi")
            XCTAssertTrue(tokenizer.splitToWordTokens(tokenIds: []).words.isEmpty)
            let unicodeIDs = [2, 3, 220, 4, 5, 6]
            let unicode = tokenizer.splitToWordTokens(tokenIds: unicodeIDs)
            XCTAssertEqual(tokenizer.decode(tokens: unicodeIDs), "é \u{fffd}")
            XCTAssertEqual(unicode.words.joined(), "é \u{fffd}")
            XCTAssertEqual(unicode.wordTokens.flatMap { $0 }, unicodeIDs)
        }

        func testMissingAndCorruptSelectedFolderNeverSearchesSiblingTokenizer() throws {
            let root = try folder()
            let sibling = root.appendingPathComponent("other-model")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try writeFixture(to: sibling)
            let selected = root.appendingPathComponent("selected-model")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            XCTAssertThrowsError(try LocalWhisperTokenizer.load(from: selected, model: .whisperTiny))
            try Data("not-json".utf8).write(to: selected.appendingPathComponent("tokenizer.json"))
            try Data("{}".utf8).write(to: selected.appendingPathComponent("tokenizer_config.json"))
            XCTAssertThrowsError(try LocalWhisperTokenizer.load(from: selected, model: .whisperTiny))
        }

        func testWrongSpecialTokenIDsAreRejected() throws {
            let root = try folder()
            try writeFixture(to: root, wrongEndToken: true)
            XCTAssertThrowsError(try LocalWhisperTokenizer.load(from: root, model: .whisperBase)) { error in
                guard case LocalTokenizerError.incompatibleTokenizer = error else {
                    return XCTFail("expected a tokenizer compatibility failure")
                }
            }
        }

        func testTokenizerSymlinkIsRejectedRatherThanFollowingSharedCache() throws {
            let root = try folder()
            let selected = root.appendingPathComponent("selected")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: selected.appendingPathComponent("tokenizer_config.json"))
            let external = root.appendingPathComponent("external.json")
            try Data("{}".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(
                at: selected.appendingPathComponent("tokenizer.json"), withDestinationURL: external)
            XCTAssertThrowsError(try LocalWhisperTokenizer.load(from: selected, model: .whisperSmall))
        }

        func testNativeShapeContractRejectsWrongModelAndEnglishOnlyVocabulary() throws {
            let contract = try LocalWhisperModelContract(model: .whisperTiny)
            XCTAssertNoThrow(try contract.validate(logits: 51_865, encoder: 384))
            XCTAssertThrowsError(try contract.validate(logits: 51_864, encoder: 384))
            XCTAssertThrowsError(try contract.validate(logits: 51_865, encoder: 512))
            XCTAssertThrowsError(try contract.validate(logits: nil, encoder: nil))
        }

        private func writeLocatorFiles(_ directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["tokenizer.json", "tokenizer_config.json"] {
                try Data("synthetic locator metadata".utf8).write(to: directory.appendingPathComponent(name))
            }
        }

        func testAcquisitionLocatorCannotSubstituteAnotherModelsTokenizer() throws {
            let root = try folder()
            let base = root.appendingPathComponent("openai/whisper-base")
            try writeLocatorFiles(base)
            XCTAssertNil(WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root]))
            XCTAssertEqual(WhisperTokenizerLocator.locate(model: .whisperBase, roots: [root])?.path, base.path)
            let tiny = root.appendingPathComponent("openai/whisper-tiny")
            try writeLocatorFiles(tiny)
            XCTAssertEqual(WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root])?.path, tiny.path)
            try FileManager.default.removeItem(at: tiny.appendingPathComponent("tokenizer_config.json"))
            XCTAssertNil(WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root]))
        }

        func testAcquisitionLocatorRequiresUnambiguousSnapshotOrExplicitRef() throws {
            let root = try folder()
            let repository = root.appendingPathComponent("models--openai--whisper-tiny")
            let firstID = String(repeating: "a", count: 40)
            let secondID = String(repeating: "b", count: 40)
            let first = repository.appendingPathComponent("snapshots/\(firstID)")
            let second = repository.appendingPathComponent("snapshots/\(secondID)")
            try writeLocatorFiles(first)
            XCTAssertEqual(WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root])?.path, first.path)
            try writeLocatorFiles(second)
            XCTAssertNil(WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root]))
            let refs = repository.appendingPathComponent("refs")
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            try Data(secondID.utf8).write(to: refs.appendingPathComponent("main"))
            XCTAssertEqual(WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root])?.path, second.path)
            try Data("invalid reference".utf8).write(to: refs.appendingPathComponent("main"))
            XCTAssertNil(WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root]))
        }

        func testRuntimeRefusesIdentifierOnlyAndMissingLocalTokenizerBeforeNativeLoad() async throws {
            do {
                _ = try await WhisperKitRuntime.load(
                    WhisperRuntimeConfiguration(model: .whisperTiny, verifiedFolder: nil, allowDownload: false))
                XCTFail("no unverified identifier/cache fallback")
            } catch {}
            let root = try folder()
            do {
                _ = try await WhisperKitRuntime.load(
                    WhisperRuntimeConfiguration(
                        model: .whisperTiny, verifiedFolder: root.path, allowDownload: true))
                XCTFail("verified-folder failure must not turn into a consented remote lookup")
            } catch {}
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
