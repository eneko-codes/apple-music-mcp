#import "MusicBridge.h"

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// Hand-declared bindings for Music, covering only the members this server sends.
//
// `sdef /System/Applications/Music.app | sdp -fh` generates a header of well over a
// thousand lines; declaring the members actually used is smaller and auditable. Every
// selector here was checked against Music's scripting dictionary — confirm before adding
// one:
//
//     sdef /System/Applications/Music.app | grep 'name="played count"'
//
// Scripting Bridge camel-cases dictionary names: `played count` becomes `playedCount`,
// `persistent ID` becomes `persistentID`, and the `next track` command becomes
// `nextTrack`.
//
// Several members are deliberately absent. Music's dictionary exposes `delete`, `move`,
// `convert`, `export`, `refresh` and `quit`; none is declared anywhere here, which makes
// them unreachable from this process. The narrow protocol is the safeguard — a library is
// a record, and nothing in this server removes anything from it. For the same reason no
// member is declared "in case it is useful later": every one is a member this server
// sends.

@protocol MusicItem <NSObject>
@property (copy, readonly) NSString *persistentID;
@property (copy) NSString *name;
@end

@protocol MusicTrack <MusicItem>
@property (copy) NSString *album;
@property (copy) NSString *albumArtist;
@property (copy) NSString *artist;
@property NSInteger bpm;
/// `cloud status` is an `eClS` enumeration; Scripting Bridge hands back the four-char
/// code, which `cloudStatusName` turns into text.
@property (readonly) FourCharCode cloudStatus;
@property (copy) NSString *comment;
@property BOOL compilation;
@property (copy) NSString *composer;
@property (copy, readonly) NSDate *dateAdded;
@property NSInteger discNumber;
@property BOOL disliked;
@property (readonly) double duration;
@property BOOL favorited;
@property (copy) NSString *genre;
@property (copy, readonly) NSString *kind;
@property (copy) NSString *lyrics;
@property NSInteger playedCount;
@property (copy) NSDate *playedDate;
@property NSInteger rating;
@property (readonly) long long size;
@property NSInteger skippedCount;
@property (copy) NSDate *skippedDate;
@property (copy) NSString *sortName;
@property NSInteger trackNumber;
@property NSInteger year;
/// `duplicate` — the only way to put an existing library track into a playlist. It
/// copies; nothing already in the target is touched.
- (SBObject *)duplicateTo:(SBObject *)to;
@end

@protocol MusicPlaylist <MusicItem>
@property (readonly) NSInteger duration;
@property (readonly) NSInteger size;
/// `special kind` is an `eSpK` enumeration. It is how a playlist Music maintains itself —
/// the library, a folder, Genius — is told apart from one a person made.
@property (readonly) FourCharCode specialKind;
@property (readonly) SBElementArray<id<MusicTrack>> *tracks;
@end

/// `smart` and `genius` live on `user playlist`, not on `playlist`, so they are asked for
/// separately and only of a playlist whose `special kind` is `none`. See
/// `isEditablePlaylist:` for why the question is worth the extra round trip.
@protocol MusicUserPlaylist <MusicPlaylist>
@property (readonly) BOOL smart;
@property (readonly) BOOL genius;
@end

@protocol MusicApplication <NSObject>
@property (readonly) SBElementArray<id<MusicTrack>> *tracks;
@property (readonly) SBElementArray<id<MusicPlaylist>> *playlists;
@property (readonly) FourCharCode playerState;
@property double playerPosition;
@property NSInteger soundVolume;
@property (readonly) id<MusicTrack> currentTrack;
@property (readonly) id<MusicPlaylist> currentPlaylist;
- (void)playOnce:(BOOL)once;
- (void)pause;
- (void)nextTrack;
- (void)previousTrack;
@end

NSString *const MusicBridgeErrorDomain = @"codes.eneko.apple-music-mcp";
static NSString *const MusicBundleIdentifier = @"com.apple.Music";

