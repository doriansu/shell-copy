import Foundation
import XCTest
@testable import ShellCopyCore

final class SystemOneNormalizerTests: XCTestCase {
    func testAIReceivesOriginalIdentifierAndCanKeepItsBreak() async throws {
        let input = "seedmux-lite-\n  team"
        var requests = 0
        let session = makeSession { request in
            requests += 1
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])
            let state = try XCTUnwrap(body["state"] as? [String: Any])
            let lines = try XCTUnwrap(state["lines"] as? [[String: String]])
            XCTAssertEqual(lines.map { $0["text"] }, ["seedmux-lite-", "  team"])
            return (200, Data(#"{"model":"jev-1.13.0","answers":{"join_1":{"type":"noul","noul":0},"space_1":{"type":"noul","noul":0}}}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let output = try await SystemOneNormalizer(session: session).normalize(input, apiKey: "synthetic-key")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(output, input)
    }

    private struct ExpectedAnswer {
        let wrap: Double
        let space: Double
    }

    private func answer(_ action: LineBoundaryAction, probability: Double = 1) -> ExpectedAnswer {
        .init(wrap: action == .keep ? 0 : probability, space: action == .space ? 1 : 0)
    }

    private func rawAnswers(_ answers: [String: ExpectedAnswer]) -> [String: SystemOneResponse.Answer] {
        var result: [String: SystemOneResponse.Answer] = [:]
        for (key, answer) in answers {
            result[key] = .init(type: "noul", noul: answer.wrap)
            result[key.replacingOccurrences(of: "join_", with: "space_")] = .init(type: "noul", noul: answer.space)
        }
        return result
    }

    private func response(_ provider: CloudProvider, _ answers: [String: ExpectedAnswer]) throws -> Data {
        let objects = rawAnswers(answers).mapValues { ["type": $0.type, "noul": $0.noul] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["model": provider.model, "answers": objects])
    }

    private func apply(_ plan: LineJoinPlan, _ answers: [String: ExpectedAnswer],
                       threshold: Double = CloudProvider.jev.joinThreshold) throws -> String {
        plan.applying(try plan.validatedDecisions(rawAnswers(answers)), threshold: threshold)
    }

    func testAllNonblankBoundariesReachAIRegardlessOfSyntax() throws {
        let samples = [
            "seedmux-lite-\n  team", "/Users/demo/skills/\n  seedmux-lite-team",
            "开发环\n境", "interoper\nability", "We need.\nMore checks.",
            "说明：\n- 第一项", "description:\n  value", "# Heading\nparagraph",
            "- first item\n- second item", "• 正文内容\n\t\t续行",
            "echo hello \\\n  world", "INFO first\nINFO second", "a | b\nc | d",
            "```swift\nlet value = 1\nprint(value)\n```", "~~~text\na\nb\n~~~"
        ]
        for text in samples {
            let plan = try XCTUnwrap(LineJoinPlan(text), text)
            XCTAssertEqual(plan.boundaries, Array(1..<plan.lines.count), text)
            let keep = Dictionary(uniqueKeysWithValues: plan.boundaries.map { ("join_\($0)", answer(.keep)) })
            XCTAssertEqual(try apply(plan, keep), text)
        }
    }

    func testThreeActionsPreserveOnlyUneditedBytesAndUseModelSpacing() throws {
        let input = "  /tmp/seedmux-lite-  \r\n\t team\n  and\r\n   more  checks\n"
        let plan = try XCTUnwrap(LineJoinPlan(input))
        XCTAssertEqual(try apply(plan, ["join_1": answer(.join), "join_2": answer(.keep), "join_3": answer(.space)]),
                       "  /tmp/seedmux-lite-team\n  and more  checks\n")
        // Spacing comes from the answer, not a Chinese/English heuristic.
        for (input, action, expected) in [
            ("interoper\n  ability", LineBoundaryAction.join, "interoperability"),
            ("hello\nworld", .space, "hello world"),
            ("使用\nAPI", .space, "使用 API"),
            ("seedmux-lite-\n  team", .join, "seedmux-lite-team"),
            ("https://example.test/\npath", .join, "https://example.test/path")
        ] {
            XCTAssertEqual(try apply(XCTUnwrap(LineJoinPlan(input)), ["join_1": answer(action)]), expected)
        }
    }

    func testBlankSeparatorsFinalEndingsAndOriginalLineNumbersStayExact() throws {
        let input = "one\r\n  two\r\n \nthree\n\tfour\n"
        let plan = try XCTUnwrap(LineJoinPlan(input))
        XCTAssertEqual(plan.boundaries, [1, 4])
        let decisions = try plan.validatedDecisions(rawAnswers(["join_1": answer(.space), "join_4": answer(.keep)]))
        XCTAssertEqual(decisions.map(\.nextLine), [2, 5])
        XCTAssertEqual(plan.applying(decisions, threshold: 0.98), "one two\r\n \nthree\n\tfour\n")
    }

    func testModelCanVetoEveryLocallyRecognizedWrapInBothModes() async throws {
        let first = "这份发布检查报告详细说明本次上线之前仍需核对的历史数据"
        for input in ["seedmux-lite-\n  team", first + "\n  校验结果。", "• " + first + "\n    校验结果。"] {
            XCTAssertNotEqual(LineNormalizer.normalize(input), input)
            for provider in CloudProvider.allCases {
                var requests = 0
                let session = makeSession { request in
                    requests += 1
                    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])
                    let state = try XCTUnwrap(body["state"] as? [String: Any])
                    let lines = try XCTUnwrap(state["lines"] as? [[String: String]])
                    XCTAssertEqual(lines.map { $0["text"] }, LineNormalizer.splitLines(input).map { $0.body })
                    return (200, try self.response(provider, ["join_1": self.answer(.keep)]))
                }
                defer { session.invalidateAndCancel() }
                let report = try await SystemOneNormalizer(provider: provider, session: session)
                    .normalizeWithReport(input, apiKey: "synthetic-key")
                XCTAssertEqual(requests, 1)
                XCTAssertEqual(report.text, input)
                XCTAssertEqual(report.decisions.count, 1)
            }
        }
    }

    func testPreviouslyReportedExamplesAreReconstructedByModelActions() async throws {
        let first = "我需要写一个客群创编的skill 这是我之前梳理的客群skill原子能力："
        let next = "notes/2026-09-24-segment-authoring-skill-research.md，你结合代码帮我出"
        let last = "一个技术方案，使用AI unslop这个skill写作"
        let cases: [(String, [String: ExpectedAnswer], String)] = [
            ("seedmux-lite-\n  team", ["join_1": answer(.join)], "seedmux-lite-team"),
            (first + "\n  " + next + "\n  " + last,
             ["join_1": answer(.keep), "join_2": answer(.join)], first + "\n  " + next + last),
            ("• 这是当前段落内被截断的时\n    间说明。\n• 下一项。",
             ["join_1": answer(.join), "join_2": answer(.keep)], "• 这是当前段落内被截断的时间说明。\n• 下一项。"),
            ("First wrapped\n  sentence.\n\n  Another wrapped\n  sentence.",
             ["join_1": answer(.space), "join_4": answer(.space)], "First wrapped sentence.\n\n  Another wrapped sentence.")
        ]
        for provider in CloudProvider.allCases {
            for (input, answers, expected) in cases {
                let session = makeSession { _ in (200, try self.response(provider, answers)) }
                defer { session.invalidateAndCancel() }
                let result = try await SystemOneNormalizer(provider: provider, session: session).normalize(input, apiKey: "synthetic-key")
                XCTAssertEqual(result, expected)
            }
        }
    }

    func testWrapThresholdAndSpacingAreIndependentModelJudgments() throws {
        let plan = try XCTUnwrap(LineJoinPlan("some\n  words"))
        for provider in CloudProvider.allCases {
            for probability in [0.7999, 0.8, 0.8848, 0.9799, 0.98, 1] {
                let selected = answer(.space, probability: probability)
                let result = try apply(plan, ["join_1": selected], threshold: provider.joinThreshold)
                XCTAssertEqual(result, probability >= provider.joinThreshold ? "some words" : "some\n  words")
            }
        }
        for (probability, expected) in [(0.0, "somewords"), (0.4999, "somewords"), (0.5, "some words"), (1.0, "some words")] {
            XCTAssertEqual(try apply(plan, ["join_1": .init(wrap: 1, space: probability)]), expected)
        }

    }

    func testReportIncludesAllActionScoresAndAppliedDecisionWithoutContent() async throws {
        for provider in CloudProvider.allCases {
            let answers = ["join_1": answer(.join, probability: 0.79), "join_4": answer(.space)]
            let session = makeSession { _ in (200, try self.response(provider, answers)) }
            defer { session.invalidateAndCancel() }
            let report = try await SystemOneNormalizer(provider: provider, session: session)
                .normalizeWithReport("seedmux-lite-\n  team\n\nmore\n  checks", apiKey: "synthetic-key")
            XCTAssertNil(report.noRequestReason)
            XCTAssertEqual(report.decisions.map(\.nextLine), [2, 5])
            XCTAssertEqual(report.text, "seedmux-lite-\n  team\n\nmore checks")
            XCTAssertEqual(report.summary, "\(provider.name) returned: 1/2 joins (AI-led).")
            XCTAssertTrue(report.details.contains { $0.contains("Lines 1–2:") && $0.contains("wrap=0.79") && $0.contains("below threshold") })
            XCTAssertTrue(report.details.contains { $0.contains("Lines 4–5:") && $0.contains("join with space") })
            XCTAssertTrue(report.details.contains("AI-led mode: no local pre-processing."))
            XCTAssertFalse(report.details.joined().contains("synthetic-key"))
            XCTAssertFalse(report.details.joined().contains("seedmux"))
        }
    }

    func testIneligibleCopiesRemainUnmodifiedWithoutLocalPassOrNetwork() async throws {
        let locallyJoinable = "This detailed deployment report explains the remaining work for the next\n  release."
        let samples = [
            ("one line", "No line breaks."),
            ("Title\n\nParagraph.\n", "Only blank-line or final boundaries."),
            ("a\nb\0", "Text contains NUL."),
            (locallyJoinable + "\n\n" + String(repeating: "x", count: 12_289), "Text exceeds 12 KiB."),
            (locallyJoinable + "\n\n" + Array(repeating: "word", count: 66).joined(separator: "\n"), "More than 64 candidate boundaries.")
        ]
        let session = makeSession { _ in
            XCTFail("Skipped requests must not reach the network")
            throw URLError(.badURL)
        }
        defer { session.invalidateAndCancel() }
        let client = SystemOneNormalizer(session: session)
        for (input, reason) in samples {
            let report = try await client.normalizeWithReport(input, apiKey: "synthetic-key")
            XCTAssertEqual(report.noRequestReason, reason)
            XCTAssertEqual(report.text, input)
            XCTAssertTrue(report.decisions.isEmpty)
            XCTAssertEqual(report.summary, "Jev not requested; original text kept.")
        }
        for key in ["", "  ", "bad\nkey", "bad\rkey"] {
            do {
                _ = try await client.normalize("seedmux-lite-\n  team", apiKey: key)
                XCTFail("Missing or malformed key accepted")
            } catch JudgmentError.missingAPIKey {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNotNil(LineJoinPlan(Array(repeating: "word", count: 65).joined(separator: "\n")))
    }

    func testInvalidOrMissingJudgmentsRejectWholeCopyBeforeEditing() throws {
        let plan = try XCTUnwrap(LineJoinPlan("one\ntwo\nthree"))
        let valid = rawAnswers(["join_1": answer(.space), "join_2": answer(.join)])
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try plan.validatedDecisions(missing))
            for bad in [SystemOneResponse.Answer(type: "choice", noul: 1),
                        .init(type: "noul", noul: -0.1), .init(type: "noul", noul: 1.1),
                        .init(type: "noul", noul: .nan), .init(type: "noul", noul: .infinity)] {
                var invalid = valid
                invalid[key] = bad
                XCTAssertThrowsError(try plan.validatedDecisions(invalid))
            }
        }
        var extra = valid
        extra["join_3"] = .init(type: "noul", noul: 1)
        XCTAssertThrowsError(try plan.validatedDecisions(extra))
    }

    func testHTTPDualJudgmentContractAndOriginalContextForBothProviders() async throws {
        for provider in CloudProvider.allCases {
            let input = "# Heading\nseedmux-lite-\n  team\n\nmore\n  checks"
            let session = makeSession { request in
                XCTAssertEqual(request.url, provider.endpoint)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(request.timeoutInterval, 5)
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])
                XCTAssertEqual(body["model"] as? String, provider.model)
                let state = try XCTUnwrap(body["state"] as? [String: Any])
                let lines = try XCTUnwrap(state["lines"] as? [[String: String]])
                XCTAssertEqual(lines.map { $0["text"] }, LineNormalizer.splitLines(input).map { $0.body })
                let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
                XCTAssertEqual(Set(questions.keys), ["join_1", "space_1", "join_2", "space_2", "join_5", "space_5"])
                for question in questions.values {
                    XCTAssertEqual(question["type"] as? String, "noul")
                    let criteria = try XCTUnwrap(question["criteria"] as? [String: String])
                    XCTAssertEqual(Set(criteria.keys), ["true", "false"])
                }
                let candidates = try XCTUnwrap(questions["space_2"]?["criteria"] as? [String: String])
                XCTAssertEqual(candidates["false"], "seedmux-lite-team")
                XCTAssertEqual(candidates["true"], "seedmux-lite- team")
                XCTAssertTrue((questions["join_2"]?["instructions"] as? String)?.contains("L1") == true)
                return (200, try self.response(provider, ["join_1": self.answer(.keep), "join_2": self.answer(.join), "join_5": self.answer(.space)]))
            }
            defer { session.invalidateAndCancel() }
            let output = try await SystemOneNormalizer(provider: provider, session: session).normalize(input, apiKey: "test-key")
            XCTAssertEqual(output, "# Heading\nseedmux-lite-team\n\nmore checks")
        }
    }

    func testEvaluationTimeoutOverrideDoesNotChangeAppDefault() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.timeoutInterval, 15)
            return (200, try self.response(.bjev, ["join_1": self.answer(.join)]))
        }
        defer { session.invalidateAndCancel() }
        let output = try await SystemOneNormalizer(provider: .bjev, session: session, requestTimeout: 15)
            .normalize("seedmux-lite-\n  team", apiKey: "test-key")
        XCTAssertEqual(output, "seedmux-lite-team")
        XCTAssertEqual(SystemOneNormalizer.timeout, 5)
    }

    func testWrongProviderModelIsRejected() async {
        let session = makeSession { _ in (200, try self.response(.jev, ["join_1": self.answer(.join)])) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await SystemOneNormalizer(provider: .bjev, session: session).normalize("seedmux-lite-\n  team", apiKey: "test-key")
            XCTFail("Accepted the wrong provider model")
        } catch JudgmentError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRegionRestrictionHasActionableError() async {
        let session = makeSession { _ in (451, Data("private server body".utf8)) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await SystemOneNormalizer(session: session).normalize("some\nwords", apiKey: "test-key")
            XCTFail("Region restriction accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("region"))
            XCTAssertTrue(error.localizedDescription.contains("451"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
    }

    func testServiceErrorsAndMalformedResponsesAreRejected() async throws {
        let cases: [(Int, String, JudgmentError)] = [
            (401, "secret server body", .unauthorized), (429, "secret", .rateLimited),
            (529, "secret", .rateLimited), (500, "secret", .httpFailure(500)),
            (302, "secret", .httpFailure(302)), (422, "secret", .httpFailure(422)),
            (200, "not json", .invalidResponse),
            (200, #"{"model":"jev-1.13.0","answers":{}}"#, .invalidResponse),
            (200, #"{"model":"other","answers":{"join_1":{"type":"noul","noul":1}}}"#, .invalidResponse)
        ]
        for (status, body, expected) in cases {
            let session = makeSession { _ in (status, Data(body.utf8)) }
            do {
                _ = try await SystemOneNormalizer(session: session).normalize("We need\nmore checks.", apiKey: "test-key")
                XCTFail("Invalid response accepted: \(status)")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
            session.invalidateAndCancel()
        }
    }

    func testNetworkTimeoutKeepsAControlledError() async {
        let session = makeSession { _ in throw URLError(.timedOut) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await SystemOneNormalizer(session: session).normalize("We need\nmore checks.", apiKey: "test-key")
            XCTFail("Timeout accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, JudgmentError.timedOut.localizedDescription)
        }
    }

    private func makeSession(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        StubURLProtocol.setHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler!
        Self.lock.unlock()
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
