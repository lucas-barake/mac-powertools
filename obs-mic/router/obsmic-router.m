// obsmic-router: captures OBS Studio's output audio with a CoreAudio process tap
// and plays it into the "OBS Mic" virtual device, so any app can use OBS's
// processed audio as its microphone. No Audio MIDI Setup configuration needed.
//
// Requires macOS 14.2+ (process tap API) and the OBSMic HAL driver installed.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

static NSString *const kDefaultBundleID = @"com.obsproject.obs-studio";
static NSString *gTargetBundleID;
static NSString *const kVirtualDeviceUID = @"OBSMic_UID";

typedef struct {
    AudioObjectID tapID;
    AudioObjectID aggregateID;
    AudioDeviceIOProcID ioProcID;
    pid_t routedPID;
    BOOL running;
} RouterState;

static RouterState gState = {kAudioObjectUnknown, kAudioObjectUnknown, NULL, 0, NO};

// Bumped whenever a new retry chain should supersede any pending one, so a
// relaunch or coreaudiod reset never leaves two chains retrying the same pid.
static unsigned gRouteGeneration = 0;

// The virtual device contributes its own input streams to the aggregate ahead of
// the tap's, so the tap's buffers start after them in inInputData.
static UInt32 gTapInputOffset = 0;

static void logmsg(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    fprintf(stderr, "[obsmic-router] %s\n", msg.UTF8String);
}

// The tap arrives as input buffers, the virtual device as output buffers.
// Both sides are always 2-channel Float32: the tap is a stereo mixdown, and the
// OBSMic driver refuses any stream format whose channel count is not its own.
static OSStatus RouterIOProc(AudioObjectID inDevice,
                             const AudioTimeStamp *inNow,
                             const AudioBufferList *inInputData,
                             const AudioTimeStamp *inInputTime,
                             AudioBufferList *outOutputData,
                             const AudioTimeStamp *inOutputTime,
                             void *inClientData) {
    for (UInt32 i = 0; i < outOutputData->mNumberBuffers; i++) {
        AudioBuffer *out = &outOutputData->mBuffers[i];
        memset(out->mData, 0, out->mDataByteSize);
        UInt32 srcIndex = gTapInputOffset + i;
        if (inInputData == NULL || srcIndex >= inInputData->mNumberBuffers) continue;
        const AudioBuffer *in = &inInputData->mBuffers[srcIndex];
        memcpy(out->mData, in->mData, MIN(in->mDataByteSize, out->mDataByteSize));
    }
    return noErr;
}

// Every property the router reads is on the global scope and main element.
static OSStatus GetAudioProperty(AudioObjectID object,
                                 AudioObjectPropertySelector selector,
                                 UInt32 qualifierSize, const void *qualifier,
                                 UInt32 dataSize, void *outData) {
    AudioObjectPropertyAddress addr = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    return AudioObjectGetPropertyData(object, &addr, qualifierSize, qualifier,
                                      &dataSize, outData);
}

static AudioObjectID CopyProcessObjectForPID(pid_t pid) {
    AudioObjectID processObject = kAudioObjectUnknown;
    OSStatus err = GetAudioProperty(kAudioObjectSystemObject,
                                    kAudioHardwarePropertyTranslatePIDToProcessObject,
                                    sizeof(pid), &pid,
                                    sizeof(processObject), &processObject);
    return (err == noErr) ? processObject : kAudioObjectUnknown;
}

static AudioObjectID CopyDeviceForUID(NSString *uid) {
    CFStringRef cfUID = (__bridge CFStringRef)uid;
    AudioObjectID deviceID = kAudioObjectUnknown;
    OSStatus err = GetAudioProperty(kAudioObjectSystemObject,
                                    kAudioHardwarePropertyTranslateUIDToDevice,
                                    sizeof(cfUID), &cfUID,
                                    sizeof(deviceID), &deviceID);
    return (err == noErr) ? deviceID : kAudioObjectUnknown;
}