/// Four-char codes from Music's own enumerations, verified against the dictionary.
static const FourCharCode MusicSpecialKindNone = 'kNon';
static const FourCharCode MusicSpecialKindLibrary = 'kSpL';

/// Swallows the errors Scripting Bridge would otherwise log.
///
/// Two reasons. Asking a library playlist for `smart` is a legitimate question with an
/// error for an answer, and the default handler prints it — noise on a path that is
/// working as designed. And the default handler writes to stderr on every failed event,
/// which turns an ordinary "no such track" into log spam.
///
/// Returning nil makes a failed event evaluate to nil or zero, so every caller below has
/// to check its result rather than trust it. That is why `createPlaylistNamed:` looks the
/// playlist up again afterwards instead of assuming the insert worked.
@interface MusicBridgeEventDelegate : NSObject <SBApplicationDelegate>
@end

@implementation MusicBridgeEventDelegate
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
    return nil;
}
@end

@implementation MusicBridge

#pragma mark - Plumbing

+ (BOOL)isMusicRunning {
    return [NSRunningApplication
               runningApplicationsWithBundleIdentifier:MusicBundleIdentifier].count > 0;
}

+ (NSError *)errorWithCode:(MusicBridgeError)code message:(NSString *)message {
    return [NSError errorWithDomain:MusicBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The application object, or nil with `error` set. Casting to the protocol is a
/// compile-time annotation in Objective-C: no runtime check, no metadata symbol, and so
/// none of the trouble the same line causes in Swift.
+ (nullable SBApplication<MusicApplication> *)applicationWithError:(NSError **)error {
    if (!self.isMusicRunning) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorMusicNotRunning
                                 message:@"Music is not running."];
        }
        return nil;
    }
    SBApplication *application =
        [SBApplication applicationWithBundleIdentifier:MusicBundleIdentifier];
    if (!application) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorNotReachable
                                 message:@"Music could not be reached."];
        }
        return nil;
    }
    // No launch flag is set to keep Music from starting, because none exists: the guard
    // is the isMusicRunning check above. Launching an app on the owner's behalf is a side
    // effect they did not ask for, and Scripting Bridge offers no way to forbid it.
    static MusicBridgeEventDelegate *delegate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ delegate = [MusicBridgeEventDelegate new]; });
    application.delegate = delegate;
    return (SBApplication<MusicApplication> *)application;
}

+ (NSString *)cloudStatusName:(FourCharCode)code {
    switch (code) {
        case 'kUnk': return @"unknown";
        case 'kPur': return @"purchased";
        case 'kMat': return @"matched";
        case 'kUpl': return @"uploaded";
        case 'kRej': return @"ineligible";
        case 'kRem': return @"removed";
        case 'kErr': return @"error";
        case 'kDup': return @"duplicate";
        case 'kSub': return @"subscription";
        case 'kPrR': return @"prerelease";
        case 'kRev': return @"no longer available";
        case 'kUpP': return @"not uploaded";
        default: return @"";
    }
}

+ (NSString *)playerStateName:(FourCharCode)code {
    switch (code) {
        case 'kPSS': return @"stopped";
        case 'kPSP': return @"playing";
        case 'kPSp': return @"paused";
        case 'kPSF': return @"fast forwarding";
        case 'kPSR': return @"rewinding";
        default: return @"unknown";
    }
}

+ (NSString *)specialKindName:(FourCharCode)code {
    switch (code) {
        case 'kNon': return @"";
        case 'kSpF': return @"folder";
        case 'kSpG': return @"Genius";
        case 'kSpL': return @"Library";
        case 'kSpZ': return @"Music";
        case 'kSpM': return @"Purchased Music";
        default: return @"";
    }
}

/// A date Music has never set comes back as nil or as a placeholder far in the past;
/// both mean "never", and NSNull is how that reaches Swift as an absent value rather
/// than as a date in 1904.
+ (id)dateValue:(nullable NSDate *)date {
    if (!date) return NSNull.null;
    if ([date compare:[NSDate dateWithTimeIntervalSince1970:0]] == NSOrderedAscending) {
        return NSNull.null;
    }
    return date;
}

