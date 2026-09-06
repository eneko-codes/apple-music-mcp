# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify the music library (playlists, tracks) and do not call `music_control` (play/pause/skip/volume — audible immediately in the room) unless explicitly asked. Test playlists may be created but must be clearly named `TESTING: ...`; note this server has no delete tool, so remove one by hand in Music when done.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Music app through Apple events. No network, no credential, no cloud API, gated by TCC consent for Automation. Music must already be running; this server never launches it.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-music-mcp | grep NSAppleEventsUsageDescription
```
