import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; the two tools that change the library
/// start with a verb, so they sort together and read as writes at a glance.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, because `Dispatch`
    /// has to compare a call's name against them without building the whole catalogue
    /// first.
    public static let statusName = "music_status"
    public static let nowPlayingName = "now_playing"
    public static let searchName = "music_search"
    public static let tracksName = "tracks_list"
    public static let playlistsName = "playlists_list"
    public static let playlistGetName = "playlist_get"
    public static let trackGetName = "track_get"
    public static let createPlaylistName = "create_playlist"
    public static let addToPlaylistName = "add_to_playlist"
    public static let controlName = "music_control"

    /// Every tool that only reads. Kept here rather than inferred from the annotations so
    /// the tests can check the two against each other instead of against themselves.
    public static let readOnlyNames: Set<String> = [
        statusName, nowPlayingName, searchName, tracksName, playlistsName, playlistGetName,
        trackGetName,
    ]

    public static func all() -> [Tool] {
        [
            status, nowPlaying, search, tracks, playlists,
            playlistGet, trackGet, createPlaylist, addToPlaylist, control,
        ]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is always a single string, never `["string", "null"]`. Claude Desktop's
    /// schema sanitiser drops a property whose type is a union and hands the model a bare
    /// `{}` in its place; an array argument is then serialised to a string and rejected
    /// on arrival. Omitting a filter is how it is left unset — there is no null here.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func integer(
        _ description: String, minimum: Int, maximum: Int, default def: Int? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
    }

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let ratingHelp = """
        Music's own 0–100 scale in steps of 20: one star is 20, five stars is 100. \
        Unrated is 0.
        """

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Music availability and settings",
        description: """
            Reports whether Music is running and whether this server may drive it, and \
            says exactly what to enable and where if it may not. Also shows the scan and \
            result limits this server is configured with. Reads no tracks and never \
            launches Music.

            Use it when another Music tool fails, or when setting the server up. Do not \
            use it to find out what is playing — that is now_playing.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let nowPlaying = Tool(
        name: nowPlayingName,
        title: "What is playing now",
        description: """
            Returns the current track with its full library row, how far into it playback \
            has reached, the player state, the volume, and the playlist it is coming from.

            Reports what Music is doing; it does not change it. Nothing being loaded is a \
            normal answer, not an error.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search the library",
        description: """
            Finds tracks, albums, artists or playlists whose text matches a query. \
            Returns one line each, with the id needed by track_get, playlist_get or \
            add_to_playlist.

            Albums and artists are not objects in Music's dictionary: those two modes \
            are a plain group-by over the matching track rows, and the count beside \
            each one is a count of tracks that were scanned, not of everything in the \
            library. Track and playlist modes return rows, not aggregates.

            Matching is case-insensitive and covers name, artist, album artist, album \
            and composer. The walk stops after \(Configuration.scanCeiling) tracks; \
            use tracks_list when the question is about a whole genre or year rather \
            than a name.
            """,
        inputSchema: object(
            properties: [
                "query": string("Text to match. Case-insensitive, matched anywhere."),
                "type": .object([
                    "type": .string("string"),
                    "enum": .array(SearchType.allCases.map { .string($0.rawValue) }),
                    "default": .string(SearchType.tracks.rawValue),
                    "description": .string(
                        "What to look for. Defaults to tracks."),
                ]),
                "limit": integer(
                    "Maximum rows to return.",
                    minimum: Configuration.searchLimitRange.lowerBound,
                    maximum: Configuration.searchLimitRange.upperBound,
                    default: Configuration.searchLimit),
            ],
            required: ["query"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let tracks = Tool(
        name: tracksName,
        title: "List raw track rows",
        description: """
            Returns library rows with every field Music stores about a track except \
            the lyrics: play count and last played, skip count and last skipped, \
            rating, favourite and dislike flags, date added, genre, year, composer, \
            duration, album, artist, kind, size and cloud status.

            This is the tool for any question about listening habits. It ships raw \
            rows and does no analysis: work out the ranking, the totals or the trend \
            from the rows themselves. There is deliberately no statistics tool here.

            Every filter mirrors a field Music itself stores, and they combine with \
            AND. Rows come back in library order — there is no sort argument, so \
            narrow with the filters and order what you get.

            One query walks at most \(Configuration.scanCeiling) tracks; the answer \
            says so when it stopped early. Music does the reading, so an unfiltered \
            pass over a large library is slow.
            """,
        inputSchema: object(properties: [
            "genre": string("Exact genre, as Music spells it. Case-insensitive."),
            "year_from": integer("Earliest release year, inclusive.", minimum: 0, maximum: 3000),
            "year_to": integer("Latest release year, inclusive.", minimum: 0, maximum: 3000),
            "added_from": string("Added on or after this date. \(dateHelp)"),
            "added_to": string("Added on or before this date. \(dateHelp)"),
            "played_count_from": integer(
                "Played at least this many times.", minimum: 0, maximum: 1_000_000),
            "played_count_to": integer(
                "Played at most this many times. 0 finds what was never played.",
                minimum: 0, maximum: 1_000_000),
            "rating_from": integer(
                "Rated at least this. \(ratingHelp)", minimum: 0, maximum: 100),
            "favorited": boolean(
                "true for favourites only, false for everything not favourited. Omit "
                    + "to ignore the flag."),
            "playlist_id": string(
                "Restrict to one playlist, by the id playlists_list returned. Omit to "
                    + "walk the whole library."),
            "limit": integer(
                "Maximum rows to return.",
                minimum: Configuration.searchLimitRange.lowerBound,
                maximum: Configuration.searchLimitRange.upperBound,
                default: Configuration.searchLimit),
            "offset": integer(
                "Skip this many matching rows; use it to page.",
                minimum: Configuration.offsetRange.lowerBound,
                maximum: Configuration.offsetRange.upperBound, default: 0),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let playlists = Tool(
        name: playlistsName,
        title: "List playlists",
        description: """
            Lists every playlist with its id, track count, total time, and whether \
            add_to_playlist can append to it.

            Call this before add_to_playlist: smart, Genius, folder and library playlists \
            are maintained by Music itself and will refuse tracks. Call it before \
            create_playlist too, to see whether the name is already taken.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let playlistGet = Tool(
        name: playlistGetName,
        title: "Read one playlist",
        description: """
            Returns a playlist's details and its tracks as raw rows, the same shape \
            tracks_list returns.

            Needs an id from playlists_list or music_search. Page with 'offset' for a \
            playlist longer than the limit.
            """,
        inputSchema: object(
            properties: [
                "id": string("Playlist id returned by playlists_list."),
                "limit": integer(
                    "Maximum track rows to return.",
                    minimum: Configuration.searchLimitRange.lowerBound,
                    maximum: Configuration.searchLimitRange.upperBound,
                    default: Configuration.searchLimit),
                "offset": integer(
                    "Skip this many tracks; use it to page.",
                    minimum: Configuration.offsetRange.lowerBound,
                    maximum: Configuration.offsetRange.upperBound, default: 0),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let trackGet = Tool(
        name: trackGetName,
        title: "Full track record",
        description: """
            Returns everything Music stores about one or more tracks, including the \
            lyrics — the one field tracks_list leaves out, because reading it costs a \
            round trip per track.

            Takes ids in bulk so several tracks can be read in one call. Ids come from \
            music_search, tracks_list or playlist_get; they are Music's persistent ids \
            and cannot be typed by hand.
            """,
        inputSchema: object(
            properties: [
                "ids": stringArray("Track ids. At least one; several are read in one pass.")
            ],
            required: ["ids"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: Writes

    static let createPlaylist = Tool(
        name: createPlaylistName,
        title: "Create an empty playlist",
        description: """
            Creates a new, empty playlist in Music.

            REFUSES a name that is already in use, and never replaces or empties an \
            existing playlist. Add tracks afterwards with add_to_playlist.
            """,
        inputSchema: object(
            properties: ["name": string("Name for the new playlist.")],
            required: ["name"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false,
            openWorldHint: false)
    )

    static let addToPlaylist = Tool(
        name: addToPlaylistName,
        title: "Add tracks to a playlist",
        description: """
            Appends tracks to an existing playlist. It only ever adds: nothing already in \
            the playlist is removed, replaced or reordered, and by default a track already \
            there gains a second entry rather than being deduplicated.

            Pass skip_duplicates=true to leave out ids the playlist already holds. Set it \
            when retrying a call that may have already succeeded — a timed-out add often \
            went through, and repeating it is how a playlist ends up with every track \
            twice. Nothing here can undo that afterwards.

            REFUSES smart, Genius, folder and library playlists — Music maintains those \
            itself. Check 'accepts tracks' in playlists_list first. An id the library does \
            not resolve is reported back rather than silently skipped.
            """,
        inputSchema: object(
            properties: [
                "playlist_id": string("Playlist id returned by playlists_list."),
                "track_ids": stringArray("Track ids to append, in the order they should go in."),
                "skip_duplicates": boolean(
                    "true to leave out ids the playlist already holds, reporting them "
                        + "instead of appending them again. Also applies within one call, so "
                        + "the same id twice is added once. Defaults to false, which appends "
                        + "everything given."),
            ],
            required: ["playlist_id", "track_ids"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false,
            openWorldHint: false)
    )

    static let control = Tool(
        name: controlName,
        title: "Control playback",
        description: """
            CHANGES WHAT IS CURRENTLY PLAYING on this Mac: starts or pauses playback, \
            skips to the next or previous track, or sets the system music volume. The \
            effect is immediate and audible to whoever is at the machine.

            It cannot be undone by calling it again — "previous" returns to the previous \
            track in the playlist, it does not restore what was playing before. Nothing \
            here modifies the library, and nothing here deletes anything. Say what you are \
            about to change before calling it.

            Music must already be running; this server will not launch it.
            """,
        inputSchema: object(
            properties: [
                "command": .object([
                    "type": .string("string"),
                    "enum": .array(PlaybackCommand.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        """
                        play resumes or starts the current track; pause stops it where it \
                        is; next and previous move within the current playlist; volume \
                        sets the level and needs the 'volume' argument.
                        """),
                ]),
                "volume": integer(
                    "Volume 0–100. Only read when command is \"volume\".",
                    minimum: 0, maximum: 100),
            ],
            required: ["command"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false,
            openWorldHint: false)
    )
}