#pragma mark - Rows

+ (NSDictionary<NSString *, id> *)rowForTrack:(id<MusicTrack>)track {
    return @{
        @"persistentID": track.persistentID ?: @"",
        @"name": track.name ?: @"",
        @"artist": track.artist ?: @"",
        @"albumArtist": track.albumArtist ?: @"",
        @"album": track.album ?: @"",
        @"genre": track.genre ?: @"",
        @"composer": track.composer ?: @"",
        @"comment": track.comment ?: @"",
        @"sortName": track.sortName ?: @"",
        @"kind": track.kind ?: @"",
        @"cloudStatus": [self cloudStatusName:track.cloudStatus],
        @"year": @(track.year),
        @"bpm": @(track.bpm),
        @"duration": @(track.duration),
        @"trackNumber": @(track.trackNumber),
        @"discNumber": @(track.discNumber),
        @"playedCount": @(track.playedCount),
        @"skippedCount": @(track.skippedCount),
        @"rating": @(track.rating),
        @"size": @(track.size),
        @"favorited": @(track.favorited),
        @"disliked": @(track.disliked),
        @"compilation": @(track.compilation),
        @"playedDate": [self dateValue:track.playedDate],
        @"skippedDate": [self dateValue:track.skippedDate],
        @"dateAdded": [self dateValue:track.dateAdded],
    };
}

+ (NSDictionary<NSString *, id> *)rowForPlaylist:(id<MusicPlaylist>)playlist {
    FourCharCode kind = playlist.specialKind;
    BOOL smart = NO;
    BOOL genius = NO;
    if (kind == MusicSpecialKindNone) {
        // Only asked of an ordinary playlist: `smart` is a `user playlist` member, and a
        // library or folder playlist answers it with an error. The delegate above keeps
        // that from reaching the log, and NO is the safe reading either way — a playlist
        // this server cannot classify is one it treats as not editable below.
        id<MusicUserPlaylist> userPlaylist = (id<MusicUserPlaylist>)playlist;
        smart = userPlaylist.smart;
        genius = userPlaylist.genius;
    }
    return @{
        @"persistentID": playlist.persistentID ?: @"",
        @"name": playlist.name ?: @"",
        @"trackCount": @(playlist.tracks.count),
        @"duration": @(playlist.duration),
        @"specialKind": [self specialKindName:kind],
        @"smart": @(smart),
        @"genius": @(genius),
    };
}

#pragma mark - Lookup

+ (nullable id<MusicPlaylist>)playlistWithPersistentID:(NSString *)persistentID
                                        inApplication:
                                            (SBApplication<MusicApplication> *)application {
    NSArray *matching = [application.playlists
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"persistentID == %@",
                                                                     persistentID]];
    return matching.firstObject;
}

/// The playlist a library-wide scan walks.
///
/// `tracks of application` is ambiguous — it has meant the current playlist in some
/// versions — so the library playlist is located explicitly by its `special kind` and the
/// application's own track list is only a fallback.
+ (SBElementArray<id<MusicTrack>> *)libraryTracksOf:
    (SBApplication<MusicApplication> *)application {
    for (id<MusicPlaylist> playlist in application.playlists) {
        if (playlist.specialKind == MusicSpecialKindLibrary) return playlist.tracks;
    }
    return application.tracks;
}

#pragma mark - Reads

+ (nullable NSDictionary<NSString *, id> *)playerStateWithError:(NSError **)error {
    SBApplication<MusicApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
    result[@"state"] = [self playerStateName:application.playerState];
    result[@"volume"] = @(application.soundVolume);
    result[@"position"] = @(application.playerPosition);

    id<MusicPlaylist> playlist = application.currentPlaylist;
    result[@"playlistName"] = playlist.name ?: @"";

    id<MusicTrack> track = application.currentTrack;
    // Nothing loaded is an ordinary state, not a failure: the key is simply absent.
    if (track && track.persistentID.length > 0) {
        result[@"track"] = [self rowForTrack:track];
    }
    return result;
}

