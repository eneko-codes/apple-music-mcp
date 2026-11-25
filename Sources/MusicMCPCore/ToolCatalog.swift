import Foundation

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

    /// The names of the arguments a tool advertises. A call that carries any other is
    /// refused, as `additionalProperties: false` in every schema says it will be.
    public static func argumentNames(of tool: Tool) -> [String] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [] }
        return Array(properties.keys)
    }

    // MARK: Bounds

    // Every size a tool enforces is here, and the schemas, the descriptions and the server
    // instructions quote these constants, so what is advertised cannot drift from what is
    // enforced. `BoundsTests` holds each one to the tool standard.

    /// How many tracks one `music_search` call reads before it stops. The text of a query
    /// is matched here, not by Music, so a search has to read rows to match them: one
    /// round trip per property per track. A listing does not: `tracks_list` and
    /// `playlist_get` read only the page they return.
    public static let scanCeiling = 2_000

    // Pages. Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult`, and each default makes a call with no argument about
    // `ToolStandard.usualPage` or less. A track row is three lines of labelled fields,
    // which is why its page is the smallest.
    public static let offsetRange = 0...10_000_000
    public static let trackLimitRange = 1...60
    public static let defaultTrackLimit = 15
    public static let playlistLimitRange = 1...200
    public static let defaultPlaylistLimit = 50

    /// How much of a comment a row shows. `track_get` shows the whole.
    public static let commentClipWidth = 80

    /// How much of each track's lyrics `track_get` shows when it is given several ids.
    /// One id reads them whole, through the window below.
    public static let lyricsClipWidth = 500

    /// The most ids one call takes. Each costs round trips to Music, and each is repeated
    /// in the result, so the count bounds both the time and the size of an answer.
    public static let trackIDsRange = 1...20
    public static let addedTracksRange = 1...100

    /// The window on one track's record. The maximum is half the longest result, so a
    /// window of ordinary text fits with room to spare; `ToolStandard.fitting` shrinks one
    /// whose characters take more UTF-16 units than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    // Filters and levels.
    public static let yearRange = 0...3000
    public static let playedCountRange = 0...1_000_000
    public static let ratingRange = 0...100
    public static let volumeRange = 0...100
    public static let longestPlaylistName = 255

    /// What narrows a search whose scan stopped early, as the notice names it.
    public static let searchNarrowing = "genre, year_from and year_to, or playlist_id"

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
    private static func string(_ description: String, longest: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": .string("string"), "description": .string(description)]
        if let longest { schema["maxLength"] = .int(longest) }
        return .object(schema)
    }

    /// A `default` is advertised only where omitting the argument really means that value.
    /// A filter has none: leaving it out means "either", and a default would read as a
    /// filter being applied.
    private static func boolean(_ description: String, default def: Bool? = nil) -> Value {
        var schema: [String: Value] = ["type": .string("boolean"), "description": .string(description)]
        if let def { schema["default"] = .bool(def) }
        return .object(schema)
    }

    private static func integer(
        _ description: String, range: ClosedRange<Int>, default def: Int? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
    }

    private static func stringArray(_ description: String, count: ClosedRange<Int>) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "minItems": .int(count.lowerBound), "maxItems": .int(count.upperBound),
            "description": .string(description),
        ])
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: offsetRange, default: 0)

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let ratingHelp = """
        Music's own 0–100 scale in steps of 20: one star is 20, five stars is 100. \
        Unrated is 0.
        """

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    private static let write = Tool.Annotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Music availability and settings",
        description: """
            Reports whether Music is running and whether this server may drive it, and \
            says exactly what to enable and where if it may not. Also shows the bounds in \
            force: how far a search scans, how many rows a page holds and how long a call \
            may take. Reads no tracks and never launches Music.

            Use it when another Music tool fails, or when setting the server up. Do not \
            use it to find out what is playing — that is now_playing.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let nowPlaying = Tool(
        name: nowPlayingName,
        title: "What is playing now",
        description: """
            Returns the current track with its library row, how far into it playback has \
            reached, the player state, the volume, and the playlist it is coming from. A \
            comment longer than \(commentClipWidth) characters is shortened, and the first \
            line says so; track_get returns it whole.

            Reports what Music is doing; it does not change it. Nothing being loaded is a \
            normal answer, not an error.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let search = Tool(
        name: searchName,
        title: "Search the library",
        description: """
            Finds tracks, albums, artists or playlists whose text matches a query, \
            \(defaultTrackLimit) to a page, with the ids that track_get, playlist_get and \
            add_to_playlist take. When more match than the page holds, the first lines of \
            the result say how many there are and the offset of the next page: pass limit \
            (up to \(trackLimitRange.upperBound)) and offset for the rest.

            A search for tracks, albums or artists reads the first \(scanCeiling) tracks of \
            the library, or of what the narrowing arguments leave, and stops. When it \
            stopped before the end, or ran out of time, the first lines say so and after \
            how many tracks: narrow it with \(searchNarrowing), which Music applies before \
            the scan. A track the scan never read cannot be found by this call.

            Matching is case-insensitive and covers name, artist, album artist, album \
            and composer. Tracks come as full rows in library order, or in playlist order \
            with playlist_id, a comment shortened to \(commentClipWidth) characters. Albums \
            and artists are not objects in Music's dictionary: those two modes group the \
            matching track rows, most tracks first, and the count beside each is of the \
            tracks this search read and matched, not of the whole library; matching tracks \
            with no album, or no artist, are counted in the first lines. Playlists are \
            matched by name, in Music's own order, without reading any track.

            Use tracks_list when the question is about a whole genre or year, or about \
            listening habits, rather than a name.
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
                "genre": string(
                    "Scan only tracks of this exact genre, as Music spells it. Case-insensitive. "
                        + "Not for type playlists."),
                "year_from": integer(
                    "Scan only tracks released in this year or later. Not for type playlists.",
                    range: yearRange),
                "year_to": integer(
                    "Scan only tracks released in this year or earlier. 0 finds tracks with no "
                        + "year. Not for type playlists.",
                    range: yearRange),
                "playlist_id": string(
                    "Scan only the tracks of one playlist, by the id playlists_list returned. "
                        + "Not for type playlists."),
                "limit": limit("rows", range: trackLimitRange, default: defaultTrackLimit),
                "offset": offset,
            ],
            required: ["query"]),
        annotations: readOnly)

    static let tracks = Tool(
        name: tracksName,
        title: "List raw track rows",
        description: """
            Returns library rows, \(defaultTrackLimit) to a page in library order (playlist \
            order with playlist_id), with the fields Music stores about a track: play count \
            and last played, skip count and last skipped, rating, favourite and dislike \
            flags, date added, genre, year, composer, duration, album, artist, kind, size \
            and cloud status. When more rows exist than the page holds, the first lines of \
            the result say how many there are and give the offset of the next page: pass \
            limit (up to \(trackLimitRange.upperBound)) and offset. Every row can be \
            reached that way, however large the library. The lyrics and the sort name are \
            left out, and a comment is shortened to \(commentClipWidth) characters; \
            track_get returns all three whole.

            This is the tool for any question about listening habits. It ships raw \
            rows and does no analysis: work out the ranking, the totals or the trend \
            from the rows themselves. There is deliberately no statistics tool here.

            Every filter mirrors a field Music itself stores, and they combine with \
            AND; from_date and to_date bound the date a track was added, both inclusive. Music applies them before anything is read, so a filtered listing is \
            both shorter and faster. There is no sort argument: narrow with the filters \
            and order what you get.

            Only the rows of the page are read, one Apple event per field, so a larger \
            limit is a slower call. Each call reads the library again, so a track added \
            or removed between two calls shifts the pages.
            """,
        inputSchema: object(properties: [
            "genre": string("Exact genre, as Music spells it. Case-insensitive."),
            "year_from": integer("Earliest release year, inclusive.", range: yearRange),
            "year_to": integer("Latest release year, inclusive.", range: yearRange),
            "from_date": string(
                "Only tracks added to the library on or after this date. \(dateHelp)"),
            "to_date": string(
                "Only tracks added to the library on or before this date; a day alone covers "
                    + "the whole of that day. \(dateHelp)"),
            "played_count_from": integer("Played at least this many times.", range: playedCountRange),
            "played_count_to": integer(
                "Played at most this many times. 0 finds what was never played.",
                range: playedCountRange),
            "rating_from": integer("Rated at least this. \(ratingHelp)", range: ratingRange),
            "favorited": boolean(
                "true for favourites only, false for everything not favourited. Omit "
                    + "to ignore the flag."),
            "playlist_id": string(
                "Restrict to one playlist, by the id playlists_list returned. Omit to "
                    + "list the whole library."),
            "limit": limit("tracks", range: trackLimitRange, default: defaultTrackLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let playlists = Tool(
        name: playlistsName,
        title: "List playlists",
        description: """
            Lists the playlists, \(defaultPlaylistLimit) to a page in Music's own order, each \
            with its id, track count, total time, and whether add_to_playlist can append \
            to it. When there are more than the page holds, the first lines of the result \
            say how many there are and the offset of the next page: pass limit (up to \
            \(playlistLimitRange.upperBound)) and offset.

            Call this before add_to_playlist: smart, Genius, folder and library playlists \
            are maintained by Music itself and will refuse tracks. Call it before \
            create_playlist too, to see whether the name is already taken; music_search \
            with type playlists finds one by name without paging.
            """,
        inputSchema: object(properties: [
            "limit": limit("playlists", range: playlistLimitRange, default: defaultPlaylistLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let playlistGet = Tool(
        name: playlistGetName,
        title: "Read one playlist",
        description: """
            Returns a playlist's details and its first \(defaultTrackLimit) tracks in \
            playlist order, as the raw rows tracks_list returns. When the playlist holds \
            more, the first lines of the result say how many there are and the offset of \
            the next page: pass limit (up to \(trackLimitRange.upperBound)) and offset. \
            Every track can be reached that way, however long the playlist. A comment is \
            shortened to \(commentClipWidth) characters; track_get returns it whole.

            Needs an id from playlists_list or music_search. Only the rows of the page \
            are read, so a larger limit is a slower call.
            """,
        inputSchema: object(
            properties: [
                "id": string("Playlist id returned by playlists_list."),
                "limit": limit("tracks", range: trackLimitRange, default: defaultTrackLimit),
                "offset": offset,
            ],
            required: ["id"]),
        annotations: readOnly)

    static let trackGet = Tool(
        name: trackGetName,
        title: "Full track record",
        description: """
            Given one id, returns everything Music stores about that track, comment and \
            lyrics included — the lyrics are the one field tracks_list leaves out. A \
            record longer than \(defaultMaxCharacters) characters comes one window at a \
            time: the first line says how long it is and the character_offset that \
            returns the rest, and max_characters (up to \(maxCharactersRange.upperBound)) \
            sizes the window.

            Given several ids (up to \(trackIDsRange.upperBound) in one call), returns \
            each record with its lyrics shortened to \(lyricsClipWidth) characters and its \
            comment to \(commentClipWidth), and the first lines say so when either was \
            shortened. Read one track in full by passing its id alone. More ids than \
            that are refused, not cut: split them across calls.

            Ids come from music_search, tracks_list or playlist_get; they are Music's \
            persistent ids and cannot be typed by hand. An id the library no longer holds \
            is named in the first lines.
            """,
        inputSchema: object(
            properties: [
                "ids": stringArray(
                    "Track ids. One returns the whole record; several return shortened lyrics.",
                    count: trackIDsRange),
                "character_offset": integer(
                    """
                    With one id: number of characters of the record to skip. A result that \
                    does not hold all of it says, in its first line, the value to pass for \
                    the rest.
                    """, range: offsetRange, default: 0),
                "max_characters": integer(
                    "With one id: the most characters of the record to return.",
                    range: maxCharactersRange, default: defaultMaxCharacters),
            ],
            required: ["ids"]),
        annotations: readOnly)

    // MARK: Writes

    static let createPlaylist = Tool(
        name: createPlaylistName,
        title: "Create an empty playlist",
        description: """
            Creates a new, empty playlist in Music and returns its id.

            REFUSES a name that is already in use, and never replaces or empties an \
            existing playlist. Add tracks afterwards with add_to_playlist.
            """,
        inputSchema: object(
            properties: [
                "name": string(
                    "Name for the new playlist, at most \(longestPlaylistName) characters.",
                    longest: longestPlaylistName)
            ],
            required: ["name"]),
        annotations: write)

    static let addToPlaylist = Tool(
        name: addToPlaylistName,
        title: "Add tracks to a playlist",
        description: """
            Appends up to \(addedTracksRange.upperBound) tracks to an existing playlist and \
            reports how many went in, naming every id that did not. It only ever adds: \
            nothing already in the playlist is removed, replaced or reordered, and by \
            default a track already there gains a second entry rather than being \
            deduplicated. More ids than that in one call are refused before anything is \
            added: split them across calls.

            Pass skip_duplicates=true to leave out ids the playlist already holds. Set it \
            when retrying a call that may have already succeeded — a timed-out add often \
            went through, and repeating it is how a playlist ends up with every track \
            twice. Nothing here can undo that afterwards.

            REFUSES every playlist Music maintains itself: smart, Genius, folder, library \
            and purchased ones. Check 'accepts tracks' in playlists_list first. An id the library does \
            not resolve is reported back rather than silently skipped.
            """,
        inputSchema: object(
            properties: [
                "playlist_id": string("Playlist id returned by playlists_list."),
                "track_ids": stringArray(
                    "Track ids to append, in the order they should go in.", count: addedTracksRange),
                "skip_duplicates": boolean(
                    "true to leave out ids the playlist already holds, reporting them "
                        + "instead of appending them again. Also applies within one call, so "
                        + "the same id twice is added once. false appends everything given.",
                    default: false),
            ],
            required: ["playlist_id", "track_ids"]),
        annotations: write)

    static let control = Tool(
        name: controlName,
        title: "Control playback",
        description: """
            CHANGES WHAT IS CURRENTLY PLAYING on this Mac: starts or pauses playback, \
            skips to the next or previous track, or sets the system music volume. The \
            effect is immediate and audible to whoever is at the machine. Returns the \
            player state afterwards.

            It cannot be undone by calling it again — "previous" returns to the previous \
            track in the playlist, it does not restore what was playing before. Nothing \
            here modifies the library, and nothing here deletes anything. Say what you are \
            about to change before calling it.

            A volume outside \(volumeRange.lowerBound)–\(volumeRange.upperBound) is moved \
            to the nearest level, and the first line says which level was set.

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
                    "Volume level. Only read when command is \"volume\".", range: volumeRange),
            ],
            required: ["command"]),
        annotations: write)
}
