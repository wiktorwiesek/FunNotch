// mrbridge.m — a tiny dylib that reads and drives system-wide Now Playing.
//
// macOS 15.4 made MediaRemote answer only processes that carry a private
// entitlement. /usr/bin/perl is an Apple platform binary that has it, so the
// app runs perl, has DynaLoader load this dylib, and calls one of the
// exported functions below. Nothing here is linked into FunNotch itself.
//
// fn_stream  — never returns: prints one JSON object per line whenever what
//              is playing changes, and exits when the app that spawned it is
//              gone (its stdout pipe closes, or it is reparented to launchd).
// fn_send    — one-shot: FN_MR_COMMAND (int) is a MRMediaRemoteCommand, and
//              FN_MR_POSITION (seconds) sets the playhead instead when given.
//
// Build (done by build.sh):
//   clang -dynamiclib -fobjc-arc -framework Foundation -o mrbridge.dylib mrbridge.m

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>

typedef void (^MRInfoBlock)(NSDictionary *info);
typedef void (^MRBoolBlock)(BOOL value);
typedef void (^MRStringBlock)(NSString *value);
typedef void (*MRGetInfo)(dispatch_queue_t, MRInfoBlock);
typedef void (*MRGetBool)(dispatch_queue_t, MRBoolBlock);
typedef void (*MRGetString)(dispatch_queue_t, MRStringBlock);
typedef BOOL (*MRSend)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);
typedef void (*MRRegister)(dispatch_queue_t);

static void *framework(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    return handle;
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

/// A finite number, or 0. A live stream reports an infinite duration (and a
/// player in a bad moment, NaN), and NSJSONSerialization answers either with
/// an exception: uncaught, that aborted the helper every time it started for
/// as long as the stream was what the Mac was playing.
static double numberValue(id value) {
    double number = 0;
    if ([value isKindOfClass:[NSNumber class]]) number = [value doubleValue];
    else if ([value isKindOfClass:[NSString class]]) number = [value doubleValue];
    return isfinite(number) ? number : 0;
}

/// One line of JSON, or nil for anything JSON cannot carry. Never throws:
/// what MediaRemote hands over is whatever the playing app put there.
static NSData *encode(NSDictionary *object, NSJSONWritingOptions options) {
    if (![NSJSONSerialization isValidJSONObject:object]) return nil;
    @try {
        return [NSJSONSerialization dataWithJSONObject:object options:options error:nil];
    } @catch (NSException *exception) {
        return nil;
    }
}

/// Runs an asynchronous MediaRemote call and waits for its callback, because
/// it never answers on the calling thread.
#define WAIT(body) ({ \
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0); \
    body; \
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)); \
})

/// How long to wait for a change notification before reading anyway. Until
/// one has arrived the notifications are unproven, so reads stay as frequent
/// as the old fixed poll; after that the read only guards against a missed
/// one, and an idle Mac reads every ten seconds instead of every second.
static double fallbackInterval(BOOL notificationsSeen, BOOL playing) {
    if (notificationsSeen) return 10;
    return playing ? 1 : 3;
}

