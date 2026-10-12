// dance: one relay pulse on BCM17 makes the bear dance once.
// build: g++ -O2 pi/dance.cc -o pi/dance -lwiringPi      run: ./pi/dance [ms]   (default 300)
#include <wiringPi.h>
#include <cstdio>
#include <cstdlib>

const int RELAY = 17;   // BCM

int main(int argc, char** argv) {
    int ms = argc > 1 ? atoi(argv[1]) : 0;
    if (ms <= 0) ms = 300;
    if (wiringPiSetupGpio() < 0) { fprintf(stderr, "wiringPi setup failed\n"); return 1; }
    pinMode(RELAY, OUTPUT);
    digitalWrite(RELAY, HIGH); delay(ms); digitalWrite(RELAY, LOW);   // HIGH then LOW covers either edge
    pinMode(RELAY, INPUT);
    return 0;
}
