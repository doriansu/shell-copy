import AppKit

/// Call on the main thread. Tests use a uniquely named pasteboard, never .general.
public final class ClipboardController {
    public static let enabledKey = "automaticallyJoinWrappedLines"
    public static let cloudEnabledKey = "useJevCloudJudgment"
    public static let providerKey = "normalizationProvider"
    public static let localFallbackKey = "useLocalRulesWhenJevFails"
    public static let hybridKey = "combineAIWithLocalRules"
    // Preserve known processing markers so other clipboard tools need not process our write again.
    private static let processingMarkers: Set<NSPasteboard.PasteboardType> = [
        .init("com.sindresorhus.Pure-Paste.hasRun"),
        .init("x.nspasteboard.ModifiedType")
    ]
    public private(set) var isEnabled: Bool
    public private(set) var cloudProvider: CloudProvider?
    public var isCloudEnabled: Bool { cloudProvider != nil }
    public private(set) var isLocalFallbackEnabled: Bool
    public private(set) var isHybridEnabled: Bool
    public private(set) var isProcessing = false
    public private(set) var cloudMessage: String?
    public private(set) var diagnosticDetails: [String] = []
    public var canRestore: Bool { original != nil && pasteboard.changeCount == observedCount }
    public var onStateChange: (() -> Void)?

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let normalize: (String) -> String
    private var cloudNormalize: ((String) async throws -> NormalizationReport)?
    private var pending: Task<Void, Never>?
    private var requestID: UUID?
    private var observedCount: Int
    private var original: [(NSPasteboard.PasteboardType, Data)]?

