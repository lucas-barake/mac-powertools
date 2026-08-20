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
    }
    fprintf(stderr, gFailures ? "RESULT: %d failure(s)\n" : "RESULT: pass\n", gFailures);
    return gFailures ? 1 : 0;
}
