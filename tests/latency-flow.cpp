#include "../native/LatencyFlow.hpp"
#include <cstdio>

int main() {
    bool passed = true;
    const auto expect = [&](bool condition, const char *name) {
        if (!condition) { std::fprintf(stderr, "FAIL latency flow: %s\n", name); passed = false; }
    };
    using namespace latencyFlow;
    for (unsigned inFlight = 0; inFlight <= 2; ++inFlight) {
        for (unsigned queued = 0; queued <= 2; ++queued) {
            expect(admitCapture(inFlight, capturePressure(queued, false)) == (inFlight + queued < 2),
                "combined capture and encoded-frame budget");
            expect(!admitCapture(inFlight, capturePressure(queued, true)), "network/ACK backpressure");
        }
    }
    expect(admitCapture(0, capturePressure(0, false)), "capture recovers after pressure clears");
    expect(continueInput(31, 100, 101, true), "input packet allowance");
    expect(!continueInput(32, 100, 101, true), "bounded input packet count");
    expect(!continueInput(1, 100, 102, true), "input time budget boundary");
    expect(!continueInput(1, 100, 101, false), "no queued input");
    expect(!handshakeExpired(true, false, 100, 30100), "handshake deadline boundary");
    expect(handshakeExpired(true, false, 100, 30101), "uncompleted handshake expires");
    expect(!handshakeExpired(true, true, 100, 90100), "negotiated session survives long output pause");
    expect(!handshakeExpired(false, false, 100, 90100), "disconnected session is not timed out");
    PendingMove move{};
    uint16_t x = 0, y = 0;
    expect(!move.stage(10, 20), "first move kept");
    expect(move.stage(11, 21), "only adjacent old move replaced");
    expect(move.take(x, y) && x == 11 && y == 21, "latest move flushed before a button/key boundary");
    expect(!move.take(x, y), "move is consumed once");
    expect(!move.stage(12, 22), "new batch starts without a stale move");
    move.pending = false;
    expect(!move.take(x, y), "pause/epoch change clears pending input");
    if (!passed) return 1;
    std::puts("PASS: two-frame combined budget, pressure recovery, input fairness, move boundaries and paused-session handshake");
    return 0;
}
