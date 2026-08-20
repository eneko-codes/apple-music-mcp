# Manual verification

Everything below runs against **your real music library**, and section 6 makes noise, which
is why no agent may run it (see the hard rule in `CLAUDE.md`). Work through it yourself, in
order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-music-mcp
```

## 0 — Before you start

Open Music. Turn the volume down before section 6. Make a playlist named `ZZTest` with two
or three tracks in it, and delete it by hand when you finish — this server has no delete
tool, deliberately.

## 1 — Permission plumbing

| Step | Call | Expected |
|---|---|---|
| 1.1 | Quit Music, then `music_search` | Refused, saying Music is not running — and **Music does not launch**. |
| 1.2 | Open Music, then `music_search` | The Automation dialog appears, quoting the usage description. |
| 1.3 | Approve, then `music_status` | Granted, with the scan ceiling and result limit it is actually running with. |
| 1.4 | Deny (System Settings → Privacy & Security → Automation), restart, call again | Refused with the exact pane to re-enable. |

Step 1.1 is worth the trouble. Music launching on its own can start playing out loud.

## 2 — Reading the library

| Step | Call | Expected |
|---|---|---|
| 2.1 | `music_search` for an artist you own | Matches, with ids. |
| 2.2 | `tracks_list` with no filter on a large library | Returns within a sensible time and says it hit the scan ceiling. |
| 2.3 | `tracks_list` filtered by genre | Narrows correctly. |
| 2.4 | `tracks_list` filtered by `played_count` above 0 | Only tracks you have actually played. |
| 2.5 | Read any row | It carries played count, played date, skipped count, rating, favourite and date added. |
| 2.6 | `track_get` on one id | Full metadata; lyrics if the track has them. |
| 2.7 | `track_get` with several ids at once | One call, all of them. |
| 2.8 | `track_get` on a track you then delete in Music | Reports the id as no longer in the library — an ordinary outcome, not a failure. |

Step 2.5 is the point of this server. If those fields are missing, the interesting half of
the library is invisible.

## 3 — Play counts across devices

| Step | Call | Expected |
|---|---|---|
| 3.1 | Note a track's played count | |
| 3.2 | Play it once **on your iPhone**, let it sync | |
| 3.3 | `track_get` again | The count went up. |

Worth doing once so you trust what the number means: it is every device, not this Mac.

## 4 — Playlists

| Step | Call | Expected |
|---|---|---|
| 4.1 | `playlists_list` | `ZZTest` present; smart playlists marked as smart; folders marked as folders. |
| 4.2 | `playlist_get` on `ZZTest` | Its tracks. |
| 4.3 | `tracks_list` scoped to `ZZTest` | Only those tracks. |

## 5 — Writes

| Step | Call | Expected |
|---|---|---|
| 5.1 | `create_playlist` named `ZZTest 2` | Created, empty. |
| 5.2 | `create_playlist` named `ZZTest 2` again | Refused — never overwrites. |
| 5.3 | `add_to_playlist` two tracks into `ZZTest 2` | Added, in order. |
| 5.4 | `add_to_playlist` one more | Appended; **the first two are still there and still in order**. |
| 5.5 | `add_to_playlist` into a **smart** playlist | Refused, explaining that its contents are the output of its rules. |
| 5.6 | `add_to_playlist` into the library itself, or a folder | Refused. |
| 5.7 | `add_to_playlist` with one real id and one nonsense id | Partial success reported honestly: what was added, what was not. |
| 5.8 | `add_to_playlist` the same track again, `skip_duplicates=true` | Nothing appended; the id is reported as already present. Track count unchanged in Music. |
| 5.9 | `add_to_playlist` one id **twice in one call**, `skip_duplicates=true` | Added once. This is the retried-timeout shape. |
| 5.10 | `add_to_playlist` a genuinely new id, `skip_duplicates=true` | Appended, and the answer says none were already there — not silence. |
| 5.11 | Look for a delete tool in `tools/list` | There is none. |

Step 5.4 is the append guarantee. Steps 5.8–5.10 are the duplicate guard: 5.10 matters
because "checked and found none" must not read the same as "never looked". Step 5.11 is why
you delete `ZZTest` and `ZZTest 2` by hand afterwards.

## 6 — Playback, with the volume down

| Step | Call | Expected |
|---|---|---|
| 6.1 | `now_playing` while nothing plays | Reports stopped, without inventing a track. |
| 6.2 | `music_control` with `play` | Something plays. |
| 6.3 | `now_playing` | The track, position and volume, matching Music. |
| 6.4 | `music_control` with `pause`, `next`, `previous` | Each does what it says, and the response describes the **resulting** state. |
| 6.5 | `music_control` with `volume` set to 20 | Volume changes; the response reports 20. |
| 6.6 | `music_control` with an invalid command | Refused before any Apple event is sent. |

## 7 — Packaging

| Step | Command | Expected |
|---|---|---|
| 7.1 | `otool -P .build/release/apple-music-mcp \| grep NSAppleEventsUsageDescription` | Present. |
| 7.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 7.3 | `codesign -dv extension/server/apple-music-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 7.4 | Install, restart Claude Desktop | Ten switches appear, one per tool. |

If you would rather Claude never touched playback, switch `music_control` off here and leave
the rest on. That is what the per-tool switches are for.

## 8 — Clean up

Delete `ZZTest` and `ZZTest 2` in Music, and set the volume back.
