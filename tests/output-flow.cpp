#include "../native/OutputFlow.hpp"
#include <cstdio>

int main() {
    uint64_t blockedAt = 0;
    const auto expect = [&](bool blocked, uint64_t now, bool expected, uint64_t expectedStart) {
        const bool actual = outputFlow::expired(blockedAt, blocked, now);
        if (actual == expected && blockedAt == expectedStart) return true;
        std::fprintf(stderr, "FAIL output flow at %llu: expired=%d, start=%llu\n",
            static_cast<unsigned long long>(now), actual,
            static_cast<unsigned long long>(blockedAt));
        return false;
    };
    bool passed = true;
    passed &= expect(false, 100, false, 0);
    passed &= expect(false, 500, false, 0);
    passed &= expect(true, 600, false, 600);
    passed &= expect(true, 900, false, 600);
    passed &= expect(false, 950, false, 0);
    passed &= expect(true, 1000, false, 1000);
    passed &= expect(true, 2999, false, 1000);
    passed &= expect(true, 3000, true, 1000);
    passed &= expect(false, 3010, false, 0);
    passed &= expect(true, 4000, false, 4000);
    passed &= expect(false, 4100, false, 0);
    passed &= expect(false, 10000, false, 0);
    if (!passed) return 1;
    std::puts("PASS: input delays do not trigger write timeout; transient backlog recovers; persistent backlog expires at 2000 ms");
    return 0;
}
