import Foundation

/// The one knob left here is `lyricsLimit`. `scanCeiling` and `searchLimit` used to be
/// settable the same way, but per the "plug and play" policy — replace configuration with
/// a good default, never with unbounded behaviour — they are now fixed below at the values
/// already in use as the extension's defaults.
///
/// `lyricsLimit` arrives as a command-line argument because that is how a Claude extension
/// passes `user_config`: the manifest substitutes `${user_config.key}` into
/// `mcp_config.args`. Parsing is hand-rolled rather than pulling in an argument-parsing
/// package — the surface is one number, and every dependency in this repo has to earn its
/// place.
public struct Configuration: Sendable, Equatable {
    /// How many tracks one query walks before giving up. Music does the reading, one
    /// round trip per property per track, so an unbounded walk over a large library is
    /// slow enough to look like a hang. Fixed rather than user-configurable.
    public static let scanCeiling = 2_000

    /// Default page size for `tracks_list` and `music_search`. The tool's own `limit`
    /// still wins. Fixed rather than user-configurable.
    public static let searchLimit = 50

    /// Default truncation for the lyrics `track_get` returns.
    public var lyricsLimit: Int = 8_000

    public init() {}

    public static let searchLimitRange = 1...200
    public static let lyricsLimitRange = 200...50_000

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...100_000

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument — observed live in the
    /// sibling servers.
    ///
    /// Taking that at face value is worse than ignoring it: `Int("${user_config.x}")` is
    /// nil, and a setting silently read as zero would clamp every scan to its floor.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Unknown flags are ignored rather than fatal: a server that will not launch is much
    /// harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            func clamped(_ range: ClosedRange<Int>) -> Int? {
                guard let value, !isPlaceholder(value), let number = Int(value) else {
                    return nil
                }
                return min(max(number, range.lowerBound), range.upperBound)
            }

            switch flag {
            case "--lyrics-limit":
                if let number = clamped(lyricsLimitRange) { configuration.lyricsLimit = number }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
