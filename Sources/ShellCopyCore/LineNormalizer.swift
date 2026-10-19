import Foundation

/// Deliberately narrow: indented prose wraps and standalone hyphenated names.
/// Plain text does not carry the distinction between hard and soft line breaks.
public enum LineNormalizer {
    public static func normalize(_ text: String) -> String {
        guard text.utf8.count <= 1_048_576,
              text.utf8.contains(10),
              !text.contains("\0"),
              !text.contains("```"), !text.contains("~~~") else { return text }

        let lines = splitLines(text)
        if let identifier = normalizeIdentifierSelection(lines) { return identifier }
        // A terminal selection can omit the opening line's padding while keeping
        // it on every later paragraph. Infer padding only from a proven prose wrap.
        let openingBlock = Array(lines.prefix { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty })
        let openingText = openingBlock.map { $0.body + $0.ending }.joined()
        let copyIndent = normalizeProse(openingBlock) != openingText
            ? openingBlock[1].body.prefix(while: { $0 == " " }).count : nil
        var result = ""
        var block: [(body: String, ending: String)] = []
        for line in lines {
            if line.body.trimmingCharacters(in: .whitespaces).isEmpty {
                result += normalizeBlock(block, isStartOfCopy: result.isEmpty, copyIndent: copyIndent)
                block.removeAll(keepingCapacity: true)
                result += line.body + line.ending
            } else {
                block.append(line)
            }
        }
        return result + normalizeBlock(block, isStartOfCopy: result.isEmpty, copyIndent: copyIndent)
    }

    private static func normalizeIdentifierSelection(_ lines: [(body: String, ending: String)]) -> String? {
        var content = lines
        if content.last?.body == "" { content.removeLast() }
        guard content.count > 1 else { return nil }
        let indent = content[1].body.prefix(while: { $0 == " " }).count
        guard indent >= 2 else { return nil }

        var joined = ""
        for (index, line) in content.enumerated() {
            let padding = line.body.prefix(while: { $0 == " " }).count
            guard padding == (index == 0 ? 0 : indent) else { return nil }
            let fragment = String(line.body.dropFirst(padding))
            guard fragment.range(of: #"^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*-?$"#,
                                 options: .regularExpression) != nil,
                  index == content.count - 1 || fragment.hasSuffix("-") else { return nil }
            joined += fragment
        }
        // Require the whole selection to be one name, never a prose/code subrange.
        guard joined.range(of: #"^[A-Za-z][A-Za-z0-9_]*(?:-[A-Za-z0-9_]+)+$"#,
                           options: .regularExpression) != nil else { return nil }
        return joined + (content.last?.ending ?? "")
    }

    // Shared with Jev so surviving boundaries keep their exact spelling in either mode.
    static func splitLines(_ text: String) -> [(body: String, ending: String)] {
        var lines: [(body: String, ending: String)] = []
        let parts = text.components(separatedBy: "\n")
        for (index, part) in parts.enumerated() {
            let hasNewline = index < parts.count - 1
            let crlf = hasNewline && part.hasSuffix("\r")
            lines.append((crlf ? String(part.dropLast()) : part, hasNewline ? (crlf ? "\r\n" : "\n") : ""))
        }
        return lines
    }

    private static func normalizeBlock(_ lines: [(body: String, ending: String)], isStartOfCopy: Bool, copyIndent: Int?) -> String {
        var result = ""
        var index = 0
        var prose: [(body: String, ending: String)] = []
        while index < lines.count {
            let line = lines[index]
            guard let marker = line.body.range(of: #"^ *(?:[-*+•]|\d+[.)]|[A-Za-z][.)]) +"#,
                                               options: .regularExpression) else {
                prose.append(line)
                index += 1
                continue
            }
            result += normalizeProse(prose, copyIndent: copyIndent)
            prose.removeAll(keepingCapacity: true)
            let prefix = String(line.body[marker])
            let content = String(line.body[marker.upperBound...])
            var item = [(body: content, ending: line.ending)]
            var end = index + 1
            var spaceIndent = prefix.count
            // A selection starting at the marker can omit the first line's padding.
            // Infer that offset only for the opening Chinese item, not later/nested items.
            if isStartOfCopy, index == 0, prefix.first != " ",
               content.contains(where: isCJK), end < lines.count {
                let continuation = lines[end].body
                let padding = continuation.prefix(while: { $0 == " " }).count
                if padding > spaceIndent,
                   continuation.dropFirst(padding).first.map(isCJK) == true {
                    spaceIndent = padding
                }
            }
            var hasInconsistentIndent = false
            while end < lines.count {
                let continuation = lines[end].body
                let padding = continuation.prefix(while: { $0 == " " || $0 == "\t" })
                let body = String(continuation.dropFirst(padding.count))
                // Space wraps align with the list text. Some terminal copies pad a
                // Chinese continuation with tabs; allow only leading tabs in that case.
                let aligned = padding.count == spaceIndent && !padding.contains("\t")
                let tabPaddedChinese = padding.contains("\t") &&
                    content.contains(where: isCJK) && body.first.map(isCJK) == true
                guard !body.isEmpty, !isStructured(body) else { break }
                guard aligned || tabPaddedChinese else {
                    hasInconsistentIndent = spaceIndent != prefix.count && !padding.isEmpty
                    break
                }
                item.append(lines[end])
                end += 1
            }
            let prepared = item.map { $0.body + $0.ending }.joined()
            let joined = hasInconsistentIndent ? prepared : normalizeProse(item, validatedListContinuations: true)
            if joined != prepared {
                result += prefix + joined
            } else {
                result += lines[index..<end].map { $0.body + $0.ending }.joined()
            }
            index = end
        }
        return result + normalizeProse(prose, copyIndent: copyIndent)
    }

