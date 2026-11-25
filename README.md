<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-music-mcp icon">
</p>

# apple-music-mcp

A local MCP server, written in Swift, exposing the macOS **Music** app to Claude through
Apple events (`ScriptingBridge`). It ships as a Claude extension.

Music has no framework a separate process can use for the local library, so this server
drives Music.app itself through Apple events. Music must already be
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
| `music_status` | read | Reports whether Music is running and automation is permitted, and the bounds in force: how far a search scans, how many rows a page holds, how long a call may take. Reads no tracks and never launches Music. |
| `now_playing` | read | The current track's library row, playback position, player state, volume and source playlist. |
| `music_search` | read | Finds tracks, albums, artists or playlists by text, a page at a time. It scans at most 2,000 tracks and says so when it stopped there; `genre`, `year_from`, `year_to` and `playlist_id` narrow the scan. Albums and artists are a group-by over matching tracks, not objects in Music's own dictionary. |
| `tracks_list` | read | Raw library rows, a page at a time: play count, last played, skip count, last skipped, rating, favourite/disliked flags, date added, and more. `limit` and `offset` reach every row. No aggregation — the reading is yours to do. |
| `playlists_list` | read | The playlists, a page at a time, with id, track count, total time, and whether `add_to_playlist` can append to it. |
| `playlist_get` | read | One playlist's details and a page of its tracks, as the same raw rows `tracks_list` returns. |
| `track_get` | read | Everything Music stores about one track, lyrics included, a window at a time when it is long; or up to 20 tracks at once with their lyrics shortened. |
| `create_playlist` | write | Creates a new, empty playlist. Refuses a name already in use. |
| `add_to_playlist` | write | Appends up to 100 tracks to an existing playlist, optionally skipping ids it already holds. Refuses smart, Genius, folder and library playlists. |
| `music_control` | write | Starts, pauses, skips or sets the volume — **audible immediately**, on this Mac. Annotated as a write although it destroys nothing, because of that. |

There is no destructive tool in this list, and there cannot be one by design: nothing
here removes a track or a playlist, from the library or from disk, and no delete tool
may be added — see below.

## Frameworks and APIs

Music exposes no framework an external process can use for the local library, so everything
here is an Apple event.

