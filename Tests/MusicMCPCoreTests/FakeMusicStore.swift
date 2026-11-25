import Dispatch
import Foundation

@testable import MusicMCPCore

/// An in-memory `MusicStore`.
///
/// Every test in this suite runs against this double, with Music closed and the owner's
/// library untouched. Nothing here sends an Apple event, which is the whole point of the
/// protocol: the tool layer is provable without a library to break.
final class FakeMusicStore: MusicStore, @unchecked Sendable {

    var availabilityValue: MusicAvailability = .ready
    var tracksValue: [TrackRow] = []
    /// The lyrics of every track that has none of its own in `lyricsByID`.
    var lyricsValue: String = ""
    var lyricsByID: [String: String] = [:]
    var playlistsValue: [PlaylistInfo] = []
    var status = PlayerStatus(
        state: .stopped, volume: 50, position: 0, playlistName: "", track: nil)

    /// Set to make the next call fail, so the error path is reachable without a real
    /// Apple event failure.
    var failure: (any Error)?

    /// Set to make a walk stop for lack of time after reading this many tracks, as the
    /// bridge does when its deadline passes. The fake never looks at a clock.
    var deadlineAfter: Int?

    /// What Music answers when a walk that stopped early asks how many candidates there
    /// are: the true count by default, nothing when `false`, and `miscount` when that is
    /// set, as a count taken while the library was changing would be.
    var answersCount = true
    var miscount: Int?

    /// Set to make the store wait and hold its thread, as an Apple event does that Music
    /// never answers.
    var block: DispatchSemaphore?

    // Recorded so a test can prove a tool passed through what it claimed to.
    private(set) var lastFilter: TrackFilter?
    private(set) var lastWalk: TrackWalk?
    private(set) var createdPlaylists: [String] = []
    private(set) var appended: [(ids: [String], playlist: String, skipDuplicates: Bool)] = []

    /// What each playlist already holds, keyed by playlist persistent id. Modelled here
    /// only because skip_duplicates is the one tool behaviour that depends on it.
    var playlistTracks: [String: [String]] = [:]
    private(set) var commands: [(command: PlaybackCommand, volume: Int?)] = []

    func availability() -> MusicAvailability {
        block?.wait()
        return availabilityValue
    }

    func playerStatus() async throws -> PlayerStatus {
        if let failure { throw failure }
        return status
    }

