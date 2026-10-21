import AppKit
import XCTest
@testable import ShellCopyCore

final class ClipboardControllerTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var defaults: UserDefaults!
    private var suite: String!
    private let first = "This detailed deployment report explains the remaining work for the next"
    private var wrapped: String { first + "\n        release." }
    private var joined: String { first + " release." }

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = try XCTUnwrap(NSPasteboard.withUniqueName() as NSPasteboard?, "Test process cannot access the macOS pasteboard server; run outside the agent sandbox.")
        suite = "ShellCopyTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // Existing cases lock down AI-only behavior; hybrid has dedicated integration coverage.
        defaults.set(false, forKey: ClipboardController.hybridKey)
    }

    override func tearDown() {
        pasteboard?.releaseGlobally()
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
    }

    @MainActor
    func testHybridDefaultsOnPersistsOptOutAndSkipsAIWhenRulesChangeText() async throws {
        defaults.removeObject(forKey: ClipboardController.hybridKey)
        let input = "seedmux-lite-\n  team"
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
            cloudNormalize: { text in
                XCTFail("A local correction must not reach AI")
                return NormalizationReport(text: text, provider: .bjev,
                    decisions: [.init(nextLine: 2, joinProbability: 0.71, spaceProbability: 0.6)], noRequestReason: nil)
            })
        XCTAssertTrue(controller.isHybridEnabled)
        controller.setEnabled(true)
        controller.setProvider(.bjev)
        copy(input)
        let finished = expectation(description: "hybrid output applied")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        controller.poll()
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.string(forType: .string), "seedmux-lite-team")
        XCTAssertEqual(controller.cloudMessage, "Local rules joined wrapped lines; no cloud request.")
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), input)
        controller.setHybridEnabled(false)
        XCTAssertFalse(ClipboardController(pasteboard: pasteboard, defaults: defaults).isHybridEnabled)
    }

    @MainActor
    func testRulesFirstSendsUnchangedTextToEachProvider() async throws {
        let input = "We need\nmore checks."
        XCTAssertEqual(LineNormalizer.normalize(input), input)
        for provider in [CloudProvider.jev, .bjev] {
            var calls = 0
            let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                cloudNormalize: { text in
                    calls += 1
                    XCTAssertEqual(text, input)
                    return NormalizationReport(text: "We need more checks.", provider: provider,
                        decisions: [.init(nextLine: 2, joinProbability: 1, spaceProbability: 1)],
                        noRequestReason: nil)
                })
            controller.setEnabled(true)
            controller.setProvider(provider)
            controller.setHybridEnabled(true)
            copy(input)
            let finished = expectation(description: "model reviewed unchanged copy")
            controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
            controller.poll()
            await fulfillment(of: [finished], timeout: 1)
            controller.onStateChange = nil
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(pasteboard.string(forType: .string), "We need more checks.")
            XCTAssertTrue(controller.restoreOriginal())
            XCTAssertEqual(pasteboard.string(forType: .string), input)
        }
    }

    func testRulesFirstWorksWithoutKeyAndStopsAfterPartialCorrection() {
        let input = wrapped + "\n\nWe need\nmore checks."
        let expected = joined + "\n\nWe need\nmore checks."
        for provider in [CloudProvider.jev, .bjev] {
            let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
            controller.setEnabled(true)
            controller.setProvider(provider)
            controller.setHybridEnabled(true)
            copy(input)
            controller.poll()
            XCTAssertFalse(controller.isProcessing)
            XCTAssertEqual(pasteboard.string(forType: .string), expected)
            XCTAssertEqual(controller.cloudMessage, "Local rules joined wrapped lines; no cloud request.")
            XCTAssertTrue(controller.restoreOriginal())
            XCTAssertEqual(pasteboard.string(forType: .string), input)
        }
    }

    @MainActor
    func testHybridModeChangeCancelsPendingCopyAndDoesNotRewriteBaseline() async throws {
        let gate = CloudGate(started: expectation(description: "request started"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { try await gate.run($0) })
        controller.setEnabled(true)
        controller.setProvider(.bjev)
        copy(wrapped)
        controller.poll()
        await fulfillment(of: [gate.started], timeout: 1)
        controller.setHybridEnabled(true)
        gate.reply(.success(joined))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(controller.isProcessing)
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        XCTAssertFalse(controller.canRestore)
    }

    func testPartialIdentifierSelectionJoinsAndRestoresExactOriginal() {
        let input = "seedmux-lite-\r\n  team"
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        copy(input)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), "seedmux-lite-team")
        XCTAssertTrue(controller.diagnosticDetails.contains("Local joins: 1"))
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), input)
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    @MainActor
    func testPurePasteMetadataReachesAIAndSurvivesNormalizationAndUndo() async throws {
        let markers = ["com.sindresorhus.Pure-Paste.hasRun", "x.nspasteboard.ModifiedType"]
        for names in [[markers[0]], [markers[1]], markers] {
            var calls = 0
            let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                cloudNormalize: { [self] text in
                    calls += 1
                    XCTAssertEqual(text, wrapped)
                    return NormalizationReport(text: joined, provider: .bjev,
                        decisions: [.init(nextLine: 2, joinProbability: 1, spaceProbability: 1)],
                        noRequestReason: nil)
                })
            controller.setEnabled(true)
            controller.setProvider(.bjev)
            controller.setHybridEnabled(false)
            let item = NSPasteboardItem()
            item.setString(wrapped, forType: .string)
            for name in names { item.setData(Data(), forType: .init(name)) }
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([item]))
            let finished = expectation(description: "marked copy handled")
            controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
            controller.poll()
            await fulfillment(of: [finished], timeout: 1)
            controller.onStateChange = nil
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(pasteboard.string(forType: .string), joined)
            for name in names { XCTAssertEqual(pasteboard.data(forType: .init(name)), Data()) }
            controller.poll()
            XCTAssertEqual(calls, 1, "Our own write must not start another request")
            XCTAssertTrue(controller.restoreOriginal())
            XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
            for name in names { XCTAssertEqual(pasteboard.data(forType: .init(name)), Data()) }
        }
    }

    func testPurePasteMarkersDoNotBypassPrivateOrUnknownFormatProtection() {
        for blocked in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
                        "com.example.private-object"] {
            let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                cloudNormalize: { _ in
                    XCTFail("Protected clipboard reached AI")
                    throw JudgmentError.unavailable
                })
            controller.setEnabled(true)
            controller.setProvider(.bjev)
            let item = NSPasteboardItem()
            item.setString(wrapped, forType: .string)
            for type in ["com.sindresorhus.Pure-Paste.hasRun", "x.nspasteboard.ModifiedType", blocked] {
                item.setData(Data(), forType: .init(type))
            }
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([item]))
            let count = pasteboard.changeCount
            controller.poll()
            XCTAssertFalse(controller.isProcessing)
            XCTAssertEqual(pasteboard.changeCount, count)
            XCTAssertFalse(controller.canRestore)
            XCTAssertTrue(controller.diagnosticDetails.contains { $0.contains(blocked) })
            XCTAssertFalse(controller.diagnosticDetails.contains { $0.contains(wrapped) })
        }
    }

    @MainActor
    func testDiagnosticsDistinguishSkippedRequestFromLowCloudScore() async throws {
        for usesCloud in [false, true] {
            let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                cloudNormalize: { text in
                    NormalizationReport(text: text, provider: .bjev,
                        decisions: usesCloud ? [.init(nextLine: 2, joinProbability: 0.79, spaceProbability: 1)] : [],
                        noRequestReason: usesCloud ? nil : "No line breaks.")
                })
            controller.setEnabled(true)
            controller.setProvider(.bjev)
            copy(usesCloud ? "We need\nmore checks." : "single line")
            let finished = expectation(description: "diagnostics ready")
            controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
            controller.poll()
            await fulfillment(of: [finished], timeout: 1)
            controller.onStateChange = nil
            XCTAssertEqual(controller.cloudMessage, usesCloud
                ? "bjev returned: 0/1 joins (AI-led)."
                : "bjev not requested; original text kept.")
            XCTAssertTrue(controller.diagnosticDetails.contains { $0.hasPrefix("Processing time: ") })
            XCTAssertTrue(controller.diagnosticDetails.contains("Clipboard unchanged."))
            if usesCloud {
                XCTAssertTrue(controller.diagnosticDetails.contains { $0.contains("wrap=0.79") && $0.contains("below threshold") })
            }
            copy("new single line")
            controller.setProvider(nil)
            XCTAssertTrue(controller.diagnosticDetails.isEmpty)
            XCTAssertNil(controller.cloudMessage)
        }
    }

    func testAIFailureDefaultsToKeepingOriginalAndExplicitFallbackPersists() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        XCTAssertFalse(controller.isLocalFallbackEnabled)
        controller.setEnabled(true)
        controller.setProvider(.jev)
        copy("seedmux-lite-\n  team")
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertFalse(controller.canRestore)
        XCTAssertTrue(controller.diagnosticDetails.contains("Local fallback disabled."))
        controller.setLocalFallbackEnabled(true)
        let reopened = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        XCTAssertTrue(reopened.isLocalFallbackEnabled)
    }

    func testWarpPartialJoinAndRestorePreserveOriginalBreaks() {
        let first = "我需要写一个客群创编的skill 这是我之前梳理的客群skill原子能力："
        let next = "notes/2026-09-24-segment-authoring-skill-research.md，你结合代码帮我出"
        let last = "一个技术方案，使用AI unslop这个skill写作"
        let original = first + "\n  " + next + "\n  " + last
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        copy(original)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), first + "\n  " + next + last)
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    func testClippedBulletSelectionJoinsAndRestoresOriginal() {
        let first = "• 当前必要修复：统一参与链路的加锁顺序。批量启停应在修改配置和业务表之前，按 ID 顺序获取全部 profile 锁；不能只给回调排序。同时核实并限制 MNS 等待时"
        let next = "间、批次大小和并发数，补 MySQL 并发回归。"
        let original = first + "\n    " + next
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        copy(original)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), first + next)
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    func testProviderSelectionMigratesOldJevPreferenceAndPersistsEachChoice() {
        XCTAssertNil(ClipboardController(pasteboard: pasteboard, defaults: defaults).cloudProvider)
        defaults.set(true, forKey: ClipboardController.cloudEnabledKey)
        let upgraded = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        XCTAssertEqual(upgraded.cloudProvider, .jev)
        for provider: CloudProvider? in [.bjev, nil, .jev] {
            upgraded.setProvider(provider)
            let reopened = ClipboardController(pasteboard: pasteboard, defaults: defaults)
            XCTAssertEqual(reopened.cloudProvider, provider)
            XCTAssertEqual(reopened.isCloudEnabled, provider != nil)
        }
    }

    func testMissingBjevKeyUsesBjevStatusAndLocalFallback() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setLocalFallbackEnabled(true)
        controller.setEnabled(true)
        controller.setProvider(.bjev)
        copy(wrapped)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), joined)
        XCTAssertEqual(controller.cloudMessage, "bjev: Set an API key to use this service. Joined using local rules.")
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
    }

    func testFirstLaunchDisabledAndEnableDoesNotRewriteExistingCopy() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        XCTAssertFalse(controller.isEnabled)
        copy(wrapped)
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        controller.setEnabled(true)
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        copy(wrapped)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), joined)
        XCTAssertTrue(controller.canRestore)
    }

    func testPersistenceAndLaunchBaseline() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        copy(wrapped)
        let count = pasteboard.changeCount
        let reopened = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        XCTAssertTrue(reopened.isEnabled)
        reopened.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertFalse(reopened.canRestore)
        reopened.setEnabled(false)
        XCTAssertFalse(ClipboardController(pasteboard: pasteboard, defaults: defaults).isEnabled)
    }

    func testSelfWriteSuppressionRestoreAndDisabledMode() {
        var calls = 0
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults, normalize: { text in
            calls += 1
            return LineNormalizer.normalize(text)
        })
        controller.setEnabled(true)
        copy(wrapped)
        controller.poll()
        let transformedCount = pasteboard.changeCount
        for _ in 0..<3 { controller.poll() }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pasteboard.changeCount, transformedCount)
        controller.setEnabled(false)
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        let restoredCount = pasteboard.changeCount
        controller.poll()
        controller.setEnabled(true)
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, restoredCount)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(controller.canRestore)
        XCTAssertFalse(controller.restoreOriginal())
        controller.setEnabled(false)
        copy(wrapped)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        XCTAssertEqual(calls, 1)
    }

    func testRestoreWhileEnabledDoesNotReprocessAndRetainsEveryRepresentation() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        let item = NSPasteboardItem()
        item.setString(wrapped, forType: .string)
        let rtf = Data(#"{\rtf1\ansi original rich text}"#.utf8)
        let html = Data("<p>original rich text</p>".utf8)
        item.setData(rtf, forType: .rtf)
        item.setData(html, forType: .html)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let types = Set(pasteboard.pasteboardItems![0].types)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), joined)
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(Set(pasteboard.pasteboardItems![0].types), types)
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.data(forType: .html), html)
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    func testNewerExternalCopyDuringNormalizationWins() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults, normalize: { [self] text in
            copy("new external copy")
            return LineNormalizer.normalize(text)
        })
        controller.setEnabled(true)
        copy(wrapped)
        controller.poll()
        XCTAssertEqual(pasteboard.string(forType: .string), "new external copy")
        XCTAssertFalse(controller.canRestore)
    }

    func testNewerExternalCopyPreventsStaleRestoreEvenBeforePoll() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        copy(wrapped)
        controller.poll()
        copy("new external copy")
        let count = pasteboard.changeCount
        XCTAssertFalse(controller.canRestore)
        XCTAssertFalse(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.changeCount, count)
        controller.poll()
        XCTAssertFalse(controller.canRestore)
    }

    func testNoOpDoesNotRewriteAndClearsStaleRestore() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        copy(wrapped)
        controller.poll()
        copy("preserve\r\nthis")
        let count = pasteboard.changeCount
        let bytes = pasteboard.data(forType: .string)
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.data(forType: .string), bytes)
        XCTAssertFalse(controller.canRestore)
    }

    func testSkipsFileUnknownConcealedImageAndMultiItemContent() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        let types: [NSPasteboard.PasteboardType] = [
            .fileURL, .png, .rtfd, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("com.example.custom")
        ]
        for type in types {
            let item = NSPasteboardItem()
            item.setString(wrapped, forType: .string)
            let data = Data("must stay intact".utf8)
            item.setData(data, forType: type)
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([item]))
            let count = pasteboard.changeCount
            controller.poll()
            XCTAssertEqual(pasteboard.changeCount, count)
            XCTAssertEqual(pasteboard.data(forType: type), data)
        }
        let items = [NSPasteboardItem(), NSPasteboardItem()]
        for item in items { item.setString(wrapped, forType: .string) }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
    }

    func testRejectsOversizedSnapshot() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        let item = NSPasteboardItem()
        item.setString(wrapped, forType: .string)
        item.setData(Data(repeating: 32, count: 8 * 1_048_576), forType: .html)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertFalse(controller.canRestore)
    }

    @MainActor
    func testCloudWaitsThenJoinsAndRestoresAllRepresentations() async throws {
        let gate = CloudGate(started: expectation(description: "request started"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { try await gate.run($0) })
        XCTAssertFalse(controller.isCloudEnabled)
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        let item = NSPasteboardItem()
        item.setString(wrapped, forType: .string)
        let html = Data("<p>original</p>".utf8)
        item.setData(html, forType: .html)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertTrue(controller.isProcessing)
        XCTAssertEqual(pasteboard.changeCount, count)
        await fulfillment(of: [gate.started], timeout: 1)
        let finished = expectation(description: "request applied")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        gate.reply(.success(joined))
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.string(forType: .string), joined)
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        XCTAssertEqual(pasteboard.data(forType: .html), html)
        controller.poll()
        XCTAssertFalse(controller.isProcessing)
    }

    @MainActor
    func testCloudResultCannotOverwriteCopyThatArrivesBeforeNextPoll() async {
        let gate = CloudGate(started: expectation(description: "request started"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { try await gate.run($0) })
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        copy(wrapped)
        controller.poll()
        await fulfillment(of: [gate.started], timeout: 1)
        copy("new copy")
        let finished = expectation(description: "stale result discarded")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        gate.reply(.success(joined))
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
        XCTAssertFalse(controller.canRestore)
        XCTAssertNil(controller.cloudMessage)
        XCTAssertTrue(controller.diagnosticDetails.isEmpty)
    }

    @MainActor
    func testOutOfOrderCloudResponsesOnlyApplyToLatestCopy() async {
        let old = CloudGate(started: expectation(description: "old request"))
        let new = CloudGate(started: expectation(description: "new request"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { text in
            try await (text == "old\ncopy" ? old : new).run(text)
        })
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        copy("old\ncopy")
        controller.poll()
        await fulfillment(of: [old.started], timeout: 1)
        copy("new\ncopy")
        controller.poll()
        await fulfillment(of: [new.started], timeout: 1)
        let noStaleCompletion = expectation(description: "no stale completion")
        noStaleCompletion.isInverted = true
        controller.onStateChange = { noStaleCompletion.fulfill() }
        old.reply(.success("old copy"))
        await fulfillment(of: [noStaleCompletion], timeout: 0.1)
        XCTAssertTrue(controller.isProcessing)
        XCTAssertEqual(pasteboard.string(forType: .string), "new\ncopy")
        let finished = expectation(description: "new request applied")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        new.reply(.success("new copy"))
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), "new\ncopy")
    }

    @MainActor
    func testModeAndKeyChangesInvalidatePendingResults() async {
        for change in 0..<5 {
            let gate = CloudGate(started: expectation(description: "request \(change)"))
            let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                                 cloudNormalize: { try await gate.run($0) })
            controller.setEnabled(true)
            controller.setCloudEnabled(true)
            controller.setLocalFallbackEnabled(true)
            copy(wrapped)
            controller.poll()
            await fulfillment(of: [gate.started], timeout: 1)
            switch change {
            case 0: controller.setEnabled(false)
            case 1: controller.setCloudEnabled(false)
            case 2: controller.setCloudNormalizer(nil)
            case 3: controller.setLocalFallbackEnabled(false)
            default: controller.setProvider(.bjev)
            }
            let noCompletion = expectation(description: "cancelled request ignored")
            noCompletion.isInverted = true
            controller.onStateChange = { noCompletion.fulfill() }
            gate.reply(.success(joined))
            await fulfillment(of: [noCompletion], timeout: 0.1)
            controller.onStateChange = nil
            XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
            XCTAssertFalse(controller.isProcessing)
            XCTAssertFalse(controller.canRestore)
        }
    }

    @MainActor
    func testCloudFailureKeepsOriginalWhenLocalFallbackIsDisabled() async {
        let gate = CloudGate(started: expectation(description: "request started"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { try await gate.run($0) })
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        controller.setLocalFallbackEnabled(false)
        copy(wrapped) // This text WOULD be changed by the local normalizer.
        let count = pasteboard.changeCount
        controller.poll()
        await fulfillment(of: [gate.started], timeout: 1)
        let finished = expectation(description: "failure handled")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        gate.reply(.failure(JudgmentError.timedOut))
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        XCTAssertEqual(controller.cloudMessage, "Jev: " + JudgmentError.timedOut.localizedDescription)
        XCTAssertTrue(controller.diagnosticDetails.contains("Local fallback disabled."))
        XCTAssertTrue(controller.diagnosticDetails.contains { $0.hasPrefix("Processing time: ") })
        XCTAssertFalse(controller.canRestore)
    }

    func testMissingCloudKeyAndChangingModesDoNotRewriteExistingCopy() {
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        controller.setEnabled(true)
        controller.setLocalFallbackEnabled(false)
        copy(wrapped)
        controller.setCloudEnabled(true)
        controller.poll()
        XCTAssertNil(controller.cloudMessage)
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        copy(wrapped)
        let count = pasteboard.changeCount
        controller.poll()
        XCTAssertEqual(controller.cloudMessage, "Jev: " + JudgmentError.missingAPIKey.localizedDescription)
        XCTAssertEqual(pasteboard.changeCount, count)
        let reopened = ClipboardController(pasteboard: pasteboard, defaults: defaults)
        XCTAssertTrue(reopened.isCloudEnabled)
        XCTAssertFalse(reopened.isLocalFallbackEnabled)
        reopened.poll()
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    @MainActor
    func testSuccessfulCloudAnswerBetweenOldAndNewDeadlinesIsApplied() async throws {
        let gate = CloudGate(started: expectation(description: "request started"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { try await gate.run($0) })
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        controller.setLocalFallbackEnabled(false)
        copy(wrapped)
        controller.poll()
        await fulfillment(of: [gate.started], timeout: 1)
        try await Task.sleep(for: .seconds(2.1))
        let finished = expectation(description: "result within five seconds applied")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        gate.reply(.success(joined))
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.string(forType: .string), joined)
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
    }

    @MainActor
    func testSuccessfulCloudAnswerAfterDeadlineIsDiscarded() async throws {
        let gate = CloudGate(started: expectation(description: "request started"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { try await gate.run($0) })
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        controller.setLocalFallbackEnabled(false)
        copy(wrapped)
        let count = pasteboard.changeCount
        controller.poll()
        await fulfillment(of: [gate.started], timeout: 1)
        try await Task.sleep(for: .seconds(SystemOneNormalizer.timeout + 0.05))
        let finished = expectation(description: "late result discarded")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        gate.reply(.success(joined))
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), wrapped)
        XCTAssertEqual(controller.cloudMessage, "Jev: " + JudgmentError.timedOut.localizedDescription)
        XCTAssertTrue(controller.diagnosticDetails.contains("Local fallback disabled."))
        XCTAssertTrue(controller.diagnosticDetails.contains { $0.hasPrefix("Processing time: ") })
        XCTAssertFalse(controller.canRestore)
    }

    @MainActor
    func testReportedExampleFallsBackAfterRegionRestrictionAndCanBeRestored() async {
        let first = "直接执行：已修复并重新打包。请退出旧版，再打开新版 Shell Copy (build/Shell Copy.app)，即可使用"
        let next = "Command-V 粘贴、Command-A 全选。"
        let input = first + "\n  " + next
        let gate = CloudGate(started: expectation(description: "request started"))
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { try await gate.run($0) })
        XCTAssertFalse(controller.isLocalFallbackEnabled)
        controller.setLocalFallbackEnabled(true)
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        copy(input)
        controller.poll()
        await fulfillment(of: [gate.started], timeout: 1)
        let finished = expectation(description: "local fallback applied")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        gate.reply(.failure(JudgmentError.regionRestricted))
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.string(forType: .string), first + next)
        XCTAssertEqual(controller.cloudMessage, "Jev: The service blocks this region (HTTP 451). Joined using local rules.")
        XCTAssertTrue(controller.diagnosticDetails.contains("Local fallback enabled; joins: 1"))
        XCTAssertTrue(controller.diagnosticDetails.contains { $0.hasPrefix("Processing time: ") })
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), input)
        controller.poll()
        XCTAssertFalse(controller.isProcessing)
    }

    @MainActor
    func testFallbackDoesNotOverrideANewerCopyOrSuccessfulCloudNoOp() async {
        for hasNewCopy in [false, true] {
            let gate = CloudGate(started: expectation(description: "request started"))
            let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                                 cloudNormalize: { try await gate.run($0) })
            controller.setLocalFallbackEnabled(true)
            controller.setEnabled(true)
            controller.setCloudEnabled(true)
            copy(wrapped)
            controller.poll()
            await fulfillment(of: [gate.started], timeout: 1)
            if hasNewCopy { copy("new copy") }
            let count = pasteboard.changeCount
            let finished = expectation(description: "unchanged clipboard")
            controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
            gate.reply(hasNewCopy ? .failure(JudgmentError.regionRestricted) : .success(wrapped))
            await fulfillment(of: [finished], timeout: 1)
            controller.onStateChange = nil
            XCTAssertEqual(pasteboard.changeCount, count)
            XCTAssertEqual(pasteboard.string(forType: .string), hasNewCopy ? "new copy" : wrapped)
            XCTAssertFalse(controller.canRestore)
        }
    }

    @MainActor
    func testListWrapFallbackCanRestoreOriginalIndentation() async {
        let input = "  • " + first + "\n    release."
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { _ in throw JudgmentError.regionRestricted })
        controller.setLocalFallbackEnabled(true)
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        copy(input)
        let finished = expectation(description: "list joined locally")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        controller.poll()
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.string(forType: .string), "  • " + first + " release.")
        XCTAssertTrue(controller.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), input)
    }

    @MainActor
    func testFallbackKeepsStructuredTextUnchanged() async {
        let input = "- " + first + "\n  - nested release item"
        let controller = ClipboardController(pasteboard: pasteboard, defaults: defaults,
                                             cloudNormalize: { _ in throw JudgmentError.regionRestricted })
        controller.setLocalFallbackEnabled(true)
        controller.setEnabled(true)
        controller.setCloudEnabled(true)
        copy(input)
        let count = pasteboard.changeCount
        let finished = expectation(description: "protected text kept")
        controller.onStateChange = { if !controller.isProcessing { finished.fulfill() } }
        controller.poll()
        await fulfillment(of: [finished], timeout: 1)
        controller.onStateChange = nil
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), input)
        XCTAssertEqual(controller.cloudMessage, "Jev: " + JudgmentError.regionRestricted.localizedDescription)
        XCTAssertFalse(controller.canRestore)
    }
}

@MainActor
private final class CloudGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<String, Error>?
    init(started: XCTestExpectation) { self.started = started }
    func run(_ text: String) async throws -> NormalizationReport {
        let result: String = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        return NormalizationReport(text: result, provider: .jev, decisions: [], noRequestReason: nil)
    }
    func reply(_ result: Result<String, Error>) {
        continuation!.resume(with: result)
        continuation = nil
    }
}
