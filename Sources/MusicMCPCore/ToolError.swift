import Foundation

public enum ToolError: Error, Equatable {
    case notAvailable(MusicAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case notFound(id: String)
    case playlistNotFound(id: String)
    case playlistExists(name: String)
    case playlistNotEditable(name: String, reason: String)
    case noTracksGiven
    case unknownCommand(String)
    case volumeRequired
    case storeFailure(String)

    public var message: String {
        switch self {
        case .notAvailable(let state):
            return Self.availabilityMessage(state)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use 2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00.
                """

        case .notFound(let id):
            return """
                The library holds no track with id '\(id)'.

                Track ids are Music's persistent ids. They survive a restart but not the
                removal of the track, and they cannot be typed by hand. Run music_search
                or tracks_list again rather than reusing an id from an earlier
                conversation.
                """

        case .playlistNotFound(let id):
            return """
                No playlist carries id '\(id)'.

                Playlist ids come from playlists_list. Call it again — a playlist deleted
                in Music takes its id with it.
                """

        case .playlistExists(let name):
            return """
                A playlist named '\(name)' already exists, so nothing was created.

                This server will not make a second playlist under a name that is taken.
                Music would allow it, and the two would then be indistinguishable in every
                listing — which is its own kind of damage. Add to the existing one with
                add_to_playlist, or choose another name.
                """

        case .playlistNotEditable(let name, let reason):
            return """
                Tracks cannot be added to '\(name)': \(reason)

                Music maintains this playlist itself. A smart playlist's contents are the
                output of its rules, so a track appended by hand either disappears at the
                next evaluation or quietly contradicts what the rules were meant to say.
                Call playlists_list to see which playlists accept tracks.
                """

        case .noTracksGiven:
            return "add_to_playlist needs at least one id in 'track_ids'."

        case .unknownCommand(let raw):
            return """
                '\(raw)' is not a playback command.

                Use one of: \(PlaybackCommand.allCases.map(\.rawValue).joined(separator: ", ")).
                """

        case .volumeRequired:
            return """
                music_control(command="volume") needs a 'volume' between 0 and 100.

                Nothing was changed.
                """

        case .storeFailure(let detail):
            return "Music returned an error: \(detail)"
        }
    }

    static func availabilityMessage(_ state: MusicAvailability) -> String {
        switch state {
        case .ready:
            return "Music is running and automation is permitted."

        case .notInstalled:
            return """
                Music.app was not found on this Mac.

                This server drives the Music app through Apple events; without it there is
                nothing to talk to.
                """

        case .notRunning:
            return """
                Music is not running.

                This server does not launch it: starting an app on your behalf is a side
                effect you did not ask for, and Music can begin playing audio out loud as
                it opens. Open Music and try again.
                """

        case .consentNotGranted:
            return """
                Automation permission for Music has not been granted yet.

                macOS raises the dialog the first time this server sends an Apple event.
                Restart Claude Desktop, call a Music tool, and approve
                "apple-music-mcp wants to control Music".
                """

        case .automationDenied:
            return """
                Automation permission for Music is denied.

                Grant it in:
                  System Settings → Privacy & Security → Automation → apple-music-mcp → enable Music
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)

                Then restart Claude Desktop. The grant is per target app: allowing Music
                says nothing about any other app.
                """
        }
    }
}
