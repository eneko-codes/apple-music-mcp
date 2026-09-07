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
    var lyricsValue: String = ""
    var playlistsValue: [PlaylistInfo] = []
    var status = PlayerStatus(
        state: .stopped, volume: 50, position: 0, playlistName: "", track: nil)

    /// Set to make the next call fail, so the error path is reachable without a real
    /// Apple event failure.
    var failure: (any Error)?

    // Recorded so a test can prove a tool passed through what it claimed to.
    private(set) var lastFilter: TrackFilter?
    private(set) var lastScanCeiling: Int?
    private(set) var createdPlaylists: [String] = []
    private(set) var appended: [(ids: [String], playlist: String, skipDuplicates: Bool)] = []

    /// What each playlist already holds, keyed by playlist persistent id. Modelled here
    /// only because skip_duplicates is the one tool behaviour that depends on it.
    var playlistTracks: [String: [String]] = [:]
    private(set) var commands: [(command: PlaybackCommand, volume: Int?)] = []

    func availability() -> MusicAvailability { availabilityValue }

    func playerStatus() async throws -> PlayerStatus {
        if let failure { throw failure }
        return status
    }

    func tracks(matching filter: TrackFilter, scanCeiling: Int) async throws -> TrackPage {
        if let failure { throw failure }
        lastFilter = filter
        lastScanCeiling = scanCeiling

        // Only the text predicate is modelled, because it is the one the tool layer can
        // get wrong. The rest is the store's job and is verified by hand against Music.
        var matched = tracksValue
        if let text = filter.text?.lowercased(), !text.isEmpty {
            matched = matched.filter {
                [$0.name, $0.artist, $0.albumArtist, $0.album, $0.composer]
                    .contains { $0.lowercased().contains(text) }
            }
        }
        if let genre = filter.genre?.lowercased(), !genre.isEmpty {
            matched = matched.filter { $0.genre.lowercased() == genre }
        }
        if let favorited = filter.favorited {
            matched = matched.filter { $0.favorited == favorited }
        }

        let capped = Array(matched.prefix(scanCeiling))
        return TrackPage(
            results: capped, total: matched.count, hitScanLimit: matched.count > scanCeiling)
    }

    func track(persistentID: String, lyricsLimit: Int) async throws -> TrackDetail? {
        if let failure { throw failure }
        guard let row = tracksValue.first(where: { $0.persistentID == persistentID }) else {
            return nil
        }
        let truncated = lyricsValue.count > lyricsLimit
        return TrackDetail(
            row: row,
            lyrics: truncated ? String(lyricsValue.prefix(lyricsLimit)) : lyricsValue,
            lyricsTruncated: truncated)
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
