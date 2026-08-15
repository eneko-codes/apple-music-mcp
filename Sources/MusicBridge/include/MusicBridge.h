#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const MusicBridgeErrorDomain;

/// Typed because Swift imports an `NSError **` method as `throws`, which would otherwise
/// flatten "no track carries that persistent id" — an ordinary outcome, since a track can
/// be removed from the library between two calls — into the same channel as a real
/// failure.
typedef NS_ERROR_ENUM(MusicBridgeErrorDomain, MusicBridgeError){
    MusicBridgeErrorMusicNotRunning = 1,
    MusicBridgeErrorNotReachable,
    MusicBridgeErrorTrackNotFound,
    MusicBridgeErrorPlaylistNotFound,
    MusicBridgeErrorPlaylistNotEditable,
    MusicBridgeErrorPlaylistExists,
    MusicBridgeErrorCreateRefused,
    MusicBridgeErrorUnknownCommand,
};

/// Everything this project sends to Music, in Objective-C.
///
/// Objective-C rather than Swift on purpose, and not for taste. Apple documents exactly
/// one way to create a scriptable object — ask the application for the class with
/// `classForScriptingClass:`, `alloc`/`initWithProperties:` it, then insert it in the
/// container's element array — and `createPlaylistNamed:` needs precisely that. The
/// pattern cannot be expressed from Swift: the class that comes back is an
/// `SBPseudoClass`, which does not inherit from `SBObject` and turns every class-level
/// message into an `__NSMessageBuilder`, so a Swift metatype cast against it aborts the
/// process. Underneath is a Swift limitation of long standing — the metadata symbols for
/// Scripting Bridge classes do not exist at link time because the classes are made at
/// runtime (swiftlang/swift#43407, open since 2016).
///
/// In Objective-C none of that arises. A cast to a protocol is a compile-time annotation,
/// the documented creation pattern compiles as written, and no `unsafeBitCast` is needed
/// anywhere. The alternative — driving Music through `NSAppleScript` — is the one thing
/// Apple's own guide tells you not to do: "You should not use NSAppleScript to execute a
/// script merely to result in sending an Apple event."
///
/// Everything crosses back to Swift as Foundation types, so no Scripting Bridge object
/// ever escapes this file. Policy — which filters to apply, how to page, where to stop,
/// how to format — stays in Swift, where the tests can reach it.
///
/// Caller strings are passed as typed parameters throughout. There is no script source to
/// splice them into, which is the injection guarantee this project has by construction.
@interface MusicBridge : NSObject

/// Whether Music is running. This server never launches it.
@property (class, readonly) BOOL isMusicRunning;

/// Transport state as `{state, volume, position, playlistName, track}`, where `track` is
/// a summary row or absent when nothing is loaded.
+ (nullable NSDictionary<NSString *, id> *)playerStateWithError:(NSError **)error;

/// Walks tracks and returns `{scanned, tracks: [row]}`, one row per track with every
/// summary property but the lyrics.
///
/// `predicate` is pushed into Music as a `whose` clause rather than applied here:
/// filtering in Music is dramatically faster than shipping the whole library across the
/// Apple event boundary. It is built in Swift from typed values — there is no string
/// splicing on either side. `maxScan` bounds the walk and `scanned` reports how far it
/// actually got, which is what lets the caller say a result was truncated.
///
/// A nil `playlistPersistentID` walks the whole library.
+ (nullable NSDictionary<NSString *, id> *)scanTracksInPlaylist:
                                               (nullable NSString *)playlistPersistentID
                                                       predicate:(nullable NSPredicate *)predicate
                                                         maxScan:(NSInteger)maxScan
                                                           error:(NSError **)error;

/// One track with its lyrics, or nil with `MusicBridgeErrorTrackNotFound` if the library
/// no longer holds that persistent id.
+ (nullable NSDictionary<NSString *, id> *)trackWithPersistentID:(NSString *)persistentID
                                                           error:(NSError **)error;

/// Every playlist, as `{persistentID, name, trackCount, duration, kind, smart, parent}`.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)playlistsWithError:(NSError **)error;

/// Creates an empty user playlist and returns its row.
///
/// Refuses with `MusicBridgeErrorPlaylistExists` when a playlist of that name is already
/// there. Music is perfectly happy to hold two playlists with the same name, so nothing
/// would be overwritten — but a second "Road trip" is indistinguishable from the first in
/// every listing, and that is its own kind of damage.
+ (nullable NSDictionary<NSString *, id> *)createPlaylistNamed:(NSString *)name
                                                          error:(NSError **)error;

/// Appends tracks to a playlist and returns `{added, missing: [persistentID]}`.
///
/// Append only: `duplicate` copies a library track into the playlist and touches nothing
/// that is already in it. Refuses smart, Genius, folder and subscription playlists, which
/// Music maintains itself.
+ (nullable NSDictionary<NSString *, id> *)addTracksWithPersistentIDs:
                                               (NSArray<NSString *> *)persistentIDs
                                            toPlaylistPersistentID:(NSString *)playlistPersistentID
                                                              error:(NSError **)error;

/// Runs one transport command and returns the resulting player state.
///
/// `command` is one of `play`, `pause`, `next`, `previous`, `volume`; `volume` is only
/// read for the last of those. The set is closed here as well as in the tool schema: the
/// bridge is the last place a command name can turn into an Apple event, so an unknown
/// one fails here rather than reaching Music.
+ (nullable NSDictionary<NSString *, id> *)runCommand:(NSString *)command
                                                volume:(nullable NSNumber *)volume
                                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
