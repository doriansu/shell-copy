import Foundation

// Only numerical timings are retained, never headers, URLs, or response bodies.
final class EvaluationMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        func elapsed(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "n/a" }
            return String(format: "%.3f", end.timeIntervalSince(start))
        }
        let lines = metrics.transactionMetrics.map { metric in
            "network: dns=\(elapsed(metric.domainLookupStartDate, metric.domainLookupEndDate)) " +
            "connect-including-tls=\(elapsed(metric.connectStartDate, metric.connectEndDate)) " +
            "tls=\(elapsed(metric.secureConnectionStartDate, metric.secureConnectionEndDate)) " +
            "upload=\(elapsed(metric.requestStartDate, metric.requestEndDate)) " +
            "wait-first-byte=\(elapsed(metric.requestEndDate, metric.responseStartDate)) " +
            "download=\(elapsed(metric.responseStartDate, metric.responseEndDate)) " +
            "reused=\(metric.isReusedConnection) proxy=\(metric.isProxyConnection)"
        }
        lock.lock()
        entries.append(contentsOf: lines)
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let result = entries
        entries = []
        return result
    }
}

// Compile with the core sources; this harness never accesses a pasteboard or keychain.
@main
struct EvaluateAI {
    struct Fixture: Decodable {
        let id: String
        let text: String
        let expected: String
    }

    static func main() async {
        guard (4...6).contains(CommandLine.arguments.count),
              let provider = CloudProvider(rawValue: CommandLine.arguments[1]) else {
            print("Usage: evaluate-ai <jev|bjev> <key-file> <fixtures-json> [timeout-seconds] [ai|hybrid|compare]")
            exit(2)
        }
        guard let timeout = Double(CommandLine.arguments.count >= 5 ? CommandLine.arguments[4] : String(SystemOneNormalizer.timeout)),
              timeout.isFinite, timeout > 0 else {
            print("Timeout must be a finite positive number.")
            exit(2)
        }
        let mode = CommandLine.arguments.count == 6 ? CommandLine.arguments[5] : "hybrid"
        guard ["ai", "hybrid", "compare"].contains(mode) else {
            print("Mode must be ai, hybrid, or compare.")
            exit(2)
        }
        let key: String
        let fixtures: [Fixture]
        do {
            key = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            fixtures = try JSONDecoder().decode([Fixture].self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        } catch {
            print("Cannot read key or fixtures; no request sent.")
            exit(2)
        }
        let metrics = EvaluationMetrics()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: metrics, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let client = SystemOneNormalizer(provider: provider, session: session, requestTimeout: timeout)
        print("provider=\(provider.rawValue) timeout=\(timeout)s mode=\(mode); timings in seconds; n/a may mean reused connection or unavailable phase")
        var passed = 0
        var wrong = 0
        var failures = 0
        var aiPassed = 0
        var regressions = 0
        for fixture in fixtures {
            let started = ContinuousClock.now
            do {
                let aiReport = try await client.normalizeWithReport(fixture.text, apiKey: key)
                let report = mode == "ai" ? aiReport : aiReport.combiningLocalRules(for: fixture.text)
                let matches = report.text == fixture.expected
                let aiMatches = aiReport.text == fixture.expected
                if aiMatches { aiPassed += 1 }
                if aiMatches && !matches { regressions += 1 }
                if matches { passed += 1 } else { wrong += 1 }
                print("\(fixture.id): \(matches ? "PASS" : "MISMATCH") \(started.duration(to: .now))")
                if mode == "compare" { print("  same-response AI-only: \(aiMatches ? "PASS" : "MISMATCH")") }
                report.details.forEach { print("  " + $0) }
            } catch {
                failures += 1
                // Never print response bodies, keys or copied text.
                print("\(fixture.id): ERROR \((error as? JudgmentError ?? .unavailable).failureReason) \(started.duration(to: .now))")
            }
            // Drain after delegate callbacks so metrics stay with their sequential request.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.delegateQueue.addOperation { continuation.resume() }
            }
            metrics.drain().forEach { print("  " + $0) }
        }
        print("\(provider.name): \(passed) passed, \(wrong) mismatches, \(failures) request failures / \(fixtures.count)")
        if mode == "compare" { print("Same-response comparison: AI-only \(aiPassed) correct; hybrid \(passed) correct; regressions \(regressions)") }
        exit(wrong == 0 && failures == 0 ? 0 : 1)
    }
}
