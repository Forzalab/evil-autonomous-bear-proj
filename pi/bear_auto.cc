// bear_auto: autonomous bear on the Pi 5. USB webcam (raw V4L2, YUYV) watches for motion;
// sustained motion = "PERSON" → relay pulse on BCM17 (Try Me dance) + short wheel wiggle, then cooldown.
// build: g++ -O2 -std=c++17 pi/bear_auto.cc -o pi/bear_auto -lwiringPi
// use:   ./pi/bear_auto --selftest            camera, relay, wheels one by one (exit code = failed steps)
//        ./pi/bear_auto                       autonomous loop (Ctrl-C to stop)
// flags: --pulse-ms N (300)  --cooldown S (25)  --motion F (0.04)  --no-wheels  --no-relay
//        --device PATH (/dev/video0)  --fake-cam (synthetic frames, moving square from frame 30)
// SAFETY: wheels in air for tests, hand on 12 V switch. Try Me ignores re-trigger for ~22 s.
#include <wiringPi.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <initializer_list>
#include <vector>

const int STEP[2] = {13, 20}, DIR[2] = {26, 21}, RELAY = 17;   // BCM
const int DELAY_US = 1500, W = 320, H = 240, DIFF = 25, STREAK = 3;
volatile sig_atomic_t stop = 0;
void on_sig(int) { stop = 1; }

struct Opts { int pulse_ms = 300; double cooldown = 25, motion = 0.04; bool wheels = true, relay = true, fake = false, selftest = false;
              const char* dev = "/dev/video0"; } opt;
bool gpio_ok = false;

// ---------- GPIO ----------
void pins_idle() {   // always: everything LOW, then INPUT
    if (!gpio_ok) return;
    const int pins[] = {RELAY, STEP[0], STEP[1], DIR[0], DIR[1]};
    for (int p : pins) digitalWrite(p, LOW);
    for (int p : pins) pinMode(p, INPUT);
}
bool gpio_init() {
    if (wiringPiSetupGpio() < 0) { fprintf(stderr, "wiringPi setup failed\n"); return false; }
    gpio_ok = true;
    const int pins[] = {RELAY, STEP[0], STEP[1], DIR[0], DIR[1]};
    for (int p : pins) { pinMode(p, OUTPUT); digitalWrite(p, LOW); }
    return true;
}
void pulse_relay(int ms) { digitalWrite(RELAY, HIGH); delay(ms); digitalWrite(RELAY, LOW); }   // HIGH then LOW covers either edge
// steps on chosen wheels; fwd = DIR1 HIGH, DIR2 LOW (mirrored motors → same travel direction)
void spin(bool w1, bool w2, int steps, bool fwd) {
    digitalWrite(DIR[0], fwd ? HIGH : LOW); digitalWrite(DIR[1], fwd ? LOW : HIGH);
    for (int s = 0; s < steps && !stop; ++s) {
        for (int lv : {HIGH, LOW}) {
            if (w1) { digitalWrite(STEP[0], lv); }
            if (w2) { digitalWrite(STEP[1], lv); }
            delayMicroseconds(DELAY_US);
        }
    }
}

// ---------- camera (V4L2 mmap, YUYV → Y) or synthetic ----------
struct Cam {
    int fd = -1, w = W, h = H, bpl = W * 2; long n = 0; bool fake = false;
    std::vector<void*> buf; std::vector<size_t> len;

