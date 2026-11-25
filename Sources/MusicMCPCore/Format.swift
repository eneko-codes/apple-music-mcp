import Foundation

/// Plain-text rendering of every tool result. Pure: it is handed finished values and sends
/// no Apple event.
///
/// Three rules shape everything here. What a result does not hold is said first, in the
/// wording of `Notice`, before any data. Dates are written in the same form the filters
/// accept, so a date read out of a row can be pasted straight back into `from_date`.
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
    /// and chosen to match what `from_date` and `to_date` parse.
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

    /// Collapses a multi-line value onto one line, so the lines of a row stay the lines of
    /// that row when a name or a comment holds a line break.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `text` cut to `width` characters, with a mark where it was cut.
    static func clip(_ text: String, to width: Int) -> String {
        text.count > width ? String(text.prefix(width)) + "…" : text
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The headline of a track: what a person would say out loud to name it.
    static func headline(_ row: TrackRow) -> String {
        var text = row.name.isEmpty ? "(untitled)" : oneLine(row.name)
        if !row.artist.isEmpty { text += " — \(oneLine(row.artist))" }
        if !row.album.isEmpty { text += " · \(oneLine(row.album))" }
        if row.year > 0 { text += " (\(row.year))" }
        return text
    }

    // MARK: Notices and bounds

    /// The comment as a row shows it. It is the one field of a row with no natural length,
    /// so a row holds its first `ToolCatalog.commentClipWidth` characters and `track_get`
    /// the whole.
    static func rowComment(_ row: TrackRow) -> String {
        clip(oneLine(row.comment), to: ToolCatalog.commentClipWidth)
    }

    /// The sentence that says comments were shortened, when one of `rows` had its comment
    /// shortened and not otherwise.
    static func commentNotice(_ rows: [TrackRow]) -> [String] {
        guard rows.contains(where: { oneLine($0.comment).count > ToolCatalog.commentClipWidth })
        else { return [] }
        return [
            Notice.clipped(
                field: "Comment", width: ToolCatalog.commentClipWidth, tool: ToolCatalog.trackGetName)
        ]
    }

    /// What an empty page says: nothing matched, or the offset skipped everything.
    static func nothing(_ none: String, skipped offset: Int) -> String {
        offset > 0 ? "(nothing at this offset)" : none
    }

    /// The sentences that place a page read at the source: `shown` rows starting at
    /// `offset`, out of a walk that ended as `read` says.
    ///
    /// The total is the walk's own count when it reached the end, and otherwise the count
    /// Music gave, or one the caller knows some other way (`expected`, a playlist's own
    /// track count). Whether more rows exist is decided by how the walk ended, never by a
    /// count: with no usable count the notice says that more exist and where they start.
    static func position(
        shown: Int, offset: Int, read: TrackPage, expected: Int? = nil, things: String
    ) -> [String] {
        var notices: [String] = []
        if case .deadline = read.stop {
            notices.append(Notice.partial(after: read.rows.count, things: things, narrowBy: "limit"))
        }
        let atEnd = read.stop == .end
        // Nothing read and not at the end: the walk ran out of time before its first row,
        // and the sentence above is all there is to say.
        guard atEnd || shown > 0 else { return notices }
        var total = read.total(after: offset, shown: shown)
        if total == nil, let expected, expected > offset + shown { total = expected }
        notices += [Notice.page(offset: offset, count: shown, total: total, things: things)].compactMap { $0 }
        return notices
    }

    // MARK: Track rows

    /// Every field but the lyrics, as `key=value` pairs across two lines.
    ///
    /// Empty fields are dropped rather than printed empty: a row for a track with no
    /// composer should not spend a column saying so, and `tracks_list` output is long
    /// enough already.
    func rowLines(_ row: TrackRow) -> [String] {
        var facts: [String] = ["id=\(row.persistentID)"]
        if !row.genre.isEmpty { facts.append("genre=\(Self.oneLine(row.genre))") }
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
            extra.append("album_artist=\(Self.oneLine(row.albumArtist))")
        }
        if row.trackNumber > 0 { extra.append("track=\(row.trackNumber)") }
        if row.discNumber > 1 { extra.append("disc=\(row.discNumber)") }
        if !row.composer.isEmpty { extra.append("composer=\(Self.oneLine(row.composer))") }
        if row.bpm > 0 { extra.append("bpm=\(row.bpm)") }
        if row.compilation { extra.append("compilation") }
        if !row.kind.isEmpty { extra.append("kind=\(row.kind)") }
        let size = Self.megabytes(row.size)
        if !size.isEmpty { extra.append("size=\(size)") }
        if !row.cloudStatus.isEmpty { extra.append("cloud=\(row.cloudStatus)") }
        let comment = Self.rowComment(row)
        if !comment.isEmpty { extra.append("comment=\(comment)") }

        var lines = ["   " + facts.joined(separator: " · ")]
        if !extra.isEmpty { lines.append("   " + extra.joined(separator: " · ")) }
        return lines
    }

    /// Numbered from the row's place in the whole listing, so the number of the last row
    /// on a page is the offset of the next one.
    func rows(_ rows: [TrackRow], startingAt offset: Int) -> [String] {
        rows.enumerated().flatMap { index, row in
            ["\(offset + index + 1). \(Self.headline(row))"] + rowLines(row)
        }
    }

    // MARK: Tools

    public func status(_ state: MusicAvailability, binaryPath: String, timeout: Duration) -> String {
        let headline: String
        switch state {
        case .ready: headline = "Music: RUNNING, automation permitted."
        case .notInstalled: headline = "Music: NOT INSTALLED."
        case .notRunning: headline = "Music: NOT RUNNING."
        case .automationDenied: headline = "Music automation: DENIED."
        case .consentNotGranted: headline = "Music automation: not requested yet."
        }

        var text = headline + "\n\n"
        // The bounds in force: a limit that is only in the code is otherwise invisible,
        // and has to be inferred from odd behaviour.
        text += Self.block([
            ("binary", binaryPath),
            ("target", ScriptingBridgeMusicStore.bundleIdentifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("search scan", "\(ToolCatalog.scanCeiling) tracks per music_search call"),
            (
                "track rows",
                "\(ToolCatalog.defaultTrackLimit) to a page, \(ToolCatalog.trackLimitRange.upperBound) at most"
            ),
            (
                "playlists",
                "\(ToolCatalog.defaultPlaylistLimit) to a page, \(ToolCatalog.playlistLimitRange.upperBound) at most"
            ),
            ("time limit", "\(timeout.components.seconds) seconds per call"),
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
                ("playlist", Self.oneLine(status.playlistName)),
            ]))
        lines.append("")
        lines.append(contentsOf: rowLines(track))
        return ToolStandard.withNotices(Self.commentNotice([track]), lines.joined(separator: "\n"))
    }

    /// One page of `tracks_list`, read at the source. `tracks` is the page to show, which
    /// can be shorter than what `read` holds when the rows were too wide to fit.
    public func trackListing(
        _ tracks: [TrackRow], offset: Int, read: TrackPage, scope: String, order: String,
        notices: [String]
    ) -> String {
        let notices =
            notices + Self.position(shown: tracks.count, offset: offset, read: read, things: "tracks")
            + Self.commentNotice(tracks)
        var text: String
        if let total = read.total(after: offset, shown: tracks.count) {
            guard total > 0 else {
                return ToolStandard.withNotices(notices, "No tracks match \(scope).")
            }
            text = "\(Self.plural(total, "track")) \(total == 1 ? "matches" : "match") \(scope), in \(order)."
        } else {
            text = "Tracks matching \(scope), in \(order)."
        }
        text += "\n\n"
        text += tracks.isEmpty
            ? "  " + Self.nothing("(none read)", skipped: offset)
            : rows(tracks, startingAt: offset).joined(separator: "\n")
        return ToolStandard.withNotices(notices, text)
    }

    /// One page of the tracks a search found. `tracks` is the page; `matching` counts every
    /// match among the `read.scanned` tracks the scan read. The caller supplies the notices,
    /// the page's position among them.
    public func searchTracks(
        _ tracks: [TrackRow], offset: Int, matching: Int, read: TrackPage, scope: String,
        order: String
    ) -> String {
        guard matching > 0 else { return "No tracks match \(scope)\(Self.scanned(read))." }
        var text = "\(Self.plural(matching, "track")) \(matching == 1 ? "matches" : "match") \(scope)"
        text += "\(Self.scanned(read)), in \(order).\n\n"
        text += tracks.isEmpty
            ? "  " + Self.nothing("(none)", skipped: offset)
            : rows(tracks, startingAt: offset).joined(separator: "\n")
        return text
    }

    /// Qualifies a count when the scan did not reach the end of the candidates, so that
    /// "3 tracks match" is never read as "3 tracks in the library match".
    static func scanned(_ read: TrackPage) -> String {
        if case .end = read.stop { return "" }
        let all = read.total(after: 0, shown: read.scanned).map { " of \($0)" } ?? ""
        return " among the \(Self.plural(read.scanned, "track")) scanned\(all)"
    }

    /// One page of the albums or artists a search found. `groups` is the page; `matching`
    /// counts every group.
    public func groups(
        _ groups: [LibraryGroup], offset: Int, matching: Int, kind: String, read: TrackPage,
        scope: String
    ) -> String {
        guard matching > 0 else { return "No \(kind) match \(scope)\(Self.scanned(read))." }
        var lines = [
            "\(matching) \(matching == 1 ? String(kind.dropLast()) + " matches" : kind + " match") "
                + "\(scope)\(Self.scanned(read)), ordered by matching tracks (most first), then name."
        ]
        lines.append("")
        if groups.isEmpty {
            lines.append("  " + Self.nothing("(none)", skipped: offset))
        }
        let width = groups.map { Self.oneLine($0.name).count }.max() ?? 0
        for group in groups {
            var line = "  " + Self.pad(Self.oneLine(group.name), to: width)
            if !group.detail.isEmpty { line += "  — \(Self.oneLine(group.detail))" }
            line += "  · \(Self.plural(group.trackCount, "track"))"
            lines.append(line)
        }
        lines.append("")
        lines.append(
            "Counts are of the tracks this search read and matched, not of the whole library. "
                + "Search with type tracks for the rows behind them.")
        return lines.joined(separator: "\n")
    }

    /// One page of playlists. `playlists` is the page; `matching` counts every playlist the
    /// listing or the search holds. `scope` is the query of a search, or nil for the list.
    public func playlistList(
        _ playlists: [PlaylistInfo], offset: Int, matching: Int, scope: String? = nil
    ) -> String {
        guard matching > 0 else {
            return scope.map { "No playlists match \($0)." } ?? "No playlists."
        }
        var lines = [
            Self.plural(matching, "playlist")
                + (scope.map { " \(matching == 1 ? "matches" : "match") \($0)" } ?? "")
                + ", in Music's own order."
        ]
        lines.append("")
        if playlists.isEmpty {
            lines.append("  " + Self.nothing("(none)", skipped: offset))
        }
        let width = playlists.map { Self.oneLine($0.name).count }.max() ?? 0
        for playlist in playlists {
            var line = "  " + Self.pad(Self.oneLine(playlist.name), to: width)
            line += "  \(Self.plural(playlist.trackCount, "track"))"
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

    /// A playlist's details and one page of its tracks, read at the source. `tracks` is the
    /// page to show, which can be shorter than what `read` holds when the rows were too
    /// wide to fit.
    public func playlistDetail(
        _ playlist: PlaylistInfo, tracks: [TrackRow], offset: Int, read: TrackPage,
        notices: [String]
    ) -> String {
        let notices =
            notices
            + Self.position(
                shown: tracks.count, offset: offset, read: read, expected: playlist.trackCount,
                things: "tracks")
            + Self.commentNotice(tracks)
        var lines = [Self.oneLine(playlist.name)]
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
            lines.append(Self.nothing("The playlist is empty.", skipped: offset))
        } else {
            lines.append("Tracks, in playlist order:")
            lines.append(contentsOf: rows(tracks, startingAt: offset))
        }
        return ToolStandard.withNotices(notices, lines.joined(separator: "\n"))
    }

    /// Everything about one track but its lyrics, as a labelled block.
    func trackFields(_ row: TrackRow, comment: String) -> String {
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
            ("comment", comment),
        ])
    }

    static func lyricsLines(_ lyrics: String) -> String {
        guard !lyrics.isEmpty else { return "  lyrics   (none stored)" }
        return "  lyrics\n"
            + lyrics.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "    \($0)" }.joined(separator: "\n")
    }

    /// The whole record of one track, comment and lyrics uncut. It is the text `track_get`
    /// windows when it is asked for a single id, so its length is the caller's to page.
    public func trackRecord(_ detail: TrackDetail) -> String {
        [
            Self.headline(detail.row), "", trackFields(detail.row, comment: detail.row.comment), "",
            Self.lyricsLines(detail.lyrics),
        ].joined(separator: "\n")
    }

    /// Several tracks in one result: each record whole except its lyrics, cut to
    /// `lyricsWidth` characters, and its comment, cut as a row cuts it. Several long texts
    /// are never returned whole; one id reads one in full.
    ///
    /// `heldIDs` are the tracks that were found and are not in `details`, because their
    /// records, even shortened, were too long to fit one result together.
    public func trackRecords(
        _ details: [TrackDetail], heldIDs: [String], missing: [String], lyricsWidth: Int,
        notices: [String]
    ) -> String {
        var notices = notices
        let single = "\(ToolCatalog.trackGetName) and a single id"
        if !heldIDs.isEmpty {
            // Named, so the caller can ask for exactly these. The list is at most the
            // number of ids a call takes, each echoed at a fixed width.
            let named = heldIDs.map(ToolStandard.echo).joined(separator: ", ")
            notices.append(
                Notice.notShown(
                    count: heldIDs.count, things: "track(s) asked for",
                    pass: "these ids in another call (\(named))"))
        }
        if details.contains(where: { $0.lyrics.count > lyricsWidth }) {
            notices.append(Notice.clipped(field: "Lyrics", width: lyricsWidth, tool: single))
        }
        if details.contains(where: { $0.row.comment.count > ToolCatalog.commentClipWidth }) {
            notices.append(
                Notice.clipped(field: "Comment", width: ToolCatalog.commentClipWidth, tool: single))
        }
        var blocks: [String] = []
        // First, like a notice: these are tracks that were asked for and are not below.
        if !missing.isEmpty {
            blocks.append(
                "Not found: \(missing.map(ToolStandard.echo).joined(separator: ", ")) — run "
                    + "music_search again, a persistent id does not survive the track leaving "
                    + "the library.")
        }
        for detail in details {
            blocks.append(
                [
                    Self.headline(detail.row), "",
                    trackFields(
                        detail.row, comment: Self.clip(detail.row.comment, to: ToolCatalog.commentClipWidth)),
                    "", Self.lyricsLines(Self.clip(detail.lyrics, to: lyricsWidth)),
                ].joined(separator: "\n"))
        }
        return ToolStandard.withNotices(notices, blocks.joined(separator: "\n\n"))
    }

    public func createdPlaylist(_ playlist: PlaylistInfo) -> String {
        """
        Created the playlist "\(Self.oneLine(playlist.name))". It is empty.

        \(Self.block([("id", playlist.persistentID)]))

        Add tracks with add_to_playlist(playlist_id="\(playlist.persistentID)", track_ids=[…]).
        """
    }

    /// One id a line. Each is the caller's own text, so it is repeated only as an error
    /// would repeat it.
    static func idList(_ ids: [String]) -> String {
        ids.map { "  " + ToolStandard.echo($0) }.joined(separator: "\n")
    }

    /// `skipDuplicatesRequested` is passed separately rather than inferred from a
    /// non-empty `duplicates`, because the two silences mean different things: with the
    /// guard off nothing was ever checked, and reporting that as "no duplicates" would be
    /// a claim this server never verified.
    ///
    /// Both lists are bounded by `ToolCatalog.addedTracksRange`, the most ids one call
    /// takes, so they are given whole: which ids did not go in is the point of the answer.
    public func added(_ outcome: AddOutcome, skipDuplicatesRequested: Bool) -> String {
        var text =
            "Added \(Self.plural(outcome.added, "track")) "
            + "to \"\(Self.oneLine(outcome.playlistName))\". Nothing already in it was changed."
        if skipDuplicatesRequested {
            if outcome.duplicates.isEmpty {
                text += " None of the ids given were already in the playlist."
            } else {
                let one = outcome.duplicates.count == 1
                text += "\n\n\(Self.plural(outcome.duplicates.count, "id")) \(one ? "was" : "were") "
                text += "already in the playlist and \(one ? "was" : "were") not added again:\n"
                text += Self.idList(outcome.duplicates)
            }
        }
        if !outcome.missing.isEmpty {
            let one = outcome.missing.count == 1
            text += "\n\n\(Self.plural(outcome.missing.count, "id")) did not resolve and "
            text += "\(one ? "was" : "were") skipped:\n"
            text += Self.idList(outcome.missing)
            text += "\n\nA persistent id stops resolving once the track leaves the library. Look "
            text += "them up again with music_search."
        }
        return text
    }

    public func controlled(
        _ command: PlaybackCommand, status: PlayerStatus, notices: [String]
    ) -> String {
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
        return ToolStandard.withNotices(notices, text)
    }
}
