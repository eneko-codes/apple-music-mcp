import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// Optional filters return nil when the key is absent, and absent is the only way to say
/// "do not filter on this". There is no clearing affordance here because nothing this
/// server exposes edits a field: every write either creates a playlist or appends to one.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// nil when the key is absent, which is how "either state is fine" is expressed. A
    /// filter that defaulted to false would silently exclude every favourite.
    public func optionalBool(_ name: String) -> Bool? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        return raw.boolValue
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    /// A filter bound: absent means unbounded, so there is no default to fall back on.
    public func optionalInt(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        guard range.contains(number) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected \(range.lowerBound)–\(range.upperBound), got \(number)")
        }
        return number
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Dates

    /// The three accepted forms: `2026-08-12`, `2026-08-12T09:00`, and full ISO 8601 with
    /// an offset. Deliberately strict — a lenient parser that guesses at `10/08/2026`
    /// will one day read it as 8 October for a caller who meant 10 August.
    ///
    /// `isDateOnly` records what the caller actually wrote, so an upper bound documented
    /// as "on or before this date" can cover the whole of that day rather than stopping
    /// at midnight.
    public func optionalDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
        guard let raw = optionalString(name) else { return nil }

        let parts = raw.split(separator: "T", omittingEmptySubsequences: false)
        if parts.count == 1 || (parts.count == 2 && !raw.contains("Z") && !raw.contains("+")) {
            let dayParts = parts[0].split(separator: "-")
            guard dayParts.count == 3, let year = Int(dayParts[0]), let month = Int(dayParts[1]),
                let day = Int(dayParts[2]), (1...12).contains(month), (1...31).contains(day)
            else { throw ToolError.badDate(argument: name, value: raw) }

            var components = DateComponents(year: year, month: month, day: day)
            if parts.count == 2 {
                let time = parts[1].split(separator: ":")
                guard time.count >= 2, let hour = Int(time[0]), let minute = Int(time[1]),
                    (0...23).contains(hour), (0...59).contains(minute)
                else { throw ToolError.badDate(argument: name, value: raw) }
                components.hour = hour
                components.minute = minute
            }
            guard let date = calendar.date(from: components) else {
                throw ToolError.badDate(argument: name, value: raw)
            }
            return (date, parts.count == 1)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else {
            throw ToolError.badDate(argument: name, value: raw)
        }
        return (date, false)
    }

    // MARK: Enumerations

    public func command() throws -> PlaybackCommand {
        let raw = try requiredString("command").lowercased()
        guard let command = PlaybackCommand(rawValue: raw) else {
            throw ToolError.unknownCommand(raw)
        }
        return command
    }

    public func searchType() throws -> SearchType {
        guard let raw = optionalString("type") else { return .tracks }
        guard let type = SearchType(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: "type",
                reason: "expected \(SearchType.allCases.map(\.rawValue).joined(separator: ", "))"
                    + ", got \"\(raw)\"")
        }
        return type
    }
}

/// What `music_search` is being asked to look for.
public enum SearchType: String, Sendable, Equatable, CaseIterable {
    case tracks
    case albums
    case artists
    case playlists
}
