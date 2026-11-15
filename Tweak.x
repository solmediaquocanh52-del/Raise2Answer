#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTCall.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define R2A_DOMAIN CFSTR("com.vn.raise2answer")
#define R2A_LOG @"/var/mobile/Documents/Raise2Answer.log"

static BOOL prefBool(CFStringRef key, BOOL def) {
    CFPreferencesAppSynchronize(R2A_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, R2A_DOMAIN);
    if (!v) return def;
    BOOL r = def;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue(v, kCFNumberIntType, &n); r = (n != 0); }
    CFRelease(v);
    return r;
}

static double prefDouble(CFStringRef key, double def) {
    CFPreferencesAppSynchronize(R2A_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, R2A_DOMAIN);
    if (!v) return def;
    double r = def;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &r);
    CFRelease(v);
    return r;
}

static void r2aLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void r2aLog(NSString *fmt, ...) {
    if (!prefBool(CFSTR("debug"), YES)) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[Raise2Answer] %@", msg);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:R2A_LOG]) [fm createFileAtPath:R2A_LOG contents:nil attributes:nil];
    NSDictionary *a = [fm attributesOfItemAtPath:R2A_LOG error:nil];
    if ([a fileSize] > 512 * 1024) [@"" writeToFile:R2A_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:R2A_LOG];
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static id send0(id o, NSString *s) {
    SEL sel = NSSelectorFromString(s);
    if (o && [o respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(o, sel);
    return nil;
}
static BOOL has(id o, NSString *s) { return o && [o respondsToSelector:NSSelectorFromString(s)]; }

static id callCenter(void) {
    Class c = NSClassFromString(@"TUCallCenter");
    return send0((id)c, @"sharedInstance");
}

static id incomingCall(void) {
    id c = callCenter();
    id call = send0(c, @"incomingCall");
    if (call) return call;
    NSArray *arr = send0(c, @"currentCalls");
    if ([arr isKindOfClass:NSArray.class]) {
        for (id x in arr) {
            @try { if ([[x valueForKey:@"status"] intValue] == 4) return x; } @catch (NSException *e) {}
        }
    }
    return nil;
}

static BOOL answerCall(void) {
    id c = callCenter();
    if (!c) { r2aLog(@"answer: TUCallCenter not found"); return NO; }
    id call = incomingCall();
    if (!call) { r2aLog(@"answer: no incoming call object"); return NO; }
    SEL s1 = NSSelectorFromString(@"answerCall:");
    if ([c respondsToSelector:s1]) { ((void (*)(id, SEL, id))objc_msgSend)(c, s1, call); r2aLog(@"answer: sent answerCall:"); return YES; }
    SEL s2 = NSSelectorFromString(@"answerCall:withSourceIdentifier:");
    if ([c respondsToSelector:s2]) { ((void (*)(id, SEL, id, id))objc_msgSend)(c, s2, call, nil); r2aLog(@"answer: sent answerCall:withSourceIdentifier:"); return YES; }
    SEL s3 = NSSelectorFromString(@"answerWithSourceIdentifier:");
    if ([call respondsToSelector:s3]) { ((void (*)(id, SEL, id))objc_msgSend)(call, s3, nil); r2aLog(@"answer: sent answerWithSourceIdentifier:"); return YES; }
    SEL s4 = NSSelectorFromString(@"answer");
    if ([call respondsToSelector:s4]) { ((void (*)(id, SEL))objc_msgSend)(call, s4); r2aLog(@"answer: sent answer"); return YES; }
    r2aLog(@"answer: no known answer method found");
    return NO;
}

static void setSpeaker(void) {
    id c = callCenter();
    id rc = send0(c, @"routeController");
    id sp = send0(rc, @"speakerRoute");
    SEL pick = NSSelectorFromString(@"pickRoute:");
    if (rc && sp && [rc respondsToSelector:pick]) {
        ((void (*)(id, SEL, id))objc_msgSend)(rc, pick, sp);
        r2aLog(@"speaker: pickRoute: sent");
        return;
    }
    r2aLog(@"speaker: unavailable (routeController=%@ speakerRoute=%@)", rc, sp);
}

static BOOL silenceRinger(void) {
    id c = callCenter();
    id call = incomingCall();
    for (NSString *n in @[@"silenceRingtone", @"stopRingtone", @"stopRinging", @"muteRingtone"]) {
        if (has(c, n)) { send0(c, n); r2aLog(@"silence: center %@", n); return YES; }
        if (has(call, n)) { send0(call, n); r2aLog(@"silence: call %@", n); return YES; }
    }
    for (NSString *n in @[@"silenceRingtoneForCall:", @"silenceCall:", @"muteRingtoneForCall:"]) {
        SEL s = NSSelectorFromString(n);
        if (call && [c respondsToSelector:s]) { ((void (*)(id, SEL, id))objc_msgSend)(c, s, call); r2aLog(@"silence: center %@", n); return YES; }
    }
    r2aLog(@"silence: no known method (see candidate list in log)");
    return NO;
}

static void dumpCandidates(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    NSArray *kws = @[@"silenc", @"mute", @"ringtone", @"answer", @"speaker", @"route"];
    for (NSString *cn in @[@"TUCallCenter", @"TUCall", @"SBTelephonyManager", @"TURouteController"]) {
        Class c = NSClassFromString(cn);
        if (!c) { r2aLog(@"class %@ missing", cn); continue; }
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            NSString *s = NSStringFromSelector(method_getName(ms[i]));
            NSString *l = s.lowercaseString;
            for (NSString *k in kws) if ([l containsString:k]) { [hits addObject:s]; break; }
        }
        if (ms) free(ms);
        r2aLog(@"%@ methods: %@", cn, [hits componentsJoinedByString:@", "]);
    }
}

static CMMotionManager *mm;
static CTCallCenter *ctc;
static BOOL ringing, connected, answeredByRaise, armed, silencedThisRing, sawNotFaceDown;
static NSDate *lastMotion, *faceDownSince;
static NSTimer *answerTimer, *speakerTimer;

static void cancelTimers(void) {
    [answerTimer invalidate]; answerTimer = nil;
    [speakerTimer invalidate]; speakerTimer = nil;
}

static void handleMotion(CMDeviceMotion *m) {
    CMAcceleration u = m.userAcceleration;
    double mag = sqrt(u.x * u.x + u.y * u.y + u.z * u.z);
    if (mag > 0.2) lastMotion = [NSDate date];
    if (!ringing || silencedThisRing || !prefBool(CFSTR("flipSilence"), YES)) return;
    double gz = m.gravity.z;
    if (gz < 0.5) { sawNotFaceDown = YES; faceDownSince = nil; return; }
    if (gz > 0.85 && sawNotFaceDown) {
        if (!faceDownSince) faceDownSince = [NSDate date];
        else if (-[faceDownSince timeIntervalSinceNow] > 0.4) {
            silencedThisRing = YES;
            r2aLog(@"flip: face down detected, silencing");
            silenceRinger();
        }
    }
}

static void startSensors(void) {
    UIDevice *d = UIDevice.currentDevice;
    d.proximityMonitoringEnabled = YES;
    if (!mm) mm = [CMMotionManager new];
    if (!mm.deviceMotionActive) {
        mm.deviceMotionUpdateInterval = 0.05;
        [mm startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *m, NSError *e) {
            if (m) handleMotion(m);
        }];
    }
    r2aLog(@"sensors on (motion available=%d)", mm.deviceMotionAvailable);
}

static void stopSensors(void) {
    cancelTimers();
    [mm stopDeviceMotionUpdates];
    UIDevice.currentDevice.proximityMonitoringEnabled = NO;
    r2aLog(@"sensors off");
}

static void beginRinging(void) {
    if (ringing || connected) return;
    if (!prefBool(CFSTR("enabled"), YES)) return;
    ringing = YES; answeredByRaise = NO; silencedThisRing = NO; sawNotFaceDown = NO;
    lastMotion = nil; faceDownSince = nil;
    startSensors();
    armed = !UIDevice.currentDevice.proximityState;
    r2aLog(@"ringing started (proximity near at start=%d)", !armed);
    dumpCandidates();
}

static void endRinging(void) {
    if (!ringing) return;
    ringing = NO;
    cancelTimers();
    if (!(connected && answeredByRaise && prefBool(CFSTR("raiseSpeaker"), NO))) stopSensors();
    r2aLog(@"ringing ended");
}

static void onProximity(void) {
    BOOL near = UIDevice.currentDevice.proximityState;
    r2aLog(@"proximity near=%d ringing=%d connected=%d", near, ringing, connected);
    if (ringing) {
        if (!near) { [answerTimer invalidate]; answerTimer = nil; armed = YES; return; }
        if (!prefBool(CFSTR("raiseAnswer"), YES)) return;
        BOOL motionOK = lastMotion && (-[lastMotion timeIntervalSinceNow] < 2.5);
        if (prefBool(CFSTR("pocketProtect"), YES) && (!armed || !motionOK)) {
            r2aLog(@"pocket protection: ignored (armed=%d motionOK=%d)", armed, motionOK);
            return;
        }
        [answerTimer invalidate];
        double delay = prefDouble(CFSTR("delay"), 0.6);
        answerTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
            answerTimer = nil;
            if (ringing && UIDevice.currentDevice.proximityState) {
                r2aLog(@"raise: held near for %.2fs, answering", delay);
                if (answerCall()) answeredByRaise = YES;
            }
        }];
    } else if (connected && answeredByRaise && prefBool(CFSTR("raiseSpeaker"), NO)) {
        if (near) { [speakerTimer invalidate]; speakerTimer = nil; return; }
        [speakerTimer invalidate];
        speakerTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *t) {
            speakerTimer = nil;
            if (connected && !UIDevice.currentDevice.proximityState) {
                r2aLog(@"raise: moved away from ear, switching to speaker");
                setSpeaker();
                answeredByRaise = NO;
                stopSensors();
            }
        }];
    }
}

