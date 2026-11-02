#pragma once
#include <bitset>
#include <cstddef>
#include <cstdint>
#include <string>

namespace inputFlow {
constexpr size_t maxTextBytes = 1024 * 1024;
constexpr uint64_t clipboardTimeoutMs = 3000;

inline bool high(uint16_t c) { return c >= 0xd800 && c <= 0xdbff; }
inline bool low(uint16_t c) { return c >= 0xdc00 && c <= 0xdfff; }
inline bool validText(const std::u16string &text) {
    if (text.size() > maxTextBytes / 2) return false;
    for (size_t i = 0; i < text.size(); ++i) {
        uint16_t c = text[i];
        if (!c || (c < 0x20 && c != '\r' && c != '\n' && c != '\t')) return false;
        if (high(c)) {
            if (++i == text.size() || !low(text[i])) return false;
        } else if (low(c)) return false;
    }
    return true;
}

inline bool clipboardText(const uint8_t *bytes, size_t length, std::u16string &text) {
    text.clear();
    if (!bytes || length < 2 || length > maxTextBytes || (length & 1)) return false;
    std::u16string decoded;
    decoded.reserve(length / 2);
    bool terminated = false;
    for (size_t i = 0; i < length; i += 2) {
        uint16_t c = uint16_t(bytes[i]) | (uint16_t(bytes[i + 1]) << 8);
        if (!c) { terminated = true; continue; }
        if (terminated) return false;
        if (c == '\r' && i + 3 < length && bytes[i + 2] == '\n' && !bytes[i + 3])
            continue;
        decoded.push_back(char16_t(c == '\r' ? '\n' : c));
    }
    if (!terminated || !validText(decoded)) return false;
    text = std::move(decoded);
    return true;
}

inline uint16_t usage(uint8_t scan, bool extended) {
    if (extended) {
        switch (scan) {
            case 0x1c: return 0x58; case 0x1d: return 0xe4;
            case 0x35: return 0x54; case 0x38: return 0xe6;
            case 0x47: return 0x4a; case 0x48: return 0x52; case 0x49: return 0x4b;
            case 0x4b: return 0x50; case 0x4d: return 0x4f;
            case 0x4f: return 0x4d; case 0x50: return 0x51; case 0x51: return 0x4e;
            case 0x52: return 0x49; case 0x53: return 0x4c;
            case 0x5b: return 0xe3; case 0x5c: return 0xe7; case 0x5d: return 0x65;
            default: return 0;
        }
    }
    static constexpr uint8_t table[] = {
        0,0x29,0x1e,0x1f,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x2d,0x2e,0x2a,0x2b,
        0x14,0x1a,0x08,0x15,0x17,0x1c,0x18,0x0c,0x12,0x13,0x2f,0x30,0x28,0xe0,0x04,0x16,
        0x07,0x09,0x0a,0x0b,0x0d,0x0e,0x0f,0x33,0x34,0x35,0xe1,0x31,0x1d,0x1b,0x06,0x19,
        0x05,0x11,0x10,0x36,0x37,0x38,0xe5,0x55,0xe2,0x2c,0x39,0x3a,0x3b,0x3c,0x3d,0x3e,
        0x3f,0x40,0x41,0x42,0x43,0x53,0x47,0x5f,0x60,0x61,0x56,0x5c,0x5d,0x5e,0x57,0x59,
        0x5a,0x5b,0x62,0x63,0,0,0x64,0x44,0x45
    };
    return scan < sizeof(table) ? table[scan] : 0;
}

inline bool modifier(uint16_t key) { return key >= 0xe0 && key <= 0xe7; }
struct Keys {
    std::bitset<256> down;
    bool pasteKey = false;
    bool control() const { return down[0xe0] || down[0xe4]; }
    bool pasteModifiers() const {
        return control() && !down[0xe2] && !down[0xe6] && !down[0xe3] && !down[0xe7];
    }
};

struct Unicode {
    uint16_t surrogate = 0;
    uint64_t started = 0;
    enum Result { Pending, Ready, Invalid };
    Result feed(uint16_t c, uint64_t now, std::u16string &text) {
        text.clear();
        if (surrogate) {
            uint16_t previous = surrogate;
            surrogate = 0;
            if (!low(c) || now - started > 1000) return Invalid;
            text = {char16_t(previous), char16_t(c)};
        } else if (high(c)) {
            surrogate = c; started = now; return Pending;
        } else {
            text.push_back(char16_t(c == '\r' ? '\n' : c));
        }
        return validText(text) ? Ready : Invalid;
    }
};

struct Clipboard {
    uint64_t generation = 0, requestedGeneration = 0, started = 0;
    bool hasText = false, outstanding = false, wanted = false;
    void formats(bool available) {
        ++generation; hasText = available; wanted = false;
    }
    bool request(uint64_t now) {
        if (!hasText || outstanding) return false;
        outstanding = wanted = true; requestedGeneration = generation; started = now;
        return true;
    }
    bool response() {
        bool accept = outstanding && wanted && requestedGeneration == generation;
        outstanding = wanted = false;
        return accept;
    }
    bool expire(uint64_t now) {
        if (!wanted || now - started < clipboardTimeoutMs) return false;
        wanted = false;
        // CLIPRDR responses have no request ID; drain a late response before requesting again.
        return true;
    }
};
}
