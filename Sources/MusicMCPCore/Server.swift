import Foundation
import MCP

public enum MusicMCPServer {

    public static let name = "apple-music-mcp"
    public static let version = "1.1.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that Music itself does the work, what the play counts actually mean, and
    /// where the line between reading and controlling falls.
    public static let instructions = """
        Access to the macOS Music app through Apple events.

        Music has no framework a separate process can use, so this server drives Music.app \
        itself. Music must be running — this server never launches it — and Music, not this \
        code, is what walks the library. Bound every search: an unfiltered walk of a large \
        library crosses the Apple event boundary one track at a time and is slow.

        Workflow: music_search or tracks_list to find things, then track_get with the id a \
        search returned. Ids are Music's own persistent ids and cannot be typed by hand.

        tracks_list returns raw rows, including played count, played date, skipped count, \
        skipped date, rating, favorited and date added. Any analysis of listening habits is \
        yours to do from those rows; this server computes nothing and ranks nothing.

        Play counts are Music's own and reflect plays on every synced device, not just this \
        Mac. A track played on an iPhone increments the same counter.

        music_control changes what is currently playing. It is not data loss, but it is \
        immediately audible to whoever is at the machine, so it carries a verb prefix and \
        says so in its description.

        create_playlist and add_to_playlist are the only tools that modify the library. \
        Neither will delete or overwrite an existing playlist, and no tool here removes a \
        track from the library or from disk.

        add_to_playlist appends whatever it is given, duplicates included, unless \
        skip_duplicates=true is passed. Pass it when retrying an add that may already have \
        gone through: a call that timed out on the client often succeeded on the server, \
        and nothing here can take the extra entries out again.

        This server exposes the library's read surface in full. What may be used at any \
        moment is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function sends an Apple event by itself.
    public static func run(
        store: any MusicStore = ScriptingBridgeMusicStore(),
        configuration: Configuration = Configuration()
    ) async throws {
        let tools = MusicTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.all())
        }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