    public init(pasteboard: NSPasteboard, defaults: UserDefaults = .standard,
                cloudNormalize: ((String) async throws -> NormalizationReport)? = nil,
                normalize: @escaping (String) -> String = LineNormalizer.normalize) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.normalize = normalize
        self.cloudNormalize = cloudNormalize
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let saved = defaults.string(forKey: Self.providerKey) {
            cloudProvider = CloudProvider(rawValue: saved)
        } else {
            // Preserve the existing Jev opt-in when upgrading; new installs stay local.
            cloudProvider = defaults.bool(forKey: Self.cloudEnabledKey) ? .jev : nil
        }
        isLocalFallbackEnabled = defaults.object(forKey: Self.localFallbackKey) as? Bool ?? false
        isHybridEnabled = defaults.object(forKey: Self.hybridKey) as? Bool ?? true
        observedCount = pasteboard.changeCount
    }

    public func setEnabled(_ enabled: Bool) {
        invalidatePending()
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        // Enabling establishes a baseline; existing clipboard content is not a new copy.
        if observedCount != pasteboard.changeCount { original = nil }
        observedCount = pasteboard.changeCount
        onStateChange?()
    }

    public func setCloudEnabled(_ enabled: Bool) {
        setProvider(enabled ? (cloudProvider ?? .jev) : nil)
    }

    public func setProvider(_ provider: CloudProvider?) {
        cloudProvider = provider
        defaults.set(provider?.rawValue ?? "local", forKey: Self.providerKey)
        resetBaseline()
    }

    public func setCloudNormalizer(_ normalizer: ((String) async throws -> NormalizationReport)?) {
        cloudNormalize = normalizer
        resetBaseline()
    }

    public func setLocalFallbackEnabled(_ enabled: Bool) {
        isLocalFallbackEnabled = enabled
        defaults.set(enabled, forKey: Self.localFallbackKey)
        resetBaseline()
    }

    public func setHybridEnabled(_ enabled: Bool) {
        isHybridEnabled = enabled
        defaults.set(enabled, forKey: Self.hybridKey)
        resetBaseline()
    }

    private func resetBaseline() {
        invalidatePending()
        if observedCount != pasteboard.changeCount { original = nil }
        observedCount = pasteboard.changeCount
        onStateChange?()
    }

    private func invalidatePending() {
        pending?.cancel()
        pending = nil
        requestID = nil
        isProcessing = false
        cloudMessage = nil
        diagnosticDetails = []
    }

    public func poll() {
        let count = pasteboard.changeCount
        guard count != observedCount else { return }
        invalidatePending()
        observedCount = count
        original = nil
        defer { onStateChange?() }
        guard isEnabled else { return }
        var skipReason = "Unsupported clipboard format, size limit, or clipboard changed during read."
        guard let snapshot = readEligibleItem(onSkip: { skipReason = $0 }),
              let text = pasteboard.string(forType: .string), text.utf8.count <= 1_048_576,
              pasteboard.changeCount == count else {
            cloudMessage = "Copy skipped; no cloud request."
            diagnosticDetails = [skipReason]
            return
        }
        if !isCloudEnabled {
            let clock = ContinuousClock()
            let started = clock.now
            let joined = normalize(text)
            let changed = apply(joined, to: text, snapshot: snapshot, count: count)
            cloudMessage = changed ? "Local rules joined wrapped lines; no cloud request." : "Local rules kept text unchanged; no cloud request."
            diagnosticDetails = ["Local joins: \(NormalizationReport.joinCount(from: text, to: joined))", timing(started.duration(to: clock.now))]
            return
        }
        guard let cloudNormalize else {
            handleCloudFailure(.missingAPIKey, text: text, snapshot: snapshot, count: count)
            return
        }
        let id = UUID()
        requestID = id
        isProcessing = true
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(SystemOneNormalizer.timeout))
        pending = Task { @MainActor [weak self] in
            let result: Result<NormalizationReport, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await cloudNormalize(text))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.pending = nil
            self.requestID = nil
            self.isProcessing = false
            defer { self.onStateChange?() }
            // Check the actual pasteboard, even when a new copy arrived between polls.
            guard self.isEnabled, self.isCloudEnabled, self.pasteboard.changeCount == count else { return }
            let resolved = result.map { report in
                self.isHybridEnabled ? report.combiningLocalRules(for: text) : report
            }
            guard clock.now <= deadline else {
                self.handleCloudFailure(.timedOut, text: text, snapshot: snapshot, count: count)
                self.diagnosticDetails.append("Processing deadline exceeded; response discarded.")
                self.diagnosticDetails.append(self.timing(started.duration(to: clock.now)))
                return
            }
            switch resolved {
            case .success(let report):
                let changed = self.apply(report.text, to: text, snapshot: snapshot, count: count)
                self.cloudMessage = report.summary
                self.diagnosticDetails = report.details
                self.diagnosticDetails.append(changed ? "Result written to clipboard." :
                    (report.text == text ? "Clipboard unchanged." : "Result not written; clipboard changed or write failed."))
            case .failure(let error):
                // Do not expose server bodies, clipboard data, or credentials in errors.
                self.handleCloudFailure(error as? JudgmentError ?? .unavailable,
                                        text: text, snapshot: snapshot, count: count)
            }
            self.diagnosticDetails.append(self.timing(started.duration(to: clock.now)))
        }
    }

    private func timing(_ duration: Duration) -> String {
        let parts = duration.components
        let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        return String(format: "Processing time: %.0f ms", milliseconds)
    }

    private func handleCloudFailure(_ error: JudgmentError, text: String,
                                    snapshot: [(NSPasteboard.PasteboardType, Data)], count: Int) {
        let reason = (cloudProvider?.name ?? "Cloud") + ": " + error.failureReason
        diagnosticDetails = [reason]
        if case .missingAPIKey = error {
            diagnosticDetails.append("Cloud request not sent: missing key.")
        } else {
            diagnosticDetails.append("Cloud processing failed; no cloud judgment applied.")
        }
        let fallback = isLocalFallbackEnabled ? normalize(text) : text
        diagnosticDetails.append(isLocalFallbackEnabled
            ? "Local fallback enabled; joins: \(NormalizationReport.joinCount(from: text, to: fallback))"
            : "Local fallback disabled.")
        if isLocalFallbackEnabled, apply(fallback, to: text, snapshot: snapshot, count: count) {
            cloudMessage = reason + ". Joined using local rules."
        } else {
            cloudMessage = reason + ". Original text kept."
        }
    }

    @discardableResult
    private func apply(_ joined: String, to text: String,
                       snapshot: [(NSPasteboard.PasteboardType, Data)], count: Int) -> Bool {
        guard joined != text, pasteboard.changeCount == count else { return false }
        let item = NSPasteboardItem()
        guard item.setString(joined, forType: .string) else { return false }
        for (type, data) in snapshot where Self.processingMarkers.contains(type) {
            guard item.setData(data, forType: type) else { return false }
        }
        if replace(with: item, expectedCount: count) {
            original = snapshot
            return true
        }
        return false
    }

    @discardableResult
    public func restoreOriginal() -> Bool {
        guard let original else { return false }
        invalidatePending()
        defer { self.original = nil; onStateChange?() }
        // Do not replace a newer copy that arrived between timer ticks or while the menu was open.
        guard pasteboard.changeCount == observedCount else { return false }
        let item = NSPasteboardItem()
        for (type, data) in original {
            guard item.setData(data, forType: type) else { return false }
        }
        return replace(with: item, expectedCount: observedCount)
    }

    private func readEligibleItem(onSkip: (String) -> Void) -> [(NSPasteboard.PasteboardType, Data)]? {
        guard let items = pasteboard.pasteboardItems, items.count == 1,
              let item = items.first, item.types.contains(.string) else { return nil }
        // An allowlist avoids rewriting file URLs, images, private/concealed clipboard items,
        // app-specific objects or rich content with attachments. Keep every admitted representation.
        let allowed: Set<NSPasteboard.PasteboardType> = [
            .string, .rtf, .html,
            NSPasteboard.PasteboardType("public.utf16-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-external-plain-text"),
            NSPasteboard.PasteboardType("NSStringPboardType")
        ]
        let unsupported = item.types.filter { !allowed.contains($0) && !Self.processingMarkers.contains($0) }
        guard unsupported.isEmpty else {
            onSkip("Unsupported or protected clipboard types: " + unsupported.map(\.rawValue).sorted().joined(separator: ", "))
            return nil
        }
        var snapshot: [(NSPasteboard.PasteboardType, Data)] = []
        var size = 0
        for type in item.types {
            guard let data = item.data(forType: type) else { return nil }
            size += data.count
            guard size <= 8 * 1_048_576 else { return nil }
            snapshot.append((type, data))
        }
        return snapshot
    }

    private func replace(with item: NSPasteboardItem, expectedCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedCount else { return false }
        let ownedCount = pasteboard.clearContents()
        // AppKit has no compare-and-swap API. Recheck after taking ownership too.
        guard pasteboard.changeCount == ownedCount else { return false }
        let written = pasteboard.writeObjects([item])
        guard pasteboard.changeCount == ownedCount else { return false }
        observedCount = ownedCount // Suppresses both normalization writes and restoration writes.
        return written
    }

    deinit { pending?.cancel() }
}
