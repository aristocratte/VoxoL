import Foundation

/// Reuses immutable compiled patterns; Foundation synchronizes NSCache access.
/// Concurrent misses may compile twice, which does not change matching behavior.
final class RegularExpressionCache: @unchecked Sendable {
    static let shared = RegularExpressionCache(
        enabled: ProcessInfo.processInfo.environment["VOXOL_REGEX_CACHE"] != "0"
    )

    private let enabled: Bool
    private let expressions = NSCache<NSData, NSRegularExpression>()

    init(enabled: Bool = true) {
        self.enabled = enabled
        expressions.countLimit = 256
    }

    func expression(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) throws -> NSRegularExpression {
        guard enabled else {
            return try NSRegularExpression(pattern: pattern, options: options)
        }

        // Swift String equality folds canonically equivalent Unicode. ICU
        // patterns can distinguish those spellings, so retain exact UTF-8 bytes.
        var bytes = Data(pattern.utf8)
        var optionBits = UInt64(options.rawValue).littleEndian
        withUnsafeBytes(of: &optionBits) { bytes.append(contentsOf: $0) }
        let key = bytes as NSData
        if let cached = expressions.object(forKey: key) {
            return cached
        }
        let compiled = try NSRegularExpression(pattern: pattern, options: options)
        expressions.setObject(compiled, forKey: key)
        return compiled
    }
}
