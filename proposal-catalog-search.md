# Proposal — Apple Music catalog search and add

Status: **research, not agreed**. Nothing in this document has been built, and one
load-bearing claim in it has not been verified on this machine. See
[What is still unverified](#what-is-still-unverified).

The question this answers: can this server search the Apple Music catalog and add from
it, **without becoming a second server** and **without any private data entering a public
repository**?

Short answer: yes to both, and the second one costs nothing — the supported route needs
no secret in the repo at all. The price is elsewhere: the shipped binary has to become an
app bundle, and it needs a paid Apple Developer Program membership.

## 1. Why the current server cannot do it

`music_search` reaches the local library only. That is not a limitation of the query — it
is what ScriptingBridge can see. Music's own `search` command is scoped to a playlist:

```
<command name="search" description="search a playlist for tracks matching the search
string. Identical to entering search text in the Search field.">
  <direct-parameter type="playlist" description="the playlist to search"/>
```

There is no command in Music's dictionary that reaches the catalog. `subscription
playlist` and `cloud status` describe Apple Music content **already in the library**.
`open location` opens a Store URL in the Music UI, which this server must not do — it is
a visible side effect and can start playback.

So the catalog needs MusicKit. MusicKit is a different framework with a different
authorisation model, and it is gated in a way that matters here.

## 2. The blocker, and Apple's own answer to it

MusicKit requires the `com.apple.application-identifier` entitlement. That is a
**restricted** entitlement: it is only valid when authorised by a provisioning profile. A
bare Mach-O executable has nowhere to carry one — provisioning profiles live inside app
bundles.

The symptom, from a developer hitting exactly this with a macOS command-line tool:

```
Error Domain=ICErrorDomain Code=-7009 "Failed to retrieve bundle identifier of the
requesting application. The requesting application is likely missing the
"com.apple.application-identifier" entitlement."
```

Apple DTS's answer on that thread is not "you cannot", it is "wrap it": build the tool as
an app target and strip the app out of it, so the product is an app-shaped directory with
a provisioning profile inside. Apple documents the pattern as
[Signing a Daemon with a Restricted Entitlement][daemon].

The resulting shape:

```
apple-music-mcp.app/
  Contents/
    Info.plist
    MacOS/
      apple-music-mcp
    PkgInfo
    _CodeSignature/
      CodeResources
    embedded.provisionprofile
```

It is still run as a plain executable — `apple-music-mcp.app/Contents/MacOS/apple-music-mcp`
— so nothing about the stdio transport changes. Only the path in
`manifest.json` → `server.entry_point` and `mcp_config.command` changes.

Apple's own confirmation step is a three-line entitlements dump, and it prints exactly the
key that is missing today:

```
entitlements: {
    "com.apple.application-identifier" = "TEAMID.codes.eneko.apple-music-mcp";
    "com.apple.developer.team-identifier" = TEAMID;
}
```

## 3. What has to be obtained, and what of it is secret

This is the part that answers "no private data in GitHub". **Nothing on this list belongs
in the repository, and nothing on it is a MusicKit private key.**

| Item | Where it comes from | Secret? | In the repo? |
|---|---|---|---|
| Apple Developer Program membership | $99/yr | no | n/a |
| Explicit App ID `codes.eneko.apple-music-mcp`, **MusicKit enabled under App Services** | Certificates, Identifiers & Profiles → Identifiers | no | no |
| Provisioning profile for that App ID | the same portal, or Xcode automatic signing | not a credential, but team-specific | **no** — pack-time input |
| Signing identity with a real Team ID | Keychain | its private key is secret | **no** — already `MCPB_SIGN_IDENTITY` |

The decisive detail: **no `.p8` MusicKit private key is required.** Apple's automatic
developer token generation says so directly —

> MusicKit … automatically generat[es] the developer token on behalf of your app. … To
> benefit from this automatic behavior, just enable the MusicKit App Service in the
> developer portal for your app. The MusicKit App Service is a runtime service that
> **automatically associates with your app's bundle identifier**.

The `.p8` key, the `kid`/`iss` claims and the ES256 signing that the original feature
request describes belong to the *other* path, which Apple documents for "other platforms"
— non-Apple ones. Taking that path here would mean embedding a private key in a shipped
binary and making raw HTTPS calls, which is both worse and unnecessary.

So the repository stays clean by construction, not by discipline. There is no secret to
forget to gitignore.

### What changes in `pack.sh`

One new optional environment variable, mirroring the existing `MCPB_SIGN_IDENTITY`:

```bash
MCPB_PROVISION_PROFILE=/path/to/apple-music-mcp.provisionprofile
```

copied to `Contents/embedded.provisionprofile` before signing. When unset, pack.sh builds
exactly what it builds today, and the catalog tools are simply not offered — see §6.

Add `*.provisionprofile` and `*.p8` to `.gitignore` as belt and braces, even though
neither should ever be inside the working tree.

Two existing checks in `pack.sh` need their paths updated for the nested binary: the
`otool -P` Info.plist check and the executable-bit check on the packed archive.

## 4. Two permissions, not one

| Grant | Key | Covers |
|---|---|---|
| Automation | `NSAppleEventsUsageDescription` | everything the server does today |
| Media & Apple Music | `NSAppleMusicUsageDescription` | MusicKit only |

Both go in `Contents/Info.plist`. They are independent: one can be granted and the other
refused, so `music_status` needs to report them separately, and a catalog tool must fail
with the Media & Apple Music instruction rather than the Automation one.

`MusicAuthorization.request()` is what raises the second dialog, and it must be called
before any other MusicKit API.

## 5. The catalog and the library do not share an identifier

This is the answer to the first open question in the original request, and it is a hard
no.

| | Local library (ScriptingBridge) | Catalog (MusicKit) |
|---|---|---|
| identifier | `persistent ID` (16 hex) | `MusicItemID` (catalog id) |
| also has | `database ID`, `episode ID` | `isrc`, `url`, `playParameters` |
| shares anything with the other? | **no** | **no** |

Music's `track` class carries no store id and no ISRC. MusicKit's `Song` carries no
persistent id. There is no key to join on.

Two consequences:

- **A MusicKit item cannot be passed to `add_to_playlist`.** It would not error. The
  bridge resolves ids with `persistentID == %@` against the library array, so an
  unrecognised id lands in `missing[]` and reads back as *"that track is not in your
  library"* — a plausible, wrong answer, which is the worst failure mode for a tool the
  model trusts.
- **"Add to library, then resolve back" does not work either.** With no shared key, the
  only join is text matching on name/artist/album, which silently picks the wrong
  remaster, the live cut, or a different "(feat. …)" spelling.

### The design that follows

Keep the two lanes separate and make crossing them impossible rather than discouraged.

- Catalog tools return catalog ids under a distinct, obviously-different shape — e.g.
  prefixed `am:` — so a catalog id and a persistent id can never be confused by eye or by
  the model.
- `add_to_playlist` and `track_get` **refuse a prefixed id outright**, with an error that
  names the right tool, rather than reporting it as missing.
- Adding a catalog item to a playlist goes through MusicKit's own
  `MusicLibrary.shared.add(_:to:)`, which Apple documents as *"Adds an item to the end of
  an existing playlist"* — append-only, and so already in keeping with this repo's
  invariant.

### One API that must never be called

Linking MusicKit brings `MusicLibrary.edit(_:items:)` into the process. It **replaces a
playlist's contents wholesale**. It does not break any invariant by existing, but it is
the loaded gun this repo's rules exist to keep out of the room, and it deserves an
explicit line in `CLAUDE.md` rather than being left to the reader's restraint.

## 6. Should the catalog tools be a mode or a second server?

A second server was ruled out. The mode has to be honest about one thing: the README, the
manifest `long_description` and the server `instructions` all currently claim *"There is
no network, no credential and no cloud API."* Catalog search is a cloud API. That sentence
has to change from a flat statement into a conditional one.

Recommended shape:

- The catalog tools are **absent from `tools/list`** unless the binary was built with the
  profile. A tool that cannot work should not appear in the catalogue, because the
  catalogue is the authorisation surface.
- `music_status` says which lane is live, so the failure is diagnosable in one call.
- The version bump is a **minor** one, and all three version strings must move together —
  `manifest.json`, `MusicMCPServer.version`, `Resources/Info.plist`.

## 7. If only *search* is wanted, there is a much cheaper answer

Worth stating plainly, because the two halves of this feature have very different costs.

The iTunes Search API (`https://itunes.apple.com/search?term=…`) is a public, unauthenticated
Apple endpoint. No membership, no entitlement, no app bundle, no provisioning profile, no
key. It answers "does this song exist, who is it by, what album is it on".

It is still a network call, so it breaks the *no network* property just as much as
MusicKit does — but it breaks nothing else, and it needs none of §2 or §3. What it
**cannot** do is add anything to the library; it returns Store metadata, not catalog items.

So:

- goal is *"what is this song / does it exist"* → iTunes Search API, an afternoon's work.
- goal is *"put it in my library"* → MusicKit, everything above.

## What is still unverified

Two things, and both should be settled before any of this is built.

1. **Whether the Media & Apple Music dialog can appear at all here.** Claude Desktop
   spawns MCP servers through `Contents/Helpers/disclaimer`, with no UI session.
   `MusicAuthorization.request()` is documented as presenting a consent dialog; whether
   that dialog reaches the screen for a process in this position is not something the
   documentation answers, and I have not tested it.
2. **Whether the app-wrapper pattern actually satisfies MusicKit**, as opposed to
   satisfying Endpoint Security, which is the example Apple's document is written around.

### The experiment that settles both

Roughly an hour, and it touches nothing in this repository:

1. Build a throwaway `.app` following [the daemon pattern][daemon], bundle id
   `codes.eneko.apple-music-mcp.probe`, MusicKit enabled on its App ID.
2. Run Apple's entitlements dump from that document. Confirm
   `com.apple.application-identifier` is present.
3. Call `MusicAuthorization.request()`, then one `MusicCatalogSearchRequest`.
4. Run it **again from a non-UI context** — `launchd`, or spawned the way Claude Desktop
   spawns it — and see whether the dialog still appears.

Step 4 is the one that matters. If the prompt never appears there, the feature needs a
one-time grant obtained some other way, and that changes the shape of the whole thing.

[daemon]: https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement

## Sources

- [Signing a Daemon with a Restricted Entitlement][daemon] — Apple
- [Xcode 13.4 command line tool cannot run because of missing entitlements](https://developer.apple.com/forums/thread/711950) — the DTS answer this proposal is built on
- [Using Automatic Token Generation for Apple Music API](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api) — Apple
- [Generating Developer Tokens](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens) — Apple
- [MusicAuthorization.request()](https://developer.apple.com/documentation/musickit/musicauthorization/request()) — Apple
