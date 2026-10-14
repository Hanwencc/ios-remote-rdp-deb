#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace avc {
constexpr size_t maxBytes = 4 * 1024 * 1024;
inline bool annexB(const uint8_t *bytes, size_t size, unsigned prefix,
                   std::vector<uint8_t> &output) {
    if (!bytes || !size || size > maxBytes || prefix < 1 || prefix > 4) return false;
    size_t offset = 0, total = output.size();
    while (offset < size) {
        if (size - offset < prefix) return false;
        uint32_t length = 0;
        for (unsigned i = 0; i < prefix; ++i) length = (length << 8) | bytes[offset++];
        if (!length || length > size - offset || total > maxBytes - 4 ||
            length > maxBytes - total - 4) return false;
        total += 4 + length;
        offset += length;
    }
    output.reserve(total);
    offset = 0;
    while (offset < size) {
        uint32_t length = 0;
        for (unsigned i = 0; i < prefix; ++i) length = (length << 8) | bytes[offset++];
        output.insert(output.end(), {0, 0, 0, 1});
        output.insert(output.end(), bytes + offset, bytes + offset + length);
        offset += length;
    }
    return true;
}
}