    bool open_dev(const char* path, bool fk) {
        fake = fk; if (fake) return true;
        fd = ::open(path, O_RDWR | O_NONBLOCK);
        if (fd < 0) { fprintf(stderr, "camera: open %s: %s\n", path, strerror(errno)); return false; }
        v4l2_format f{}; f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        f.fmt.pix.width = W; f.fmt.pix.height = H; f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV; f.fmt.pix.field = V4L2_FIELD_ANY;
        if (ioctl(fd, VIDIOC_S_FMT, &f) < 0) return fail("VIDIOC_S_FMT");
        if (f.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) { fprintf(stderr, "camera: no YUYV support\n"); return false; }
        w = f.fmt.pix.width; h = f.fmt.pix.height; bpl = f.fmt.pix.bytesperline ? (int)f.fmt.pix.bytesperline : w * 2;
        v4l2_requestbuffers rb{}; rb.count = 4; rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; rb.memory = V4L2_MEMORY_MMAP;
        if (ioctl(fd, VIDIOC_REQBUFS, &rb) < 0 || rb.count < 1) return fail("VIDIOC_REQBUFS");
        for (unsigned i = 0; i < rb.count; ++i) {
            v4l2_buffer b{}; b.type = rb.type; b.memory = V4L2_MEMORY_MMAP; b.index = i;
            if (ioctl(fd, VIDIOC_QUERYBUF, &b) < 0) return fail("VIDIOC_QUERYBUF");
            void* p = mmap(nullptr, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
            if (p == MAP_FAILED) return fail("mmap");
            buf.push_back(p); len.push_back(b.length);
            if (ioctl(fd, VIDIOC_QBUF, &b) < 0) return fail("VIDIOC_QBUF");
        }
        v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (ioctl(fd, VIDIOC_STREAMON, &t) < 0) return fail("VIDIOC_STREAMON");
        return true;
    }
    bool fail(const char* what) { fprintf(stderr, "camera: %s: %s\n", what, strerror(errno)); return false; }

    bool grab(std::vector<unsigned char>& y) {   // grayscale w*h
        y.resize((size_t)w * h);
        if (fake) {                               // static gradient; from frame 30 a bright 120px square moves 24 px/frame
            for (int r = 0; r < h; ++r) for (int c = 0; c < w; ++c) y[r * w + c] = (unsigned char)(60 + (r + c) / 8);
            if (n >= 30) { int x0 = (int)((n - 30) * 24 % (w - 120)), y0 = (h - 120) / 2;
                for (int r = y0; r < y0 + 120; ++r) for (int c = x0; c < x0 + 120; ++c) y[r * w + c] = 240; }
            ++n; usleep(10000); return true;
        }
        fd_set fs; FD_ZERO(&fs); FD_SET(fd, &fs); timeval tv{2, 0};
        int r = select(fd + 1, &fs, nullptr, nullptr, &tv);
        if (r <= 0) { if (r == 0) fprintf(stderr, "camera: timeout\n"); return false; }
        v4l2_buffer b{}; b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP;
        if (ioctl(fd, VIDIOC_DQBUF, &b) < 0) return errno == EAGAIN ? grab(y) : fail("VIDIOC_DQBUF");
        const unsigned char* src = (const unsigned char*)buf[b.index];
        for (int r2 = 0; r2 < h; ++r2) for (int c = 0; c < w; ++c) y[r2 * w + c] = src[r2 * bpl + 2 * c];   // Y0 U Y1 V
        ioctl(fd, VIDIOC_QBUF, &b); ++n;
        return true;
    }
    void close_dev() {
        if (fd < 0) return;
        v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE; ioctl(fd, VIDIOC_STREAMOFF, &t);
        for (size_t i = 0; i < buf.size(); ++i) munmap(buf[i], len[i]);
        ::close(fd); fd = -1;
    }
};

double now_s() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
const char* stamp() {
    static char s[32]; timespec t; clock_gettime(CLOCK_REALTIME, &t); tm lt; localtime_r(&t.tv_sec, &lt);
    size_t k = strftime(s, sizeof s, "%Y-%m-%d %H:%M:%S", &lt); snprintf(s + k, sizeof s - k, ".%03ld", t.tv_nsec / 1000000);
    return s;
}
void banner(const char* s) { printf("\n==================================================\n=== %s\n==================================================\n", s); fflush(stdout); }
int result(const char* name, bool ok) { printf(">>> %s: %s\n", name, ok ? "PASS" : "FAIL"); fflush(stdout); return ok ? 0 : 1; }

// ---------- modes ----------
int selftest() {
    int failed = 0;
    banner("STEP 1/3: CAMERA");
    {
        Cam cam; bool ok = false;
        if (opt.fake) puts("(fake camera)"); else printf("device %s\n", opt.dev);
        fflush(stdout);
        if (cam.open_dev(opt.dev, opt.fake)) {
            std::vector<unsigned char> y; int got = 0; double mean = 0;
            for (int i = 0; i < 5 && !stop; ++i) if (cam.grab(y)) {
                ++got; long sum = 0; for (unsigned char v : y) sum += v; mean = (double)sum / y.size();
            }
            printf("frames %d/5, %dx%d, mean brightness %.1f\n", got, cam.w, cam.h, mean);
            ok = got == 5;
        }
        cam.close_dev();
        failed += result("CAMERA", ok);
    }
    bool gpio = (opt.relay || opt.wheels) && gpio_init();
    banner("STEP 2/3: RELAY (BCM17)");
    if (!opt.relay) puts(">>> RELAY: SKIPPED (--no-relay)");
    else {
        if (gpio) printf("pulse %d ms\n", opt.pulse_ms), pulse_relay(opt.pulse_ms);
        failed += result("RELAY", gpio && !stop);
    }
    banner("STEP 3/3: WHEELS (STEP 13/20, DIR 26/21)");
    if (!opt.wheels) puts(">>> WHEELS: SKIPPED (--no-wheels)");
    else {
        if (gpio) {
            puts("wheel 1 fwd 200"); spin(true, false, 200, true);
            puts("wheel 2 fwd 200"); spin(false, true, 200, true);
            puts("both back 200");   spin(true, true, 200, false);
        }
        failed += result("WHEELS", gpio && !stop);
    }
    pins_idle();
    printf("\nselftest done: %d failed, pins idle\n", failed);
    return failed;
}

int autonomous() {
    if ((opt.relay || opt.wheels) && !gpio_init()) return 1;
    Cam cam;
    if (!cam.open_dev(opt.dev, opt.fake)) { cam.close_dev(); pins_idle(); return 1; }
    printf("%s watching %s %dx%d  motion>%.3f x%d frames  cooldown %.0fs  relay %s  wheels %s\n", stamp(),
           opt.fake ? "fake-cam" : opt.dev, cam.w, cam.h, opt.motion, STREAK, opt.cooldown, opt.relay ? "on" : "off", opt.wheels ? "on" : "off");
    fflush(stdout);
    std::vector<unsigned char> cur, prev;
    int streak = 0, rc = 0; double quiet_until = 0;
    while (!stop) {
        if (!cam.grab(cur)) { if (!stop) { fprintf(stderr, "camera: grab failed\n"); rc = 1; } break; }
        if (prev.size() == cur.size()) {
            long moved = 0;
            for (size_t i = 0; i < cur.size(); ++i) moved += abs((int)cur[i] - (int)prev[i]) > DIFF;
            double frac = (double)moved / cur.size();
            streak = frac > opt.motion ? streak + 1 : 0;
            if (streak >= STREAK && now_s() >= quiet_until) {
                printf("%s PERSON motion=%.3f -> %s%s\n", stamp(), frac, opt.relay ? "dance " : "", opt.wheels ? "wiggle" : "");
                fflush(stdout);
                if (opt.relay) pulse_relay(opt.pulse_ms);
                if (opt.wheels) { spin(true, true, 100, true); spin(true, true, 100, false); }
                quiet_until = now_s() + opt.cooldown; streak = 0;
            }
        }
        prev.swap(cur);
    }
    cam.close_dev(); pins_idle();
    printf("%s stopped, pins idle\n", stamp());
    return rc;
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        const char* a = argv[i]; bool more = i + 1 < argc;
        if (!strcmp(a, "--selftest")) opt.selftest = true;
        else if (!strcmp(a, "--fake-cam")) opt.fake = true;
        else if (!strcmp(a, "--no-wheels")) opt.wheels = false;
        else if (!strcmp(a, "--no-relay")) opt.relay = false;
        else if (!strcmp(a, "--pulse-ms") && more) opt.pulse_ms = atoi(argv[++i]);
        else if (!strcmp(a, "--cooldown") && more) opt.cooldown = atof(argv[++i]);
        else if (!strcmp(a, "--motion") && more) opt.motion = atof(argv[++i]);
        else if (!strcmp(a, "--device") && more) opt.dev = argv[++i];
        else { fprintf(stderr, "use: %s [--selftest] [--fake-cam] [--pulse-ms N] [--cooldown S] [--motion F]"
                               " [--no-wheels] [--no-relay] [--device PATH]\n", argv[0]); return 2; }
    }
    if (opt.pulse_ms <= 0) opt.pulse_ms = 300;
    struct sigaction sa{}; sa.sa_handler = on_sig;   // no SA_RESTART: select() returns EINTR on Ctrl-C
    sigaction(SIGINT, &sa, nullptr); sigaction(SIGTERM, &sa, nullptr);
    return opt.selftest ? selftest() : autonomous();
}
