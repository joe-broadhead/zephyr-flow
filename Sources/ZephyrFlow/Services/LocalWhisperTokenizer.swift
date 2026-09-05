import Foundation
import Hub
import NaturalLanguage
import Tokenizers
import WhisperKit
import ZephyrFlowCore

enum LocalTokenizerError: Error {
    case missingOrInvalidFile
    case incompatibleTokenizer
    case incompatibleModel
}

/// Compatibility for the three existing multilingual model selections, not
/// an authenticity claim. No English-only or large-model tokenizer may be
/// silently substituted. The native tensor shapes are checked after loading.
struct LocalWhisperModelContract {
    let encoderWidth: Int
    static let vocabularySize = 51_865

    init(model: ModelIdentifier) throws {
        switch model {
        case .whisperTiny: encoderWidth = 384
        case .whisperBase: encoderWidth = 512
        case .whisperSmall: encoderWidth = 768
        default: throw LocalTokenizerError.incompatibleModel
        }
    }

    func validate(logits: Int?, encoder: Int?) throws {
        guard logits == Self.vocabularySize, encoder == encoderWidth else {
            throw LocalTokenizerError.incompatibleModel
        }
    }
}

/// Loads only the two files inside the selected verified artifact. There is
/// no repository search, shared-cache fallback or remote factory call here.
/// Parsing uses the dependency's binary-distinct JSON parser, preserving
/// vocabulary entries that Swift String equality might otherwise coalesce.
final class LocalWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    static let requiredTokens: [String: Int] = [
        "<|endoftext|>": 50_257, "<|startoftranscript|>": 50_258,
        "<|en|>": 50_259, "<|translate|>": 50_358,
        "<|transcribe|>": 50_359, "<|startofprev|>": 50_361,
        "<|nospeech|>": 50_362, "<|notimestamps|>": 50_363,
        "<|0.00|>": 50_364, "<|30.00|>": 51_864, "Ġ": 220,
    ]

    static func load(from folder: URL, model: ModelIdentifier) throws -> LocalWhisperTokenizer {
        _ = try LocalWhisperModelContract(model: model)
        let configuration = folder.appendingPathComponent("tokenizer_config.json")
        let vocabulary = folder.appendingPathComponent("tokenizer.json")
        for file in [configuration, vocabulary] {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                let bytes = values.fileSize, bytes > 0, bytes <= 64 * 1024 * 1024
            else { throw LocalTokenizerError.missingOrInvalidFile }
        }
        // This client is used exclusively for configuration(fileURL:), a
        // synchronous local parse API. Do not use .shared, model-name loading,
        // or the dependency's remote tokenizer helper, even after parse errors.
        let localParser = HubApi(
            downloadBase: folder, hfToken: "", endpoint: "https://offline.invalid",
            useBackgroundSession: false, useOfflineMode: true)
        let config = try localParser.configuration(fileURL: configuration)
        let data = try localParser.configuration(fileURL: vocabulary)
        guard
            config.tokenizerClass.string() == "WhisperTokenizer"
                || config.tokenizerClass.string() == "WhisperTokenizerFast"
        else { throw LocalTokenizerError.incompatibleTokenizer }
        let parsed = try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: data, strict: true)
        return try LocalWhisperTokenizer(tokenizer: parsed)
    }

    init(tokenizer: any Tokenizer) throws {
        for id in 0..<LocalWhisperModelContract.vocabularySize {
            guard let token = tokenizer.convertIdToToken(id), tokenizer.convertTokenToId(token) == id else {
                throw LocalTokenizerError.incompatibleTokenizer
            }
        }
        for (token, expectedID) in Self.requiredTokens {
            guard tokenizer.convertTokenToId(token) == expectedID,
                tokenizer.convertIdToToken(expectedID) == token
            else { throw LocalTokenizerError.incompatibleTokenizer }
        }
        self.tokenizer = tokenizer
        specialTokens = SpecialTokens(
            endToken: 50_257, englishToken: 50_259, noSpeechToken: 50_362,
            noTimestampsToken: 50_363, specialTokenBegin: 50_257,
            startOfPreviousToken: 50_361, startOfTranscriptToken: 50_258,
            timeTokenBegin: 50_364, transcribeToken: 50_359,
            translateToken: 50_358, whitespaceToken: 220)
        // The selected multilingual tiny/base/small vocabulary has exactly
        // 99 language IDs between start-of-transcript and translate.
        allLanguageTokens = Set(50_259..<50_358)
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    /// Group complete Unicode pieces first, then whitespace-delimited words.
    /// Keep every input token (including incomplete trailing bytes) in order.
    /// Ambiguous replacement characters conservatively keep the rest of the
    /// stream together rather than split a partially decoded byte sequence.
    /// Final chunk decoding uses these groups for word timestamps. Missing or
    /// conflicting alignment causes incomplete review, never guessed stitching.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let whole = decode(tokens: tokenIds)
        let language = NLLanguageRecognizer.dominantLanguage(for: whole)?.rawValue
        let noSpaces = ["zh", "ja", "th", "lo", "my", "yue"].contains(language ?? "")
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        for (offset, token) in tokenIds.enumerated() {
            pending.append(token)
            let piece = decode(tokens: pending)
            if piece.contains("\u{fffd}"), offset != tokenIds.count - 1 { continue }
            let punctuation =
                !piece.isEmpty
                && piece.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.contains($0)
                }
            let startsWord =
                noSpaces || words.isEmpty || pending[0] >= specialTokens.specialTokenBegin
                || piece.first?.isWhitespace == true || punctuation
            if startsWord {
                words.append(piece)
                groups.append(pending)
            } else {
                words[words.count - 1] += piece
                groups[groups.count - 1].append(contentsOf: pending)
            }
            pending.removeAll(keepingCapacity: true)
        }
        return (words, groups)
    }
}

/// Overrides the only tokenizer acquisition hook used by the pinned loader.
/// Never call super.loadTokenizerIfNeeded(): its catch path contacts the Hub.
final class LocalTokenizerWhisperKit: WhisperKit {
    private let localTokenizer: LocalWhisperTokenizer
    private let contract: LocalWhisperModelContract

    init(folder: String, model: ModelIdentifier, tokenizer: LocalWhisperTokenizer) async throws {
        localTokenizer = tokenizer
        contract = try LocalWhisperModelContract(model: model)
        try await super.init(
            WhisperKitConfig(
                model: model.rawValue, modelFolder: folder,
                verbose: false, logLevel: .error, prewarm: false, load: false, download: false))
    }

    override func loadTokenizerIfNeeded() async throws {
        try contract.validate(logits: textDecoder.logitsSize, encoder: audioEncoder.embedSize)
        textDecoder.isModelMultilingual = true
        tokenizer = localTokenizer
        // WhisperKit 0.18's modelVariant setter is private. Zephyr uses its
        // selected-model identity and checked tensor dimensions, not that
        // library diagnostic property (which remains its default .tiny).
    }
}