+ (nullable NSDictionary<NSString *, id> *)scanTracksInPlaylist:
                                              (nullable NSString *)playlistPersistentID
                                                      predicate:(nullable NSPredicate *)predicate
                                                        maxScan:(NSInteger)maxScan
                                                          error:(NSError **)error {
    SBApplication<MusicApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    SBElementArray<id<MusicTrack>> *source;
    if (playlistPersistentID.length > 0) {
        id<MusicPlaylist> playlist = [self playlistWithPersistentID:playlistPersistentID
                                                     inApplication:application];
        if (!playlist) {
            if (error) {
                *error = [self errorWithCode:MusicBridgeErrorPlaylistNotFound
                                     message:@"No playlist carries that id."];
            }
            return nil;
        }
        source = playlist.tracks;
    } else {
        source = [self libraryTracksOf:application];
    }

    // The filter is pushed into Music as a `whose` clause. The unfiltered array is only
    // materialised when there is no filter to push down — building it first and then
    // discarding it would pay for the whole library on exactly the path the filter exists
    // to avoid.
    NSArray *candidates =
        predicate ? [source filteredArrayUsingPredicate:predicate] : ([source get] ?: @[]);

    NSInteger scanned = 0;
    NSMutableArray<NSDictionary<NSString *, id> *> *tracks = [NSMutableArray array];
    for (id<MusicTrack> track in candidates) {
        if (scanned >= maxScan) break;
        scanned += 1;
        // NOTE: one round trip per property per track. If a large library makes this too
        // slow, SBElementArray's -arrayByApplyingSelector: fetches one property for every
        // element in a single event; it is faster and considerably harder to keep in step
        // when a property is missing on one track. Bounded scanning is the cheaper answer
        // until measurement says otherwise.
        [tracks addObject:[self rowForTrack:track]];
    }
    return @{@"scanned": @(scanned), @"tracks": tracks};
}

+ (nullable NSDictionary<NSString *, id> *)trackWithPersistentID:(NSString *)persistentID
                                                           error:(NSError **)error {
    SBApplication<MusicApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    // Matched inside Music rather than by walking the library here.
    NSArray *matching = [[self libraryTracksOf:application]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"persistentID == %@",
                                                                     persistentID]];
    id<MusicTrack> track = matching.firstObject;
    if (!track) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorTrackNotFound
                                 message:@"The library no longer holds a track with that id."];
        }
        return nil;
    }

    NSMutableDictionary<NSString *, id> *row = [[self rowForTrack:track] mutableCopy];
    row[@"lyrics"] = track.lyrics ?: @"";
    return row;
}

+ (nullable NSArray<NSDictionary<NSString *, id> *> *)playlistsWithError:(NSError **)error {
    SBApplication<MusicApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (id<MusicPlaylist> playlist in application.playlists) {
        if (playlist.name.length == 0) continue;
        [results addObject:[self rowForPlaylist:playlist]];
    }
    return results;
}

#pragma mark - Writes

