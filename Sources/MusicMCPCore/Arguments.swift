import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
///
/// An argument that is absent or null is "not given", and that is the only way to say "do
/// not filter on this". A value of the wrong type is refused with the form expected, never
/// read as not given: a filter that silently fell away would answer a different question.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    /// Whether the caller sent the argument at all, whatever its value.
    public func has(_ name: String) -> Bool {
        given(name) != nil
    }

    /// Refuses an argument the tool does not take. A misspelt or outdated filter that was
    /// silently dropped would answer a wider question than the one asked.
    public func check(against allowed: [String], tool: String) throws {
        for name in values.keys.sorted() where !allowed.contains(name) {
            throw ToolError.unknownArgument(name: name, tool: tool, allowed: allowed.sorted())
        }
    }

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    // MARK: Text

    /// Text with the surrounding white space removed; empty text is "not given".
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func requiredString(_ name: String) throws -> String {
        guard given(name) != nil else { throw ToolError.missingArgument(name) }
        guard let text = try optionalString(name) else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return text
    }

    /// A list of ids. Anything that is not a list is refused, one id as plain text
    /// included, and so is an entry that is not text: a dropped id would be one the caller
    /// believes was read or added.
    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { return [] }
        let expected = "a list of ids, each one text, was expected"
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: expected)
        }
        return try entries.map { entry -> String in
            guard let text = entry.stringValue else {
                throw ToolError.badArgument(name: name, reason: expected)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    // MARK: Numbers

    /// A quantity: a size, a count, a threshold. Outside its range it is moved to the
    /// nearest allowed value, and `notices` gains the sentence that says which value was
    /// used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        try optionalInt(name, in: range) ?? fallback
    }

    /// A filter bound, moved into its range like any other quantity. Absent means
    /// unbounded, so there is no default to fall back on.
    public func optionalInt(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let number = try wholeNumber(name) else { return nil }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of a window on one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: ToolCatalog.offsetRange),
            try int(
                "max_characters", default: ToolCatalog.defaultMaxCharacters,
                in: ToolCatalog.maxCharactersRange)
        )
    }

    // MARK: Flags

    public func bool(_ name: String, default fallback: Bool) throws -> Bool {
        try optionalBool(name) ?? fallback
    }

    /// nil when the key is absent, which is how "either state is fine" is expressed. A
    /// filter that defaulted to false would silently exclude every favourite.
    public func optionalBool(_ name: String) throws -> Bool? {
        guard let raw = given(name) else { return nil }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    // MARK: Dates

    /// The three accepted forms: `2026-08-12`, `2026-08-12T09:00`, and full ISO 8601 with
    /// an offset. Deliberately strict — a lenient parser that guesses at `10/08/2026`
    /// will one day read it as 8 October for a caller who meant 10 August. It is parsed
    /// here and not by `ISO8601DateFormatter`, which rolls 31 February over to March
    /// without a word.
    ///
    /// `isDateOnly` records what the caller actually wrote, so an upper bound documented
    /// as "on or before this date" can cover the whole of that day rather than stopping
    /// at midnight.
    public func optionalDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
        guard let raw = try optionalString(name) else { return nil }
        guard let parsed = Self.date(raw, calendar: calendar) else {
            throw ToolError.badDate(argument: name, value: raw)
        }
        return parsed
    }

    /// `nil` for anything but the three forms, and for a day or a time that does not exist.
    static func date(_ raw: String, calendar: Calendar) -> (date: Date, isDateOnly: Bool)? {
        let parts = raw.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }

        let day = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard day.count == 3, let year = number(day[0], digits: 4...4), let month = number(day[1], digits: 1...2),
            let dayOfMonth = number(day[2], digits: 1...2)
        else { return nil }
        var components = DateComponents(year: year, month: month, day: dayOfMonth, hour: 0, minute: 0, second: 0)

        // A time followed by Z or by an offset of either sign names an instant, and is
        // read in that offset. Without one the time is local.
        var offsetSeconds: Int?
        if parts.count == 2 {
            var time = parts[1]
            if let zoneStart = time.lastIndex(where: { "Zz+-".contains($0) }) {
                guard let offset = offset(time[zoneStart...]) else { return nil }
                offsetSeconds = offset
                time = time[..<zoneStart]
            }
            let clock = time.split(separator: ":", omittingEmptySubsequences: false)
            guard clock.count == 2 || clock.count == 3, let hour = number(clock[0], digits: 1...2),
                let minute = number(clock[1], digits: 2...2)
            else { return nil }
            components.hour = hour
            components.minute = minute
            if clock.count == 3 {
                guard let second = number(clock[2], digits: 2...2) else { return nil }
                components.second = second
            }
        }

        var resolving = calendar
        if offsetSeconds != nil {
            resolving = Calendar(identifier: .gregorian)
            resolving.timeZone = .gmt
        }
        // A calendar rolls a date that does not exist over to one that does: 31 February
        // becomes 3 March, hour 25 the next day. Reading the components back catches it.
        guard let date = resolving.date(from: components),
            resolving.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components
        else { return nil }
        return (date.addingTimeInterval(-Double(offsetSeconds ?? 0)), parts.count == 1)
    }

    /// Decimal digits and nothing else, as many as `digits` allows, as a number. A month
    /// or an hour may come without its leading zero; nothing may come with a sign.
    private static func number(_ text: Substring, digits: ClosedRange<Int>) -> Int? {
        guard digits.contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// `Z`, `+02:00` or `-05:00` as seconds east of Greenwich.
    private static func offset(_ zone: Substring) -> Int? {
        if zone == "Z" || zone == "z" { return 0 }
        let fields = zone.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let hours = number(fields[0], digits: 2...2),
            let minutes = number(fields[1], digits: 2...2),
            hours <= 23, minutes <= 59
        else { return nil }
        return (zone.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
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
        guard let raw = try optionalString("type") else { return .tracks }
        guard let type = SearchType(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: "type",
                reason: "expected one of: " + SearchType.allCases.map(\.rawValue).joined(separator: ", "))
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
