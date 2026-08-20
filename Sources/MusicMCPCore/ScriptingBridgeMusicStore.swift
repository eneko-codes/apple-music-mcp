import AppKit
import Foundation
import MusicBridge

/// `MusicStore` backed by the real Music app, driven through Apple events.
///
/// Nothing here reads the library database directly: every read is Music doing the work
/// and handing back the result. That is why Music has to be running, and why every walk
/// is bounded — a property read is a round trip, and an unbounded pass over a large
/// library will appear to hang.
///
/// The Apple events themselves live in the `MusicBridge` Objective-C target; see its
/// header for why they cannot live in Swift. What stays here is policy: which filters to
/// push down, how a text query matches, and how a raw dictionary becomes a `TrackRow`.
/// That split is deliberate — policy is what the tests can reach through `MusicStore`,
/// and the bridge is the part no test can.
public struct ScriptingBridgeMusicStore: MusicStore {
    public static let bundleIdentifier = "com.apple.Music"

    public init() {}

    // MARK: Availability

    public func availability() -> MusicAvailability {
        guard
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
                != nil
        else { return .notInstalled }

        // "Not running" is checked before consent, and the order matters. Consent is
        // reported as pending until the first Apple event, and that event would launch
        // Music — which, unlike most apps, can start playing audio out loud as it opens.
        // Answering `.notRunning` first keeps the refusal ahead of the launch.
        guard MusicBridge.isMusicRunning else { return .notRunning }

        switch Self.automationPermission() {
        case OSStatus(errAEEventNotPermitted): return .automationDenied
        case OSStatus(errAEEventWouldRequireUserConsent): return .consentNotGranted
        case OSStatus(procNotFound): return .notRunning
        default: return .ready
        }
    }