+ (nullable NSDictionary<NSString *, id> *)createPlaylistNamed:(NSString *)name
                                                          error:(NSError **)error {
    SBApplication<MusicApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSArray *existing = [application.playlists
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@", name]];
    if (existing.count > 0) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorPlaylistExists
                                 message:[NSString stringWithFormat:
                                                       @"A playlist named '%@' already exists.",
                                                       name]];
        }
        return nil;
    }

    // Apple's documented creation pattern, and the reason this file is Objective-C.
    Class playlistClass = [application classForScriptingClass:@"user playlist"]
                              ?: [application classForScriptingClass:@"playlist"];
    if (!playlistClass) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorCreateRefused
                                 message:@"Music did not offer its playlist class."];
        }
        return nil;
    }

    id playlist = [[playlistClass alloc] initWithProperties:@{@"name": name}];
    if (!playlist) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorCreateRefused
                                 message:@"Music would not create the playlist."];
        }
        return nil;
    }
    // Scripting Bridge: an object "is not viable in the application until it has been
    // added to its container. Consequently, you cannot set or access its properties until
    // it's been added."
    [application.playlists addObject:playlist];

    // Looked up again rather than read back off the object just inserted. A failed event
    // evaluates to nil under the delegate above, so a persistent id read straight from
    // the new object would be an empty string on exactly the path that needs reporting.
    NSArray *created = [application.playlists
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@", name]];
    id<MusicPlaylist> inserted = created.lastObject;
    if (!inserted) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorCreateRefused
                                 message:@"Music accepted the playlist but it did not appear."];
        }
        return nil;
    }
    return [self rowForPlaylist:inserted];
}

+ (nullable NSDictionary<NSString *, id> *)addTracksWithPersistentIDs:
                                              (NSArray<NSString *> *)persistentIDs
                                           toPlaylistPersistentID:(NSString *)playlistPersistentID
                                                             error:(NSError **)error {
    SBApplication<MusicApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<MusicPlaylist> playlist = [self playlistWithPersistentID:playlistPersistentID
                                                 inApplication:application];
    if (!playlist) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorPlaylistNotFound
                                 message:@"No playlist carries that id."];
        }
        return nil;
    }

    // The last line of defence, duplicated from the Swift side on purpose: a playlist
    // Music maintains itself cannot take an appended track, and asking it to is how a
    // smart playlist's rules get quietly overwritten.
    NSDictionary *playlistRow = [self rowForPlaylist:playlist];
    BOOL editable = [playlistRow[@"specialKind"] length] == 0
                    && ![playlistRow[@"smart"] boolValue] && ![playlistRow[@"genius"] boolValue];
    if (!editable) {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorPlaylistNotEditable
                                 message:[NSString
                                             stringWithFormat:@"Music maintains '%@' itself; "
                                                               "tracks cannot be added to it.",
                                                              playlistRow[@"name"]]];
        }
        return nil;
    }

    SBElementArray<id<MusicTrack>> *library = [self libraryTracksOf:application];
    NSInteger added = 0;
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *identifier in persistentIDs) {
        NSArray *matching = [library
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"persistentID == %@",
                                                                         identifier]];
        id<MusicTrack> track = matching.firstObject;
        if (!track) {
            [missing addObject:identifier];
            continue;
        }
        // `duplicate` appends a copy; it cannot remove or reorder what is already there.
        if ([track duplicateTo:(SBObject *)playlist]) {
            added += 1;
        } else {
            [missing addObject:identifier];
        }
    }
    return @{@"added": @(added), @"missing": missing, @"playlistName": playlistRow[@"name"]};
}

+ (nullable NSDictionary<NSString *, id> *)runCommand:(NSString *)command
                                                volume:(nullable NSNumber *)volume
                                                 error:(NSError **)error {
    SBApplication<MusicApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    if ([command isEqualToString:@"play"]) {
        // `once:NO` keeps Music's own repeat setting; passing YES would silently change
        // a preference the owner set.
        [application playOnce:NO];
    } else if ([command isEqualToString:@"pause"]) {
        [application pause];
    } else if ([command isEqualToString:@"next"]) {
        [application nextTrack];
    } else if ([command isEqualToString:@"previous"]) {
        [application previousTrack];
    } else if ([command isEqualToString:@"volume"]) {
        NSInteger level = MIN(MAX(volume.integerValue, 0), 100);
        application.soundVolume = level;
    } else {
        if (error) {
            *error = [self errorWithCode:MusicBridgeErrorUnknownCommand
                                 message:[NSString stringWithFormat:@"'%@' is not a playback "
                                                                     "command.",
                                                                    command]];
        }
        return nil;
    }
    return [self playerStateWithError:error];
}

@end
