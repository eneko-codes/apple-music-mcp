# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S LIBRARY AND SPEAKERS ARE NOT YOURS

**It is FORBIDDEN to change the owner's music library or what is playing.** This rule
outranks every other instruction in this file. It applies to every agent and every session.

Two different harms here, and both count. Changing the library is the ordinary kind. Calling
`music_control` is the surprising kind: it is **immediately audible in the room**, possibly
at three in the morning, possibly through a speaker in another part of the house.

Never:

- create, rename or add to a playlist the owner made;
- call `music_control` at all — no play, no pause, no skip, no volume;
- launch Music. It can begin playing out loud the moment it opens;
- read the library store directly from disk;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A temporary playlist may be created and used
for a test, provided that:

- it is named so it is disposable at a glance (`ZZTest …`);
- it is deleted in the same session that made it — **by hand, in Music**, because this
  server has no delete tool and must not gain one;
- the owner is told it existed and that it is gone.

Note the trap: a playlist an agent creates cannot be removed through these tools at all.
Prefer the fake.

**Fixtures first, always.** `FakeMusicStore` drives the whole tool layer with invented
tracks and play counts. Reach for a live test only for code the fake cannot reach —
everything below the `MusicStore` seam.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; no Apple event is sent |
| `sdef /System/Applications/Music.app` | Prints the dictionary |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against the real library remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Music app through Apple
events. There is no network, no credential and no cloud API, and the gate is TCC consent for
Automation.

Music has no framework a separate process can use for the local library, so this server
drives Music.app itself. **Music must be running, and this server never launches it.**

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

`Sources/MusicMCPCore` holds everything; `Sources/apple-music-mcp/main.swift` is a launcher
that exists only because a Swift executable target cannot be imported by a test target.

**`Sources/MusicBridge` is Objective-C, and not by preference** — the documented Scripting
Bridge creation pattern cannot be expressed in Swift, because the class returned is an
`SBPseudoClass` and a metatype cast against it aborts the process
(swiftlang/swift#43407). Only Foundation types cross back.

Watch the argument labels when calling into the bridge. The Objective-C importer keeps the
whole base name up to the first colon unless a preposition splits it: `runCommand:volume:`
imports as `runCommand(_:volume:)`, **not** `run(command:volume:)`, while
`trackWithPersistentID:` does split into `track(withPersistentID:)`.

**`MusicStore` is the seam.** Nothing above it sends an Apple event.

## Invariants worth protecting

- **No aggregation, ever.** `tracks_list` returns raw rows carrying `playedCount`,
  `playedDate`, `skippedCount`, `skippedDate`, `rating`, `favorited` and `dateAdded`. Any
  reading of those — most played, never played, skip rate by genre — belongs to the model,
  where it can be seen and argued with, not to a compiled heuristic nobody can inspect.
  There must be no `listening_stats` tool.
- **Play counts are Music's own and count every device.** A track played on an iPhone
  increments the same counter. Say so rather than letting it read as "played on this Mac".
- **`Configuration.scanCeiling` bounds every walk.** Music is traversed one track at a time
  across the Apple event boundary, so an unbounded query on a large library is very slow.
  Fixed rather than user-configurable, and passed per call rather than held by the store,
  so the value the tools enforce and the value `music_status` reports are the same
  constant, never two numbers.
- **A result that hit the ceiling says so.** Otherwise "the newest N matches" reads as "the
  matches".
- **`add_to_playlist` appends and only appends.** Nothing already in a playlist is removed,
  reordered or replaced.
- **Smart and Genius playlists are refused.** Their contents are the output of their rules;
  a track appended by hand either vanishes on the next evaluation or corrupts what the rules
  were meant to express. So is the library playlist itself, and so are folders.
- **`create_playlist` never overwrites.** A name already in use is refused.
- **Nothing here removes a track or a playlist**, and no such tool may be added. A track
  deleted from Music can take the file with it.
- **`music_control` is annotated as a write** even though it destroys nothing, because it is
  immediately audible to whoever is in the room.
- **Lyrics are truncated at `lyricsLimit`** and only `track_get` pays for them.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-music-mcp.mcpb`. The
manifest's `tools` array creates the per-tool switches in Claude Desktop and is read before
the server has ever run. Every flag in `mcp_config.args` must exist in
`Configuration.parse`; one that does not fails silently, leaving the setting on its default.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject**. The embedded `Resources/Info.plist` carries
`NSAppleEventsUsageDescription`; without it macOS denies Apple events **without ever
prompting**.

macOS only raises the Automation dialog when a real Apple event is sent, which is why
`consentNotGranted` does not block a call.

**A linker-signed binary gets no TCC prompt.** `pack.sh` re-signs and prints the designated
requirement; an empty line there means the build is broken in a way nothing else will show.
