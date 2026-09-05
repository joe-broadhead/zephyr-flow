import Foundation

// Swift 6.1's swift-format uses a synthesized Codable enum for this option:
// https://github.com/swiftlang/swift-format/blob/swift-6.1.2-RELEASE/Sources/SwiftFormat/API/Configuration.swift
// This checks that wire shape; it is not an execution of the old formatter.
enum LegacyReflowBehavior: Codable {
    case never
    case onlyLinesOverLength
    case always
}

struct LegacyFormatterConfiguration: Decodable {
    let reflowMultilineStringLiterals: LegacyReflowBehavior
}

guard CommandLine.arguments.count == 2 else { exit(64) }
do {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let configuration = try JSONDecoder().decode(
        LegacyFormatterConfiguration.self, from: Data(contentsOf: url))
    guard case .never = configuration.reflowMultilineStringLiterals else { exit(3) }
} catch is DecodingError {
    print("Incompatible configuration encoding")
    exit(1)
} catch {
    print("Unable to read configuration fixture")
    exit(2)
}
