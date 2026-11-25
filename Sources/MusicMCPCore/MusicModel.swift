import Foundation

/// What Music is doing right now.
public enum PlaybackState: String, Sendable, Equatable {
    case stopped
    case playing
    case paused
    case fastForwarding = "fast forwarding"
    case rewinding
    /// Music answered with a code this server does not know. Reported rather than
    /// guessed at: a new state in a future release should read as unfamiliar, not as
    /// "stopped".
    case unknown

    public init(bridgeName: String) {
        self = PlaybackState(rawValue: bridgeName) ?? .unknown
    }
}

/// One row of the library, with every property `tracks_list` promises and no lyrics —
/// reading lyrics costs a round trip per track and is what `track_get` is for.
///
/// Absent values are the empty string, zero, or nil for a date. Music has no null: a
/// track with no composer has an empty composer, and flattening that to nil would lose
/// the distinction between "not set" and "not read".
public struct TrackRow: Sendable, Equatable {
    public let persistentID: String
    public let name: String
    public let artist: String
    public let albumArtist: String
    public let album: String
    public let genre: String
    public let composer: String
    public let comment: String
    public let sortName: String
    public let kind: String
    /// iCloud state: purchased, matched, uploaded, subscription, and so on. Empty when
    /// Music reports nothing.
    public let cloudStatus: String
    public let year: Int
    public let bpm: Int
    /// Seconds. Music stores this as a real, so a 3:31 track is 211.4 rather than 211.
    public let duration: Double
    public let trackNumber: Int
    public let discNumber: Int
    public let playedCount: Int
    public let skippedCount: Int
    /// Music's own 0–100 scale, in steps of 20 — one star is 20, five stars is 100.
    /// Passed through unconverted so a filter and a displayed value cannot disagree.
    public let rating: Int
    public let size: Int
    public let favorited: Bool
    public let disliked: Bool
    public let compilation: Bool
    public let playedDate: Date?
    public let skippedDate: Date?
    public let dateAdded: Date?

    public init(
        persistentID: String, name: String, artist: String = "", albumArtist: String = "",
        album: String = "", genre: String = "", composer: String = "", comment: String = "",
        sortName: String = "", kind: String = "", cloudStatus: String = "", year: Int = 0,
        bpm: Int = 0, duration: Double = 0, trackNumber: Int = 0, discNumber: Int = 0,
        playedCount: Int = 0, skippedCount: Int = 0, rating: Int = 0, size: Int = 0,
        favorited: Bool = false, disliked: Bool = false, compilation: Bool = false,
        playedDate: Date? = nil, skippedDate: Date? = nil, dateAdded: Date? = nil
    ) {
        self.persistentID = persistentID
        self.name = name
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.composer = composer
        self.comment = comment
        self.sortName = sortName
        self.kind = kind
        self.cloudStatus = cloudStatus
        self.year = year
        self.bpm = bpm
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.playedCount = playedCount
        self.skippedCount = skippedCount
        self.rating = rating
        self.size = size
        self.favorited = favorited
        self.disliked = disliked
        self.compilation = compilation
        self.playedDate = playedDate
        self.skippedDate = skippedDate
        self.dateAdded = dateAdded
    }
}

/// A row plus the lyrics, which only `track_get` pays for.
public struct TrackDetail: Sendable, Equatable {
    public let row: TrackRow
    /// Whole, however long: the tool layer decides how much of it one result holds and
    /// says how to read the rest.
    public let lyrics: String

    public init(row: TrackRow, lyrics: String) {
        self.row = row
        self.lyrics = lyrics
    }
}

/// Which stretch of the candidates one query walks.
///
/// The candidates are the tracks left by the filters Music evaluates itself, in the order
/// Music lists them. Passing over one costs nothing, because none of its properties is
/// read; reading one costs a round trip per property. So a listing pages at the source
/// (`skip` is its offset, `read` its limit) and never hauls rows it will not show.
public struct TrackWalk: Sendable, Equatable {
    /// Candidates to pass over before any is read.
    public var skip: Int
    /// The most candidates to read in full.
    public var read: Int
    /// When to stop reading although `read` was not reached. `nil` reads on regardless.
    public var deadline: Date?

    public init(skip: Int = 0, read: Int, deadline: Date? = nil) {
        self.skip = skip
        self.read = read
        self.deadline = deadline
    }
}

public struct TrackPage: Sendable, Equatable {

    /// Why the walk ended. Reported, never inferred from a count: a walk that read exactly
    /// `read` candidates and a source exactly that long look the same from the outside, and
    /// only one of them has tracks nobody looked at.
    public enum Stop: Sendable, Equatable {
        /// Every candidate was passed over or read.
        case end
        /// `read` candidates were read and at least one more follows.
        case readLimit
        /// The deadline passed with candidates still unread.
        case deadline
    }

