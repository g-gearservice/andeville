#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
typedef void (*GetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*Register)(dispatch_queue_t);
// Now Playing for Andeville's hub. MediaRemote answers only Apple's own processes since macOS 15.4, so Andeville runs
// /usr/bin/perl, which loads this library and calls one of the two XS subs below.
static void *mediaRemote(void) {
    return dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
}

/// Prints the current song as one JSON line ({"playing":false} when there is none), then runs `done`.
/// `known`: the play state a notification just carried; asked right after a change, the getter can still answer
/// the old one, which held the notch back until the next change.
static void emit(void *h, NSNumber *known, void (^done)(void)) {
    GetInfo info = (GetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    GetPlaying playing = (GetPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!info || !playing) { puts("{}"); exit(1); }
    dispatch_queue_t q = dispatch_get_main_queue();
    void (^read)(Boolean) = ^(Boolean isPlaying) {
        info(q, ^(NSDictionary *d) {
            id t = d[@"kMRMediaRemoteNowPlayingInfoTitle"], a = d[@"kMRMediaRemoteNowPlayingInfoArtist"], art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            void (^finish)(NSData *) = ^(NSData *artData) {
                // Streaming, a line goes out only when something shown changed: the poll below asks every second.
                // The artwork by its bytes: a browser's thumbnails are same-size TIFFs, so equal lengths say nothing.
                // Main queue only, so the statics need no lock.
                static NSString *last; static NSData *lastArt;
                NSString *now = [NSString stringWithFormat:@"%@|%@|%d", t, a, isPlaying];
                if (!done && [now isEqual:last] && (artData == lastArt || [artData isEqualToData:lastArt])) return;
                last = now;
                lastArt = artData;
                NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:@(isPlaying) forKey:@"playing"];
                if ([t isKindOfClass:NSString.class]) out[@"title"] = t;
                if ([a isKindOfClass:NSString.class]) out[@"artist"] = a;
                if (artData.length) out[@"artwork"] = [artData base64EncodedStringWithOptions:0];
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout);
                if (done) done();
            };
            NSData *infoArt = [art isKindOfClass:NSData.class] && [art length] ? art : nil;
            // The artwork as Control Center asks for it: MRNowPlayingRequest's artwork request (MRArtwork.imageData).
            // Newer macOS leaves it out of the info on some reads, and when there the info's copy is a different
            // encoding of the same image, so mixing the two flickered the notch between them every second.
            id req = [NSClassFromString(@"MRNowPlayingRequest") new];
            SEL ask = NSSelectorFromString(@"requestNowPlayingItemArtworkOnQueue:completion:");
            if (!t || ![req respondsToSelector:ask]) { finish(infoArt); return; }
            ((void (*)(id, SEL, dispatch_queue_t, void (^)(id, id)))objc_msgSend)(req, ask, q, ^(id artwork, id error) {
                SEL bytes = NSSelectorFromString(@"imageData");
                id data = [artwork respondsToSelector:bytes] ? ((id (*)(id, SEL))objc_msgSend)(artwork, bytes) : nil;
                finish([data isKindOfClass:NSData.class] && [data length] ? data : infoArt);
            });
        });
    };
    if (known) read(known.boolValue); else playing(q, read);
}

// One read: prints one line and exits.
void andeville_now_playing(void) {
    emit(mediaRemote(), nil, ^{ exit(0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ puts("{}"); exit(0); });
    dispatch_main();
}

// Live: a line now and one on every change (song, artwork, play/pause, player), until stdin closes, which is Andeville
// going away.
void andeville_now_playing_stream(void) {
    void *h = mediaRemote();
    Register reg = (Register)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!reg) exit(1);
    reg(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        // queue:nil and a hop onto the main dispatch queue: dispatch_main() ends the main thread, so the main
        // NSOperationQueue never runs, and MediaRemote, posting synchronously, hung on the first change for good.
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
            id k = n.userInfo[@"kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey"];
            NSNumber *known = [k isKindOfClass:NSNumber.class] ? k : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ emit(h, known, nil); });
        }];
    }
    emit(h, nil, nil);
    // Browsers hand over a new video's artwork seconds after its title, and nothing announces it (nor, at times, the
    // next video itself): asked once a second, printed only on a change.
    // ponytail: 1 Hz poll, each one an XPC round trip carrying the artwork; slow it if it ever shows in Activity Monitor.
    dispatch_source_t poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(poll, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(poll, ^{ emit(h, nil, nil); });
    dispatch_resume(poll);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char c;
        while (read(0, &c, 1) > 0) {}
        exit(0);
    });
    dispatch_main();
}