    func tracks(matching filter: TrackFilter, walk: TrackWalk) async throws -> TrackPage {
        if let failure { throw failure }
        lastFilter = filter
        lastWalk = walk

        // The candidates: what the filters Music evaluates itself leave. Only the ones the
        // tool layer can get wrong are modelled; the rest is the store's job and is
        // verified by hand against Music. A playlist whose tracks a test did not list
        // holds every track.
        var candidates = tracksValue
        if let id = filter.playlistPersistentID, let members = playlistTracks[id] {
            let byID = Dictionary(
                tracksValue.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
            candidates = members.compactMap { byID[$0] }
        }
        if let genre = filter.genre?.lowercased(), !genre.isEmpty {
            candidates = candidates.filter { $0.genre.lowercased() == genre }
        }
        if let from = filter.yearFrom { candidates = candidates.filter { $0.year >= from } }
        if let to = filter.yearTo { candidates = candidates.filter { $0.year <= to } }
        if let favorited = filter.favorited {
            candidates = candidates.filter { $0.favorited == favorited }
        }

        // As the bridge walks them: skip, then read up to the limit or the deadline.
        var read = Array(candidates.dropFirst(walk.skip).prefix(walk.read))
        var stop: TrackPage.Stop = walk.skip + walk.read < candidates.count ? .readLimit : .end
        if let deadlineAfter, read.count > deadlineAfter {
            read = Array(read.prefix(deadlineAfter))
            stop = .deadline
        }

        // The text is matched after the read, as in the real store: a query can only find
        // what the walk reached.
        var rows = read
        if let text = filter.text?.lowercased(), !text.isEmpty {
            rows = rows.filter {
                [$0.name, $0.artist, $0.albumArtist, $0.album, $0.composer]
                    .contains { $0.lowercased().contains(text) }
            }
        }
        // A walk that reached the end counted the candidates itself; one that did not has
        // only what Music says.
        let counted = stop == .end ? candidates.count : (answersCount ? miscount ?? candidates.count : nil)
        return TrackPage(rows: rows, scanned: read.count, stop: stop, candidates: counted)
    }

    func track(persistentID: String) async throws -> TrackDetail? {
        if let failure { throw failure }
        guard let row = tracksValue.first(where: { $0.persistentID == persistentID }) else {
            return nil
        }
        return TrackDetail(row: row, lyrics: lyricsByID[persistentID] ?? lyricsValue)
    }

    func playlists() async throws -> [PlaylistInfo] {
        if let failure { throw failure }
        return playlistsValue
    }

    func createPlaylist(named name: String) async throws -> PlaylistInfo {
        if let failure { throw failure }
        createdPlaylists.append(name)
        let created = PlaylistInfo(
            persistentID: "PL-\(createdPlaylists.count)", name: name, trackCount: 0, duration: 0)
        playlistsValue.append(created)
        return created
    }

    func addTracks(
        persistentIDs: [String], toPlaylist playlistPersistentID: String, skipDuplicates: Bool
    ) async throws -> AddOutcome {
        if let failure { throw failure }
        let playlist = playlistsValue.first { $0.persistentID == playlistPersistentID }
        appended.append(
            (ids: persistentIDs, playlist: playlistPersistentID, skipDuplicates: skipDuplicates))

        let known = Set(tracksValue.map(\.persistentID))
        var present = Set(playlistTracks[playlistPersistentID] ?? [])
        var missing: [String] = []
        var duplicates: [String] = []
        var added = 0

        for identifier in persistentIDs {
            if skipDuplicates, present.contains(identifier) {
                duplicates.append(identifier)
                continue
            }
            guard known.contains(identifier) else {
                missing.append(identifier)
                continue
            }
            playlistTracks[playlistPersistentID, default: []].append(identifier)
            // Mirrors the bridge: an id appended in this same call counts as present for
            // the ids that follow it.
            if skipDuplicates { present.insert(identifier) }
            added += 1
        }

        return AddOutcome(
            playlistName: playlist?.name ?? playlistPersistentID,
            added: added, missing: missing, duplicates: duplicates)
    }

    func control(_ command: PlaybackCommand, volume: Int?) async throws -> PlayerStatus {
        if let failure { throw failure }
        commands.append((command: command, volume: volume))
        status = PlayerStatus(
            state: command == .pause ? .paused : .playing,
            volume: volume ?? status.volume,
            position: status.position,
            playlistName: status.playlistName,
            track: status.track)
        return status
    }
}

// MARK: - Driving the tools

struct ToolResult {
    var text: String
    var isError: Bool
}

func call(
    _ tool: String, _ arguments: [String: Value] = [:], store: FakeMusicStore = FakeMusicStore(),
    timeout: Duration = MusicTools.defaultTimeout
) async -> ToolResult {
    // A fixed calendar, so a date in a result reads the same on every machine.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let tools = MusicTools(store: store, calendar: calendar, timeout: timeout)
    let result = await tools.handle(ToolCall(name: tool, arguments: arguments))
    return ToolResult(text: result.text, isError: result.isError)
}

// MARK: - Fixtures

extension TrackRow {
    /// Invented throughout. Nothing here is taken from the owner's library.
    static func fixture(
        id: String = "T1", name: String = "Marea Baja", artist: String = "Lagun",
        album: String = "Itsasoa", genre: String = "Folk", playedCount: Int = 0,
        favorited: Bool = false
    ) -> TrackRow {
        TrackRow(
            persistentID: id, name: name, artist: artist, albumArtist: artist, album: album,
            genre: genre, year: 2021, duration: 214, playedCount: playedCount,
            favorited: favorited)
    }
}