    /// The rows that were read and matched the text filter, in the order Music lists them.
    public let rows: [TrackRow]
    /// How many candidates were read in full, whether or not their text matched.
    public let scanned: Int
    public let stop: Stop
    /// How many candidates there are in all. Exact when the walk reached the end, because
    /// the walk counted them. Otherwise it is Music's own count, asked after the walk
    /// stopped, and `nil` when Music gave none: a figure to state, never one to rely on
    /// for deciding whether more exist. `stop` decides that.
    public let candidates: Int?

    public init(rows: [TrackRow], scanned: Int, stop: Stop, candidates: Int?) {
        self.rows = rows
        self.scanned = scanned
        self.stop = stop
        self.candidates = candidates
    }

    /// How many candidates exist, as a result showing `shown` rows after `offset` may
    /// state it: the walk's own count at the end, and Music's count only when it agrees
    /// that rows remain after the ones shown.
    public func total(after offset: Int, shown: Int) -> Int? {
        switch stop {
        case .end: return candidates ?? offset + shown
        case .readLimit, .deadline:
            guard let candidates, candidates > offset + shown else { return nil }
            return candidates
        }
    }
}

public struct PlaylistInfo: Sendable, Equatable {
    public let persistentID: String
    public let name: String
    public let trackCount: Int
    /// Seconds.
    public let duration: Int
    /// Music's `special kind`: "Library", "folder", "Genius", "Music", "Purchased Music",
    /// or empty for an ordinary playlist.
    public let specialKind: String
    public let isSmart: Bool
    public let isGenius: Bool

    public init(
        persistentID: String, name: String, trackCount: Int, duration: Int,
        specialKind: String = "", isSmart: Bool = false, isGenius: Bool = false
    ) {
        self.persistentID = persistentID
        self.name = name
        self.trackCount = trackCount
        self.duration = duration
        self.specialKind = specialKind
        self.isSmart = isSmart
        self.isGenius = isGenius
    }

    /// Whether `add_to_playlist` may append to it.
    ///
    /// Everything Music maintains itself is excluded: the library, folders, Genius and
    /// smart playlists. A smart playlist's contents are the output of its rules, and a
    /// track appended by hand either vanishes on the next evaluation or corrupts what the
    /// rules were meant to express.
    public var isEditable: Bool {
        specialKind.isEmpty && !isSmart && !isGenius
    }
}

public struct PlayerStatus: Sendable, Equatable {
    public let state: PlaybackState
    /// 0–100, Music's own scale.
    public let volume: Int
    /// Seconds into the current track.
    public let position: Double
    public let playlistName: String
    /// Absent when nothing is loaded, which is an ordinary state rather than a failure.
    public let track: TrackRow?

    public init(
        state: PlaybackState, volume: Int, position: Double, playlistName: String,
        track: TrackRow?
    ) {
        self.state = state
        self.volume = volume
        self.position = position
        self.playlistName = playlistName
        self.track = track
    }
}

/// What `add_to_playlist` actually managed to do. `missing` holds the ids the library did
/// not resolve, so a partial success reads as a partial success.
public struct AddOutcome: Sendable, Equatable {
    public let playlistName: String
    public let added: Int
    public let missing: [String]
    /// Ids left out because the playlist already held them. Only ever populated when the
    /// caller asked for that; without `skipDuplicates` nothing is skipped, so an empty
    /// array here means "none were skipped", never "none were duplicates".
    public let duplicates: [String]

    public init(playlistName: String, added: Int, missing: [String], duplicates: [String]) {
        self.playlistName = playlistName
        self.added = added
        self.missing = missing
        self.duplicates = duplicates
    }
}

/// The closed set of transport commands. Playback is the only state this server changes
/// outside the two playlist tools, and an enumeration is what keeps the list from growing
/// by accident — `stop`, `quit` and `convert` are in Music's dictionary and are not here.
public enum PlaybackCommand: String, Sendable, Equatable, CaseIterable {
    case play
    case pause
    case next
    case previous
    case volume
}

/// Every filter `tracks_list` and `music_search` can apply, all of them mirroring a field
/// Music itself stores. Nothing here is computed: a filter exists to avoid hauling the
/// whole library across the Apple event boundary, which is mechanical necessity rather
/// than judgment.
public struct TrackFilter: Sendable, Equatable {
    /// Matched against name, artist, album artist, album and composer. Applied in Swift
    /// rather than pushed into Music, because a `whose` clause cannot express "any of
    /// five fields contains this" without becoming unreadable.
    public var text: String?
    public var genre: String?
    public var yearFrom: Int?
    public var yearTo: Int?
    public var addedFrom: Date?
    public var addedTo: Date?
    public var playedCountFrom: Int?
    public var playedCountTo: Int?
    public var ratingFrom: Int?
    public var favorited: Bool?
    /// Scopes the walk to one playlist instead of the library.
    public var playlistPersistentID: String?

    public init() {}

    /// True when nothing at all was asked for, which is what makes a scan of the whole
    /// library worth warning about.
    public var isEmpty: Bool { self == TrackFilter() }
}
