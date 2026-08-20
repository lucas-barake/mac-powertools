// Drives the router's app launch/terminate state machine directly. Only the
// NSWorkspace notification source is stood in for; gState, TearDown and the
// handlers are the production ones, included verbatim.
#define main obsmic_router_main
#include "../router/obsmic-router.m"
#undef main

static int gFailures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); gFailures++; } \
    else fprintf(stderr, "ok:   %s\n", msg); } while (0)

int main(void) {
    @autoreleasepool {
        // A route is live for OBS instance pid 4242. The object ids stay unknown
        // so TearDown touches no real CoreAudio object.
        gState.tapID = kAudioObjectUnknown;
        gState.aggregateID = kAudioObjectUnknown;
        gState.ioProcID = NULL;
        gState.routedPID = 4242;
        gState.running = YES;

        // A terminate notification for an earlier instance that is already gone.
        HandleAppTerminated(1111);
        CHECK(gState.running == YES,
              "terminate of unrouted pid 1111 leaves the route for pid 4242 up");

        HandleAppTerminated(4242);
        CHECK(gState.running == NO,
              "terminate of the routed pid 4242 tears the route down");

        // A HAL reset invalidates every cached id, so the route is dropped, not
        // destroyed through ids that may now name something else.
        gState.tapID = 4;
        gState.aggregateID = 5;
        gState.routedPID = 4242;
        gState.running = YES;
        ForgetRoute();
        CHECK(gState.running == NO && gState.tapID == kAudioObjectUnknown
                  && gState.aggregateID == kAudioObjectUnknown && gState.routedPID == 0,
              "ForgetRoute drops all cached CoreAudio state");

        // Output gain comes from a shared preference; anything unusable means unity.
        CFStringRef domain = CFSTR("dev.lucasbarake.obsmic.tests");
        CFStringRef key = (__bridge CFStringRef)kOutputGainKey;
        CFPreferencesSetAppValue(key, NULL, domain);
        CFPreferencesAppSynchronize(domain);
        CHECK(LoadOutputGain(domain) == 1.0f, "missing gain preference reads as 100%");

        float want = 2.5f;
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloatType, &want);
        CFPreferencesSetAppValue(key, n, domain);
        CFPreferencesAppSynchronize(domain);
        CFRelease(n);
        CHECK(LoadOutputGain(domain) == 2.5f, "stored gain 2.5 reads back as 250%");

        float tooLoud = 40.0f;
        n = CFNumberCreate(NULL, kCFNumberFloatType, &tooLoud);
        CFPreferencesSetAppValue(key, n, domain);
        CFPreferencesAppSynchronize(domain);
        CFRelease(n);
        CHECK(LoadOutputGain(domain) == 1.0f, "out of range gain falls back to 100%");

        CFPreferencesSetAppValue(key, CFSTR("loud"), domain);
        CFPreferencesAppSynchronize(domain);
        CHECK(LoadOutputGain(domain) == 1.0f, "non-numeric gain falls back to 100%");

        // Gain is applied in the IO callback on top of the plain copy.
        Float32 inSamples[4] = {0.1f, -0.2f, 0.3f, -0.4f};
        Float32 outSamples[4] = {9, 9, 9, 9};
        AudioBufferList inList = {1, {{2, sizeof(inSamples), inSamples}}};
        AudioBufferList outList = {1, {{2, sizeof(outSamples), outSamples}}};
        gTapInputOffset = 0;
        atomic_store(&gOutputGain, 2.0f);
        RouterIOProc(0, NULL, &inList, NULL, &outList, NULL, NULL);
        CHECK(outSamples[0] == 0.2f && outSamples[1] == -0.4f
                  && outSamples[2] == 0.6f && outSamples[3] == -0.8f,
              "IOProc scales copied samples by the output gain");
        atomic_store(&gOutputGain, 1.0f);
        RouterIOProc(0, NULL, &inList, NULL, &outList, NULL, NULL);
        CHECK(outSamples[3] == -0.4f, "unity gain copies samples unchanged");

        CFPreferencesSetAppValue(key, NULL, domain);
        CFPreferencesAppSynchronize(domain);
    }
    fprintf(stderr, gFailures ? "RESULT: %d failure(s)\n" : "RESULT: pass\n", gFailures);
    return gFailures ? 1 : 0;
}
