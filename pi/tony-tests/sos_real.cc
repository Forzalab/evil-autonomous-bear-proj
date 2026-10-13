// sos: bear dances (relay BCM17) + both wheels spin SOS in morse (... --- ...).
// build: g++ -O2 sos.cc -o sos -lwiringPi      run: ./sos
// SAFETY: bear OFF cart, wheels in air, hand on 12 V switch.
#include <wiringPi.h>
#include <csignal>
#include <cstdio>

const int STEP[2] = {13, 16}, DIR[2] = {26, 21}, RELAY = 17;   // real wiring 2026-10-13 (relay pin 17 unused now; bear SIG is on SDA1)   // BCM
const int DELAY_US = 1500, DOT = 60, DASH = 180;                // steps per symbol
volatile sig_atomic_t stop = 0;
void on_sig(int) { stop = 1; }

void spin(int steps) {
    for (int s = 0; s < steps && !stop; ++s) {
        digitalWrite(STEP[0], HIGH); digitalWrite(STEP[1], HIGH); delayMicroseconds(DELAY_US);
        digitalWrite(STEP[0], LOW);  digitalWrite(STEP[1], LOW);  delayMicroseconds(DELAY_US);
    }
}

int main() {
    if (wiringPiSetupGpio() < 0) { fprintf(stderr, "wiringPi setup failed\n"); return 1; }
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    for (int i = 0; i < 2; ++i) { pinMode(STEP[i], OUTPUT); pinMode(DIR[i], OUTPUT); digitalWrite(STEP[i], LOW); }
    digitalWrite(DIR[0], HIGH); digitalWrite(DIR[1], LOW);      // mirrored motors → same travel direction
    pinMode(RELAY, OUTPUT);

    puts("DANCE!");                                              // one pulse: HIGH then LOW covers either edge
    digitalWrite(RELAY, HIGH); delay(300); digitalWrite(RELAY, LOW);

    const char* sos = "...---...";
    for (int i = 0; sos[i] && !stop; ++i) {
        putchar(sos[i]); fflush(stdout);
        spin(sos[i] == '.' ? DOT : DASH);
        delay((i % 3 == 2) ? 600 : 200);                         // letter gap after every 3 symbols
    }
    for (int i = 0; i < 2; ++i) { digitalWrite(STEP[i], LOW); pinMode(STEP[i], INPUT); pinMode(DIR[i], INPUT); }
    digitalWrite(RELAY, LOW); pinMode(RELAY, INPUT);
    puts(stop ? "\nSTOPPED, pins idle" : "\nSOS done, pins idle");
}
