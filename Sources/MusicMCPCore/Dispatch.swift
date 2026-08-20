import Foundation
import MCP

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
public struct MusicTools: Sendable {
    private let store: any MusicStore
    private let calendar: Calendar
    private let configuration: Configuration
    private let format: Format

    public init(
        store: any MusicStore, calendar: Calendar = .current,
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.calendar = calendar
        self.configuration = configuration
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.availability(), binaryPath: Self.binaryPath, configuration: configuration)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through: sending
        // the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.nowPlayingName:
            return format.nowPlaying(try await store.playerStatus())

        case ToolCatalog.searchName:
            return try await search(arguments)

        case ToolCatalog.tracksName:
            return try await tracksList(arguments)

        case ToolCatalog.playlistsName:
            return format.playlistList(try await store.playlists())

        case ToolCatalog.playlistGetName:
            return try await playlistGet(arguments)

        case ToolCatalog.trackGetName:
            return try await trackGet(arguments)

        case ToolCatalog.createPlaylistName:
            return try await createPlaylist(arguments)

        case ToolCatalog.addToPlaylistName:
            return try await addToPlaylist(arguments)

        case ToolCatalog.controlName:
            return try await control(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    // MARK: Reads

    private func search(_ arguments: Arguments) async throws -> String {
        let query = try arguments.requiredString("query")
        let type = try arguments.searchType()
        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)

        switch type {
        // Playlist names are already in hand from playlists_list, so this mode answers
        // without walking the library at all.
        case .playlists:
            let matches = try await store.playlists().filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
            guard !matches.isEmpty else { return "No playlists match '\(query)'." }
            return format.playlistList(Array(matches.prefix(limit)))

        case .tracks:
            let page = try await matchingTracks(query)
            return format.trackResults(
                Array(page.results.prefix(limit)), total: page.total, offset: 0,
                hitScanLimit: page.hitScanLimit, describing: "'\(query)'")

        case .albums:
            let page = try await matchingTracks(query)
            return format.groups(
                Array(Self.albums(page.results).prefix(limit)), kind: "albums",
                scope: "'\(query)'", hitScanLimit: page.hitScanLimit)

        case .artists:
            let page = try await matchingTracks(query)
            return format.groups(
                Array(Self.artists(page.results).prefix(limit)), kind: "artists",
                scope: "'\(query)'", hitScanLimit: page.hitScanLimit)
        }
    }

    private func matchingTracks(_ query: String) async throws -> TrackPage {
        var filter = TrackFilter()
        filter.text = query
        return try await store.tracks(matching: filter, scanCeiling: Configuration.scanCeiling)
    }

    private func tracksList(_ arguments: Arguments) async throws -> String {
        var filter = TrackFilter()
        filter.genre = arguments.optionalString("genre")
        filter.yearFrom = try arguments.optionalInt("year_from", in: 0...3000)
        filter.yearTo = try arguments.optionalInt("year_to", in: 0...3000)
        filter.addedFrom = try arguments.optionalDate("added_from")?.date
        // "Added on or before 12 August" has to include the whole of the 12th; a bare day
        // parses to midnight, which would exclude everything added that day.
        filter.addedTo = try arguments.optionalDate("added_to").map { parsed in
            parsed.isDateOnly ? Self.endOfDay(parsed.date, calendar: calendar) : parsed.date
        }
        filter.playedCountFrom = try arguments.optionalInt("played_count_from", in: 0...1_000_000)
        filter.playedCountTo = try arguments.optionalInt("played_count_to", in: 0...1_000_000)
        filter.ratingFrom = try arguments.optionalInt("rating_from", in: 0...100)
        filter.favorited = arguments.optionalBool("favorited")
        filter.playlistPersistentID = arguments.optionalString("playlist_id")

        if let from = filter.yearFrom, let to = filter.yearTo, from > to {
            throw ToolError.badArgument(
                name: "year_to", reason: "it is before 'year_from' (\(from))")
        }
        if let from = filter.playedCountFrom, let to = filter.playedCountTo, from > to {
            throw ToolError.badArgument(
                name: "played_count_to", reason: "it is below 'played_count_from' (\(from))")
        }
        if let from = filter.addedFrom, let to = filter.addedTo, from > to {
            throw ToolError.badArgument(
                name: "added_to", reason: "it is before 'added_from'")
        }

        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        let page = try await store.tracks(matching: filter, scanCeiling: Configuration.scanCeiling)
        let window = Array(page.results.dropFirst(offset).prefix(limit))
        return format.trackResults(
            window, total: page.total, offset: offset, hitScanLimit: page.hitScanLimit,
            describing: Self.describe(filter))
    }

    private func playlistGet(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredString("id")
        guard let playlist = try await store.playlists().first(where: { $0.persistentID == id })
        else { throw ToolError.playlistNotFound(id: id) }

        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        var filter = TrackFilter()
        filter.playlistPersistentID = id
        let page = try await store.tracks(matching: filter, scanCeiling: Configuration.scanCeiling)
        let window = Array(page.results.dropFirst(offset).prefix(limit))
        return format.playlistDetail(
            playlist, tracks: window, total: page.total, offset: offset)
    }

    private func trackGet(_ arguments: Arguments) async throws -> String {
        let ids = try arguments.stringArray("ids")
        guard !ids.isEmpty else { throw ToolError.missingArgument("ids") }

        var details: [TrackDetail] = []
        var missing: [String] = []
        for id in ids {
            if let detail = try await store.track(
                persistentID: id, lyricsLimit: configuration.lyricsLimit)
            {
                details.append(detail)
            } else {
                missing.append(id)
            }
        }
        // Every id missing is a failure worth erroring on; some missing is a partial
        // answer, and swallowing the good rows to report the bad ones helps nobody.
        guard !details.isEmpty else { throw ToolError.notFound(id: ids.joined(separator: ", ")) }
        return format.trackDetails(details, missing: missing)
    }

    // MARK: Writes

    private func createPlaylist(_ arguments: Arguments) async throws -> String {
        let name = try arguments.requiredString("name")
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
        let skipDuplicates = arguments.bool("skip_duplicates")

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
        let volume = try arguments.optionalInt("volume", in: 0...100)
        // Refused rather than defaulted: a "volume" call with no level would otherwise
        // have to pick one, and any number it picked would be somebody's living room.
        if command == .volume, volume == nil { throw ToolError.volumeRequired }

        let status = try await store.control(command, volume: volume)
        return format.controlled(command, status: status)
    }

    // MARK: Grouping

    /// Distinct albums among the scanned rows, with the track count for each.
    ///
    /// Keyed on album plus album artist so two records called "Greatest Hits" by
    /// different artists stay apart. Order is by count then name, which is a stable
    /// presentation choice and not a ranking: the count is printed beside every row, so
    /// nothing is hidden behind the ordering.
    static func albums(_ rows: [TrackRow]) -> [LibraryGroup] {
        var counts: [String: (album: String, artist: String, count: Int)] = [:]
        for row in rows where !row.album.isEmpty {
            let artist = row.albumArtist.isEmpty ? row.artist : row.albumArtist
            let key = "\(row.album)\u{1F}\(artist)"
            counts[key, default: (row.album, artist, 0)].count += 1
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.album < $1.album }
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

    /// Echoing the scope back means a caller can see that its filters were understood the
    /// way it meant them.
    static func describe(_ filter: TrackFilter) -> String {
        var parts: [String] = []
        if let text = filter.text { parts.append("'\(text)'") }
        if let genre = filter.genre { parts.append("genre \(genre)") }
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
