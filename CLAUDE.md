# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify the library, and do not call `music_control` (play/pause/skip/volume — audible immediately in the room) unless asked.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real library, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own playlist and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` — and note this server has no delete tool, so removing it means doing so by hand in Music, in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Music app through Apple events. No network, no credential, no cloud API, gated by TCC consent for Automation. Music must already be running; this server never launches it. There is **no third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## Apple technology

Music ships no framework an external process can use for the local library, so everything is an Apple event. [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) — `SBApplication`, `SBElementArray` — for every read and write; `AEDeterminePermissionToAutomateTarget` ([Apple Events](https://developer.apple.com/documentation/coreservices/apple_events)) to check consent without sending an event; [AppKit](https://developer.apple.com/documentation/appkit) `NSWorkspace`/`NSRunningApplication` to see whether the app is there and running. Consent key: [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription). MusicKit and `NSAppleMusicUsageDescription` are a different route to a different store and are not used.

## Native surface not used

`sdef /System/Applications/Music.app` is the authority on what is possible here. Check it before proposing a tool.

- `convert`, `export`, `download`, `refresh`, `print`, `quit`, `open location`, `reveal`.
- `delete` — the dictionary has it; this server has no delete tool, which is why a test playlist has to be removed by hand.
- `EQ preset`, `AirPlay device`, `radio tuner playlist`, `subscription playlist`, `shared track`, and every window class.
- `search` — matching is done here in Swift over the rows Music returns, not by Music.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-music-mcp | grep NSAppleEventsUsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

**How a tool keeps to the tool standard here.** Sizes are constants in `ToolCatalog`, and the schemas, the descriptions, the instructions and `music_status` quote them by interpolation, never as literals. `Arguments.int` and `Arguments.optionalInt` move a quantity (`limit`, `offset`, a window, a year, a count, a rating) into its range and collect the sentence that says so in `notices`; a volume outside its range is moved and reported like any other quantity; a wrong type is refused, never read as not given, and `Arguments.check` refuses an argument the tool's schema does not list.

- **Listings that Music can filter page at the source.** `tracks_list` and `playlist_get` hand `offset` and `limit` to the store as a `TrackWalk`: the bridge passes over `skip` candidates without reading a property and reads at most `read`, so only the page crosses the Apple event boundary. `TrackPage.stop` says why the walk ended, and `Format.position` words it with `Notice.page`. Whether more rows exist is decided by `stop` alone; the total is the walk's own count at the end and Music's count before it, used only when it agrees that rows remain, and otherwise `total: nil` ("more exist").
- **A search reads before it pages.** The text of a query is matched in Swift, so `music_search` reads up to `ToolCatalog.scanCeiling` candidates, then pages the matches in memory with `ToolStandard.page`. A scan that stopped early is announced with `Notice.scanStopped`, naming the arguments that narrow it.
- **Playlists are loaded whole and paged in memory**, in the order Music hands them over.
- **One track is one long text.** `track_get` with one id renders the whole record and cuts it with `ToolStandard.window`; with several ids it clips lyrics and comment and says so with `Notice.clipped`, and holds back the records that still do not fit (`Notice.notShown`). A row clips its comment the same way.
- **Time.** `MusicTools.handle` abandons a call at `defaultTimeout` with `ToolError.timedOut`, whose text depends on whether the tool writes. A walk carries a deadline (`defaultReadBudget`) that the bridge checks between tracks, and a walk cut short returns what it read under `Notice.partial`.
- **Lists of ids are bounded on the way in** (`trackIDsRange`, `addedTracksRange`) and refused whole when longer, so the lists a result repeats are bounded too.

Every result that grows with the data is rendered through `ToolStandard.fitting` or `ToolStandard.page`, which halve a page or a window whose text would still be longer than a result may be, so a tool never leans on the guard. `BoundsTests` holds every bound, notice and length to this: a new listing takes `limit` and `offset` through `Arguments.page` and gets an entry in its `listings`.

**The bridge cannot be tested here.** `MusicBridge.m` is the one file no test reaches, because it only runs against Music. A change to it is read line by line and then verified by the owner against a real library, asked for as the data rule says.

## Release checklist

- **Bump the version before packing.** The installer keys on the manifest `version` alone.
- **Three files carry the version and must agree**: `extension/manifest.json`, `MusicMCPServer.version` in `Server.swift`, and `CFBundleShortVersionString` in `Resources/Info.plist`.
- **The text the model reads is code.** Update the server `instructions`, tool and argument descriptions and the manifest `tools` and `long_description` in the same commit as the behaviour. The manifest is plain JSON and cannot quote a constant, so a bound it states is checked by `BoundsTests`.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
