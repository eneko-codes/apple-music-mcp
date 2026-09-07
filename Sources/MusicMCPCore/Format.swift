import Foundation

/// Plain-text rendering of every tool result.
///
/// Two rules shape everything here. Dates are written in the same form the filters
/// accept, so a date read out of a row can be pasted straight back into `added_from`.
/// And a track row is `key=value` rather than a table, because twenty-six fields do not
/// fit in columns and an unlabelled column is a field waiting to be misread.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// `2026-08-09`, and `2026-08-09T11:20` when the time matters. Hand-rolled rather
    /// than `DateFormatter` so output does not change shape with the machine's locale,
    /// and chosen to match what `added_from` and `added_to` parse.
    func stamp(_ date: Date, withTime: Bool = false) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard withTime else { return day }
        return day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `3:31`, or `1:04:12` once it passes an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, remainder) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    static func megabytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// The headline of a track: what a person would say out loud to name it.
    static func headline(_ row: TrackRow) -> String {
        var text = row.name.isEmpty ? "(untitled)" : row.name
        if !row.artist.isEmpty { text += " — \(row.artist)" }
        if !row.album.isEmpty { text += " · \(row.album)" }
        if row.year > 0 { text += " (\(row.year))" }
        return text
    }

    // MARK: Track rows

    /// Every field but the lyrics, as `key=value` pairs across two lines.
    ///
    /// Empty fields are dropped rather than printed empty: a row for a track with no
    /// composer should not spend a column saying so, and `tracks_list` output is long
    /// enough already.
    func rowLines(_ row: TrackRow) -> [String] {
        var facts: [String] = ["id=\(row.persistentID)"]
        if !row.genre.isEmpty { facts.append("genre=\(row.genre)") }
        if row.duration > 0 { facts.append("length=\(Self.clock(row.duration))") }
        facts.append("played=\(row.playedCount)")
        if let played = row.playedDate { facts.append("last_played=\(stamp(played))") }
        facts.append("skipped=\(row.skippedCount)")
        if let skipped = row.skippedDate { facts.append("last_skipped=\(stamp(skipped))") }
        facts.append("rating=\(row.rating)")
        if row.favorited { facts.append("favourite") }
        if row.disliked { facts.append("disliked") }

        var extra: [String] = []
        if let added = row.dateAdded { extra.append("added=\(stamp(added))") }
        if !row.albumArtist.isEmpty, row.albumArtist != row.artist {
            extra.append("album_artist=\(row.albumArtist)")
        }
        if row.trackNumber > 0 { extra.append("track=\(row.trackNumber)") }
        if row.discNumber > 1 { extra.append("disc=\(row.discNumber)") }
        if !row.composer.isEmpty { extra.append("composer=\(row.composer)") }
        if row.bpm > 0 { extra.append("bpm=\(row.bpm)") }
        if row.compilation { extra.append("compilation") }
        if !row.kind.isEmpty { extra.append("kind=\(row.kind)") }
        let size = Self.megabytes(row.size)
        if !size.isEmpty { extra.append("size=\(size)") }
        if !row.cloudStatus.isEmpty { extra.append("cloud=\(row.cloudStatus)") }
        if !row.comment.isEmpty { extra.append("comment=\(row.comment)") }

        var lines = ["   " + facts.joined(separator: " · ")]
        if !extra.isEmpty { lines.append("   " + extra.joined(separator: " · ")) }
        return lines
    }

    func rows(_ rows: [TrackRow], startingAt offset: Int) -> [String] {
        rows.enumerated().flatMap { index, row in
            ["\(offset + index + 1). \(Self.headline(row))"] + rowLines(row)
        }
    }

    /// The shared footer for anything paged: what was withheld, and how to ask for it.
    func footer(shown: Int, total: Int, offset: Int, hitScanLimit: Bool) -> [String] {
        var lines: [String] = []
        let seen = offset + shown
        if total > seen {
            lines.append("")
            lines.append("\(total - seen) more · call again with offset=\(seen)")
        }
        if hitScanLimit {
            lines.append("")
            lines.append(
                """
                The scan ceiling was reached before the library was exhausted, so tracks \
                exist that this query never looked at. Narrow the filters and try again.
                """)
        }
        return lines
    }

    // MARK: Tools

    public func status(
        _ state: MusicAvailability, binaryPath: String, configuration: Configuration
    ) -> String {
        let headline: String
        switch state {
        case .ready: headline = "Music: RUNNING, automation permitted."
        case .notInstalled: headline = "Music: NOT INSTALLED."
        case .notRunning: headline = "Music: NOT RUNNING."
        case .automationDenied: headline = "Music automation: DENIED."
        case .consentNotGranted: headline = "Music automation: not requested yet."
        }

        var text = headline + "\n\n"
        // The effective configuration: a setting that never reached the process is
        // otherwise invisible, and has to be inferred from odd behaviour.
        text += Self.block([
            ("binary", binaryPath),
            ("target", ScriptingBridgeMusicStore.bundleIdentifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("scan ceiling", "\(Configuration.scanCeiling) tracks per query"),
            ("default rows", "\(Configuration.searchLimit)"),
            ("lyrics limit", "\(configuration.lyricsLimit) characters"),
        ])
        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        return text
    }

    public func nowPlaying(_ status: PlayerStatus) -> String {
        guard let track = status.track else {
            var text = "Nothing is loaded. Player state: \(status.state.rawValue)."
            text += "\n\n" + Self.block([("volume", "\(status.volume)")])
            return text
        }

        var lines = ["\(status.state.rawValue.uppercased()) · \(Self.headline(track))"]
        lines.append("")
        lines.append(
            Self.block([
                (
                    "position",
                    track.duration > 0
                        ? "\(Self.clock(status.position)) of \(Self.clock(track.duration))"
                        : Self.clock(status.position)
                ),
                ("volume", "\(status.volume)"),
                ("playlist", status.playlistName),
            ]))
        lines.append("")
        lines.append(contentsOf: rowLines(track))
        return lines.joined(separator: "\n")
    }

    public func trackResults(
        _ results: [TrackRow], total: Int, offset: Int, hitScanLimit: Bool, describing scope: String
    ) -> String {
        guard !results.isEmpty else {
            var text = "No tracks match \(scope)."
            if hitScanLimit {
                text += "\n\nThe scan ceiling was reached first, so the library was not "
                text += "exhausted. Narrow the filters and try again."
            }
            return text
        }
        var lines = ["\(total) match \(scope)."]
        lines.append("")
        lines.append(contentsOf: rows(results, startingAt: offset))
        lines.append(
            contentsOf: footer(
                shown: results.count, total: total, offset: offset, hitScanLimit: hitScanLimit))
        return lines.joined(separator: "\n")
    }

    public func groups(
        _ groups: [LibraryGroup], kind: String, scope: String, hitScanLimit: Bool
    ) -> String {
        guard !groups.isEmpty else { return "No \(kind) match \(scope)." }
        let width = groups.map(\.name.count).max() ?? 0
        var lines = ["\(groups.count) \(kind) match \(scope), grouped from the scanned rows."]
        lines.append("")
        for group in groups {
            var line = "  " + Self.pad(group.name, to: width)
            if !group.detail.isEmpty { line += "  — \(group.detail)" }
            line += "  · \(group.trackCount) track\(group.trackCount == 1 ? "" : "s")"
            lines.append(line)
        }
        lines.append("")
        lines.append(
            "Counts are of tracks this query scanned, not of the whole library. Use "
                + "tracks_list for the rows behind them.")
        if hitScanLimit {
            lines.append("")
            lines.append(
                "The scan ceiling was reached, so a name absent here may still exist.")
        }
        return lines.joined(separator: "\n")
    }

    public func playlistList(_ playlists: [PlaylistInfo]) -> String {
        guard !playlists.isEmpty else { return "No playlists." }
        let width = playlists.map(\.name.count).max() ?? 0
        var lines: [String] = []
        for playlist in playlists {
            var line = "  " + Self.pad(playlist.name, to: width)
            line += "  \(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")"
            if playlist.duration > 0 { line += " · \(Self.clock(Double(playlist.duration)))" }
            line += " · \(describe(playlist))"
            line += " · id=\(playlist.persistentID)"
            lines.append(line)
        }
        lines.append("")
        lines.append(
            "Only playlists marked \"accepts tracks\" can take an add_to_playlist call.")
        return lines.joined(separator: "\n")
    }

    /// What a playlist is, in the terms `add_to_playlist` cares about.
    func describe(_ playlist: PlaylistInfo) -> String {
        if !playlist.specialKind.isEmpty { return playlist.specialKind.lowercased() }
        if playlist.isGenius { return "Genius" }
        if playlist.isSmart { return "smart" }
        return "accepts tracks"
    }

    public func playlistDetail(
        _ playlist: PlaylistInfo, tracks: [TrackRow], total: Int, offset: Int
    ) -> String {
        var lines = [playlist.name]
        lines.append("")
        lines.append(
            Self.block([
                ("id", playlist.persistentID),
                ("tracks", "\(playlist.trackCount)"),
                (
                    "total time",
                    playlist.duration > 0 ? Self.clock(Double(playlist.duration)) : nil
                ),
                ("kind", describe(playlist)),
                (
                    "add_to_playlist",
                    playlist.isEditable
                        ? "accepted"
                        : "refused — Music maintains this playlist itself"
                ),
            ]))
        lines.append("")
        if tracks.isEmpty {
            lines.append(offset > 0 ? "No tracks at offset \(offset)." : "The playlist is empty.")
        } else {
            lines.append(contentsOf: rows(tracks, startingAt: offset))
            lines.append(
                contentsOf: footer(
                    shown: tracks.count, total: total, offset: offset, hitScanLimit: false))
        }
        return lines.joined(separator: "\n")
    }

    public func trackDetails(_ details: [TrackDetail], missing: [String]) -> String {
        var lines: [String] = []
        for detail in details {
            let row = detail.row
            lines.append(Self.headline(row))
            lines.append("")
            lines.append(
                Self.block([
                    ("id", row.persistentID),
                    ("artist", row.artist),
                    ("album artist", row.albumArtist),
                    ("album", row.album),
                    ("composer", row.composer),
                    ("genre", row.genre),
                    ("year", row.year > 0 ? "\(row.year)" : nil),
                    ("length", row.duration > 0 ? Self.clock(row.duration) : nil),
                    ("bpm", row.bpm > 0 ? "\(row.bpm)" : nil),
                    (
                        "track",
                        row.trackNumber > 0
                            ? "\(row.trackNumber)\(row.discNumber > 1 ? " (disc \(row.discNumber))" : "")"
                            : nil
                    ),
                    (
                        "played",
                        "\(row.playedCount)"
                            + (row.playedDate.map { ", last \(stamp($0, withTime: true))" } ?? "")
                    ),
                    (
                        "skipped",
                        "\(row.skippedCount)"
                            + (row.skippedDate.map { ", last \(stamp($0, withTime: true))" } ?? "")
                    ),
                    ("rating", "\(row.rating) of 100"),
                    ("favourite", row.favorited ? "yes" : nil),
                    ("disliked", row.disliked ? "yes" : nil),
                    ("compilation", row.compilation ? "yes" : nil),
                    ("added", row.dateAdded.map { stamp($0, withTime: true) }),
                    ("kind", row.kind),
                    ("size", Self.megabytes(row.size)),
                    ("cloud", row.cloudStatus),
                    ("sort name", row.sortName == row.name ? nil : row.sortName),
                    ("comment", row.comment),
                ]))
            lines.append("")
            if detail.lyrics.isEmpty {
                lines.append("  lyrics   (none stored)")
            } else {
                lines.append("  lyrics")
                lines.append(
                    detail.lyrics.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "    \($0)" }.joined(separator: "\n"))
                if detail.lyricsTruncated {
                    lines.append("    … truncated at the configured lyrics limit.")
                }
            }
            lines.append("")
        }
        if !missing.isEmpty {
            lines.append(
                "Not found: \(missing.joined(separator: ", ")) — run music_search again, "
                    + "a persistent id does not survive the track leaving the library.")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    public func createdPlaylist(_ playlist: PlaylistInfo) -> String {
        """
        Created the playlist "\(playlist.name)". It is empty.

        \(Self.block([("id", playlist.persistentID)]))

        Add tracks with add_to_playlist(playlist_id="\(playlist.persistentID)", track_ids=[…]).
        """
    }

    /// `skipDuplicatesRequested` is passed separately rather than inferred from a
    /// non-empty `duplicates`, because the two silences mean different things: with the
    /// guard off nothing was ever checked, and reporting that as "no duplicates" would be
    /// a claim this server never verified.
    public func added(_ outcome: AddOutcome, skipDuplicatesRequested: Bool) -> String {
        var text =
            "Added \(outcome.added) track\(outcome.added == 1 ? "" : "s") "
            + "to \"\(outcome.playlistName)\". Nothing already in it was changed."
        if skipDuplicatesRequested {
            if outcome.duplicates.isEmpty {
                text += " None of the ids given were already in the playlist."
            } else {
                text += """


                    \(outcome.duplicates.count) id\(outcome.duplicates.count == 1 ? "" : "s") \
                    \(outcome.duplicates.count == 1 ? "was" : "were") already in the playlist \
                    and \(outcome.duplicates.count == 1 ? "was" : "were") not added again:
                      \(outcome.duplicates.joined(separator: "\n  "))
                    """
            }
        }
        if !outcome.missing.isEmpty {
            text += """


                \(outcome.missing.count) id\(outcome.missing.count == 1 ? "" : "s") did not \
                resolve and \(outcome.missing.count == 1 ? "was" : "were") skipped:
                  \(outcome.missing.joined(separator: "\n  "))

                A persistent id stops resolving once the track leaves the library. Look \
                them up again with music_search.
                """
        }
        return text
    }

    public func controlled(_ command: PlaybackCommand, status: PlayerStatus) -> String {
        let action: String
        switch command {
        case .play: action = "Playback started."
        case .pause: action = "Playback paused."
        case .next: action = "Skipped to the next track."
        case .previous: action = "Went back to the previous track."
        case .volume: action = "Volume set to \(status.volume)."
        }

        var text = action + "\n\n"
        if let track = status.track {
            text += "Now \(status.state.rawValue): \(Self.headline(track))"
        } else {
            text += "Player state: \(status.state.rawValue). Nothing is loaded."
        }
        text += "\n\n" + Self.block([("volume", "\(status.volume)")])
        return text
    }
}