static NSString *CopyTapUID(AudioObjectID tapID) {
    CFStringRef uid = NULL;
    OSStatus err = GetAudioProperty(tapID, kAudioTapPropertyUID,
                                    0, NULL, sizeof(uid), &uid);
    return (err == noErr) ? (__bridge_transfer NSString *)uid : nil;
}

static void TearDown(void) {
    if (gState.aggregateID != kAudioObjectUnknown) {
        if (gState.ioProcID != NULL) {
            if (gState.running) AudioDeviceStop(gState.aggregateID, gState.ioProcID);
            AudioDeviceDestroyIOProcID(gState.aggregateID, gState.ioProcID);
            gState.ioProcID = NULL;
        }
        AudioHardwareDestroyAggregateDevice(gState.aggregateID);
        gState.aggregateID = kAudioObjectUnknown;
    }
    if (gState.tapID != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(gState.tapID);
        gState.tapID = kAudioObjectUnknown;
    }
    gState.routedPID = 0;
    gState.running = NO;
}

// A coreaudiod restart takes the tap and the aggregate with it and invalidates
// every object id we hold, so the ids are dropped instead of destroyed: they may
// already name something else.
static void ForgetRoute(void) {
    gState.tapID = kAudioObjectUnknown;
    gState.aggregateID = kAudioObjectUnknown;
    gState.ioProcID = NULL;
    gState.routedPID = 0;
    gState.running = NO;
}

static BOOL BuildRoute(pid_t obsPID) {
    AudioObjectID processObject = CopyProcessObjectForPID(obsPID);
    if (processObject == kAudioObjectUnknown) {
        logmsg(@"coreaudiod does not know pid %d yet", obsPID);
        return NO;
    }

    AudioObjectID virtualDevice = CopyDeviceForUID(kVirtualDeviceUID);
    if (virtualDevice == kAudioObjectUnknown) {
        logmsg(@"virtual device %@ not found. Is the OBSMic driver installed?", kVirtualDeviceUID);
        return NO;
    }

    AudioObjectPropertyAddress streamsAddr = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 streamsSize = 0;
    if (AudioObjectGetPropertyDataSize(virtualDevice, &streamsAddr, 0, NULL, &streamsSize) != noErr) {
        logmsg(@"could not read virtual device input streams");
        return NO;
    }
    gTapInputOffset = streamsSize / sizeof(AudioObjectID);

    CATapDescription *desc =
        [[CATapDescription alloc] initStereoMixdownOfProcesses:@[ @(processObject) ]];
    desc.name = @"OBS Mic Tap";
    desc.privateTap = YES;
    // Unmuted: OBS's own monitoring output keeps playing wherever the user points it.
    desc.muteBehavior = CATapUnmuted;

    AudioObjectID tapID = kAudioObjectUnknown;
    OSStatus err = AudioHardwareCreateProcessTap(desc, &tapID);
    if (err != noErr) {
        logmsg(@"AudioHardwareCreateProcessTap failed: %d (check System Audio Recording permission)", (int)err);
        return NO;
    }
    gState.tapID = tapID;

    NSString *tapUID = CopyTapUID(tapID);
    if (tapUID == nil) {
        logmsg(@"could not read tap UID");
        TearDown();
        return NO;
    }

    // The virtual device is the aggregate's clock master. The tap is
    // drift-compensated against it, so no clock skew can accumulate.
    NSDictionary *aggDesc = @{
        @kAudioAggregateDeviceUIDKey :
            [NSString stringWithFormat:@"dev.lucasbarake.obsmic.aggregate.%@",
                                       [NSUUID UUID].UUIDString],
        @kAudioAggregateDeviceNameKey : @"OBS Mic Router",
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceMainSubDeviceKey : kVirtualDeviceUID,
        @kAudioAggregateDeviceSubDeviceListKey : @[
            @{@kAudioSubDeviceUIDKey : kVirtualDeviceUID}
        ],
        @kAudioAggregateDeviceTapListKey : @[ @{
            @kAudioSubTapUIDKey : tapUID,
            @kAudioSubTapDriftCompensationKey : @YES,
        } ],
    };

    AudioObjectID aggregateID = kAudioObjectUnknown;
    err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &aggregateID);
    if (err != noErr) {
        logmsg(@"AudioHardwareCreateAggregateDevice failed: %d", (int)err);
        TearDown();
        return NO;
    }
    gState.aggregateID = aggregateID;

    err = AudioDeviceCreateIOProcID(aggregateID, RouterIOProc, NULL, &gState.ioProcID);
    if (err != noErr) {
        logmsg(@"AudioDeviceCreateIOProcID failed: %d", (int)err);
        TearDown();
        return NO;
    }

    err = AudioDeviceStart(aggregateID, gState.ioProcID);
    if (err != noErr) {
        logmsg(@"AudioDeviceStart failed: %d", (int)err);
        TearDown();
        return NO;
    }

    gState.routedPID = obsPID;
    gState.running = YES;
    logmsg(@"routing %@ (pid %d) -> OBS Mic", gTargetBundleID, obsPID);
    return YES;
}

