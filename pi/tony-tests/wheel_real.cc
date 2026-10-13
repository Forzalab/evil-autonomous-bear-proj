// wheel_test: N steps on one wheel or both, with ramp + clean stop.
// build: g++ -O2 wheel_test.cc -o wheel_test -lwiringPi
// use:   ./wheel_test <1|2|both> <steps> <fwd|back> [fast_delay_us=2000]
// SAFETY: bear OFF cart, wheels in air, hand on 12 V switch. Plug motors only with 12 V OFF.
#include <wiringPi.h>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>

const int STEP[2] = {13, 16}, DIR[2] = {26, 21};   // BCM, real wiring 2026-10-13: wheel1 STEP13/DIR26, wheel2 STEP16/DIR21
volatile sig_atomic_t stop = 0;

void idle() { for (int i = 0; i < 2; ++i) { digitalWrite(STEP[i], LOW); pinMode(STEP[i], INPUT); pinMode(DIR[i], INPUT); } }
void on_sig(int) { stop = 1; }

int main(int argc, char** argv) {
    if (argc < 4) { fprintf(stderr, "use: %s <1|2|both> <steps> <fwd|back> [fast_delay_us]\n", argv[0]); return 1; }
    bool use[2] = { !strcmp(argv[1], "1") || !strcmp(argv[1], "both"), !strcmp(argv[1], "2") || !strcmp(argv[1], "both") };
    int steps = atoi(argv[2]);
    bool fwd = !strcmp(argv[3], "fwd");
    int fast = argc > 4 ? atoi(argv[4]) : 2000, slow = fast * 4, ramp = steps / 4;
    if ((!use[0] && !use[1]) || steps <= 0 || fast < 500) { fprintf(stderr, "bad args: wheel 1|2|both, steps > 0, fast_delay_us >= 500\n"); return 1; }

    if (wiringPiSetupGpio() < 0) { fprintf(stderr, "wiringPi setup failed\n"); return 1; }
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    for (int i = 0; i < 2; ++i) if (use[i]) {
        pinMode(STEP[i], OUTPUT); pinMode(DIR[i], OUTPUT); digitalWrite(STEP[i], LOW);
        digitalWrite(DIR[i], (fwd ^ (i == 1)) ? HIGH : LOW);   // motors mirrored: DIR2 = !DIR1
    }
    printf("wheel %s, %d steps, %s, %d..%d us\n", argv[1], steps, argv[3], slow, fast);
    for (int s = 0; s < steps && !stop; ++s) {
        int edge = s < ramp ? s : (steps - 1 - s < ramp ? steps - 1 - s : ramp);   // distance from nearest end
        int d = ramp ? slow - (slow - fast) * edge / ramp : fast;                  // linear ramp
        for (int i = 0; i < 2; ++i) if (use[i]) digitalWrite(STEP[i], HIGH);
        delayMicroseconds(d);
        for (int i = 0; i < 2; ++i) if (use[i]) digitalWrite(STEP[i], LOW);
        delayMicroseconds(d);
    }
    idle();
    printf(stop ? "STOPPED (Ctrl-C), pins idle\n" : "done, pins idle\n");
}
