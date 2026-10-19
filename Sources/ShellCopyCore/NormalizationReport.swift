import Foundation

enum LineBoundaryAction {
    case keep, join, space

    var description: String {
        switch self {
        case .keep: return "keep break"
        case .join: return "join without space"
        case .space: return "join with space"
        }
    }
}

/// Returned with the text, but only metadata is retained by the controller.
public struct NormalizationReport {
    public struct BoundaryDecision {
        /// One-based line number in the original copy.
        public let nextLine: Int
        public let joinProbability: Double
        public let spaceProbability: Double
        var resolvedAction: LineBoundaryAction? = nil
        var resolutionReason: String? = nil

        func appliedAction(threshold: Double) -> LineBoundaryAction {
            if let resolvedAction { return resolvedAction }
            guard joinProbability >= threshold else { return .keep }
            return spaceProbability >= 0.5 ? .space : .join
        }
    }

    public let text: String
    public let provider: CloudProvider
    public let decisions: [BoundaryDecision]
    public let noRequestReason: String?
    public var usesLocalRules = false

    public var summary: String {
        if noRequestReason != nil {
            return "\(provider.name) not requested; original text kept."
        }
        let accepted = decisions.filter { $0.appliedAction(threshold: provider.joinThreshold) != .keep }.count
        return "\(provider.name) returned: \(accepted)/\(decisions.count) joins (\(usesLocalRules ? "AI + rules" : "AI-led"))."
    }

    public var details: [String] {
        var rows = [usesLocalRules
            ? "Hybrid mode: AI sees original text; rules resolve boundaries after validation."
            : "AI-led mode: no local pre-processing."]
        if let noRequestReason {
            rows.append("\(provider.name) not requested: " + noRequestReason)
        } else {
            rows.append("\(provider.name) response validated; threshold: \(provider.joinThreshold)")
            rows.append("Line numbers refer to original copied text.")
            rows += decisions.map { boundary in
                let applied = boundary.appliedAction(threshold: provider.joinThreshold)
                let reason = boundary.resolutionReason.map { " (" + $0 + ")" }
                    ?? (applied == .keep ? " (join below threshold)" : "")
                return "Lines \(boundary.nextLine - 1)–\(boundary.nextLine): wrap=\(boundary.joinProbability), space-if-joined=\(boundary.spaceProbability) → \(applied.description)\(reason)"
            }
        }
        return rows
    }

    static func joinCount(from original: String, to result: String) -> Int {
        original.utf8.filter { $0 == 10 }.count - result.utf8.filter { $0 == 10 }.count
    }
}
