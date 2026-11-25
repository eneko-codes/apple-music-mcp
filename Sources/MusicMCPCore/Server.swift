import Foundation

public enum MusicMCPServer {

    public static let name = "apple-music-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that Music itself does the work, that every result is bounded and says what
    /// it left out, what the play counts actually mean, and where the line between reading
    /// and controlling falls.
    public static let instructions = """
        Access to the macOS Music app through Apple events.

        Music has no framework a separate process can use, so this server drives Music.app \
        itself. Music must be running — this server never launches it — and Music, not this \
        code, is what reads the library, one Apple event per field of each track.

        Workflow: music_search or tracks_list to find things, then track_get with the id a \
        search returned. playlists_list and playlist_get do the same for playlists, \
        now_playing says what is playing, and music_status says why a call fails. Ids are \
        Music's own persistent ids and cannot be typed by hand.

        EVERY RESULT IS BOUNDED AND SAYS WHAT IT LEFT OUT. tracks_list, playlists_list, \
        playlist_get and music_search return one page of rows. When rows exist that a \
        result does not hold, its first lines say so and give the offset of the next page: \
        pass limit and offset. tracks_list and playlist_get read only the rows of the page, \
        so every track can be reached, however large the library. music_search matches its \
        query here, so it has to read tracks to search them: it stops after \
        \(ToolCatalog.scanCeiling) tracks and says so, and genre, year_from, year_to and \
        playlist_id narrow what it scans. track_get with one id returns the whole record, \
        lyrics included, one window at a time with character_offset and max_characters \
        when it is long; with several ids it shortens the lyrics. A comment is shortened \
        in rows. A number outside its range (limit, offset, a year, a count, a rating, a \
        window) is moved to the nearest allowed value, and the first lines say which one \
        was used; a volume too is moved and reported, and an argument a tool does not take \
        is refused.

        EVERY CALL IS BOUNDED IN TIME. Reading stops after \
        \(MusicTools.defaultReadBudget.components.seconds) seconds and the result holds \
        what was read, saying that it is partial. A call that has not answered after \
        \(MusicTools.defaultTimeout.components.seconds) seconds is abandoned with an error \
        that says so. Abandoning a call does not stop Music, so a write may still have \
        gone through: check before repeating it.

        tracks_list returns raw rows, including played count, played date, skipped count, \
        skipped date, rating, favorited and date added; from_date and to_date bound the \
        date added. Any analysis of listening habits is yours to do from those rows; this \
        server computes nothing and ranks nothing.

        Play counts are Music's own and reflect plays on every synced device, not just this \
        Mac. A track played on an iPhone increments the same counter.

        music_control changes what is currently playing. It is not data loss, but it is \
        immediately audible to whoever is at the machine, so it says so in its description.

        create_playlist and add_to_playlist are the only tools that modify the library. \
        Neither will delete or overwrite an existing playlist, and no tool here removes a \
        track from the library or from disk.

        add_to_playlist appends whatever it is given, duplicates included, unless \
        skip_duplicates=true is passed. Pass it when retrying an add that may already have \
        gone through: a call that timed out often succeeded all the same, and nothing here \
        can take the extra entries out again.

        This server exposes the library's read surface in full. What may be used at any \
        moment is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function sends an Apple event by itself.
    public static func run(store: any MusicStore = ScriptingBridgeMusicStore()) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: MusicTools(store: store)))
    }

    public static func handler(tools: MusicTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
