<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-music-mcp icon">
</p>

# apple-music-mcp

A local MCP server, written in Swift, exposing the macOS **Music** app to Claude through
Apple events (`ScriptingBridge`). It ships as a Claude extension.

Music has no framework a separate process can use for the local library, so this server
drives Music.app itself, the same way `apple-mail-mcp` drives Mail. Music must already be
running — this server never launches it, because Music can start playing audio out loud
the moment it opens.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `music_status` | read | Reports whether Music is running and automation is permitted, and the scan ceiling, default row count and lyrics limit in force. Reads no tracks and never launches Music. |
| `now_playing` | read | The current track's full library row, playback position, player state, volume and source playlist. |
| `music_search` | read | Finds tracks, albums, artists or playlists by text. Albums and artists are a group-by over matching tracks, not objects in Music's own dictionary. |
| `tracks_list` | read | Raw library rows: play count, last played, skip count, last skipped, rating, favourite/disliked flags, date added, and more. No aggregation — the reading is yours to do. |
| `playlists_list` | read | Every playlist, with id, track count, total time, and whether `add_to_playlist` can append to it. |
| `playlist_get` | read | One playlist's details and its tracks, as the same raw rows `tracks_list` returns. |
| `track_get` | read | Everything Music stores about one or more tracks, including lyrics — the one field `tracks_list` omits. |
| `create_playlist` | write | Creates a new, empty playlist. Refuses a name already in use. |
| `add_to_playlist` | write | Appends tracks to an existing playlist. Refuses smart, Genius, folder and library playlists. |
| `music_control` | write | Starts, pauses, skips or sets the volume — **audible immediately**, on this Mac. Annotated as a write although it destroys nothing, because of that. |

There is no destructive tool in this list, and there cannot be one by design: nothing
here removes a track or a playlist, from the library or from disk, and no delete tool
may be added — see below.

## The rules worth knowing before you use it

**Music must already be running.** The server checks and refuses rather than launching
it; starting an app on your behalf is a side effect you did not ask for, and Music
opening can begin playing audio out loud.

**Play counts are Music's own, and they count every synced device.** A track played on
an iPhone increments the same counter Music reports here — say so rather than letting a
number read as "played on this Mac".

**`tracks_list` and `playlist_get` return raw rows and nothing else.** Play count, last
played, skip count, rating, favourite flag, date added — Music's own fields, unfiltered.
There is deliberately no statistics tool: ranking a library, finding what is most
played, computing a skip rate — that reasoning belongs where it can be seen and argued
with, not baked into a compiled heuristic. A query that hits the scan ceiling
(`Configuration.scanCeiling`, fixed at 2,000 tracks per call) says so rather than
presenting a partial answer as a complete one.

**`music_control` is audible and live, not undoable.** Calling it again does not restore
the previous state — `previous` moves to the previous track in the playlist, it does not
"undo" a `next`. It changes nothing in the library, but the effect happens in the room,
possibly through a speaker somewhere else in the house.

**`create_playlist` never overwrites.** A name already in use is refused outright.

**`add_to_playlist` only ever appends.** Nothing already in a playlist is removed,
reordered or replaced, and a track already present gains a second entry rather than
being deduplicated. It also refuses smart, Genius, folder and library playlists — their
contents are Music's own rules or Music's own aggregate, and a track appended by hand
would either vanish on the next evaluation or corrupt what the rules were meant to
express.

**There is no delete tool, for a track or for a playlist, and none is planned.** A track
removed from the library can take the underlying file with it — that is not a risk this
server takes on your behalf.

**Lyrics are truncated at a configurable limit** (8,000 characters by default) and only
`track_get` pays the cost of fetching them; every other read leaves lyrics out entirely,
because reading them costs a round trip per track.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, re-signs it, checks the
embedded `Info.plist` survived both linking and signing, prints the designated
requirement, and writes `dist/apple-music-mcp.mcpb`. It fails loudly rather than
shipping a bundle that would silently refuse to work.

```bash
security find-identity -v -p codesigning
```

### 2. Install it

Open `dist/apple-music-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — reinstalling does not replace a server process that is already running,
and the old one keeps answering.

### 3. Grant the permission

Open Music first; the server will not launch it for you.

Call `music_status`. It reports the permission state **without sending an Apple event**
— it asks the system directly via `AEDeterminePermissionToAutomateTarget` with
`askUserIfNeeded: false`, so it is always safe to call first when something is failing.

Then call a tool that actually reads the library, such as `music_search`. macOS raises
*"apple-music-mcp wants to control Music"*. Approve it, and the grant appears under:

```
System Settings → Privacy & Security → Automation → apple-music-mcp → Music
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)
```

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`.
Sending Apple events needs `NSAppleEventsUsageDescription`, embedded at link time. Note
that this is `Automation` permission, the same gate `apple-mail-mcp` uses — not the
separate `NSAppleMusicUsageDescription`/MusicKit grant, which this server never asks
for, because it never touches the media library through that framework.

If no dialog ever appears:

```bash
otool -P extension/server/apple-music-mcp | grep NSAppleEventsUsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild
changes that. Worse, a linker-signed binary never gets a consent dialog at all; the
request returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle
identifier and the certificate instead:

```
designated => identifier "codes.eneko.apple-music-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds. `pack.sh` prints the requirement on every build, so a silent
regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires. Note
that, unlike `apple-mail-mcp`, this repository has no `Resources/entitlements.plist` yet
— `pack.sh` only applies one if the file exists. The hardened runtime blocks Apple
events outright without the `com.apple.security.automation.apple-events` entitlement, so
add that file before distributing a hardened build.

## Tool switches

Every tool can be turned on and off individually, because the bundle declares all ten in
its manifest. That is where policy lives — not in this code. Turning off
`create_playlist`, `add_to_playlist` and `music_control` leaves a strictly read-only
server.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Apple Music": {
      "command": "/absolute/path/to/apple-music-mcp/.build/release/apple-music-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the
same display name collide, and `music_status` prints the binary path precisely so you
can tell which one answered.

## Known limits

- **No delete tool, deliberately.** A playlist created by mistake, or a duplicate
  `add_to_playlist` entry, has to be cleaned up in Music itself.
- **Smart, Genius, folder and library playlists refuse writes.** Their contents are the
  output of Music's own rules or Music's own aggregation; `add_to_playlist` and
  `create_playlist` cannot touch them, and neither can any workaround built on top of
  these tools.
- **One query walks at most 2,000 tracks.** Music does the reading, one round trip per
  property per track across the Apple event boundary, so an unbounded pass over a large
  library is slow. The ceiling is fixed, not user-configurable, and a truncated result
  says so.
- **No aggregation or ranking.** `tracks_list` and `playlist_get` return raw rows; there
  is no "most played" or "never played" tool, and there will not be one.
- **Play counts are shared across every device synced to the library**, not scoped to
  this Mac.
- **`music_search`'s album and artist modes are a group-by, not a lookup of real Music
  objects.** The count beside each result is how many matching track rows were scanned,
  not a total for the whole library.

## Development

```bash
swift build
swift test
```

21 tests, all against an in-memory fake (`FakeMusicStore`) with Music closed. They need
no permissions and never touch the real library, playlists or playback — see
`CLAUDE.md`, whose first section is the rule that makes that non-negotiable: this
server's tests may never call `music_control`, launch Music, or read the library store
directly.

Manual verification against a real library, including the checks that make audible
noise, is the owner's job by hand.

## Licence

MIT.
