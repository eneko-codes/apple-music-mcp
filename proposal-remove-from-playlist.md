# Proposal — `remove_from_playlist`, and the rule change it needs first

Status: **draft for the owner's decision**. No code has been written and `CLAUDE.md` has
not been touched. The rule below is the owner's to change or to leave alone; this document
only sets out what changing it would mean and what the tool would have to guarantee.

## Why this is on the table

A `add_to_playlist` call timed out on the client after succeeding on the server. It was
retried. Twelve duplicate tracks ended up in a playlist, and this server offered no way to
take them out — the only route was doing it by hand in Music.

The duplicate *cause* is now addressed: `add_to_playlist` takes `skip_duplicates`, which
would have prevented that specific incident. What it does not do is repair a playlist that
is already wrong. That is what this proposal is about, and it is a separate question with a
separate answer.

## The rule as it stands

`CLAUDE.md`, in *Invariants worth protecting*:

> - **Nothing here removes a track or a playlist**, and no such tool may be added. A track
>   deleted from Music can take the file with it.

The stated reason is precise and correct: **a track deleted from Music can take the file
with it.** That is a real and irreversible harm.

But the rule is written more broadly than its reason. It forbids removal in general, on the
strength of a danger that belongs to one specific kind of removal.

## What Music's dictionary actually says

`delete` is the standard Core Suite command, and it is not a track-specific operation at
all:

```
<command name="delete" code="coredelo" description="Delete an element from an object">
  <direct-parameter type="specifier" description="the element to delete"/>
</command>
```

*"Delete an element from an object."* The direct parameter is a **specifier**, so what gets
destroyed depends entirely on which container the specifier names:

| Specifier | Effect |
|---|---|
| `track id X of user playlist P` | removes the entry from **that playlist**. The library keeps the track; the file is untouched. |
| `track id X of library playlist 1` | removes it from the **library**. This is the case that can take the file. |

The two are one keystroke apart, and they are separated only by the container. That is
simultaneously the argument that a safe tool is possible *and* the argument for being
extremely careful about where the specifier is built.

**This reading is from the dictionary, not from observation.** It has not been tested
against a real playlist, because doing so would mean touching the owner's library. See
[Verification required first](#verification-required-first).

## The proposed rule change

Narrow the rule to its actual reason, and make the excluded case explicit rather than
implied.

```diff
-- **Nothing here removes a track or a playlist**, and no such tool may be added. A track
--  deleted from Music can take the file with it.
+- **Nothing here removes a track from the library, or removes a playlist**, and no such
+  tool may be added. A track deleted from the library can take the file with it, and a
+  deleted playlist cannot be recovered from these tools.
+- **`remove_from_playlist` removes playlist entries and nothing else.** The specifier it
+  builds always names a user playlist as the container, never the library and never the
+  application, so the track stays in the library and the file is never touched. It is
+  refused for the same playlists `add_to_playlist` refuses. Building that specifier
+  anywhere except the bridge, or against any container but a user playlist obtained by
+  persistent id, is the bug this invariant exists to prevent.
```

The two neighbouring references would need to move with it, or they become stale in the way
`CLAUDE.md` itself warns about:

- **Line 26–27** — *"this server has no delete tool and must not gain one"*, in the ZZTest
  exception. Still true of the *playlist* the exception creates, but the sentence would now
  overstate it. Suggested: *"because this server cannot delete a playlist and must not gain
  a tool that can"*.
- **Line 30** — *"a playlist an agent creates cannot be removed through these tools at
  all"*. Unchanged and still true: this proposal adds no way to delete a playlist. Worth
  keeping exactly as it is, because it stays the reason to prefer the fake.

## The tool

### Addressing entries by position, not by id

This is the design decision that matters, and it comes straight out of the incident.

Twelve duplicates of the same track share one persistent id. A tool that takes track ids
cannot express *"remove eleven of these twelve and keep one"* — the id names all of them
equally. Positions are unambiguous:

```
remove_from_playlist(
  playlist_id:    "…",          # from playlists_list
  positions:      [4, 5, 6],    # 1-based, as playlist_get numbers them
  expected_count: 27,           # the playlist's track count as just read
)
```

Three properties fall out of that shape:

- **It forces a read first.** Positions only come from `playlist_get`, so nothing can be
  removed that was not just looked at.
- **`expected_count` is a concurrency guard.** If the playlist's track count no longer
  matches what the caller saw, the positions refer to a playlist that has since changed and
  the call is **refused**, not applied to whatever is there now. This is the one guard that
  makes a positional API safe.
- **Deletion runs in descending position order** inside the bridge, so earlier deletions
  cannot shift the indices of later ones. A caller passing `[4, 5, 6]` gets entries 4, 5 and
  6 as they read them, not 4, 6 and 8.

### What it must refuse

Everything `add_to_playlist` refuses, for the same reasons and through the same
`PlaylistInfo.isEditable` check — smart, Genius, folder and library playlists — plus:

- a position outside `1...trackCount`;
- an `expected_count` that does not match;
- an empty `positions` array;
- **any request that would empty the playlist entirely.** Removing every entry is
  indistinguishable in effect from deleting the playlist, which this server does not do.

### Annotations and naming

`destructiveHint: true` — the first tool in this server to carry it. `music_control` is
annotated as a write while destroying nothing; this one genuinely destroys something, even
if only an entry, and the annotation should say so plainly rather than being softened
because the harm is bounded.

Verb prefix `remove_`, so it sorts and reads as a write alongside `create_` and `add_`.

### Where the code goes

The specifier must be built in `MusicBridge.m` and nowhere else, from a playlist obtained
via the existing `playlistWithPersistentID:inApplication:`. No Swift-side code should be
able to name a container. The editable check is duplicated in the bridge exactly as
`addTracksWithPersistentIDs:` already duplicates it — *"the last line of defence, duplicated
from the Swift side on purpose"*.

## Verification required first

**None of this should be built on my reading of the dictionary alone.** The distinction the
whole proposal rests on — that deleting an element of a user playlist leaves the library
track and its file intact — is documented behaviour that I have not observed, and I am not
permitted to observe it here.

Before the rule changes, on a throwaway `ZZTest` playlist, by hand:

| Step | Check | Expected |
|---|---|---|
| 1 | Add a track to `ZZTest`, note its persistent id | — |
| 2 | `delete track id … of user playlist "ZZTest"` in Script Editor | entry gone from `ZZTest` |
| 3 | Search the library for that persistent id | **still there** |
| 4 | Check the file on disk | **still there** |
| 5 | Add the same track twice, delete position 2 | one entry left, not zero |
| 6 | Confirm Music raised no "keep file / move to Trash" dialog | no dialog at any point |

Step 6 is the one that would invalidate the whole proposal. If Music prompts, or if step 3
or 4 fails, the rule should stay exactly as it is.

## The honest counter-argument

The rule as written has a property the narrowed version loses: **it is impossible to get
wrong.** "Nothing removes anything" needs no reviewer to check which container a specifier
names, no test to confirm the editable check was duplicated, and no reader to understand
the difference between a playlist entry and a library track.

The narrowed rule is correct but conditional, and conditional rules fail differently — they
fail when someone extends the code later and does not know why the condition was there.
That is a real cost, and it is worth weighing against the actual frequency of the problem:
one incident, whose cause is now fixed by `skip_duplicates`.

A defensible answer is to leave the rule alone and treat by-hand cleanup as the accepted
price of a guarantee that never needs interpreting.
