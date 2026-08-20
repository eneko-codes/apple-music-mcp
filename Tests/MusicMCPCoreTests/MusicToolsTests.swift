import Foundation
import MCP
import Testing

@testable import MusicMCPCore

/// Drives the tool layer end to end against `FakeMusicStore`. No test in this file sends
/// an Apple event, so the suite runs with Music closed, no Automation consent and the
/// owner's library untouched — which is the point.
@Suite("Tool dispatch")
struct MusicToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeMusicStore = FakeMusicStore(),
        configuration: Configuration = Configuration()
    ) async -> (text: String, isError: Bool) {
        let tools = MusicTools(store: store, configuration: configuration)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    private func stocked() -> FakeMusicStore {
        let store = FakeMusicStore()
        store.tracksValue = [
            .fixture(id: "T1", name: "Marea Baja", artist: "Lagun", playedCount: 12),
            .fixture(id: "T2", name: "Hondartza", artist: "Lagun", playedCount: 0),
            .fixture(
                id: "T3", name: "Gaua", artist: "Beste Bat", genre: "Electronic",
                playedCount: 5, favorited: true),
        ]
        store.playlistsValue = [
            PlaylistInfo(persistentID: "PL1", name: "Driving", trackCount: 2, duration: 400),
            PlaylistInfo(
                persistentID: "PL2", name: "Top Rated", trackCount: 9, duration: 1800,
                isSmart: true),
        ]
        return store
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such as
    /// `["string", "null"]` and hands the model a bare `{}` in its place. An untyped array
    /// is then serialised to a string before it leaves the client and rejected on arrival.
    /// The fault is invisible until a caller happens to use that field, so the whole
    /// catalogue is walked here rather than trusting review.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Annotations match what each tool actually does")
    func annotationsAreHonest() {
        let reads = [
            ToolCatalog.statusName, ToolCatalog.nowPlayingName, ToolCatalog.searchName,
            ToolCatalog.tracksName, ToolCatalog.playlistsName, ToolCatalog.playlistGetName,
            ToolCatalog.trackGetName,
        ]
        for tool in ToolCatalog.all() {
            let expected = reads.contains(tool.name)
            #expect(
                tool.annotations.readOnlyHint == expected,
                "\(tool.name) has the wrong readOnlyHint")
        }
    }

    /// The manifest's `tools` array is what creates the per-tool switches in Claude
    /// Desktop, and it is read before the server has ever run. A tool missing from it has
    /// no switch at all.
    @Test("Catalogue and extension manifest agree")
    func manifestMatchesCatalogue() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MusicMCPCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appending(path: "extension/manifest.json")
        guard let data = try? Data(contentsOf: manifest) else { return }

        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let listed = ((parsed?["tools"] as? [[String: Any]]) ?? []).compactMap {
            $0["name"] as? String
        }
        #expect(Set(listed) == Set(ToolCatalog.all().map(\.name)))
    }

    // MARK: Availability

    @Test("A tool call is refused when Music is not running")
    func refusesWhenNotRunning() async {
        let store = stocked()
        store.availabilityValue = .notRunning
        let (text, isError) = await call(ToolCatalog.tracksName, store: store)
        #expect(isError)
        #expect(text.contains("running"))
    }

    /// macOS only raises the Automation dialog when a real Apple event is sent, so
    /// refusing this state would mean the dialog never appears and consent could never be
    /// granted at all.
    @Test("Ungranted consent does not block the call that would trigger the prompt")
    func consentNotGrantedStillProceeds() async {
        let store = stocked()
        store.availabilityValue = .consentNotGranted
        let (_, isError) = await call(ToolCatalog.tracksName, store: store)
        #expect(!isError)
    }

    @Test("music_status reads nothing and works while unavailable")
    func statusWorksWhenUnavailable() async {
        let store = stocked()
        store.availabilityValue = .automationDenied
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(!text.isEmpty)
    }

    // MARK: Reads

    @Test("music_search passes the query through to the store")
    func searchFiltersByText() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.searchName, ["query": .string("Marea")], store: store)
        #expect(!isError)
        #expect(text.contains("Marea Baja"))
        #expect(!text.contains("Gaua"))
    }

    @Test("tracks_list returns raw rows including the play counts")
    func tracksListReturnsRawRows() async {
        let (text, isError) = await call(ToolCatalog.tracksName, store: stocked())
        #expect(!isError)
        #expect(text.contains("Marea Baja"))
        #expect(text.contains("Hondartza"))
        #expect(text.contains("Gaua"))
    }

    @Test("A search is bounded by the fixed scan ceiling")
    func searchRespectsScanCeiling() async {
        let store = stocked()
        _ = await call(ToolCatalog.tracksName, store: store)
        #expect(store.lastScanCeiling == Configuration.scanCeiling)
    }

    @Test("playlists_list reports every playlist")
    func playlistsAreListed() async {
        let (text, isError) = await call(ToolCatalog.playlistsName, store: stocked())
        #expect(!isError)
        #expect(text.contains("Driving"))
        #expect(text.contains("Top Rated"))
    }

    @Test("track_get returns a full record for a known id")
    func trackGetReturnsDetail() async {
        let store = stocked()
        store.lyricsValue = "invented lyrics for a fixture track"
        let (text, isError) = await call(
            ToolCatalog.trackGetName, ["ids": .array([.string("T1")])], store: store)
        #expect(!isError)
        #expect(text.contains("Marea Baja"))
    }

    /// A track can be removed from the library between two calls, so an unresolved id is
    /// an ordinary outcome and has to read as one rather than as a failure.
    @Test("track_get names an id the library no longer holds")
    func trackGetHandlesMissingID() async {
        let (text, _) = await call(
            ToolCatalog.trackGetName, ["ids": .array([.string("NOPE")])], store: stocked())
        #expect(text.contains("NOPE"))
    }

    @Test("track_get accepts several ids in one call")
    func trackGetAcceptsBulkIDs() async {
        let (text, isError) = await call(
            ToolCatalog.trackGetName,
            ["ids": .array([.string("T1"), .string("T3")])], store: stocked())
        #expect(!isError)
        #expect(text.contains("Marea Baja"))
        #expect(text.contains("Gaua"))
    }

    @Test("A missing required argument is named in the error")
    func missingArgumentIsNamed() async {
        let (text, isError) = await call(ToolCatalog.trackGetName, store: stocked())
        #expect(isError)
        #expect(text.contains("id"))
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let (_, isError) = await call("music_delete_everything", store: stocked())
        #expect(isError)
    }

    // MARK: Writes

    @Test("create_playlist makes exactly one playlist")
    func createPlaylistCreatesOne() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.createPlaylistName, ["name": .string("ZZTest Fixture")], store: store)
        #expect(!isError)
        #expect(store.createdPlaylists == ["ZZTest Fixture"])
    }

    /// A smart playlist's contents are the output of its rules. A track appended by hand
    /// either vanishes on the next evaluation or corrupts what the rules meant to express.
    @Test("add_to_playlist refuses a smart playlist")
    func addToPlaylistRefusesSmartPlaylist() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.addToPlaylistName,
            ["playlist_id": .string("PL2"), "track_ids": .array([.string("T1")])],
            store: store)
        #expect(isError)
        #expect(store.appended.isEmpty)
    }

    @Test("add_to_playlist appends and never removes")
    func addToPlaylistAppends() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.addToPlaylistName,
            ["playlist_id": .string("PL1"), "track_ids": .array([.string("T1"), .string("T2")])],
            store: store)
        #expect(!isError)
        #expect(store.appended.count == 1)
        #expect(store.appended.first?.ids == ["T1", "T2"])
        // The guard is opt-in, so an unadorned call must not quietly acquire it.
        #expect(store.appended.first?.skipDuplicates == false)
    }

    @Test("add_to_playlist appends a second copy when skip_duplicates is not asked for")
    func addToPlaylistDuplicatesByDefault() async {
        let store = stocked()
        store.playlistTracks["PL1"] = ["T1"]
        let (text, isError) = await call(
            ToolCatalog.addToPlaylistName,
            ["playlist_id": .string("PL1"), "track_ids": .array([.string("T1")])],
            store: store)
        #expect(!isError)
        #expect(store.playlistTracks["PL1"] == ["T1", "T1"])
        // Silence about duplicates, because none was ever checked for.
        #expect(!text.contains("already in the playlist"))
    }

    @Test("skip_duplicates leaves out what the playlist already holds")
    func skipDuplicatesLeavesOutWhatIsThere() async {
        let store = stocked()
        store.playlistTracks["PL1"] = ["T1"]
        let (text, isError) = await call(
            ToolCatalog.addToPlaylistName,
            [
                "playlist_id": .string("PL1"),
                "track_ids": .array([.string("T1"), .string("T2")]),
                "skip_duplicates": .bool(true),
            ],
            store: store)
        #expect(!isError)
        #expect(store.appended.first?.skipDuplicates == true)
        #expect(store.playlistTracks["PL1"] == ["T1", "T2"])
        #expect(text.contains("Added 1 track"))
        #expect(text.contains("already in the playlist"))
        #expect(text.contains("T1"))
    }

    /// The failure that prompted the flag: a client timeout on a call the server had
    /// already completed, retried as one batch.
    @Test("skip_duplicates guards a call against its own repeated ids")
    func skipDuplicatesGuardsWithinOneCall() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.addToPlaylistName,
            [
                "playlist_id": .string("PL1"),
                "track_ids": .array([.string("T1"), .string("T1"), .string("T1")]),
                "skip_duplicates": .bool(true),
            ],
            store: store)
        #expect(!isError)
        #expect(store.playlistTracks["PL1"] == ["T1"])
    }

    @Test("skip_duplicates says so when nothing was already there")
    func skipDuplicatesReportsACleanRun() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.addToPlaylistName,
            [
                "playlist_id": .string("PL1"),
                "track_ids": .array([.string("T1")]),
                "skip_duplicates": .bool(true),
            ],
            store: store)
        #expect(!isError)
        // Distinguishes "checked, found none" from "never looked", which an empty
        // duplicates list on its own cannot.
        #expect(text.contains("None of the ids given were already in the playlist"))
    }

    @Test("music_control reaches the store with the command it was given")
    func controlPassesTheCommand() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.controlName, ["command": .string("pause")], store: store)
        #expect(!isError)
        #expect(store.commands.first?.command == .pause)
    }

    @Test("A store failure is reported rather than swallowed")
    func storeFailureIsReported() async {
        let store = stocked()
        store.failure = ToolError.storeFailure("Music stopped responding")
        let (text, isError) = await call(ToolCatalog.tracksName, store: store)
        #expect(isError)
        #expect(text.contains("Music"))
    }
}
