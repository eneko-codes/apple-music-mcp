# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify the library, and do not call `music_control` (play/pause/skip/volume — audible immediately in the room) unless asked.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real library, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own playlist and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` — and note this server has no delete tool, so removing it means doing so by hand in Music, in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Music app through Apple events. No network, no credential, no cloud API, gated by TCC consent for Automation. Music must already be running; this server never launches it.

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