| Used | For | Reference |
|---|---|---|
| ScriptingBridge — `SBApplication`, `SBElementArray` | Every read and write | [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) |
| `AEDeterminePermissionToAutomateTarget` | Checking Automation consent without sending an event | [Apple Events](https://developer.apple.com/documentation/coreservices/apple_events) |
| AppKit — `NSWorkspace`, `NSRunningApplication` | Whether the app is installed, and whether it is running | [AppKit](https://developer.apple.com/documentation/appkit) |
| `NSAppleEventsUsageDescription` | The consent string macOS shows | [Information Property List](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription) |

Music's dictionary (`sdef /System/Applications/Music.app`) is large. Unused commands include
`convert`, `export`, `download`, `refresh`, `subscribe`, `print`, `quit`, `open location`,
and the `EQ preset`, `AirPlay device`, `visual` and window classes — this server reads the
library, creates a playlist, adds to one, and drives transport, and nothing else. MusicKit
and `NSAppleMusicUsageDescription` are a different route to a different store, and are not
used at all.

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
with, not baked into a compiled heuristic.

**Every result is bounded, and says what it left out.** Tracks, playlists and search
results come one page at a time, in an order the result states. When a result does not
hold everything, its first lines say so and give the exact arguments that return the
rest: `limit` and `offset` for rows, `character_offset` and `max_characters` for one
track's record. `tracks_list` and `playlist_get` page at the source: `offset` tracks are
passed over without being read and only the rows of the page are, so every track can be
reached however large the library. A number outside its range (`limit`, `offset`, a year, a play
count, a rating, a window) is moved to the nearest allowed value and the first lines say
which one was used; a volume too is moved and reported. A wrong type, a date that does not exist, a range that ends before it
starts and an argument the tool does not take are refused too, with the form expected:
nothing is dropped silently. `from_date` and `to_date` bound the date a track was added,
both inclusive. The sizes are constants
in `ToolCatalog.swift`, which the schemas, descriptions and instructions quote. No result
is longer than `ToolStandard.longestResult`: each tool keeps to that itself, and the
protocol layer cuts, with a notice, any result that did not.

**`music_search` can only find what it scanned.** The text of a query is matched in this
server, not by Music, so a search reads tracks to match them and stops after
`ToolCatalog.scanCeiling` (2,000). When it stopped there its first lines say so, and
`genre`, `year_from`, `year_to` and `playlist_id` narrow what Music hands over before the
scan. It never presents a partial scan as a complete one.

**Every call is bounded in time.** Reading tracks stops after 40 seconds and the result
holds what was read, saying that it is partial. A call that has not answered after 55
seconds is abandoned with an error. Abandoning a call does not stop Music: a write may
still have gone through, and the error says how to check.

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

**`skip_duplicates` is the one guard against that append being permanent.** Off by
default, because Music itself allows the same track twice and a caller may mean it. Pass
`skip_duplicates=true` and ids the playlist already holds are reported back instead of
appended, within the call as well as against what is already there. It exists for the
case that actually happens: a client times out on an add the server had already
completed, the call is retried, and the playlist quietly doubles. Since nothing here
removes a track, undoing that means doing it by hand in Music.

**There is no delete tool, for a track or for a playlist, and none is planned.** A track
removed from the library can take the underlying file with it — that is not a risk this
server takes on your behalf.

**Lyrics and comments are never cut silently.** `track_get` with one id returns the whole
record, comment and lyrics included, 10,000 characters to a window; a longer one says how
long it is and the `character_offset` of the rest. With several ids (20 at most) each
record's lyrics are shortened to 500 characters and the first lines say so. A row shows
the first 80 characters of a comment and names `track_get` when it cut one. Only
`track_get` pays the cost of fetching lyrics; every other read leaves them out entirely,
because reading them costs a round trip per track. The server takes no settings.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours.

That builds an arm64 (Apple silicon only) release binary, re-signs it, checks the
embedded `Info.plist` survived both linking and signing, prints the designated
requirement, and writes `dist/apple-music-mcp.mcpb`. It fails loudly rather than
shipping a bundle that would silently refuse to work.

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
that this is `Automation` permission — not the
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
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="<Developer ID Application hash>" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires. Note
that this repository has no `Resources/entitlements.plist` yet — `pack.sh` only applies one
if the file exists. The hardened runtime blocks Apple
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
  `add_to_playlist` entry, has to be cleaned up in Music itself. `skip_duplicates`
  prevents the common case; it cannot repair one that already happened.
- **Smart, Genius, folder and library playlists refuse writes.** Their contents are the
  output of Music's own rules or Music's own aggregation; `add_to_playlist` and
  `create_playlist` cannot touch them, and neither can any workaround built on top of
  these tools.
- **A search scans at most 2,000 tracks.** Music does the reading, one round trip per
  property per track across the Apple event boundary, and a query is matched here, so
  `music_search` has to read tracks to search them. The ceiling is fixed, a search that
  stopped at it says so, and its narrowing arguments are the way past it. A track's name
  cannot be searched for in a part of the library no narrowing reaches.
- **A total short of the last page is Music's own count.** `tracks_list` reads just the
  page and asks Music how many tracks the filters leave. If Music gives no count, or one
  that contradicts the rows read, the result says that more exist, not how many.
- **Each page is a new reading.** A track added or removed between two calls shifts the
  pages that follow.
- **One call takes at most 20 ids in `track_get` and 100 in `add_to_playlist`.** More are
  refused whole, before anything is read or added: split them across calls.
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

The tests run entirely against an in-memory fake (`FakeMusicStore`) with Music closed. They need
no permissions and never touch the real library, playlists or playback — see
`CLAUDE.md`, whose first section is the rule that makes that non-negotiable: this
server's tests may never call `music_control`, launch Music, or read the library store
directly.

Manual verification against a real library, including the checks that make audible
noise, is the owner's job by hand.

## Licence

MIT.
