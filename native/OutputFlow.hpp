#pragma once
#include <cstdint>

namespace outputFlow {
inline constexpr uint64_t timeoutMs = 2000;

inline bool expired(uint64_t &blockedAt, bool blocked, uint64_t now) {
    if (!blocked) {
        blockedAt = 0;
        return false;
    }
    if (!blockedAt) blockedAt = now;
    return now - blockedAt >= timeoutMs;
}
}
