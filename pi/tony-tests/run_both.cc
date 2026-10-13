// run_both: spin both wheels together, continuously, for N seconds (same waveform as step_pin: short ramp, then steady).
// build: g++ -O2 run_both.cc -o run_both -lwiringPi      use: ./run_both [seconds=40] [half_period_us=800] [fwd|back]
// Real wiring 2026-10-13: wheel1 STEP13/DIR26, wheel2 STEP16/DIR21. Ctrl-C stops cleanly, pins go back to input.
#include <wiringPi.h>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>

const int STEP[2] = {13, 16}, DIR[2] = {26, 21};
volatile sig_atomic_t stop = 0;
void on_sig(int) { stop = 1; }

int main(int argc, char** argv) {
    double secs = argc > 1 ? atof(argv[1]) : 40;
    int half = argc > 2 ? atoi(argv[2]) : 800;
    bool fwd = argc > 3 ? strcmp(argv[3], "back") != 0 : true;
    if (secs <= 0 || secs > 120 || half < 300 || half > 20000) { fprintf(stderr, "use: %s [seconds 0-120] [half_us 300-20000] [fwd|back]\n", argv[0]); return 1; }
    if (wiringPiSetupGpio() < 0) { fprintf(stderr, "wiringPi setup failed\n"); return 1; }
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    for (int i = 0; i < 2; ++i) {
        pinMode(STEP[i], OUTPUT); digitalWrite(STEP[i], LOW);
        pinMode(DIR[i], OUTPUT); digitalWrite(DIR[i], (fwd ^ (i == 1)) ? HIGH : LOW);   // mirrored motors → same travel direction
    }
    delayMicroseconds(1000);
    unsigned int start = millis(), limit = (unsigned int)(secs * 1000);
    long steps = 0;
    while (!stop && millis() - start < limit) {
        int d = steps < 50 ? half * 4 : half;   // 50-step soft start, then steady (the burst that works)
        digitalWrite(STEP[0], HIGH); digitalWrite(STEP[1], HIGH); delayMicroseconds(d);
        digitalWrite(STEP[0], LOW);  digitalWrite(STEP[1], LOW);  delayMicroseconds(d);
        ++steps;
    }
    for (int i = 0; i < 2; ++i) { digitalWrite(STEP[i], LOW); pinMode(STEP[i], INPUT); pinMode(DIR[i], INPUT); }
    printf("run_both: %ld steps in %.1f s, %s%s, pins idle\n", steps, (millis() - start) / 1000.0, fwd ? "fwd" : "back", stop ? " (STOPPED)" : "");
}
