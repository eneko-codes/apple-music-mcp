import Foundation

/// Whether Music can be driven at all, and if not, why.
///
/// There is no `authorizationStatus` for Apple events the way there is for Contacts or
/// EventKit, so this collapses several distinct causes — Music missing, Music not
/// running, consent refused — into one value the tools can act on.
public enum MusicAvailability: Sendable, Equatable {
    case ready
    case notInstalled
    /// Music is installed but not launched. This server does not launch it: starting an
    /// app on someone's behalf is a side effect they did not ask for, and Music launching
    /// can begin playing audio out loud.
    case notRunning
    case automationDenied
    /// macOS has not asked yet. The first real Apple event raises the dialog.
    case consentNotGranted

    /// Whether a tool call must be refused outright.
    ///
    /// `.consentNotGranted` deliberately does **not** block, which is why "may a call
    /// proceed" is a different question from "is Music ready". macOS only shows the
    /// Automation dialog when a real Apple event is sent, so refusing here would mean the
    /// dialog never appears and the permission could never be granted at all. If consent
    /// is then refused, the event fails and the error path reports it.
    public var blocksCalls: Bool {
        switch self {
        case .ready, .consentNotGranted: return false
        case .notInstalled, .notRunning, .automationDenied: return true
        }
    }
}

/// The seam between the tool layer and Music.
///
/// Nothing above this protocol sends an Apple event, which is what lets the tests drive
/// every branch against an in-memory double — with Music closed and the owner's library
/// untouched.
public protocol MusicStore: Sendable {
    func availability() -> MusicAvailability

    func playerStatus() async throws -> PlayerStatus

    /// `scanCeiling` bounds how many tracks one query may walk. It is passed per call
    /// rather than held by the store so the value the tools enforce and the value
    /// `music_status` reports cannot be two different numbers.
    ///
    /// Paging is the caller's job: the store returns everything that matched within the
    /// ceiling, because a library has no cursor and re-walking it per page would cost
    /// more than shipping the rows once.
    func tracks(matching filter: TrackFilter, scanCeiling: Int) async throws -> TrackPage

    /// nil when the library no longer holds that persistent id — an ordinary outcome
    /// rather than a failure, since a track can be removed between two calls.
    func track(persistentID: String, lyricsLimit: Int) async throws -> TrackDetail?

    func playlists() async throws -> [PlaylistInfo]

    /// Creates an empty playlist. Never overwrites: a name already in use is refused.
    func createPlaylist(named name: String) async throws -> PlaylistInfo

    /// Appends to a playlist. Append only — nothing already in the playlist is removed,
    /// reordered or replaced.
    func addTracks(persistentIDs: [String], toPlaylist playlistPersistentID: String) async throws
        -> AddOutcome

    /// Changes playback and returns the resulting state, so the answer describes what the
    /// owner will actually hear rather than what was requested.
    func control(_ command: PlaybackCommand, volume: Int?) async throws -> PlayerStatus
}
