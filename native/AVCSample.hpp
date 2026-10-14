#pragma once
#include "AVC.hpp"
#include <CoreMedia/CoreMedia.h>

namespace avc {
enum class BufferPath { Invalid, Borrowed, Copied };
inline BufferPath appendBlock(CMBlockBufferRef block, unsigned prefix, std::vector<uint8_t> &output) {
    if (!block) return BufferPath::Invalid;
    size_t size = CMBlockBufferGetDataLength(block);
    if (!size || size > maxBytes) return BufferPath::Invalid;
    char *bytes = nullptr;
    size_t contiguous = 0, total = 0;
    if (CMBlockBufferGetDataPointer(block, 0, &contiguous, &total, &bytes) ||
        !bytes || total != size || contiguous > total) return BufferPath::Invalid;
    if (contiguous == total)
        return annexB(reinterpret_cast<const uint8_t *>(bytes), size, prefix, output) ?
            BufferPath::Borrowed : BufferPath::Invalid;
    std::vector<uint8_t> copy(size);
    if (CMBlockBufferCopyDataBytes(block, 0, size, copy.data()) ||
        !annexB(copy.data(), size, prefix, output)) return BufferPath::Invalid;
    return BufferPath::Copied;
}
}
