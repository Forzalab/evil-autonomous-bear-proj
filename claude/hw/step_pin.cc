// step_pin: square wave on one BCM pin (stepper STEP hunt), optional DIR pin held first.
// build: g++ -O2 step_pin.cc -o step_pin -lwiringPi
// use:   step_pin <bcm> <pulses> <half_period_us> [dir_bcm dir_level]
// Refuses BCM 0, 1 (ID EEPROM) and 2 (relay SIG: LOW makes the bear dance). Exit 2.
// First 50 pulses at 4x half period (gentle ramp). All used pins -> INPUT at the end / on SIGINT/SIGTERM.
#include <wiringPi.h>
#include <csignal>
#include <cstdio>
#include <cstdlib>

volatile sig_atomic_t stop = 0;
void on_sig(int) { stop = 1; }
bool bad(int p) { return p <= 2 || p > 27; }

int main(int argc, char** argv) {
    if (argc != 4 && argc != 6) { fprintf(stderr, "use: %s <bcm> <pulses> <half_period_us> [dir_bcm dir_level]\n", argv[0]); return 1; }
    int pin = atoi(argv[1]), pulses = atoi(argv[2]), half = atoi(argv[3]);
    int dir = argc == 6 ? atoi(argv[4]) : -1, lvl = argc == 6 ? atoi(argv[5]) : 0;
    if (bad(pin) || (dir >= 0 && (bad(dir) || dir == pin))) { fprintf(stderr, "refused: pins must be BCM 3..27 (never 0, 1, 2), dir != step\n"); return 2; }
    if (pulses <= 0 || pulses > 5000 || half < 100 || half > 20000) { fprintf(stderr, "bad args: pulses 1..5000, half_period_us 100..20000\n"); return 1; }
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    if (wiringPiSetupGpio() < 0) { fprintf(stderr, "wiringPi setup failed\n"); return 1; }
    if (dir >= 0) { pinMode(dir, OUTPUT); digitalWrite(dir, lvl ? HIGH : LOW); delayMicroseconds(1000); }
    pinMode(pin, OUTPUT); digitalWrite(pin, LOW);
    int done = 0;
    for (; done < pulses && !stop; ++done) {
        int d = done < 50 ? half * 4 : half;
        digitalWrite(pin, HIGH); delayMicroseconds(d);
        digitalWrite(pin, LOW);  delayMicroseconds(d);
    }
    digitalWrite(pin, LOW); pinMode(pin, INPUT);
    if (dir >= 0) { digitalWrite(dir, LOW); pinMode(dir, INPUT); }
    printf("step_pin: bcm %d, %d/%d pulses, half %d us%s%s\n", pin, done, pulses, half,
           dir >= 0 ? (lvl ? ", dir HIGH" : ", dir LOW") : "", stop ? " (STOPPED by signal)" : "");
    return stop ? 130 : 0;
}
