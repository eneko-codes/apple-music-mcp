import Foundation

public enum ToolError: Error, Equatable {
    case notAvailable(MusicAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case unknownArgument(name: String, tool: String, allowed: [String])
    case unknownTool(String)
    case notFound(ids: [String])
    case tooManyIDs(argument: String, given: Int, most: Int)
    case playlistNotFound(id: String)
    case playlistExists(name: String)
    case playlistNotEditable(name: String, reason: String)
    case noTracksGiven
    case unknownCommand(String)
    case volumeRequired
    case storeFailure(String)
    case timedOut(seconds: Int, tool: String)

    /// How many ids an error lists before it counts the rest.
    static let idsListed = 3

    /// How much of Music's own error text is passed on. It is not the caller's text, so it
    /// gets more room than an echo, and still a bound.
    static let storeDetailWidth = 500

    /// Every piece of a caller's text goes through `ToolStandard.echo`, so no error grows
    /// with what it was sent.
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
                Argument '\(argument)' is not a date this server accepts: '\(ToolStandard.echo(value))'

                Use 2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00, and a day \
                and time that exist.
                """

        case .unknownArgument(let name, let tool, let allowed):
            return """
                '\(ToolStandard.echo(name))' is not an argument of \(tool).

                \(allowed.isEmpty ? "It takes none." : "It takes: " + allowed.joined(separator: ", ") + ".")
                """

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .notFound(let ids):
            let listed = ids.prefix(Self.idsListed).map { "'\(ToolStandard.echo($0))'" }
                .joined(separator: ", ")
            let others = ids.count - Self.idsListed
            return """
                The library holds no track with id \(listed)\(others > 0 ? " or the \(others) other ids given" : "").

                Track ids are Music's persistent ids. They survive a restart but not the
                removal of the track, and they cannot be typed by hand. Run music_search
                or tracks_list again rather than reusing an id from an earlier
                conversation.
                """

        case .tooManyIDs(let argument, let given, let most):
            return """
                '\(argument)' holds \(given) ids and one call takes at most \(most). Nothing \
                was read or changed.

                Split the ids across several calls of at most \(most) each.
                """

        case .playlistNotFound(let id):
            return """
                No playlist carries id '\(ToolStandard.echo(id))'.

                Playlist ids come from playlists_list. Call it again — a playlist deleted
                in Music takes its id with it.
                """

        case .playlistExists(let name):
            return """
                A playlist named '\(ToolStandard.echo(name))' already exists, so nothing was created.

                This server will not make a second playlist under a name that is taken.
                Music would allow it, and the two would then be indistinguishable in every
                listing — which is its own kind of damage. Add to the existing one with
                add_to_playlist, or choose another name.
                """

        case .playlistNotEditable(let name, let reason):
            return """
                Tracks cannot be added to '\(ToolStandard.echo(name))': \(ToolStandard.echo(reason))

                Music maintains this playlist itself. A smart playlist's contents are the
                output of its rules, so a track appended by hand either disappears at the
                next evaluation or quietly contradicts what the rules were meant to say.
                Call playlists_list to see which playlists accept tracks.
                """

        case .noTracksGiven:
            return "add_to_playlist needs at least one id in 'track_ids'."

        case .unknownCommand(let raw):
            return """
                '\(ToolStandard.echo(raw))' is not a playback command.

                Use one of: \(PlaybackCommand.allCases.map(\.rawValue).joined(separator: ", ")).
                """

        case .volumeRequired:
            return """
                music_control(command="volume") needs a 'volume' between \
                \(ToolCatalog.volumeRange.lowerBound) and \(ToolCatalog.volumeRange.upperBound).

                Nothing was changed.
                """

        case .storeFailure(let detail):
            return "Music returned an error: \(String(detail.prefix(Self.storeDetailWidth)))"

        case .timedOut(let seconds, let tool):
            return """
                The call did not finish within \(seconds) seconds and was abandoned. Music \
                does the work, one Apple event at a time, and it may be busy or showing a \
                dialog.

                \(Self.afterTimeout(tool))
                """
        }
    }

    /// What to do after a call was abandoned. A read changed nothing; a write may still
    /// have gone through, because abandoning a call does not stop Music.
    static func afterTimeout(_ tool: String) -> String {
        switch tool {
        case ToolCatalog.addToPlaylistName:
            return """
                The add may still be going on or may have finished: nothing here can stop \
                it. Read the playlist with playlist_get, then retry with \
                skip_duplicates=true and fewer ids, so that nothing is added twice.
                """
        case ToolCatalog.createPlaylistName:
            return """
                The playlist may have been created all the same. Call playlists_list \
                before trying again: create_playlist refuses a name that is taken.
                """
        case ToolCatalog.controlName:
            return """
                The command may have reached Music all the same. Call now_playing to see \
                what it is doing before sending the command again.
                """
        default:
            return """
                Nothing was changed. Ask for less: a lower limit, a narrower filter or \
                fewer ids. music_status says whether Music can be reached at all.
                """
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
