import Foundation

extension NormalizationReport {
    /// Combine validated AI decisions with boundary-only rule proposals, never rewritten model text.
    public func combiningLocalRules(for original: String) -> NormalizationReport {
        guard !usesLocalRules else { return self }
        guard noRequestReason == nil, let plan = LineJoinPlan(original),
              decisions.map(\.nextLine) == plan.boundaries.map({ $0 + 1 }) else { return self }
        let proposals = HybridRules.proposals(original, plan: plan)
        let pathSelection = HybridRules.isPathSelection(plan.lines)
        let fenced = original.contains("```") || original.contains("~~~")
        let resolved = decisions.map { decision -> BoundaryDecision in
            let index = decision.nextLine - 1
            let left = plan.lines[index - 1].body.trimmingCharacters(in: .whitespaces)
            let right = plan.lines[index].body.trimmingCharacters(in: .whitespaces)
            let proposal = pathSelection ? LineBoundaryAction.join : proposals[index]
            let aiAction = decision.appliedAction(threshold: provider.joinThreshold)
            let action: LineBoundaryAction
            let reason: String
            if fenced || LineNormalizer.isStructured(right) ||
                (LineNormalizer.isStructured(left) && proposal == nil) {
                action = .keep
                reason = "rule protects code, record, heading or list structure"
            } else if decision.joinProbability <= 0.2 {
                // An explicit policy cutoff, not a calibrated accuracy guarantee.
                action = .keep
                reason = "AI strong keep veto; wrap <= 0.2"
            } else if let proposal {
                action = proposal
                reason = pathSelection ? "whole-selection path/URL rule; AI did not veto"
                    : "local wrap rule; AI did not veto"
            } else if aiAction != .keep, let tail = left.last, let head = right.first,
                      LineNormalizer.isCJK(tail), LineNormalizer.isCJK(head) {
                action = .join
                reason = "AI joins; rule avoids space between CJK characters"
            } else {
                action = aiAction
                reason = "AI decision; no applicable join rule"
            }
            var result = decision
            result.resolvedAction = action
            result.resolutionReason = reason
            return result
        }
        return NormalizationReport(text: plan.applying(resolved, threshold: provider.joinThreshold),
            provider: provider, decisions: resolved, noRequestReason: nil, usesLocalRules: true)
    }
}

private enum HybridRules {
    static func proposals(_ original: String, plan: LineJoinPlan) -> [Int: LineBoundaryAction] {
        let normalized = LineNormalizer.normalize(original)
        guard normalized != original,
              original.filter({ !$0.isWhitespace }) == normalized.filter({ !$0.isWhitespace }) else { return [:] }
        // Align by non-whitespace character offsets. Only removed original line boundaries
        // become proposals; the local normalizer's indentation edits are not copied wholesale.
        var gaps: [Int: String] = [:]
        var position = 0
        for character in normalized {
            if character.isWhitespace { gaps[position, default: ""].append(character) }
            else { position += 1 }
        }
        var actions: [Int: LineBoundaryAction] = [:]
        position = 0
        let candidates = Set(plan.boundaries)
        for index in 1..<plan.lines.count {
            position += plan.lines[index - 1].body.filter { !$0.isWhitespace }.count
            guard candidates.contains(index) else { continue }
            switch gaps[position] ?? "" {
            case "": actions[index] = .join
            case " ": actions[index] = .space
            default: break
            }
        }
        return actions
    }

    static func isPathSelection(_ source: [(body: String, ending: String)]) -> Bool {
        var lines = source
        if lines.last?.body == "" { lines.removeLast() }
        guard lines.count > 1, let first = lines.first?.body else { return false }
        let indent = lines[1].body.prefix { $0 == " " }.count
        guard indent >= 2 else { return false }
        var fragments: [String] = []
        for (index, line) in lines.enumerated() {
            let padding = line.body.prefix { $0 == " " }.count
            guard padding == (index == 0 ? 0 : indent) else { return false }
            let fragment = String(line.body.dropFirst(padding))
            guard fragment.range(of: #"^[A-Za-z0-9_./~%+@:=?#&-]+$"#, options: .regularExpression) != nil,
                  index == 0 || (!fragment.hasPrefix("/") && !fragment.hasPrefix("~/") &&
                    !fragment.hasPrefix("./") && !fragment.hasPrefix("../") && !fragment.contains("://")) else { return false }
            fragments.append(fragment)
        }
        if first.hasPrefix("https://") || first.hasPrefix("http://") {
            guard let components = URLComponents(string: fragments.joined()),
                  let host = components.host, !host.isEmpty else { return false }
            return true
        }
        return first.hasPrefix("/") || first.hasPrefix("~/") || first.hasPrefix("./") || first.hasPrefix("../")
    }
}
