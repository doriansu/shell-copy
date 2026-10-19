import XCTest
@testable import ShellCopyCore

final class HybridNormalizerTests: XCTestCase {
    private func report(_ text: String, wrap: Double, space: Double) throws -> NormalizationReport {
        guard let plan = LineJoinPlan(text) else {
            return NormalizationReport(text: text, provider: .bjev, decisions: [], noRequestReason: "No eligible boundaries")
        }
        let decisions = plan.boundaries.map {
            NormalizationReport.BoundaryDecision(nextLine: $0 + 1, joinProbability: wrap, spaceProbability: space)
        }
        return NormalizationReport(text: plan.applying(decisions, threshold: CloudProvider.bjev.joinThreshold),
            provider: .bjev, decisions: decisions, noRequestReason: nil)
    }

    func testRulesRecoverUncertainIdentifierAndCorrectItsSpacing() throws {
        let input = "seedmux-lite-\r\n  team\r\n"
        for probability in [0.21, 0.4296, 0.7141, 0.99] {
            let ai = try report(input, wrap: probability, space: 0.99)
            let hybrid = ai.combiningLocalRules(for: input)
            XCTAssertEqual(hybrid.text, "seedmux-lite-team\r\n")
            XCTAssertTrue(hybrid.usesLocalRules)
            XCTAssertTrue(hybrid.summary.contains("1/1 joins (AI + rules)"))
            XCTAssertTrue(hybrid.details.contains { $0.contains("local wrap rule") })
            XCTAssertEqual(hybrid.combiningLocalRules(for: input).text, hybrid.text)
        }
    }

    func testStrongAIKeepVetoesLocalJoinProposal() throws {
        for input in ["seedmux-lite-\n  team", "https://example.test/docs/\n  start"] {
            for probability in [0, 0.19, 0.2] {
                let hybrid = try report(input, wrap: probability, space: 0).combiningLocalRules(for: input)
                XCTAssertEqual(hybrid.text, input)
                XCTAssertTrue(hybrid.details.contains { $0.contains("AI strong keep veto") })
            }
        }
    }

    func testWholePathAndURLRulesRequireOneConsistentlyIndentedSelection() throws {
        for input in ["/Users/demo/seedmux-lite-\n  team/SKILL.md", "https://example.test/docs/\n  getting-started"] {
            XCTAssertEqual(try report(input, wrap: 0.4, space: 0.9).combiningLocalRules(for: input).text,
                           input.replacingOccurrences(of: "\n  ", with: ""))
        }
        for input in ["/first/path\n  /second/path", "https://first.test\n  https://second.test",
                      "/first/path\nsecond", "/first/path\n  second\n   third",
                      "/first/path\n\n  second", "hello\n  world"] {
            XCTAssertEqual(try report(input, wrap: 0.4, space: 0).combiningLocalRules(for: input).text, input)
        }
    }

    func testStructureRulesVetoEvenVeryHighAIJoinScores() throws {
        for input in ["```swift\nlet n = 1\nprint(n)\n```", "- Buy milk\n- Call Alice",
                      "INFO first\nINFO second", "printf hello \\\n  world",
                      "# First heading\n# Second heading", "value:\n  nested"] {
            XCTAssertEqual(try report(input, wrap: 1, space: 1).combiningLocalRules(for: input).text, input)
        }
    }

    func testCJKSpacingDoesNotAuthorizeJoiningAndDoesNotChangeMixedLanguageSpacing() throws {
        XCTAssertEqual(try report("开发环\n  境", wrap: 0.9, space: 0.9).combiningLocalRules(for: "开发环\n  境").text, "开发环境")
        XCTAssertEqual(try report("开发环\n  境", wrap: 0.7, space: 0.9).combiningLocalRules(for: "开发环\n  境").text, "开发环\n  境")
        XCTAssertEqual(try report("使用\n  API", wrap: 0.9, space: 0.9).combiningLocalRules(for: "使用\n  API").text, "使用 API")
    }

    func testLocalProposalAlignmentPreservesParagraphsInternalSpacesAndOriginalLineNumbers() throws {
        let first = "This detailed deployment report explains the remaining work for the next"
        let input = first + "\r\n    release  candidate.\r\n\r\n  " + first + "\n  release.\n"
        let hybrid = try report(input, wrap: 0.7, space: 0).combiningLocalRules(for: input)
        XCTAssertEqual(hybrid.text, first + " release  candidate.\r\n\r\n  " + first + "\n  release.\n")
        XCTAssertEqual(hybrid.decisions.map(\.nextLine), [2, 5])
        XCTAssertEqual(input.filter { !$0.isWhitespace }, hybrid.text.filter { !$0.isWhitespace })
    }

    func testWrappedListUsesExistingListContinuationRule() throws {
        let input = "• 这份发布检查报告详细说明本次上线之前仍需核对的历史数据\n    校验结果。"
        XCTAssertEqual(try report(input, wrap: 0.76, space: 0.78).combiningLocalRules(for: input).text,
                       input.replacingOccurrences(of: "\n    ", with: ""))
    }

    func testNoApplicableRuleLeavesAIBehaviorUnchanged() throws {
        for probability in [0.4, 0.79, 0.81] {
            let input = "The gardener decided to plant\n  more flowers."
            let ai = try report(input, wrap: probability, space: 0.9)
            XCTAssertEqual(ai.combiningLocalRules(for: input).text, ai.text)
        }
        let skipped = NormalizationReport(text: "one\n\ntwo", provider: .bjev, decisions: [], noRequestReason: "Blank separator")
        XCTAssertEqual(skipped.combiningLocalRules(for: skipped.text).text, skipped.text)
    }
}
