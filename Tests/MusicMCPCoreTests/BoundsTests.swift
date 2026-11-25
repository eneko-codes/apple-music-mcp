import Dispatch
import Foundation
import Testing

@testable import MusicMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every track, playlist, comment and lyric in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: An invented library with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    private static func trackID(_ index: Int) -> String {
        String(format: "%016X", index + 1)
    }

    /// A track with every field set, each about as long as an ordinary one gets, so that
    /// its row is the widest an ordinary row is. `widePageShrinks` covers the rows that are
    /// wider still.
    private static func track(
        _ index: Int, name: String? = nil, genre: String = "Alternative", year: Int = 2021,
        comment: String? = nil
    ) -> TrackRow {
        TrackRow(
            persistentID: trackID(index),
            name: name ?? "Invented Track \(padded(index)) of the Record",
            artist: "Invented Artist \(padded(index))",
            albumArtist: "Invented Ensemble \(padded(index))",
            album: "Invented Album \(padded(index)) Deluxe",
            genre: genre, composer: "Invented Composer \(padded(index))",
            comment: comment ?? "An invented comment about take \(padded(index)).",
            sortName: "Track \(padded(index))", kind: "Apple Music AAC audio file",
            cloudStatus: "subscription", year: year, bpm: 120, duration: 3852, trackNumber: 12,
            discNumber: 2, playedCount: 1234, skippedCount: 123, rating: 100, size: 12_900_000,
            favorited: true, disliked: false, compilation: true,
            playedDate: Date(timeIntervalSince1970: 1_780_000_000),
            skippedDate: Date(timeIntervalSince1970: 1_781_000_000),
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func library(_ count: Int) -> FakeMusicStore {
        let store = FakeMusicStore()
        store.tracksValue = (0..<count).map { track($0) }
        return store
    }

    /// A playlist name 60 characters long, about the longest an ordinary one gets.
    private static func playlistName(_ index: Int) -> String {
        let name = "Invented Playlist \(padded(index)) "
        return name + String(repeating: "x", count: 60 - name.count)
    }

    private static func playlists(_ count: Int) -> FakeMusicStore {
        let store = FakeMusicStore()
        store.playlistsValue = (0..<count).map {
            PlaylistInfo(
                persistentID: trackID(10_000 + $0), name: playlistName($0), trackCount: 1234,
                duration: 45_296, specialKind: "Purchased Music")
        }
        return store
    }

    /// One listing tool, and a library that gives it `count` rows of the widest ordinary
    /// width, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var name: String
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        var store: @Sendable (Int) -> FakeMusicStore
        var row: @Sendable (Int) -> String

        var testDescription: String { name }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> ToolResult {
            await MusicMCPCoreTests.call(
                tool, arguments.merging(extra) { _, new in new }, store: store(count))
        }

        /// The rows of a library with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }

        /// The sentence that places a page of `count` rows after `offset`, out of `total`.
        func position(_ offset: Int, _ count: Int, of total: Int) -> String {
            let last = offset + count
            return "Showing \(offset + 1)–\(last) of \(total) \(things). "
                + (last < total ? "Pass offset=\(last) for the next page." : "That is all.")
        }
    }

    private static let tracks = Listing(
        name: "tracks_list", tool: ToolCatalog.tracksName, things: "tracks",
        limits: ToolCatalog.trackLimitRange, defaultLimit: ToolCatalog.defaultTrackLimit,
        store: { library($0) }, row: { "Invented Track \(padded($0)) " })

    private static let playlistTracks = Listing(
        name: "playlist_get", tool: ToolCatalog.playlistGetName, things: "tracks",
        limits: ToolCatalog.trackLimitRange, defaultLimit: ToolCatalog.defaultTrackLimit,
        arguments: ["id": "PL1"],
        store: { count in
            let store = library(count)
            store.playlistsValue = [
                PlaylistInfo(persistentID: "PL1", name: playlistName(0), trackCount: count, duration: 400)
            ]
            // Back to front, so that playlist order is seen to differ from library order.
            store.playlistTracks["PL1"] = (0..<count).reversed().map { trackID($0) }
            return store
        },
        row: { "Invented Track \(padded($0)) " })

    private static let playlistList = Listing(
        name: "playlists_list", tool: ToolCatalog.playlistsName, things: "playlists",
        limits: ToolCatalog.playlistLimitRange, defaultLimit: ToolCatalog.defaultPlaylistLimit,
        store: { playlists($0) }, row: { "Invented Playlist \(padded($0)) " })

    private static let foundTracks = Listing(
        name: "music_search tracks", tool: ToolCatalog.searchName, things: "tracks",
        limits: ToolCatalog.trackLimitRange, defaultLimit: ToolCatalog.defaultTrackLimit,
        arguments: ["query": "Invented"], store: { library($0) },
        row: { "Invented Track \(padded($0)) " })

    private static let foundAlbums = Listing(
        name: "music_search albums", tool: ToolCatalog.searchName, things: "albums",
        limits: ToolCatalog.trackLimitRange, defaultLimit: ToolCatalog.defaultTrackLimit,
        arguments: ["query": "Invented", "type": "albums"], store: { library($0) },
        row: { "Invented Album \(padded($0)) Deluxe  — Invented Ensemble" })

    private static let foundArtists = Listing(
        name: "music_search artists", tool: ToolCatalog.searchName, things: "artists",
        limits: ToolCatalog.trackLimitRange, defaultLimit: ToolCatalog.defaultTrackLimit,
        arguments: ["query": "Invented", "type": "artists"], store: { library($0) },
        row: { "  Invented Artist \(padded($0))  · 1 track" })

    private static let foundPlaylists = Listing(
        name: "music_search playlists", tool: ToolCatalog.searchName, things: "playlists",
        limits: ToolCatalog.trackLimitRange, defaultLimit: ToolCatalog.defaultTrackLimit,
        arguments: ["query": "Invented", "type": "playlists"], store: { playlists($0) },
        row: { "Invented Playlist \(padded($0)) " })

    private static let listings = [
        tracks, playlistTracks, playlistList, foundTracks, foundAlbums, foundArtists, foundPlaylists,
    ]

    /// Rows a playlist holds come back in playlist order, which the fixture reverses.
    private static func expected(_ listing: Listing, _ rows: [Int], of count: Int) -> [Int] {
        listing.tool == ToolCatalog.playlistGetName ? rows.map { count - 1 - $0 }.sorted() : rows
    }

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(result.text.hasPrefix(listing.position(0, listing.defaultLimit, of: total) + "\n\n"))
        #expect(
            listing.rows(in: result.text, of: total)
                == Self.expected(listing, Array(0..<listing.defaultLimit), of: total))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("clipped"))
        #expect(!result.text.contains("scan stopped"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(result.text.hasPrefix(listing.position(0, maximum, of: total) + "\n\n"))
        #expect(
            listing.rows(in: result.text, of: total) == Self.expected(listing, Array(0..<maximum), of: total))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"
                    + listing.position(0, maximum, of: total) + "\n\n"))
        #expect(listing.rows(in: over.text, of: total).count == maximum)

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(
            under.text.hasPrefix(
                "limit=0 is outside 1–\(maximum); 1 was used.\n" + listing.position(0, 1, of: total) + "\n\n"))
        #expect(listing.rows(in: under.text, of: total) == Self.expected(listing, [0], of: total))
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix(listing.position(0, 3, of: 7) + "\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == Self.expected(listing, [0, 1, 2], of: 7))

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix(listing.position(3, 3, of: 7) + "\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == Self.expected(listing, [3, 4, 5], of: 7))

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == Self.expected(listing, [6], of: 7))
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == Self.expected(listing, [6], of: 7))

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("A listing with nothing in it says so, and is not mistaken for an offset past the end", arguments: listings)
    private func emptyListing(_ listing: Listing) async {
        let none = await listing.call(0)
        #expect(!none.isError)
        #expect(!none.text.contains("(nothing at this offset)"))
        #expect(!none.text.contains("Showing"))
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        #expect(await Self.tracks.call(1).text.contains("in library order."))
        #expect(await Self.tracks.call(1, ["playlist_id": "PL1"]).text.contains("in playlist order."))
        #expect(await Self.playlistTracks.call(1).text.contains("Tracks, in playlist order:"))
        #expect(await Self.playlistList.call(1).text.contains("in Music's own order."))
        #expect(await Self.foundTracks.call(1).text.contains("in library order."))
        #expect(await Self.foundTracks.call(1, ["playlist_id": "PL1"]).text.contains("in playlist order."))
        #expect(await Self.foundAlbums.call(1).text.contains("ordered by matching tracks (most first), then name."))
        #expect(await Self.foundArtists.call(1).text.contains("ordered by matching tracks (most first), then name."))
        #expect(await Self.foundPlaylists.call(1).text.contains("in Music's own order."))
    }

    @Test("Albums and artists with the same count never tie: name, then artist, decides")
    func groupsNeverTie() {
        let rows = [
            TrackRow(persistentID: "A", name: "One", artist: "Zeta", album: "Greatest Hits"),
            TrackRow(persistentID: "B", name: "Two", artist: "Alfa", album: "Greatest Hits"),
            TrackRow(persistentID: "C", name: "Three", artist: "Alfa", album: "Another"),
            TrackRow(persistentID: "D", name: "Four", artist: "Beta", album: "Busiest"),
            TrackRow(persistentID: "E", name: "Five", artist: "Beta", album: "Busiest"),
        ]
        #expect(
            MusicTools.albums(rows).map { "\($0.name)/\($0.detail)/\($0.trackCount)" } == [
                "Busiest/Beta/2", "Another/Alfa/1", "Greatest Hits/Alfa/1", "Greatest Hits/Zeta/1",
            ])
        #expect(MusicTools.albums(rows) == MusicTools.albums(rows.reversed()))
        #expect(MusicTools.artists(rows).map(\.name) == ["Alfa", "Beta", "Zeta"])
    }

    // MARK: Paging at the source

    @Test("tracks_list and playlist_get read only the rows of the page, wherever the page is")
    func listingsReadOnlyThePage() async {
        // More tracks than a search scans, to show that a listing is not held to that.
        let count = ToolCatalog.scanCeiling + 40
        let store = Self.library(count)
        let offset = ToolCatalog.scanCeiling + 20
        let listed = await call(ToolCatalog.tracksName, ["offset": .int(offset), "limit": .int(5)], store: store)
        #expect(store.lastWalk?.skip == offset)
        #expect(store.lastWalk?.read == 5)
        #expect(listed.text.hasPrefix("Showing \(offset + 1)–\(offset + 5) of \(count) tracks. Pass offset=\(offset + 5) for the next page.\n\n"))
        #expect(listed.text.contains("\(offset + 1). Invented Track \(Self.padded(offset)) "))

        let end = await call(ToolCatalog.tracksName, ["offset": .int(count - 3)], store: store)
        #expect(end.text.hasPrefix("Showing \(count - 2)–\(count) of \(count) tracks. That is all.\n\n"))
        #expect(end.text.contains("\(count) tracks match the whole library, in library order."))

        let long = Self.playlistTracks.store(count)
        let last = await call(
            ToolCatalog.playlistGetName, ["id": "PL1", "offset": .int(offset), "limit": .int(5)], store: long)
        #expect(long.lastWalk?.skip == offset)
        #expect(long.lastWalk?.read == 5)
        #expect(long.lastFilter?.playlistPersistentID == "PL1")
        #expect(last.text.hasPrefix("Showing \(offset + 1)–\(offset + 5) of \(count) tracks. Pass offset=\(offset + 5) for the next page.\n\n"))
    }

    @Test("A listing that ran out of time returns what it read, says it is partial and where to resume")
    func partialListing() async {
        let store = Self.library(30)
        store.deadlineAfter = 4
        let result = await call(ToolCatalog.tracksName, store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                """
                Partial: the time limit was reached after 4 tracks. Narrow by limit.
                Showing 1–4 of 30 tracks. Pass offset=4 for the next page.

                30 tracks match the whole library, in library order.
                """))
        #expect(Self.tracks.rows(in: result.text, of: 30) == [0, 1, 2, 3])

        // Out of time before the first row: partial, and never "past the end".
        store.deadlineAfter = 0
        let none = await call(ToolCatalog.tracksName, store: store)
        #expect(none.text.hasPrefix("Partial: the time limit was reached after 0 tracks. Narrow by limit.\n\n30 tracks match"))
        #expect(none.text.contains("(none read)"))
        #expect(!none.text.contains("past the end"))
    }

    @Test("Without a count from Music, or with one that contradicts the rows read, a page says that more exist")
    func totalIsNeverTrustedOverTheWalk() async {
        let store = Self.library(30)
        store.answersCount = false
        let uncounted = await call(ToolCatalog.tracksName, ["limit": .int(5), "offset": .int(10)], store: store)
        #expect(
            uncounted.text.hasPrefix(
                "Showing 11–15 tracks; more exist. Pass offset=15 for the next page.\n\nTracks matching the whole library, in library order."))

        // A count below what was already read would otherwise announce the end, or nothing.
        store.answersCount = true
        for wrong in [0, 5, 15] {
            store.miscount = wrong
            let result = await call(ToolCatalog.tracksName, store: store)
            let size = ToolCatalog.defaultTrackLimit
            #expect(
                result.text.hasPrefix("Showing 1–\(size) tracks; more exist. Pass offset=\(size) for the next page.\n\n"),
                "\(wrong)")
        }

        // The last page counts for itself, whatever Music says.
        store.miscount = 999
        let last = await call(ToolCatalog.tracksName, ["offset": .int(25)], store: store)
        #expect(last.text.hasPrefix("Showing 26–30 of 30 tracks. That is all.\n\n30 tracks match"))

        // A playlist's own track count stands in when the walk has no count.
        let playlist = Self.playlistTracks.store(30)
        playlist.answersCount = false
        let page = await call(ToolCatalog.playlistGetName, ["id": "PL1", "limit": .int(5)], store: playlist)
        #expect(page.text.hasPrefix("Showing 1–5 of 30 tracks. Pass offset=5 for the next page.\n\n"))
    }

    // MARK: The scan of a search

    @Test("A search that stopped at the scan ceiling says so first, and the narrowing arguments reach the rest")
    func scanCeiling() async {
        let ceiling = ToolCatalog.scanCeiling
        let store = Self.library(ceiling + 10)
        // Past the ceiling, and the only track of its genre and year.
        store.tracksValue[ceiling + 5] = Self.track(
            ceiling + 5, name: "Needle in the Stack", genre: "Zydeco", year: 1958)
        let narrowing = "Narrow by genre, year_from and year_to, or playlist_id."

        let missed = await call(ToolCatalog.searchName, ["query": "Needle"], store: store)
        #expect(
            missed.text
                == "The scan stopped after \(ceiling) tracks; more may exist. \(narrowing)\n\nNo tracks match 'Needle' among the \(ceiling) tracks scanned of \(ceiling + 10).")

        let some = await call(ToolCatalog.searchName, ["query": "Invented", "limit": .int(2)], store: store)
        #expect(
            some.text.hasPrefix(
                """
                The scan stopped after \(ceiling) tracks; more may exist. \(narrowing)
                Showing 1–2 of \(ceiling) tracks. Pass offset=2 for the next page.

                \(ceiling) tracks match 'Invented' among the \(ceiling) tracks scanned of \(ceiling + 10), in library order.
                """))

        for extra: [String: Value] in [["genre": "zydeco"], ["year_from": 1950, "year_to": 1960]] {
            let found = await call(
                ToolCatalog.searchName, ["query": "Needle"].merging(extra) { _, new in new }, store: store)
            #expect(found.text.hasPrefix("1 track matches 'Needle' · "), "\(extra)")
            #expect(found.text.contains("Needle in the Stack"), "\(extra)")
            #expect(!found.text.contains("scan stopped"), "\(extra)")
        }

        let groups = await call(ToolCatalog.searchName, ["query": "Invented", "type": "artists"], store: store)
        #expect(groups.text.hasPrefix("The scan stopped after \(ceiling) tracks; more may exist. \(narrowing)\nShowing 1–"))
        #expect(groups.text.contains("\(ceiling) artists match 'Invented' among the \(ceiling) tracks scanned of \(ceiling + 10)"))
    }

    @Test("A library exactly as long as the scan is searched whole, with no notice")
    func scanAtTheCeiling() async {
        let ceiling = ToolCatalog.scanCeiling
        let store = Self.library(ceiling)
        store.tracksValue[ceiling - 1] = Self.track(ceiling - 1, name: "Needle in the Stack")
        let found = await call(ToolCatalog.searchName, ["query": "Needle"], store: store)
        #expect(found.text.hasPrefix("1 track matches 'Needle', in library order.\n\n1. Needle in the Stack"))
    }

    @Test("A search that ran out of time says it is partial and after how many tracks")
    func partialScan() async {
        let store = Self.library(30)
        store.deadlineAfter = 12
        let result = await call(ToolCatalog.searchName, ["query": "Invented"], store: store)
        #expect(
            result.text.hasPrefix(
                """
                Partial: the time limit was reached after 12 tracks. Narrow by genre, year_from and year_to, or playlist_id.

                12 tracks match 'Invented' among the 12 tracks scanned of 30, in library order.
                """))
    }

    @Test("A search for playlists refuses the arguments that narrow a scan of tracks")
    func playlistSearchRefusesNarrowing() async {
        for extra: [String: Value] in [["genre": "Folk"], ["year_from": 1990], ["year_to": 1990], ["playlist_id": "PL1"]] {
            let result = await call(
                ToolCatalog.searchName,
                ["query": "Invented", "type": "playlists"].merging(extra) { _, new in new },
                store: Self.playlists(3))
            #expect(result.isError, "\(extra)")
            #expect(result.text.contains("a search for playlists takes query, limit and offset only"), "\(extra)")
        }
    }

    @Test("Matching tracks that belong to no album or artist are counted before the groups")
    func ungroupedMatchesAreCounted() async {
        let store = FakeMusicStore()
        store.tracksValue = [
            TrackRow(persistentID: "A", name: "Invented One", artist: "Invented Artist", album: "Invented Album"),
            TrackRow(persistentID: "B", name: "Invented Two", artist: "Invented Artist"),
            TrackRow(persistentID: "C", name: "Invented Three"),
        ]
        let albums = await call(ToolCatalog.searchName, ["query": "Invented", "type": "albums"], store: store)
        #expect(
            albums.text.hasPrefix(
                "2 matching tracks with no album are not shown. Pass type=tracks to include them.\n\n1 album matches 'Invented', ordered by"))
        let artists = await call(ToolCatalog.searchName, ["query": "Invented", "type": "artists"], store: store)
        #expect(
            artists.text.hasPrefix(
                "1 matching tracks with no artist are not shown. Pass type=tracks to include them.\n\n1 artist matches 'Invented', ordered by"))
        #expect(artists.text.contains("  Invented Artist  · 2 tracks"))
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // The number leads the name, so that looking for a row never has to walk the filler.
        let wide = String(repeating: "w", count: 2000)
        let store = FakeMusicStore()
        store.tracksValue = (0..<60).map { Self.track($0, name: "row-\(Self.padded($0))-\(wide)") }
        let maximum = ToolCatalog.trackLimitRange.upperBound
        var offset = 0
        var seen: [Int] = []
        while offset < 60 {
            let result = await call(
                ToolCatalog.tracksName, ["limit": .int(maximum), "offset": .int(offset)], store: store)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<60).filter { result.text.contains("row-\(Self.padded($0))-") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < maximum)
            #expect(result.text.hasPrefix(Self.tracks.position(offset, shown.count, of: 60) + "\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<60))
    }

    // MARK: A comment in a row

    @Test("A comment longer than a row shows is cut there, and the first line names the tool that shows it whole")
    func commentIsClipped() async {
        let width = ToolCatalog.commentClipWidth
        let long = String(repeating: "c", count: width + 1) + "TAIL"
        let exact = String(repeating: "e", count: width)
        let notice = "Comment is clipped to \(width) characters in each row. Read one in full with track_get."

        let store = FakeMusicStore()
        store.tracksValue = [Self.track(0, comment: long), Self.track(1, comment: exact)]
        store.playlistsValue = [PlaylistInfo(persistentID: "PL1", name: "Invented", trackCount: 2, duration: 1)]
        store.status = PlayerStatus(
            state: .playing, volume: 40, position: 12, playlistName: "Invented", track: store.tracksValue[0])

        let cases: [(tool: String, arguments: [String: Value], prefix: String)] = [
            (ToolCatalog.tracksName, [:], notice + "\n\n"),
            (ToolCatalog.playlistGetName, ["id": "PL1"], notice + "\n\n"),
            (ToolCatalog.searchName, ["query": "Invented"], notice + "\n\n"),
            (ToolCatalog.nowPlayingName, [:], notice + "\n\nPLAYING"),
        ]
        for (tool, arguments, prefix) in cases {
            let result = await call(tool, arguments, store: store)
            #expect(result.text.hasPrefix(prefix), "\(tool): \(result.text.prefix(200))")
            #expect(result.text.contains("comment=" + String(repeating: "c", count: width) + "…"), "\(tool)")
            #expect(!result.text.contains("TAIL"), "\(tool)")
        }

        // At the width exactly, nothing is cut and nothing is announced.
        store.tracksValue = [Self.track(1, comment: exact)]
        let whole = await call(ToolCatalog.tracksName, store: store)
        #expect(!whole.text.contains("clipped"))
        #expect(whole.text.contains("comment=" + exact))
        #expect(!whole.text.contains("…"))
    }

    @Test("A name or a comment with a line break in it stays on the line of its row")
    func rowsStayOnTheirLines() async {
        let store = FakeMusicStore()
        store.tracksValue = [Self.track(0, name: "Two\nLines", comment: "first\r\nsecond")]
        let result = await call(ToolCatalog.tracksName, store: store)
        #expect(result.text.contains("1. Two Lines — "))
        #expect(result.text.contains("comment=first second"))
    }

    // MARK: The window on one track's record

    private static let longLyrics = (0..<800).map { "An invented line of the song, number \(padded($0))" }
        .joined(separator: "\n")

    private static func oneTrack(lyrics: String, comment: String? = nil) -> FakeMusicStore {
        let store = FakeMusicStore()
        store.tracksValue = [track(0, comment: comment)]
        store.lyricsValue = lyrics
        return store
    }

    /// The whole record as `track_get` windows it, rendered with the calendar `call` uses.
    private static func record(lyrics: String, comment: String? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return Format(calendar: calendar).trackRecord(
            TrackDetail(row: track(0, comment: comment), lyrics: lyrics))
    }

    private func record(_ extra: [String: Value] = [:], lyrics: String = longLyrics) async -> ToolResult {
        await call(
            ToolCatalog.trackGetName, ["ids": [.string(Self.trackID(0))]].merging(extra) { _, new in new },
            store: Self.oneTrack(lyrics: lyrics))
    }

    /// What follows the notices of a result.
    private func data(_ text: String) throws -> String {
        let gap = try #require(text.range(of: "\n\n"))
        return String(text[gap.upperBound...])
    }

    @Test("A long record comes as one default window, announced before the data")
    func defaultWindow() async throws {
        let whole = Self.record(lyrics: Self.longLyrics)
        let size = ToolCatalog.defaultMaxCharacters
        #expect(whole.count > size)
        let result = await record()
        #expect(result.text.hasPrefix("Characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\nInvented Track 0000"))
        #expect(try data(result.text) == String(whole.prefix(size)))
        #expect(result.text.utf16.count <= ToolStandard.usualPage + 200)
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole record")
    func windowsChain() async throws {
        let whole = Self.record(lyrics: Self.longLyrics)
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await record(["character_offset": .int(offset), "max_characters": .int(7000)])
            let window = try data(result.text)
            let last = offset + window.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(window.count == min(7000, whole.count - offset))
            joined += window
            offset = last
        }
        #expect(joined == whole)
        #expect(joined.contains("number 0799"))
    }

    @Test("A record that fits one window is returned whole, lyrics and comment uncut, with no notice")
    func shortRecordHasNoNotice() async {
        let comment = String(repeating: "c", count: ToolCatalog.commentClipWidth * 3)
        let lyrics = String(repeating: "la ", count: ToolCatalog.lyricsClipWidth)
        let result = await call(
            ToolCatalog.trackGetName, ["ids": [.string(Self.trackID(0))]],
            store: Self.oneTrack(lyrics: lyrics, comment: comment))
        #expect(result.text == Self.record(lyrics: lyrics, comment: comment))
        #expect(result.text.contains(comment))
        #expect(result.text.contains(lyrics.trimmingCharacters(in: .whitespaces)))
        #expect(!result.text.contains("Characters"))
        #expect(!result.text.contains("clipped"))
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async throws {
        let lyrics = Self.longLyrics + "\n" + Self.longLyrics
        let whole = Self.record(lyrics: lyrics)
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        #expect(whole.count > maximum)

        let atMaximum = await record(["max_characters": .int(maximum)], lyrics: lyrics)
        #expect(!atMaximum.text.contains("is outside"))
        #expect(try data(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await record(["max_characters": .int(maximum + 1)], lyrics: lyrics)
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nCharacters 1–\(maximum) of "))
        #expect(try data(over.text).count == maximum)

        let under = await record(["max_characters": .int(0)], lyrics: lyrics)
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nCharacters 1–1 of "))
        #expect(try data(under.text) == "I")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async throws {
        let whole = Self.record(lyrics: Self.longLyrics)
        let past = await record(["character_offset": .int(whole.count + 50)])
        #expect(
            past.text
                == "Characters 0 of \(whole.count): character_offset=\(whole.count + 50) is past the end. That is all.\n\n")

        let negative = await record(["character_offset": .int(-3)])
        let range = ToolCatalog.offsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nCharacters 1–"))
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async throws {
        // Eight UTF-16 units to the character: a full window would be four results long.
        let lyrics = (0..<300).map { _ in String(repeating: "👩‍👩‍👧", count: 100) }.joined(separator: "\n")
        let whole = Self.record(lyrics: lyrics)
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await record(
                ["character_offset": .int(offset), "max_characters": .int(maximum)], lyrics: lyrics)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let window = try data(result.text)
            #expect(!window.isEmpty && window.count < maximum)
            let last = offset + window.count
            #expect(result.text.hasPrefix("Characters \(offset + 1)–\(last) of \(whole.count). "))
            joined += window
            offset = last
        }
        #expect(joined == whole)
    }

    // MARK: Several tracks in one call

    @Test("Several ids return each record with its lyrics and comment cut to a stated width, announced first")
    func severalRecordsAreClipped() async {
        let width = ToolCatalog.lyricsClipWidth
        let store = FakeMusicStore()
        store.tracksValue = [
            Self.track(0, comment: String(repeating: "c", count: ToolCatalog.commentClipWidth + 1) + "TAIL"),
            Self.track(1),
        ]
        store.lyricsByID[Self.trackID(0)] = String(repeating: "l", count: width + 1) + "REST"
        store.lyricsByID[Self.trackID(1)] = String(repeating: "s", count: width)

        let result = await call(
            ToolCatalog.trackGetName, ["ids": [.string(Self.trackID(0)), .string(Self.trackID(1))]], store: store)
        #expect(
            result.text.hasPrefix(
                """
                Lyrics is clipped to \(width) characters in each row. Read one in full with track_get and a single id.
                Comment is clipped to \(ToolCatalog.commentClipWidth) characters in each row. Read one in full with track_get and a single id.

                Invented Track 0000
                """))
        #expect(result.text.contains(String(repeating: "l", count: width) + "…"))
        #expect(!result.text.contains("REST"))
        #expect(!result.text.contains("TAIL"))
        // The second track's lyrics are exactly the width: whole, with no mark.
        #expect(result.text.contains("    " + String(repeating: "s", count: width)))
        #expect(!result.text.contains(String(repeating: "s", count: width) + "…"))

        // The one id reads what the several cut.
        let one = await call(ToolCatalog.trackGetName, ["ids": [.string(Self.trackID(0))]], store: store)
        #expect(one.text.contains("REST") && one.text.contains("TAIL"))
    }

    @Test("Several short records carry no notice")
    func severalShortRecords() async {
        let store = Self.library(3)
        store.lyricsValue = "An invented verse."
        let result = await call(
            ToolCatalog.trackGetName, ["ids": [.string(Self.trackID(0)), .string(Self.trackID(2))]], store: store)
        #expect(result.text.hasPrefix("Invented Track 0000"))
        #expect(!result.text.contains("clipped"))
        #expect(result.text.contains("Invented Track 0002"))
    }

    @Test("A window is refused with several ids, because it reads one record")
    func windowNeedsOneID() async {
        let ids: Value = [.string(Self.trackID(0)), .string(Self.trackID(1))]
        for argument in ["character_offset", "max_characters"] {
            let result = await call(
                ToolCatalog.trackGetName, ["ids": ids, argument: 100], store: Self.library(2))
            #expect(result.isError, "\(argument)")
            #expect(
                result.text.contains(
                    "Argument '\(argument)' is not valid: it windows the record of one track, and 2 ids were given; pass a single id"),
                "\(argument)")
        }
    }

    @Test("Records too long to fit together even shortened are held back, and the first line says how many")
    func longRecordsAreHeldBack() async {
        let most = ToolCatalog.trackIDsRange.upperBound
        let store = FakeMusicStore()
        // The number leads the name, so that looking for a record never has to walk the filler.
        store.tracksValue = (0..<most).map {
            Self.track($0, name: "record-\(Self.padded($0))-" + String(repeating: "w", count: 4000))
        }
        store.lyricsValue = "An invented verse."
        let ids = (0..<most).map { Value.string(Self.trackID($0)) }
        let result = await call(ToolCatalog.trackGetName, ["ids": .array(ids)], store: store)
        #expect(!result.isError)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        let shown = (0..<most).filter { result.text.contains("record-\(Self.padded($0))-") }
        #expect(!shown.isEmpty && shown.count < most)
        #expect(shown == Array(0..<shown.count))
        let held = (shown.count..<most).map { Self.trackID($0) }
        #expect(
            result.text.hasPrefix(
                "\(held.count) track(s) asked for are not shown. Pass these ids in another call (\(held.map(ToolStandard.echo).joined(separator: ", "))) to include them.\n\n"))
    }

    @Test("An id the library no longer holds is named before the records that were found")
    func missingIDsComeFirst() async {
        let store = Self.library(2)
        let result = await call(
            ToolCatalog.trackGetName, ["ids": [.string(Self.trackID(0)), "GONE", .string(Self.trackID(1))]],
            store: store)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Not found: GONE — run music_search again"))
        #expect(result.text.contains("Invented Track 0000") && result.text.contains("Invented Track 0001"))
    }

    @Test("The most ids one call takes are read, and one more is refused whole")
    func idCountBounds() async {
        let most = ToolCatalog.trackIDsRange.upperBound
        let store = Self.library(most + 1)
        store.lyricsValue = String(repeating: "An invented line of the song.\n", count: 400)
        let ids = (0...most).map { Value.string(Self.trackID($0)) }

        let atMost = await call(ToolCatalog.trackGetName, ["ids": .array(Array(ids.prefix(most)))], store: store)
        #expect(!atMost.isError)
        #expect((0..<most).allSatisfy { atMost.text.contains("Invented Track \(Self.padded($0)) ") })
        #expect(atMost.text.utf16.count <= ToolStandard.longestResult)

        let tooMany = await call(ToolCatalog.trackGetName, ["ids": .array(ids)], store: store)
        #expect(tooMany.isError)
        #expect(tooMany.text.contains("'ids' holds \(most + 1) ids and one call takes at most \(most)"))
        #expect(tooMany.text.contains("Split the ids across several calls"))
    }

    @Test("add_to_playlist takes its most ids in one call and refuses one more before adding anything")
    func addedCountBounds() async {
        let most = ToolCatalog.addedTracksRange.upperBound
        let store = Self.library(most + 1)
        store.playlistsValue = [PlaylistInfo(persistentID: "PL1", name: "Invented", trackCount: 0, duration: 0)]
        let ids = (0...most).map { Value.string(Self.trackID($0)) }

        let tooMany = await call(
            ToolCatalog.addToPlaylistName, ["playlist_id": "PL1", "track_ids": .array(ids)], store: store)
        #expect(tooMany.isError)
        #expect(tooMany.text.contains("'track_ids' holds \(most + 1) ids and one call takes at most \(most)"))
        #expect(store.appended.isEmpty)

        let atMost = await call(
            ToolCatalog.addToPlaylistName, ["playlist_id": "PL1", "track_ids": .array(Array(ids.prefix(most)))],
            store: store)
        #expect(!atMost.isError)
        #expect(atMost.text.hasPrefix("Added \(most) tracks to \"Invented\"."))
    }

    @Test("The ids add_to_playlist could not add are all named, each no longer than an echo, and the answer fits")
    func addedOutcomeIsBounded() async {
        let most = ToolCatalog.addedTracksRange.upperBound
        let store = FakeMusicStore()
        store.playlistsValue = [PlaylistInfo(persistentID: "PL1", name: "Invented", trackCount: 0, duration: 0)]
        // None resolves, and each is far longer than an id is.
        let ids = (0..<most).map { Value.string("missing-\(Self.padded($0))-" + String(repeating: "z", count: 3000)) }
        let result = await call(
            ToolCatalog.addToPlaylistName, ["playlist_id": "PL1", "track_ids": .array(ids)], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("\(most) ids did not resolve and were skipped:"))
        #expect((0..<most).allSatisfy { result.text.contains("missing-\(Self.padded($0))-") })
        #expect(!result.text.contains(String(repeating: "z", count: ToolStandard.echoWidth)))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    // MARK: Numbers moved, values refused

    @Test("A filter bound outside its range is moved, and the result says which value was used")
    func filtersAreMoved() async {
        let cases: [(argument: String, asked: Int, range: ClosedRange<Int>)] = [
            ("year_from", -1, ToolCatalog.yearRange),
            ("year_to", ToolCatalog.yearRange.upperBound + 1, ToolCatalog.yearRange),
            ("played_count_from", -5, ToolCatalog.playedCountRange),
            ("played_count_to", ToolCatalog.playedCountRange.upperBound + 1, ToolCatalog.playedCountRange),
            ("rating_from", ToolCatalog.ratingRange.upperBound + 1, ToolCatalog.ratingRange),
        ]
        for (argument, asked, range) in cases {
            let used = min(max(asked, range.lowerBound), range.upperBound)
            let result = await call(ToolCatalog.tracksName, [argument: .int(asked)], store: Self.library(2))
            #expect(!result.isError, "\(argument)")
            #expect(
                result.text.hasPrefix(
                    "\(argument)=\(asked) is outside \(range.lowerBound)–\(range.upperBound); \(used) was used.\n\n"),
                "\(argument): \(result.text.prefix(120))")
        }

        let store = Self.library(2)
        let inside = await call(
            ToolCatalog.tracksName,
            ["year_from": .int(ToolCatalog.yearRange.lowerBound), "year_to": .int(ToolCatalog.yearRange.upperBound)],
            store: store)
        #expect(!inside.text.contains("is outside"))
        #expect(store.lastFilter?.yearTo == ToolCatalog.yearRange.upperBound)

        let search = await call(
            ToolCatalog.searchName, ["query": "Invented", "year_from": .int(-1)], store: Self.library(2))
        #expect(search.text.hasPrefix("year_from=-1 is outside "))
    }

    @Test("A volume outside its range is moved to the nearest level, and the result says so")
    func volumeIsMoved() async {
        let range = ToolCatalog.volumeRange
        for (asked, used) in [(range.lowerBound - 1, range.lowerBound), (range.upperBound + 1, range.upperBound)] {
            let store = FakeMusicStore()
            let result = await call(
                ToolCatalog.controlName, ["command": "volume", "volume": .int(asked)], store: store)
            #expect(!result.isError, "\(asked)")
            #expect(
                result.text.hasPrefix(
                    "volume=\(asked) is outside \(range.lowerBound)–\(range.upperBound); \(used) was used."),
                "\(asked)")
            #expect(store.commands.first?.volume == used, "\(asked)")
        }
        for volume in [range.lowerBound, range.upperBound] {
            let store = FakeMusicStore()
            let result = await call(
                ToolCatalog.controlName, ["command": "volume", "volume": .int(volume)], store: store)
            #expect(!result.isError, "\(volume)")
            #expect(store.commands.first?.volume == volume, "\(volume)")
        }
    }

    @Test("A wrong type is refused with the form expected, never read as not given")
    func wrongTypesAreRefused() async {
        let whole = "a whole number was expected"
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.tracksName, ["limit": "ten"], "Argument 'limit' is not valid: \(whole)"),
            (ToolCatalog.tracksName, ["limit": 2.5], "Argument 'limit' is not valid: \(whole)"),
            (ToolCatalog.tracksName, ["offset": true], "Argument 'offset' is not valid: \(whole)"),
            (ToolCatalog.tracksName, ["genre": 5], "Argument 'genre' is not valid: text was expected"),
            (ToolCatalog.tracksName, ["year_from": "1990"], "Argument 'year_from' is not valid: \(whole)"),
            (ToolCatalog.tracksName, ["favorited": "yes"], "Argument 'favorited' is not valid: true or false was expected"),
            (ToolCatalog.tracksName, ["playlist_id": ["PL1"]], "Argument 'playlist_id' is not valid: text was expected"),
            (ToolCatalog.tracksName, ["from_date": 20_260_812], "Argument 'from_date' is not valid: text was expected"),
            (ToolCatalog.playlistsName, ["limit": [1]], "Argument 'limit' is not valid: \(whole)"),
            (ToolCatalog.playlistGetName, ["id": 7], "Argument 'id' is not valid: text was expected"),
            (ToolCatalog.searchName, ["query": 7], "Argument 'query' is not valid: text was expected"),
            (ToolCatalog.searchName, ["query": "x", "type": "songs"], "expected one of: tracks, albums, artists, playlists"),
            (ToolCatalog.searchName, ["query": "x", "type": 3], "Argument 'type' is not valid: text was expected"),
            (ToolCatalog.trackGetName, ["ids": 5], "Argument 'ids' is not valid: a list of ids, each one text, was expected"),
            (ToolCatalog.trackGetName, ["ids": "T1"], "Argument 'ids' is not valid: a list of ids, each one text, was expected"),
            (
                ToolCatalog.addToPlaylistName, ["playlist_id": "PL1", "track_ids": "T1"],
                "Argument 'track_ids' is not valid: a list of ids, each one text, was expected"
            ),
            (ToolCatalog.trackGetName, ["ids": ["T1", 5]], "Argument 'ids' is not valid: a list of ids, each one text, was expected"),
            (ToolCatalog.trackGetName, ["ids": ["T1"], "max_characters": "all"], "Argument 'max_characters' is not valid: \(whole)"),
            (
                ToolCatalog.addToPlaylistName, ["playlist_id": "PL1", "track_ids": ["T1"], "skip_duplicates": "true"],
                "Argument 'skip_duplicates' is not valid: true or false was expected"
            ),
            (ToolCatalog.controlName, ["command": "volume", "volume": "loud"], "Argument 'volume' is not valid: \(whole)"),
        ]
        for (tool, arguments, expected) in cases {
            let store = Self.library(2)
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
            #expect(store.appended.isEmpty && store.commands.isEmpty)
        }
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.playlistList.call(30, ["limit": 20.0, "offset": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 playlists."))
        let store = Self.library(2)
        let filtered = await call(ToolCatalog.tracksName, ["genre": .null, "favorited": .null], store: store)
        #expect(!filtered.isError)
        #expect(store.lastFilter?.genre == nil && store.lastFilter?.favorited == nil)
    }

    @Test("A date that does not exist is refused, and so is a range that ends before it starts")
    func impossibleDatesAndRanges() async {
        for date in [
            "2026-02-31", "2026-13-01", "2026-08-12T25:00", "2026-08-12T09:61", "12/08/2026", "yesterday",
            "2026-02-31T09:00:00+02:00", "2026-08-12T09:00:00-5",
        ] {
            let result = await call(ToolCatalog.tracksName, ["from_date": .string(date)], store: Self.library(1))
            #expect(result.isError, "\(date)")
            #expect(result.text.contains("Argument 'from_date' is not a date this server accepts: '\(date)'"), "\(date)")
            #expect(result.text.contains("Use 2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00"), "\(date)")
        }
        for date in ["2024-02-29", "2026-08-12T09:00", "2026-08-12T09:00:00+02:00"] {
            let result = await call(ToolCatalog.tracksName, ["to_date": .string(date)], store: Self.library(1))
            #expect(!result.isError, "\(date)")
        }

        // An offset of either sign, or Z, names an instant and is read as one.
        let nineInNewYork = Date(timeIntervalSince1970: 1_786_543_200)  // 2026-08-12T14:00:00Z
        for (date, instant) in [
            ("2026-08-12T09:00:00-05:00", nineInNewYork), ("2026-08-12T16:00:00+02:00", nineInNewYork),
            ("2026-08-12T14:00:00Z", nineInNewYork), ("2026-08-12T14:00", nineInNewYork),
        ] {
            let store = Self.library(1)
            let result = await call(ToolCatalog.tracksName, ["from_date": .string(date)], store: store)
            #expect(!result.isError, "\(date)")
            #expect(store.lastFilter?.addedFrom == instant, "\(date)")
        }

        let reversed: [(arguments: [String: Value], expected: String)] = [
            (["from_date": "2026-08-12", "to_date": "2026-08-11"], "Argument 'to_date' is not valid: it is before 'from_date'"),
            (["year_from": 2000, "year_to": 1999], "Argument 'year_to' is not valid: it is before 'year_from' (2000)"),
            (
                ["played_count_from": 9, "played_count_to": 3],
                "Argument 'played_count_to' is not valid: it is below 'played_count_from' (9)"
            ),
        ]
        for (arguments, expected) in reversed {
            let result = await call(ToolCatalog.tracksName, arguments, store: Self.library(1))
            #expect(result.isError && result.text.contains(expected), "\(arguments): \(result.text)")
        }
        let search = await call(
            ToolCatalog.searchName, ["query": "x", "year_from": 2000, "year_to": 1999], store: Self.library(1))
        #expect(search.isError && search.text.contains("it is before 'year_from' (2000)"))

        // One day alone is a whole day: both ends inclusive.
        let sameDayStore = Self.library(1)
        let sameDay = await call(
            ToolCatalog.tracksName, ["from_date": "2026-08-12", "to_date": "2026-08-12"], store: sameDayStore)
        #expect(!sameDay.isError)
        #expect(sameDayStore.lastFilter?.addedFrom == Date(timeIntervalSince1970: 1_786_492_800))
        #expect(sameDayStore.lastFilter?.addedTo == Date(timeIntervalSince1970: 1_786_492_800 + 86_399))
    }

    @Test("A playlist name longer than the longest allowed is refused, and nothing is created")
    func playlistNameBounds() async {
        let longest = ToolCatalog.longestPlaylistName
        let store = FakeMusicStore()
        let over = await call(
            ToolCatalog.createPlaylistName, ["name": .string(String(repeating: "n", count: longest + 1))], store: store)
        #expect(over.isError)
        #expect(over.text.contains("at most \(longest) characters were expected, and it has \(longest + 1)"))
        #expect(store.createdPlaylists.isEmpty)

        let atLongest = await call(
            ToolCatalog.createPlaylistName, ["name": .string(String(repeating: "n", count: longest))], store: store)
        #expect(!atLongest.isError)
        #expect(store.createdPlaylists.count == 1)
    }

    // MARK: Errors and time

    @Test("An error or a result repeats at most a short piece of what the caller sent")
    func callerTextIsClipped() async {
        let long = String(repeating: "n", count: 5000)
        let echoed = String(repeating: "n", count: ToolStandard.echoWidth) + "…"
        let store = Self.library(1)
        store.playlistsValue = [PlaylistInfo(persistentID: "PL1", name: "Invented", trackCount: 0, duration: 0)]
        let errors: [(tool: String, arguments: [String: Value])] = [
            (long, [:]),
            (ToolCatalog.trackGetName, ["ids": [.string(long)]]),
            (ToolCatalog.playlistGetName, ["id": .string(long)]),
            (ToolCatalog.tracksName, ["from_date": .string(long)]),
            (ToolCatalog.tracksName, [long: 1]),
            (ToolCatalog.controlName, ["command": .string(long)]),
            (ToolCatalog.addToPlaylistName, ["playlist_id": .string(long), "track_ids": ["T1"]]),
        ]
        for (tool, arguments) in errors {
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool.prefix(20))")
            #expect(result.text.contains(echoed), "\(tool.prefix(20)): \(result.text.prefix(200))")
            #expect(!result.text.contains(echoed.dropLast() + "n"), "\(tool.prefix(20))")
            #expect(result.text.utf16.count <= ToolStandard.longestError / 10, "\(tool.prefix(20))")
        }
        let results: [(tool: String, arguments: [String: Value])] = [
            (ToolCatalog.searchName, ["query": .string(long)]),
            (ToolCatalog.searchName, ["query": .string(long), "type": "playlists"]),
            (ToolCatalog.tracksName, ["genre": .string(long)]),
        ]
        for (tool, arguments) in results {
            let result = await call(tool, arguments, store: store)
            #expect(!result.isError, "\(tool)")
            #expect(result.text.contains(echoed), "\(tool): \(result.text.prefix(200))")
            #expect(result.text.utf16.count < 500, "\(tool)")
        }
        #expect(ToolStandard.echo("music_delete") == "music_delete")
    }

    @Test("An argument a tool does not take is refused, with the ones it does take")
    func unknownArgumentsAreRefused() async {
        let store = Self.library(2)
        // The names this tool's date range had before it took the standard ones.
        for name in ["added_from", "added_to", "since"] {
            let result = await call(ToolCatalog.tracksName, [name: "2026-08-12"], store: store)
            #expect(result.isError, "\(name)")
            #expect(result.text.hasPrefix("'\(name)' is not an argument of tracks_list.\n\nIt takes: favorited, from_date, genre, limit, offset, "), "\(result.text)")
        }
        #expect(store.lastFilter == nil)

        let status = await call(ToolCatalog.statusName, ["verbose": true])
        #expect(status.isError && status.text.contains("'verbose' is not an argument of music_status.\n\nIt takes none."))

        let add = await call(
            ToolCatalog.addToPlaylistName, ["playlist_id": "PL1", "track_ids": ["T1"], "replace": true], store: store)
        #expect(add.isError && add.text.contains("'replace' is not an argument of add_to_playlist."))
        #expect(store.appended.isEmpty)
    }

    @Test("When no id resolves, the error names a few of them and counts the rest")
    func notFoundListsAFew() async {
        let ids = (0..<8).map { Value.string("GONE-\($0)") }
        let result = await call(ToolCatalog.trackGetName, ["ids": .array(ids)], store: Self.library(1))
        #expect(result.isError)
        #expect(result.text.hasPrefix("The library holds no track with id 'GONE-0', 'GONE-1', 'GONE-2' or the 5 other ids given."))
        #expect(!result.text.contains("GONE-3"))
    }

    @Test("Every error this server words is far inside the longest error")
    func errorsAreShort() {
        let long = String(repeating: "n", count: 5000)
        let errors: [ToolError] = [
            .notAvailable(.notRunning), .notAvailable(.automationDenied), .notAvailable(.consentNotGranted),
            .notAvailable(.notInstalled), .missingArgument("ids"),
            .badArgument(name: "limit", reason: "a whole number was expected"),
            .badDate(argument: "from_date", value: long), .unknownTool(long),
            .unknownArgument(name: long, tool: ToolCatalog.tracksName, allowed: ["genre", "limit"]),
            .notFound(ids: Array(repeating: long, count: 20)),
            .tooManyIDs(argument: "ids", given: 500, most: 20), .playlistNotFound(id: long),
            .playlistExists(name: long), .playlistNotEditable(name: long, reason: long), .noTracksGiven,
            .unknownCommand(long), .volumeRequired, .storeFailure(long),
            .timedOut(seconds: 55, tool: ToolCatalog.tracksName),
            .timedOut(seconds: 55, tool: ToolCatalog.addToPlaylistName),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 5, "\(Diagnostics.kind(of: error))")
        }
    }

    private let shortTimeout = Duration.milliseconds(200)

    @Test("A call Music never answers is abandoned at the deadline and answered with an error", .timeLimit(.minutes(1)))
    func stuckCallIsAnswered() async {
        let gate = DispatchSemaphore(value: 0)
        let store = Self.library(3)
        store.block = gate
        // Released afterwards so the abandoned work does not leak a blocked thread.
        defer { gate.signal() }

        let result = await call(ToolCatalog.tracksName, store: store, timeout: shortTimeout)
        #expect(result.isError)
        #expect(result.text.contains("did not finish within"))
        #expect(result.text.contains("Nothing was changed. Ask for less"))
    }

    @Test("A call that finishes in time is untouched by the deadline")
    func fastCallIsUnaffected() async {
        let result = await call(ToolCatalog.tracksName, store: Self.library(3), timeout: .seconds(5))
        #expect(!result.isError)
        #expect(result.text.contains("3 tracks match the whole library"))
    }

    @Test("The time-out error says what to do next, and never that nothing changed after a write")
    func timeoutMessages() {
        let read = ToolError.timedOut(seconds: 55, tool: ToolCatalog.searchName).message
        #expect(read.contains("did not finish within 55 seconds"))
        #expect(read.contains("Nothing was changed"))

        let add = ToolError.timedOut(seconds: 55, tool: ToolCatalog.addToPlaylistName).message
        #expect(add.contains("skip_duplicates=true"))
        #expect(!add.contains("Nothing was changed"))
        for tool in [ToolCatalog.createPlaylistName, ToolCatalog.controlName] {
            #expect(!ToolError.timedOut(seconds: 55, tool: tool).message.contains("Nothing was changed"), "\(tool)")
        }
        #expect(Diagnostics.kind(of: ToolError.timedOut(seconds: 55, tool: "x")) == "ToolError.timedOut")
    }

    @Test("The deadline of a call is within the standard's time limit, and reading stops before it")
    func deadlineIsWithinTheTimeLimit() {
        #expect(MusicTools.defaultTimeout <= ToolStandard.timeLimit)
        #expect(MusicTools.defaultReadBudget < MusicTools.defaultTimeout)
    }

    @Test("A walk is handed a deadline that falls before the call's own")
    func walksCarryADeadline() async throws {
        let store = Self.library(3)
        let before = Date()
        _ = await call(ToolCatalog.tracksName, store: store)
        let deadline = try #require(store.lastWalk?.deadline)
        let budget = Double(MusicTools.defaultReadBudget.components.seconds)
        #expect(deadline >= before.addingTimeInterval(budget))
        #expect(deadline <= Date().addingTimeInterval(budget))
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(ToolStandard.overlongTexts(instructions: MusicMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
        #expect(!MusicMCPServer.instructions.isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == ToolCatalog.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit)") == true)
    }

    @Test("The window's schema states the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.trackGetName })
        let size = try #require(properties(of: tool)["max_characters"])
        #expect(size["minimum"]?.intValue == ToolCatalog.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == ToolCatalog.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == ToolCatalog.defaultMaxCharacters)
        #expect(ToolCatalog.defaultMaxCharacters == ToolStandard.usualPage)
        let offset = try #require(properties(of: tool)["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
        #expect(tool.description?.contains("max_characters (up to \(ToolCatalog.maxCharactersRange.upperBound))") == true)
    }

    @Test("The schemas state how many ids a call takes and how long a name may be")
    func schemaStatesTheCounts() throws {
        let get = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.trackGetName })
        #expect(properties(of: get)["ids"]?["maxItems"]?.intValue == ToolCatalog.trackIDsRange.upperBound)
        #expect(get.description?.contains("up to \(ToolCatalog.trackIDsRange.upperBound) in one call") == true)
        #expect(get.description?.contains("shortened to \(ToolCatalog.lyricsClipWidth) characters") == true)

        let add = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.addToPlaylistName })
        #expect(properties(of: add)["track_ids"]?["maxItems"]?.intValue == ToolCatalog.addedTracksRange.upperBound)
        #expect(add.description?.contains("up to \(ToolCatalog.addedTracksRange.upperBound) tracks") == true)

        let create = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.createPlaylistName })
        #expect(properties(of: create)["name"]?["maxLength"]?.intValue == ToolCatalog.longestPlaylistName)
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page, window and date a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters", "from_date", "to_date"]
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "skip", "start", "from", "to",
            "max_chars", "max_length", "char_offset", "cursor", "added_from", "added_to", "date_from",
            "date_to", "since", "until", "after", "before",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The installer keys on the manifest version alone, so a build whose three version
    /// strings disagree is a build nobody can tell from the one before it.
    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(try manifest()["version"] as? String == MusicMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == MusicMCPServer.version)
    }

    /// The manifest is plain JSON and cannot take a figure from a constant, so this holds
    /// each bound it states to the one the code enforces.
    @Test("The manifest states the bounds the code enforces")
    func manifestStatesTheBounds() throws {
        let manifest = try manifest()
        let long = try #require(manifest["long_description"] as? String)
        #expect(long.contains("stops after \(ToolCatalog.scanCeiling) tracks"))
        #expect(long.contains("reading stops after \(MusicTools.defaultReadBudget.components.seconds) seconds"))
        #expect(long.contains("not answered after \(MusicTools.defaultTimeout.components.seconds) seconds"))

        let listed = try #require(manifest["tools"] as? [[String: Any]])
        func description(_ name: String) -> String {
            listed.first { $0["name"] as? String == name }?["description"] as? String ?? ""
        }
        #expect(description(ToolCatalog.searchName).contains("at most \(ToolCatalog.scanCeiling) tracks"))
        #expect(description(ToolCatalog.trackGetName).contains("up to \(ToolCatalog.trackIDsRange.upperBound)"))
        #expect(description(ToolCatalog.trackGetName).contains("shortened to \(ToolCatalog.lyricsClipWidth) characters"))
        #expect(
            description(ToolCatalog.addToPlaylistName).contains("up to \(ToolCatalog.addedTracksRange.upperBound) tracks"))
        for tool in listed {
            #expect((tool["description"] as? String)?.isEmpty == false)
        }
    }

    @Test("The instructions and music_status state the bounds the code enforces")
    func boundsAreStated() async {
        let instructions = MusicMCPServer.instructions
        #expect(instructions.contains("stops after \(ToolCatalog.scanCeiling) tracks"))
        #expect(instructions.contains("Reading stops after \(MusicTools.defaultReadBudget.components.seconds) seconds"))
        #expect(instructions.contains("not answered after \(MusicTools.defaultTimeout.components.seconds) seconds"))
        for tool in ToolCatalog.all() {
            #expect(instructions.contains(tool.name), "\(tool.name) is not in the instructions")
        }

        let search = ToolCatalog.all().first { $0.name == ToolCatalog.searchName }?.description ?? ""
        #expect(search.contains("the first \(ToolCatalog.scanCeiling) tracks"))
        #expect(search.contains("narrow it with \(ToolCatalog.searchNarrowing)"))

        let status = await call(ToolCatalog.statusName)
        #expect(status.text.contains("\(ToolCatalog.scanCeiling) tracks per music_search call"))
        #expect(status.text.contains("\(ToolCatalog.defaultTrackLimit) to a page, \(ToolCatalog.trackLimitRange.upperBound) at most"))
        #expect(status.text.contains("\(ToolCatalog.defaultPlaylistLimit) to a page, \(ToolCatalog.playlistLimitRange.upperBound) at most"))
        #expect(status.text.contains("\(MusicTools.defaultTimeout.components.seconds) seconds per call"))
    }
}
