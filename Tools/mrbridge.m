// mrbridge.m — a tiny dylib that reads and drives system-wide Now Playing.
//
// macOS 15.4 made MediaRemote answer only processes that carry a private
// entitlement. /usr/bin/perl is an Apple platform binary that has it, so the
// app runs perl, has DynaLoader load this dylib, and calls one of the
// exported functions below. Nothing here is linked into FunNotch itself.
//
// fn_stream  — never returns: prints one JSON object per line, about once a
//              second, and exits when its stdout pipe closes (the app quit).
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

static double numberValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSString class]]) return [value doubleValue];
    return 0;
}

/// Runs an asynchronous MediaRemote call and waits for its callback, because
/// it never answers on the calling thread.
#define WAIT(body) ({ \
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0); \
    body; \
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)); \
})

void fn_stream(void) {
    @autoreleasepool {
        void *lib = framework();
        MRGetInfo getInfo = lib ? (MRGetInfo)dlsym(lib, "MRMediaRemoteGetNowPlayingInfo") : NULL;
        MRGetBool getPlaying = lib ? (MRGetBool)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
        MRGetString getDisplayID = lib ? (MRGetString)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationDisplayID") : NULL;
        if (!getInfo) {
            printf("{\"error\":\"MediaRemote unavailable\"}\n");
            fflush(stdout);
            return;
        }

        NSString *lastArtworkID = @"";
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

        while (1) {
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
                if (info.count > 0) {
                    out[@"title"] = stringValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                    out[@"artist"] = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                    out[@"album"] = stringValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                    out[@"duration"] = @(numberValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]));
                    out[@"elapsed"] = @(numberValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]));
                    double rate = numberValue(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                    out[@"playing"] = @(playingKnown ? playing : rate > 0);
                    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([stamp isKindOfClass:[NSDate class]]) {
                        out[@"timestamp"] = @([stamp timeIntervalSince1970]);
                    }
                    out[@"bundle"] = displayID;

                    NSString *artworkID = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
                    if (artworkID.length == 0) {
                        artworkID = [NSString stringWithFormat:@"%@|%@", out[@"title"], out[@"artist"]];
                    }
                    out[@"artworkID"] = artworkID;
                    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    // The image is large; send it once per track, not once a second.
                    if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0
                        && ![artworkID isEqualToString:lastArtworkID]) {
                        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                        lastArtworkID = artworkID;
                    }
                }

                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (json) {
                    // A closed pipe raises SIGPIPE, which ends this process
                    // along with the app that spawned it.
                    fwrite(json.bytes, 1, json.length, stdout);
                    fputc('\n', stdout);
                    fflush(stdout);
                }
            }
            [NSThread sleepForTimeInterval:1.0];
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
