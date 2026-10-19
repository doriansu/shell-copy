import Foundation

public enum CloudProvider: String, CaseIterable {
    case jev, bjev

    public var name: String { self == .jev ? "Jev" : "bjev" }
    public var serviceName: String { self == .jev ? "TypeSafe" : "bjev (ByteDance)" }
    public var model: String { self == .jev ? "jev-1.13.0" : "bjev" }
    // Separate decision policies: these numbers are not measured accuracy guarantees.
    // Applied to the visual-wrap probability. Spacing is a separate AI judgment.
    public var joinThreshold: Double { self == .jev ? 0.98 : 0.80 }

    var endpoint: URL {
        URL(string: self == .jev
            ? "https://api.typesafe.ai/v1/systemone"
            : "https://bjev.bytedance.net/v1/systemone")!
    }
}
