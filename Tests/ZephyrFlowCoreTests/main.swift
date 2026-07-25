import Foundation
import ZephyrFlowCore

@main
struct CoreTests {
    static func main() async {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  ✓ \(name)")
            } else {
                print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                failed += 1
            }
        }

        print("ZephyrFlowCore tests\n")

        let processor = FlowProcessor()

        // Raw
        do {
            let out = await processor.process("  um hello world  ", style: .raw)
            check("raw passthrough trims", out == "um hello world", out)
        }

        // Clean fillers
        do {
            let out = await processor.process("um I think uh we should, you know, ship it", style: .clean)
            check("clean strips um", !out.lowercased().contains("um"), out)
            check("clean strips uh", !out.lowercased().split(separator: " ").contains("uh"), out)
            check("clean strips you know", !out.lowercased().contains("you know"), out)
            check("clean keeps ship", out.lowercased().contains("ship"), out)
            check("clean capitalizes", out.first?.isUppercase == true, out)
        }

        // Empty
        do {
            let out = await processor.process("   ", style: .clean)
            check("empty → empty", out.isEmpty)
        }

        // Bullets
        do {
            let out = await processor.process("Buy milk. Call mom. Ship the release.", style: .bullets)
            let lines = out.split(separator: "\n")
            check("bullets has multiple lines", lines.count >= 2, out)
            check("bullets prefix", lines.allSatisfy { $0.hasPrefix("•") }, out)
        }

        // Professional
        do {
            let out = await processor.process("I can't ship this yet", style: .professional)
            check("professional expands can't", out.lowercased().contains("cannot"), out)
            check("professional drops contraction", !out.contains("can't"), out)
        }

        // Summary
        do {
            let input = "We need to ship today. The build is green. Stakeholders are waiting for the demo this afternoon."
            let out = await processor.process(input, style: .summary)
            check("summary non-empty", !out.isEmpty, out)
            check("summary not longer", out.count <= input.count, out)
        }

        // Settings defaults (privacy posture)
        do {
            let s = AppSettings.default
            check("local only default", s.localOnlyMode)
            check("downloads on by default", s.allowModelDownloads)
            check("mayDownload follows allow flag", s.mayDownloadModels)
            check("default model whisper tiny", s.preferredModel == .whisperTiny)
            check("default hotkey fn", s.hotkey.specialKey == .fn)
            check("debug logging off", !s.debugLogging)
            check("save history default on", s.saveHistory)
        }

        // Download gate (model files only — independent of Local Only audio policy)
        do {
            var s = AppSettings.default
            s.allowModelDownloads = false
            check("mayDownload off when flag off", !s.mayDownloadModels)
            s.allowModelDownloads = true
            s.localOnlyMode = true
            check("localOnly still allows model download flag", s.mayDownloadModels)
        }

        // Codable round-trip
        do {
            let original = AppSettings.default
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            check("settings round-trip", original == decoded)
        } catch {
            check("settings round-trip", false, error.localizedDescription)
        }

        // InsertionResult
        check("inserted succeeds", InsertionResult.inserted.succeeded)
        check("copied message", InsertionResult.copiedToClipboard.userMessage == "Copied to clipboard")
        check("failed fails", !InsertionResult.failed("x").succeeded)

        // Streaming partial window policy (Whisper progressive decode)
        do {
            check(
                "partial needs >= 1s audio",
                !StreamingPartialWindow.canRunPartial(sampleCount: StreamingPartialWindow.minPartialSamples - 1)
            )
            check(
                "partial ok at 1s",
                StreamingPartialWindow.canRunPartial(sampleCount: StreamingPartialWindow.minPartialSamples)
            )
            let short = [Float](repeating: 0.1, count: 100)
            let slicedShort = StreamingPartialWindow.sliceForPartial(short)
            check("short slice is identity", slicedShort.count == short.count)

            let longCount = StreamingPartialWindow.windowSamples + 500
            var long = [Float](repeating: 0, count: longCount)
            long[longCount - 1] = 0.99
            let sliced = StreamingPartialWindow.sliceForPartial(long)
            check("long slice capped", sliced.count == StreamingPartialWindow.windowSamples)
            check("long slice keeps newest", abs(sliced.last! - 0.99) < 0.0001)
            check("interval positive", StreamingPartialWindow.intervalNanoseconds > 0)
        }

        // Insertion strategy resolver
        do {
            let term = InsertionStrategyResolver.strategies(
                bundleID: "com.apple.Terminal", role: nil, mode: .automatic
            )
            check("terminal leads with terminalPaste", term.first == .terminalPaste)
            let secure = InsertionStrategyResolver.strategies(
                bundleID: "com.apple.Notes", role: "AXSecureTextField", mode: .automatic
            )
            check("secure is copyOnly only", secure == [.copyOnly])
            let copyMode = InsertionStrategyResolver.strategies(
                bundleID: "com.apple.Notes", role: nil, mode: .alwaysCopy
            )
            check("alwaysCopy", copyMode == [.copyOnly])
        }

        // Flow guardrails
        do {
            check(
                "guard accepts same numbers",
                FlowGuardrails.accept(input: "pay 12000 now", output: "Pay 12,000 now.") != nil
            )
            check(
                "guard rejects novel number",
                FlowGuardrails.accept(input: "pay 100 now", output: "Pay 999 now.") == nil
            )
            check(
                "guard rejects preamble",
                FlowGuardrails.accept(input: "hello", output: "Sure, hello there") == nil
            )
        }

        // Settings defaults for new fields
        do {
            let s = AppSettings.default
            check("flow backend regex default", s.flowBackend == .regex)
            check("insertion automatic default", s.insertionMode == .automatic)
            check("panel not locked default", !s.panelPositionLocked)
        }

        print("")
        if failed == 0 {
            print("All tests passed.")
            exit(0)
        } else {
            print("\(failed) test(s) failed.")
            exit(1)
        }
    }
}