void fn_stream(void) {
    @autoreleasepool {
        void *lib = framework();
        MRGetInfo getInfo = lib ? (MRGetInfo)dlsym(lib, "MRMediaRemoteGetNowPlayingInfo") : NULL;
        MRGetBool getPlaying = lib ? (MRGetBool)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
        MRGetString getDisplayID = lib ? (MRGetString)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationDisplayID") : NULL;
        MRRegister registerNotifications = lib ? (MRRegister)dlsym(lib, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
        if (!getInfo) {
            printf("{\"error\":\"MediaRemote unavailable\"}\n");
            fflush(stdout);
            return;
        }

        NSString *lastArtworkID = @"";
        NSData *lastLine = nil;
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

        // MediaRemote announces every change; the loop below sleeps until one
        // arrives instead of asking three questions over XPC every second.
        dispatch_semaphore_t changed = dispatch_semaphore_create(0);
        __block BOOL notificationsSeen = NO;
        if (registerNotifications) {
            dispatch_queue_t notifyQueue = dispatch_queue_create("mrbridge.notify", DISPATCH_QUEUE_SERIAL);
            registerNotifications(notifyQueue);
            for (NSString *name in @[
                     @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                     @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                 ]) {
                [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                              usingBlock:^(NSNotification *note) {
                    notificationsSeen = YES;
                    dispatch_semaphore_signal(changed);
                }];
            }
        }
        BOOL playingNow = NO;

        while (1) {
            // Nothing writes to a pipe nobody reads: with output only on
            // change, SIGPIPE alone could leave this running for a long time
            // after the app quit.
            if (getppid() == 1) exit(0);

            @autoreleasepool {
                __block NSDictionary *info = nil;
                __block BOOL playing = NO;
                __block BOOL playingKnown = NO;
                __block NSString *displayID = @"";

                WAIT(getInfo(queue, ^(NSDictionary *value) {
                    info = value;
                    dispatch_semaphore_signal(semaphore);
                }));
                if (getPlaying) {
                    WAIT(getPlaying(queue, ^(BOOL value) {
                        playing = value;
                        playingKnown = YES;
                        dispatch_semaphore_signal(semaphore);
                    }));
                }
                if (getDisplayID) {
                    WAIT(getDisplayID(queue, ^(NSString *value) {
                        displayID = value ?: @"";
                        dispatch_semaphore_signal(semaphore);
                    }));
                }

                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                NSData *artwork = nil;
                NSString *artworkID = @"";
                playingNow = NO;
                if (info.count > 0) {
                    out[@"title"] = stringValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                    out[@"artist"] = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                    out[@"album"] = stringValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                    out[@"duration"] = @(numberValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]));
                    out[@"elapsed"] = @(numberValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]));
                    double rate = numberValue(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                    playingNow = playingKnown ? playing : rate > 0;
                    out[@"playing"] = @(playingNow);
                    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([stamp isKindOfClass:[NSDate class]] && isfinite([stamp timeIntervalSince1970])) {
                        out[@"timestamp"] = @([stamp timeIntervalSince1970]);
                    }
                    out[@"bundle"] = displayID;

                    artworkID = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
                    if (artworkID.length == 0) {
                        artworkID = [NSString stringWithFormat:@"%@|%@", out[@"title"], out[@"artist"]];
                    }
                    out[@"artworkID"] = artworkID;
                    NSData *data = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([data isKindOfClass:[NSData class]] && data.length > 0) artwork = data;
                } else {
                    // The app drops its picture on an empty report; when the
                    // same item comes back it needs the image again.
                    lastArtworkID = @"";
                }

                // Sorted keys, so an unchanged state always serialises the
                // same and is not sent again. The playhead is `elapsed` at
                // `timestamp`, which stays put while playback runs on.
                NSData *line = encode(out, NSJSONWritingSortedKeys);
                // The image is large; send it once per track, not with every
                // change — but also when it turns up after the track did.
                BOOL sendArtwork = artwork && ![artworkID isEqualToString:lastArtworkID];
                if (line && (sendArtwork || ![line isEqualToData:lastLine])) {
                    lastLine = line;
                    if (sendArtwork) {
                        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                        lastArtworkID = artworkID;
                        line = encode(out, 0);
                    }
                    if (line) {
                        // A closed pipe raises SIGPIPE, which ends this process
                        // along with the app that spawned it.
                        fwrite(line.bytes, 1, line.length, stdout);
                        fputc('\n', stdout);
                        fflush(stdout);
                    }
                }
            }

            double wait = fallbackInterval(notificationsSeen, playingNow);
            if (dispatch_semaphore_wait(changed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC))) == 0) {
                // Changes arrive in bursts (app, then state, then info);
                // read once after the burst settles.
                [NSThread sleepForTimeInterval:0.15];
                while (dispatch_semaphore_wait(changed, DISPATCH_TIME_NOW) == 0) {}
            }
        }
    }
}

void fn_send(void) {
    @autoreleasepool {
        void *lib = framework();
        if (!lib) return;
        const char *command = getenv("FN_MR_COMMAND");
        const char *position = getenv("FN_MR_POSITION");
        if (position) {
            MRSetElapsed setElapsed = (MRSetElapsed)dlsym(lib, "MRMediaRemoteSetElapsedTime");
            if (setElapsed) setElapsed(atof(position));
        } else if (command) {
            MRSend send = (MRSend)dlsym(lib, "MRMediaRemoteSendCommand");
            if (send) send(atoi(command), nil);
        }
        // The command is queued to mediaremoted asynchronously.
        [NSThread sleepForTimeInterval:0.3];
    }
}