    private static func normalizeProse(_ lines: [(body: String, ending: String)],
                                       validatedListContinuations: Bool = false, copyIndent: Int? = nil) -> String {
        let original = lines.map { $0.body + $0.ending }.joined()
        guard lines.count > 1, var first = lines.first?.body else { return original }
        var prefix = ""
        if let copyIndent, copyIndent >= 2,
           lines.allSatisfy({ $0.body.prefix(while: { $0 == " " }).count == copyIndent }) {
            prefix = String(first.prefix(copyIndent))
            first = String(first.dropFirst(copyIndent))
        }
        guard
              first.first != " ", first.first != "\t",
              displayWidth(first) >= 48, isProse(first),
              !lines.contains(where: {
                  isStructured(validatedListContinuations
                               ? String($0.body.drop(while: { $0 == " " || $0 == "\t" })) : $0.body)
              }) else { return original }

        let indent = lines[1].body.prefix(while: { $0 == " " }).count
        guard validatedListContinuations || (indent >= 2 &&
              lines.dropFirst().allSatisfy({ line in
                  line.body.prefix(while: { $0 == " " }).count == indent && !line.body.contains("\t")
              })) else { return original }

        var result = ""
        var joined = first
        for index in 1..<lines.count {
            let line = lines[index]
            let next = validatedListContinuations
                ? String(line.body.drop(while: { $0 == " " || $0 == "\t" }))
                : String(line.body.dropFirst(indent))
            var left = joined
            while left.last == " " { left.removeLast() }
            guard let last = left.last, let head = next.first,
                  !".!?。！？:：;；-—\\/=|{}[]".contains(last),
                  head.isLetter || head.isNumber || "（(“\"".contains(head) else {
                // A protected boundary does not veto other wraps in the same block.
                result += joined + lines[index - 1].ending
                joined = line.body
                continue
            }
            // Preserve column spacing inside lines. Only the wrap boundary changes.
            let space = (isCJK(last) || isCJK(head) || "，、；：）”".contains(last)) ? "" : " "
            joined = left + space + next
        }
        return prefix + result + joined + (lines.last?.ending ?? "")
    }

    private static func isProse(_ text: String) -> Bool {
        if text.filter({ isCJK($0) }).count >= 12 { return true }
        return text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 }.count >= 8
    }

    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + (isCJK($1) ? 2 : 1) }
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
    }

    static func isStructured(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        if line.contains("\t") || line.contains("\r") || value.contains(" | ") || value.contains(" && ") { return true }
        let patterns = [
            #"^(?:[-*+•]|\d+[.)]|[A-Za-z][.)])\s"#, // Lists
            #"^(?:[$>#%]|[{}\[\]])"#, // Prompts, headings, JSON, code
            #"^(?:\d{4}-\d{2}-\d{2}[T ]|\d{2}:\d{2}:\d{2}|\[?(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\b)"#,
            #"^(?:at\s+\S+\(|Traceback\b|Caused by:|File \"|\w+(?:Error|Exception):)"#,
            #"^(?:let|var|const|func|def|class|import|from|return|if|else|for|while|switch|case|SELECT|INSERT|UPDATE|DELETE|WITH)\b"#,
            #"^(?:sudo|env|export|cd|ls|pwd|cat|echo|printf|grep|rg|find|sed|awk|curl|wget|git|ssh|scp|python\d*|node|npm|bash|zsh|sh|go|swift|make|docker|kubectl|chmod|rm|cp|mv|brew)\b"#,
            #"^[A-Za-z_][A-Za-z0-9_.-]*\s*:(?:\s|$)"#, // YAML / labelled records, including empty values
            #"^[A-Za-z_][A-Za-z0-9_]*\s+=\s"#,
            #"^[A-Za-z_][A-Za-z0-9_]*=[^\s]+(?:\s+[A-Za-z_][A-Za-z0-9_]*=[^\s]+)*$"#,
            #"(?:[{}]|;\s*$|\\\s*$|->|=>)"#
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}