    /// Asks TCC whether this process may drive Music, **without sending a real event and
    /// without raising a dialog** (`askUserIfNeeded: false`). That is what lets
    /// `music_status` be honest about permissions while reading no tracks at all.
    static func automationPermission() -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Data(bundleIdentifier.utf8)
        let created = identifier.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    private func guardAvailability() throws {
        let state = availability()
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }
    }

    /// The bridge reports failures as `NSError`; the tool layer speaks `ToolError`.
    private func storeFailure(_ error: Error) -> ToolError {
        .storeFailure(error.localizedDescription)
    }

    // MARK: Decoding

    /// A bridge dictionary becomes a row here and nowhere else, so a key that changes
    /// name breaks in one place.
    static func row(_ raw: [String: Any]) -> TrackRow {
        func date(_ key: String) -> Date? { raw[key] as? Date }
        return TrackRow(
            persistentID: raw["persistentID"] as? String ?? "",
            name: raw["name"] as? String ?? "",
            artist: raw["artist"] as? String ?? "",
            albumArtist: raw["albumArtist"] as? String ?? "",
            album: raw["album"] as? String ?? "",
            genre: raw["genre"] as? String ?? "",
            composer: raw["composer"] as? String ?? "",
            comment: raw["comment"] as? String ?? "",
            sortName: raw["sortName"] as? String ?? "",
            kind: raw["kind"] as? String ?? "",
            cloudStatus: raw["cloudStatus"] as? String ?? "",
            year: raw["year"] as? Int ?? 0,
            bpm: raw["bpm"] as? Int ?? 0,
            duration: raw["duration"] as? Double ?? 0,
            trackNumber: raw["trackNumber"] as? Int ?? 0,
            discNumber: raw["discNumber"] as? Int ?? 0,
            playedCount: raw["playedCount"] as? Int ?? 0,
            skippedCount: raw["skippedCount"] as? Int ?? 0,
            rating: raw["rating"] as? Int ?? 0,
            size: raw["size"] as? Int ?? 0,
            favorited: raw["favorited"] as? Bool ?? false,
            disliked: raw["disliked"] as? Bool ?? false,
            compilation: raw["compilation"] as? Bool ?? false,
            playedDate: date("playedDate"),
            skippedDate: date("skippedDate"),
            dateAdded: date("dateAdded"))
    }

    static func playlist(_ raw: [String: Any]) -> PlaylistInfo {
        PlaylistInfo(
            persistentID: raw["persistentID"] as? String ?? "",
            name: raw["name"] as? String ?? "",
            trackCount: raw["trackCount"] as? Int ?? 0,
            duration: raw["duration"] as? Int ?? 0,
            specialKind: raw["specialKind"] as? String ?? "",
            isSmart: raw["smart"] as? Bool ?? false,
            isGenius: raw["genius"] as? Bool ?? false)
    }

    static func status(_ raw: [String: Any]) -> PlayerStatus {
        PlayerStatus(
            state: PlaybackState(bridgeName: raw["state"] as? String ?? ""),
            volume: raw["volume"] as? Int ?? 0,
            position: raw["position"] as? Double ?? 0,
            playlistName: raw["playlistName"] as? String ?? "",
            track: (raw["track"] as? [String: Any]).map(row))
    }

    // MARK: Filtering

    /// Turns the filter into a `whose` clause Music evaluates itself.
    ///
    /// Everything expressible as a comparison on one property is pushed down, because
    /// filtering inside Music is dramatically cheaper than shipping rows across the Apple
    /// event boundary. The text query is not: it spans five fields, and a five-way OR of
    /// `CONTAINS` in a `whose` clause is both unreadable and the kind of construct that
    /// fails by returning nothing rather than by erroring. It is applied in Swift instead,
    /// after the scan — which is why a text search can only find what the scan reached,
    /// and why the ceiling being hit is reported.
    ///
    /// Built with `NSPredicate(format:argumentArray:)`, so caller strings are typed
    /// arguments and never spliced into a string.
    static func predicate(for filter: TrackFilter) -> NSPredicate? {
        var clauses: [String] = []
        var values: [Any] = []

        if let genre = filter.genre {
            clauses.append("genre ==[c] %@")
            values.append(genre)
        }
        if let year = filter.yearFrom {
            clauses.append("year >= %d")
            values.append(year)
        }
        if let year = filter.yearTo {
            clauses.append("year <= %d")
            values.append(year)
        }
        if let added = filter.addedFrom {
            clauses.append("dateAdded >= %@")
            values.append(added)
        }
        if let added = filter.addedTo {
            clauses.append("dateAdded <= %@")
            values.append(added)
        }
        if let played = filter.playedCountFrom {
            clauses.append("playedCount >= %d")
            values.append(played)
        }
        if let played = filter.playedCountTo {
            clauses.append("playedCount <= %d")
            values.append(played)
        }
        if let rating = filter.ratingFrom {
            clauses.append("rating >= %d")
            values.append(rating)
        }
        if let favorited = filter.favorited {
            clauses.append("favorited == %@")
            values.append(NSNumber(value: favorited))
        }

        guard !clauses.isEmpty else { return nil }
        return NSPredicate(
            format: clauses.joined(separator: " AND "), argumentArray: values)
    }

    /// Case-insensitive match across the fields a person would name a track by.
    static func matches(_ row: TrackRow, text: String) -> Bool {
        [row.name, row.artist, row.albumArtist, row.album, row.composer]
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }

    // MARK: Reads

    public func playerStatus() async throws -> PlayerStatus {
        try guardAvailability()
        do { return Self.status(try MusicBridge.playerState()) } catch { throw storeFailure(error) }
    }

    public func tracks(matching filter: TrackFilter, scanCeiling: Int) async throws -> TrackPage {
        try guardAvailability()

        let page: [String: Any]
        do {
            page = try MusicBridge.scanTracks(
                inPlaylist: filter.playlistPersistentID,
                predicate: Self.predicate(for: filter), maxScan: scanCeiling)
        } catch let failure as NSError
            where failure.domain == MusicBridgeErrorDomain
                && failure.code == MusicBridgeError.playlistNotFound.rawValue
        {
            throw ToolError.playlistNotFound(id: filter.playlistPersistentID ?? "")
        } catch {
            throw storeFailure(error)
        }

        let scanned = page["scanned"] as? Int ?? 0
        var rows = (page["tracks"] as? [[String: Any]] ?? []).map(Self.row)
        if let text = filter.text, !text.isEmpty {
            rows = rows.filter { Self.matches($0, text: text) }
        }
        // The ceiling being reached is reported rather than inferred from the count: a
        // scan that stopped exactly at the ceiling and a library exactly that size look
        // identical from the outside, and only one of them is missing tracks.
        return TrackPage(results: rows, total: rows.count, hitScanLimit: scanned >= scanCeiling)
    }

    public func track(persistentID: String, lyricsLimit: Int) async throws -> TrackDetail? {
        try guardAvailability()

        let raw: [String: Any]
        do {
            raw = try MusicBridge.track(withPersistentID: persistentID)
        } catch let failure as NSError
            where failure.domain == MusicBridgeErrorDomain
                && failure.code == MusicBridgeError.trackNotFound.rawValue
        {
            // Not a failure: a track can leave the library between two calls, and the
            // tool layer turns a nil into its own "search again" message.
            return nil
        } catch {
            throw storeFailure(error)
        }

        let lyrics = raw["lyrics"] as? String ?? ""
        let truncated = lyrics.count > lyricsLimit
        return TrackDetail(
            row: Self.row(raw),
            lyrics: truncated ? String(lyrics.prefix(lyricsLimit)) : lyrics,
            lyricsTruncated: truncated)
    }

    public func playlists() async throws -> [PlaylistInfo] {
        try guardAvailability()
        do {
            return try MusicBridge.playlists().map(Self.playlist)
        } catch { throw storeFailure(error) }
    }

    // MARK: Writes

    public func createPlaylist(named name: String) async throws -> PlaylistInfo {
        try guardAvailability()
        do {
            return Self.playlist(try MusicBridge.createPlaylistNamed(name))
        } catch let failure as NSError
            where failure.domain == MusicBridgeErrorDomain
                && failure.code == MusicBridgeError.playlistExists.rawValue
        {
            throw ToolError.playlistExists(name: name)
        } catch {
            throw storeFailure(error)
        }
    }

    public func addTracks(
        persistentIDs: [String], toPlaylist playlistPersistentID: String, skipDuplicates: Bool
    ) async throws -> AddOutcome {
        try guardAvailability()

        let raw: [String: Any]
        do {
            raw = try MusicBridge.addTracks(
                withPersistentIDs: persistentIDs, toPlaylistPersistentID: playlistPersistentID,
                skipDuplicates: skipDuplicates)
        } catch let failure as NSError
            where failure.domain == MusicBridgeErrorDomain
                && failure.code == MusicBridgeError.playlistNotFound.rawValue
        {
            throw ToolError.playlistNotFound(id: playlistPersistentID)
        } catch let failure as NSError
            where failure.domain == MusicBridgeErrorDomain
                && failure.code == MusicBridgeError.playlistNotEditable.rawValue
        {
            throw ToolError.playlistNotEditable(
                name: playlistPersistentID, reason: failure.localizedDescription)
        } catch {
            throw storeFailure(error)
        }

        return AddOutcome(
            playlistName: raw["playlistName"] as? String ?? "",
            added: raw["added"] as? Int ?? 0,
            missing: raw["missing"] as? [String] ?? [],
            duplicates: raw["duplicates"] as? [String] ?? [])
    }

    public func control(_ command: PlaybackCommand, volume: Int?) async throws -> PlayerStatus {
        try guardAvailability()
        do {
            return Self.status(
                try MusicBridge.runCommand(
                    command.rawValue, volume: volume.map { NSNumber(value: $0) }))
        } catch { throw storeFailure(error) }
    }
}
