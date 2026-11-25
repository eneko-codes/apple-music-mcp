import Foundation

/// An album or an artist, counted off the rows a query scanned.
///
/// Not a model type: Music's dictionary has no album and no artist object, so neither
/// crosses the seam. Both are a plain group-by over track rows, which is the only kind of
/// aggregate this server does — a count, never a score or a ranking.
public struct LibraryGroup: Sendable, Equatable {
    public let name: String
    /// The album artist, for an album row. Empty for an artist row.
    public let detail: String
    public let trackCount: Int
}

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event itself — everything goes through `MusicStore`, which is
/// what lets the tests drive every branch below with Music closed and the owner's library
/// untouched.
public struct MusicTools: ToolHandler {
    private let store: any MusicStore
    private let calendar: Calendar
    private let format: Format
    private let timeout: Duration
    private let readBudget: Duration

    /// How long a call may take before it is abandoned and answered with an error. It
    /// stays under the 60 s a client commonly waits, and so well under
    /// `ToolStandard.timeLimit`, so that the answer is this server's own and says what to
    /// do next, not a client's generic "no result".
    public static let defaultTimeout = Duration.seconds(55)

    /// How long a walk of tracks may go on reading. It ends before the call's own deadline
    /// so that a walk cut short still has time to return what it read, as a partial result
    /// that says so.
    public static let defaultReadBudget = Duration.seconds(40)

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    public init(
        store: any MusicStore, calendar: Calendar = .current,
        timeout: Duration = MusicTools.defaultTimeout,
        readBudget: Duration = MusicTools.defaultReadBudget
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.timeout = timeout
        self.readBudget = readBudget
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds), tool: parameters.name),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let known = error as? ToolError ?? .storeFailure(error.localizedDescription)
        return ToolOutput(text: known.message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        guard let tool = ToolCatalog.all().first(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }
        let arguments = Arguments(parameters.arguments, calendar: calendar)
        try arguments.check(against: ToolCatalog.argumentNames(of: tool), tool: tool.name)
        // Fixed when the call starts, so the time spent before a walk counts against it.
        let readDeadline = Date().addingTimeInterval(MusicTools.seconds(readBudget))

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(store.availability(), binaryPath: Self.binaryPath, timeout: timeout)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through: sending
        // the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.nowPlayingName:
            return format.nowPlaying(try await store.playerStatus())

        case ToolCatalog.searchName:
            return try await search(arguments, readDeadline: readDeadline)

        case ToolCatalog.tracksName:
            return try await tracksList(arguments, readDeadline: readDeadline)

        case ToolCatalog.playlistsName:
            return try await playlistsList(arguments)

        case ToolCatalog.playlistGetName:
            return try await playlistGet(arguments, readDeadline: readDeadline)

        case ToolCatalog.trackGetName:
            return try await trackGet(arguments)

        case ToolCatalog.createPlaylistName:
            return try await createPlaylist(arguments)

        case ToolCatalog.addToPlaylistName:
            return try await addToPlaylist(arguments)

        case ToolCatalog.controlName:
            return try await control(arguments)

        default:
            throw ToolError.unknownTool(parameters.name)
        }
    }

    // MARK: Reads

    private func search(_ arguments: Arguments, readDeadline: Date) async throws -> String {
        let query = try arguments.requiredString("query")
        let type = try arguments.searchType()
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultTrackLimit, limits: ToolCatalog.trackLimitRange)

        var filter = TrackFilter()
        filter.text = query
        filter.genre = try arguments.optionalString("genre")
        filter.yearFrom = try arguments.optionalInt("year_from", in: ToolCatalog.yearRange)
        filter.yearTo = try arguments.optionalInt("year_to", in: ToolCatalog.yearRange)
        filter.playlistPersistentID = try arguments.optionalString("playlist_id")
        try Self.checkYears(filter)

        switch type {
        case .playlists:
            // Refused, not ignored: a narrowing argument that silently fell away would
            // leave the caller believing the answer was narrowed.
            for (name, given) in [
                ("genre", filter.genre != nil), ("year_from", filter.yearFrom != nil),
                ("year_to", filter.yearTo != nil), ("playlist_id", filter.playlistPersistentID != nil),
            ] where given {
                throw ToolError.badArgument(
                    name: name,
                    reason: "it narrows a search for tracks, albums or artists; a search for "
                        + "playlists takes query, limit and offset only")
            }
            // Playlist names are already in hand from the playlist listing, so this mode
            // answers without walking the library at all.
            let matches = try await store.playlists().filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
            return ToolStandard.page(
                of: matches, limit: page.limit, offset: page.offset, things: "playlists",
                notices: arguments.notices
            ) {
                format.playlistList(
                    $0, offset: page.offset, matching: matches.count, scope: Self.quoted(query))
            }

        case .tracks:
            let read = try await scan(filter, until: readDeadline)
            return ToolStandard.page(
                of: read.rows, limit: page.limit, offset: page.offset, things: "tracks",
                notices: arguments.notices + Self.scanNotice(read)
            ) {
                ToolStandard.withNotices(
                    Format.commentNotice($0),
                    format.searchTracks(
                        $0, offset: page.offset, matching: read.rows.count, read: read,
                        scope: Self.describe(filter), order: Self.order(filter)))
            }

        case .albums, .artists:
            let read = try await scan(filter, until: readDeadline)
            let groups = type == .albums ? Self.albums(read.rows) : Self.artists(read.rows)
            // A matching track with no album, or no artist, belongs to no group. It is
            // counted here so that the groups are not taken for every match.
            let field = type == .albums ? "album" : "artist"
            let ungrouped = read.rows.count - groups.reduce(0) { $0 + $1.trackCount }
            let outside =
                ungrouped > 0
                ? [
                    Notice.notShown(
                        count: ungrouped, things: "matching tracks with no \(field)",
                        pass: "type=tracks")
                ] : []
            return ToolStandard.page(
                of: groups, limit: page.limit, offset: page.offset, things: type.rawValue,
                notices: arguments.notices + Self.scanNotice(read) + outside
            ) {
                format.groups(
                    $0, offset: page.offset, matching: groups.count, kind: type.rawValue,
                    read: read, scope: Self.describe(filter))
            }
        }
    }

    /// Reads the tracks a search matches its query against: the first
    /// `ToolCatalog.scanCeiling` candidates, or as many as the time allows.
    ///
    /// The whole scan is read before a page is cut from it, because the query is matched
    /// here and not by Music: where the matches fall is only known once the rows are read.
    private func scan(_ filter: TrackFilter, until readDeadline: Date) async throws -> TrackPage {
        try await store.tracks(
            matching: filter, walk: TrackWalk(read: ToolCatalog.scanCeiling, deadline: readDeadline))
    }

    /// The sentence for a search whose scan did not look at every candidate, with the
    /// arguments that make Music hand over fewer of them.
    static func scanNotice(_ read: TrackPage) -> [String] {
        switch read.stop {
        case .end: return []
        case .readLimit:
            return [
                Notice.scanStopped(
                    after: read.scanned, things: "tracks", narrowBy: ToolCatalog.searchNarrowing)
            ]
        case .deadline:
            return [
                Notice.partial(
                    after: read.scanned, things: "tracks", narrowBy: ToolCatalog.searchNarrowing)
            ]
        }
    }

    private func tracksList(_ arguments: Arguments, readDeadline: Date) async throws -> String {
        var filter = TrackFilter()
        filter.genre = try arguments.optionalString("genre")
        filter.yearFrom = try arguments.optionalInt("year_from", in: ToolCatalog.yearRange)
        filter.yearTo = try arguments.optionalInt("year_to", in: ToolCatalog.yearRange)
        filter.addedFrom = try arguments.optionalDate("from_date")?.date
        // "Added on or before 12 August" has to include the whole of the 12th; a bare day
        // parses to midnight, which would exclude everything added that day.
        filter.addedTo = try arguments.optionalDate("to_date").map { parsed in
            parsed.isDateOnly ? Self.endOfDay(parsed.date, calendar: calendar) : parsed.date
        }
        filter.playedCountFrom = try arguments.optionalInt(
            "played_count_from", in: ToolCatalog.playedCountRange)
        filter.playedCountTo = try arguments.optionalInt(
            "played_count_to", in: ToolCatalog.playedCountRange)
        filter.ratingFrom = try arguments.optionalInt("rating_from", in: ToolCatalog.ratingRange)
        filter.favorited = try arguments.optionalBool("favorited")
        filter.playlistPersistentID = try arguments.optionalString("playlist_id")

        try Self.checkYears(filter)
        if let from = filter.playedCountFrom, let to = filter.playedCountTo, from > to {
            throw ToolError.badArgument(
                name: "played_count_to", reason: "it is below 'played_count_from' (\(from))")
        }
        if let from = filter.addedFrom, let to = filter.addedTo, from > to {
            throw ToolError.badArgument(
                name: "to_date", reason: "it is before 'from_date'")
        }

        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultTrackLimit, limits: ToolCatalog.trackLimitRange)

        // Paged at the source: the store passes over `offset` candidates and only the rows
        // of the page cross the Apple event boundary, so no offset is out of reach.
        let read = try await store.tracks(
            matching: filter,
            walk: TrackWalk(skip: page.offset, read: page.limit, deadline: readDeadline))
        let scope = Self.describe(filter)
        return ToolStandard.fitting(page.limit) { size in
            format.trackListing(
                Array(read.rows.prefix(size)), offset: page.offset, read: read, scope: scope,
                order: Self.order(filter), notices: arguments.notices)
        }
    }

    private func playlistsList(_ arguments: Arguments) async throws -> String {
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultPlaylistLimit, limits: ToolCatalog.playlistLimitRange)
        // In the order Music hands them over: it is a position, so no two playlists tie
        // and a page boundary falls in the same place on the next call.
        let playlists = try await store.playlists()
        return ToolStandard.page(
            of: playlists, limit: page.limit, offset: page.offset, things: "playlists",
            notices: arguments.notices
        ) {
            format.playlistList($0, offset: page.offset, matching: playlists.count)
        }
    }

    private func playlistGet(_ arguments: Arguments, readDeadline: Date) async throws -> String {
        let id = try arguments.requiredString("id")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultTrackLimit, limits: ToolCatalog.trackLimitRange)
        guard let playlist = try await store.playlists().first(where: { $0.persistentID == id })
        else { throw ToolError.playlistNotFound(id: id) }

        var filter = TrackFilter()
        filter.playlistPersistentID = id
        let read = try await store.tracks(
            matching: filter,
            walk: TrackWalk(skip: page.offset, read: page.limit, deadline: readDeadline))
        return ToolStandard.fitting(page.limit) { size in
            format.playlistDetail(
                playlist, tracks: Array(read.rows.prefix(size)), offset: page.offset, read: read,
                notices: arguments.notices)
        }
    }

    private func trackGet(_ arguments: Arguments) async throws -> String {
        let ids = try arguments.stringArray("ids")
        guard !ids.isEmpty else { throw ToolError.missingArgument("ids") }
        let most = ToolCatalog.trackIDsRange.upperBound
        guard ids.count <= most else {
            throw ToolError.tooManyIDs(argument: "ids", given: ids.count, most: most)
        }
        // Refused, not ignored: a window over several records would be read as having
        // returned the part of each that was asked for.
        for name in ["character_offset", "max_characters"] where ids.count > 1 && arguments.has(name) {
            throw ToolError.badArgument(
                name: name,
                reason: "it windows the record of one track, and \(ids.count) ids were given; "
                    + "pass a single id")
        }
        let window = try arguments.window()

        var details: [TrackDetail] = []
        var missing: [String] = []
        for id in ids {
            if let detail = try await store.track(persistentID: id) {
                details.append(detail)
            } else {
                missing.append(id)
            }
        }
        // Every id missing is a failure worth erroring on; some missing is a partial
        // answer, and swallowing the good rows to report the bad ones helps nobody.
        guard !details.isEmpty else { throw ToolError.notFound(ids: ids) }

        // One id is one long text, read through a window. Several are rows that each hold
        // a long text, so the long fields are cut and one id reads them whole.
        if ids.count == 1, let detail = details.first {
            let record = format.trackRecord(detail)
            return ToolStandard.fitting(window.maxCharacters) { size in
                let part = ToolStandard.window(
                    of: record, characterOffset: window.characterOffset, maxCharacters: size)
                return ToolStandard.withNotices(
                    arguments.notices + [part.notice].compactMap { $0 }, part.text)
            }
        }
        // The lyrics are shortened further before any record is held back: a record left
        // out costs the caller another call, a shorter lyric only the single-id read it
        // was already told about.
        return ToolStandard.fitting(details.count) { count in
            ToolStandard.fitting(ToolCatalog.lyricsClipWidth) { width in
                format.trackRecords(
                    Array(details.prefix(count)), heldIDs: details.dropFirst(count).map(\.row.persistentID), missing: missing,
                    lyricsWidth: width, notices: arguments.notices)
            }
        }
    }

    // MARK: Writes

    private func createPlaylist(_ arguments: Arguments) async throws -> String {
        let name = try arguments.requiredString("name")
        guard name.count <= ToolCatalog.longestPlaylistName else {
            throw ToolError.badArgument(
                name: "name",
                reason: "at most \(ToolCatalog.longestPlaylistName) characters were expected, "
                    + "and it has \(name.count)")
        }
        // Checked here as well as in the bridge so the refusal is reachable from the
        // tests, and so the message names the tool that should have been called instead.
        if try await store.playlists().contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            throw ToolError.playlistExists(name: name)
        }
        return format.createdPlaylist(try await store.createPlaylist(named: name))
    }

    private func addToPlaylist(_ arguments: Arguments) async throws -> String {
        let playlistID = try arguments.requiredString("playlist_id")
        let trackIDs = try arguments.stringArray("track_ids")
        guard !trackIDs.isEmpty else { throw ToolError.noTracksGiven }
        // Refused whole, before anything is added: adding the first hundred and dropping
        // the rest would leave a playlist the caller believes is complete.
        let most = ToolCatalog.addedTracksRange.upperBound
        guard trackIDs.count <= most else {
            throw ToolError.tooManyIDs(argument: "track_ids", given: trackIDs.count, most: most)
        }
        let skipDuplicates = try arguments.bool("skip_duplicates", default: false)

        guard
            let playlist = try await store.playlists().first(where: {
                $0.persistentID == playlistID
            })
        else { throw ToolError.playlistNotFound(id: playlistID) }

        guard playlist.isEditable else {
            throw ToolError.playlistNotEditable(
                name: playlist.name, reason: Self.notEditableReason(playlist))
        }

        return format.added(
            try await store.addTracks(
                persistentIDs: trackIDs, toPlaylist: playlistID,
                skipDuplicates: skipDuplicates),
            skipDuplicatesRequested: skipDuplicates)
    }

    private func control(_ arguments: Arguments) async throws -> String {
        let command = try arguments.command()
        let volume = try arguments.optionalInt("volume", in: ToolCatalog.volumeRange)
        // Refused rather than defaulted: a "volume" call with no level would otherwise
        // have to pick one, and any number it picked would be somebody's living room.
        if command == .volume, volume == nil { throw ToolError.volumeRequired }

        let status = try await store.control(command, volume: volume)
        return format.controlled(command, status: status, notices: arguments.notices)
    }

    // MARK: Grouping

    /// Distinct albums among the scanned rows, with the track count for each.
    ///
    /// Keyed on album plus album artist so two records called "Greatest Hits" by
    /// different artists stay apart. Order is by count, then name, then artist, so that no
    /// two albums tie and a page boundary falls in the same place on the next call. It is
    /// a presentation choice and not a ranking: the count is printed beside every row, so
    /// nothing is hidden behind the ordering.
    static func albums(_ rows: [TrackRow]) -> [LibraryGroup] {
        var counts: [String: (album: String, artist: String, count: Int)] = [:]
        for row in rows where !row.album.isEmpty {
            let artist = row.albumArtist.isEmpty ? row.artist : row.albumArtist
            let key = "\(row.album)\u{1F}\(artist)"
            counts[key, default: (row.album, artist, 0)].count += 1
        }
        return counts.values
            .sorted {
                ($1.count, $0.album, $0.artist) < ($0.count, $1.album, $1.artist)
            }
            .map { LibraryGroup(name: $0.album, detail: $0.artist, trackCount: $0.count) }
    }

    static func artists(_ rows: [TrackRow]) -> [LibraryGroup] {
        var counts: [String: Int] = [:]
        for row in rows where !row.artist.isEmpty {
            counts[row.artist, default: 0] += 1
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { LibraryGroup(name: $0.key, detail: "", trackCount: $0.value) }
    }

    // MARK: Helpers

    /// A caller's text as a result repeats it: quoted, and no longer than an error would
    /// repeat it, so no result grows with what it was sent.
    static func quoted(_ text: String) -> String {
        "'\(ToolStandard.echo(text))'"
    }

    /// The order Music hands tracks over in, as a result states it: a playlist's own when
    /// the walk is of one playlist, the library's otherwise.
    static func order(_ filter: TrackFilter) -> String {
        filter.playlistPersistentID == nil ? "library order" : "playlist order"
    }

    /// A range that ends before it starts is refused, with the bound it contradicts.
    static func checkYears(_ filter: TrackFilter) throws {
        if let from = filter.yearFrom, let to = filter.yearTo, from > to {
            throw ToolError.badArgument(
                name: "year_to", reason: "it is before 'year_from' (\(from))")
        }
    }

    /// Echoing the scope back means a caller can see that its filters were understood the
    /// way it meant them.
    static func describe(_ filter: TrackFilter) -> String {
        var parts: [String] = []
        if let text = filter.text { parts.append(quoted(text)) }
        if let genre = filter.genre { parts.append("genre \(ToolStandard.echo(genre))") }
        if let from = filter.yearFrom { parts.append("year ≥ \(from)") }
        if let to = filter.yearTo { parts.append("year ≤ \(to)") }
        if filter.addedFrom != nil { parts.append("added from") }
        if filter.addedTo != nil { parts.append("added to") }
        if let from = filter.playedCountFrom { parts.append("played ≥ \(from)") }
        if let to = filter.playedCountTo { parts.append("played ≤ \(to)") }
        if let rating = filter.ratingFrom { parts.append("rating ≥ \(rating)") }
        if let favorited = filter.favorited {
            parts.append(favorited ? "favourites" : "not favourited")
        }
        if filter.playlistPersistentID != nil { parts.append("in one playlist") }
        return parts.isEmpty ? "the whole library" : parts.joined(separator: " · ")
    }

    static func notEditableReason(_ playlist: PlaylistInfo) -> String {
        if playlist.isGenius { return "it is a Genius playlist." }
        if playlist.isSmart { return "it is a smart playlist." }
        if playlist.specialKind.isEmpty { return "Music will not accept tracks for it." }
        return "it is the \(playlist.specialKind.lowercased()) playlist."
    }

    static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: date))
            ?? date
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