static NSRunningApplication *FindOBS(void) {
    NSArray<NSRunningApplication *> *apps =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:gTargetBundleID];
    return apps.firstObject;
}

// coreaudiod learns about a process shortly after it starts doing audio, and
// the first tap creation can fail until the user answers the system audio
// permission prompt, so keep retrying for as long as the app is alive. The
// chain ends on its own once the pid is gone or a route is up.
static void RetryChain(pid_t pid, int attempt, unsigned generation) {
    if (generation != gRouteGeneration || gState.running) return;
    NSRunningApplication *obs = FindOBS();
    if (obs == nil || obs.processIdentifier != pid) return;
    if (BuildRoute(pid)) return;
    int delay = MIN(2 * (attempt + 1), 10);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        RetryChain(pid, attempt + 1, generation);
    });
}

static void StartRouteChain(pid_t pid) {
    RetryChain(pid, 0, ++gRouteGeneration);
}

static void HandleAppLaunched(pid_t pid) {
    logmsg(@"%@ launched (pid %d)", gTargetBundleID, pid);
    StartRouteChain(pid);
}

// A terminate notification can arrive after a relaunch has already been routed,
// so only the instance actually being routed may tear the route down.
static void HandleAppTerminated(pid_t pid) {
    if (!gState.running || gState.routedPID != pid) return;
    logmsg(@"%@ (pid %d) terminated, tearing down route", gTargetBundleID, pid);
    TearDown();
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gTargetBundleID = (argc > 1) ? @(argv[1]) : kDefaultBundleID;
        logmsg(@"starting, target app: %@", gTargetBundleID);

        NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
        [center addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if ([app.bundleIdentifier isEqualToString:gTargetBundleID]) {
                HandleAppLaunched(app.processIdentifier);
            }
        }];
        [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if ([app.bundleIdentifier isEqualToString:gTargetBundleID]) {
                HandleAppTerminated(app.processIdentifier);
            }
        }];

        // kAudioHardwarePropertyServiceRestarted: "any state the client has, such
        // as cached data or added listeners, must be re-established by the client."
        AudioObjectPropertyAddress restartAddr = {
            kAudioHardwarePropertyServiceRestarted,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        AudioObjectAddPropertyListenerBlock(
            kAudioObjectSystemObject, &restartAddr, dispatch_get_main_queue(),
            ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
                logmsg(@"coreaudiod restarted, rebuilding route");
                ForgetRoute();
                NSRunningApplication *running = FindOBS();
                if (running != nil) StartRouteChain(running.processIdentifier);
            });

        void (^shutdown)(void) = ^{
            logmsg(@"shutting down");
            TearDown();
            exit(0);
        };
        signal(SIGINT, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t sigint = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigint, shutdown);
        dispatch_resume(sigint);
        dispatch_source_t sigterm = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigterm, shutdown);
        dispatch_resume(sigterm);

        NSRunningApplication *obs = FindOBS();
        if (obs != nil) {
            logmsg(@"%@ already running (pid %d)", gTargetBundleID, obs.processIdentifier);
            StartRouteChain(obs.processIdentifier);
        } else {
            logmsg(@"waiting for %@ to launch", gTargetBundleID);
        }

        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