static void evaluateTU(void) {
    BOOL inc = incomingCall() != nil;
    if (inc && !ringing) beginRinging();
    else if (!inc && ringing && !connected) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (ringing && !connected && !incomingCall()) endRinging();
        });
    }
}

static void setup(void) {
    dlopen("/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities", RTLD_LAZY);
    r2aLog(@"loaded in SpringBoard, TUCallCenter=%@", callCenter() ? @"yes" : @"no");

    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceProximityStateDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { onProximity(); }];

    for (NSString *name in @[@"TUCallCenterCallStatusChangedNotification", @"TUCallStatusChangedNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { evaluateTU(); }];
    }

    ctc = [[CTCallCenter alloc] init];
    ctc.callEventHandler = ^(CTCall *call) {
        NSString *s = call.callState;
        dispatch_async(dispatch_get_main_queue(), ^{
            r2aLog(@"CT call state: %@", s);
            if ([s isEqualToString:CTCallStateIncoming]) {
                beginRinging();
            } else if ([s isEqualToString:CTCallStateConnected]) {
                connected = YES;
                if (ringing) endRinging();
            } else if ([s isEqualToString:CTCallStateDisconnected]) {
                connected = NO;
                if (ringing) endRinging();
                answeredByRaise = NO;
                stopSensors();
            }
        });
    };
}

%ctor {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ setup(); });
}
