#pragma once
#include <algorithm>
#include <cstdint>

namespace latencyFlow {
constexpr unsigned frameBudget = 2;
constexpr unsigned inputBatchLimit = 32;
constexpr uint64_t inputBudgetMs = 2;
constexpr uint32_t blockedBit = 4;

inline uint32_t capturePressure(unsigned queued, bool blocked) {
    return std::min(queued, frameBudget) | (blocked ? blockedBit : 0);
}
inline bool admitCapture(unsigned inFlight, uint32_t pressure) {
    return !(pressure & blockedBit) && inFlight < frameBudget &&
        inFlight + (pressure & ~blockedBit) < frameBudget;
}
inline bool continueInput(unsigned processed, uint64_t started, uint64_t now, bool more) {
    return more && processed < inputBatchLimit && now - started < inputBudgetMs;
}
inline bool handshakeExpired(bool connected, bool negotiated, uint64_t accepted, uint64_t now) {
    return connected && !negotiated && now - accepted > 30000;
}
struct PendingMove {
    bool pending;
    uint16_t x, y;
    bool stage(uint16_t nextX, uint16_t nextY) {
        bool replaced = pending;
        pending = true; x = nextX; y = nextY;
        return replaced;
    }
    bool take(uint16_t &nextX, uint16_t &nextY) {
        if (!pending) return false;
        pending = false; nextX = x; nextY = y;
        return true;
    }
};
}
