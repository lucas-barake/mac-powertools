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
static NSString *const kVirtualDeviceUID = @"OBSMic_UID";

static NSString *gTargetBundleID;

typedef struct {
    AudioObjectID tapID;
    AudioObjectID aggregateID;
    AudioDeviceIOProcID ioProcID;
    BOOL running;
} RouterState;

static RouterState gState = {kAudioObjectUnknown, kAudioObjectUnknown, NULL, NO};

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
// Both are Float32; channel counts are matched buffer-by-buffer for safety.
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
        if (in->mNumberChannels == out->mNumberChannels) {
            memcpy(out->mData, in->mData, MIN(in->mDataByteSize, out->mDataByteSize));
        } else {
            UInt32 inFrames = in->mDataByteSize / (in->mNumberChannels * sizeof(Float32));
            UInt32 outFrames = out->mDataByteSize / (out->mNumberChannels * sizeof(Float32));
            UInt32 frames = MIN(inFrames, outFrames);
            UInt32 chans = MIN(in->mNumberChannels, out->mNumberChannels);
            const Float32 *src = in->mData;
            Float32 *dst = out->mData;
            for (UInt32 f = 0; f < frames; f++) {
                for (UInt32 c = 0; c < chans; c++) {
                    dst[f * out->mNumberChannels + c] = src[f * in->mNumberChannels + c];
                }
            }
        }
    }
    return noErr;
}

static AudioObjectID CopyProcessObjectForPID(pid_t pid) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectID processObject = kAudioObjectUnknown;
    UInt32 size = sizeof(processObject);
    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                              sizeof(pid), &pid, &size, &processObject);
    return (err == noErr) ? processObject : kAudioObjectUnknown;
}

static AudioObjectID CopyDeviceForUID(NSString *uid) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef cfUID = (__bridge CFStringRef)uid;
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                              sizeof(cfUID), &cfUID, &size, &deviceID);
    return (err == noErr) ? deviceID : kAudioObjectUnknown;
}

static NSString *CopyTapUID(AudioObjectID tapID) {
    AudioObjectPropertyAddress addr = {
        kAudioTapPropertyUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    OSStatus err = AudioObjectGetPropertyData(tapID, &addr, 0, NULL, &size, &uid);
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
        logmsg(@"virtual device %@ not found — is the OBSMic driver installed?", kVirtualDeviceUID);
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

    // The virtual device is the aggregate's clock master; the tap is
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

    gState.running = YES;
    logmsg(@"routing %@ (pid %d) -> OBS Mic", gTargetBundleID, obsPID);
    return YES;
}

static NSRunningApplication *FindOBS(void) {
    NSArray<NSRunningApplication *> *apps =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:gTargetBundleID];
    return apps.firstObject;
}

// coreaudiod learns about a process shortly after it starts doing audio,
// so retry translation with backoff instead of failing once.
static void TryBuildRouteWithRetries(pid_t pid, int attempt) {
    if (gState.running) return;
    NSRunningApplication *obs = FindOBS();
    if (obs == nil || obs.processIdentifier != pid) return;
    if (BuildRoute(pid)) return;
    if (attempt >= 30) {
        logmsg(@"giving up on pid %d after %d attempts", pid, attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        TryBuildRouteWithRetries(pid, attempt + 1);
    });
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
                logmsg(@"%@ launched (pid %d)", gTargetBundleID, app.processIdentifier);
                TryBuildRouteWithRetries(app.processIdentifier, 0);
            }
        }];
        [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if ([app.bundleIdentifier isEqualToString:gTargetBundleID]) {
                logmsg(@"%@ terminated, tearing down route", gTargetBundleID);
                TearDown();
            }
        }];

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
            TryBuildRouteWithRetries(obs.processIdentifier, 0);
        } else {
            logmsg(@"waiting for %@ to launch", gTargetBundleID);
        }

        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
