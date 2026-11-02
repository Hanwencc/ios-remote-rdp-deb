#include "../native/AVCSample.hpp"
#include <cstdio>

int main() {
    uint8_t bytes[]{0,0,0,3,0x65,0x11,0x22};
    uint8_t first[]{0,0,0}, second[]{3,0x65,0x11,0x22};
    const std::vector<uint8_t> expected{0,0,0,1,0x67,0,0,0,1,0x65,0x11,0x22};
    CMBlockBufferRef contiguous = nullptr, segmented = nullptr;
    OSStatus result = CMBlockBufferCreateWithMemoryBlock(nullptr, bytes, sizeof(bytes),
        kCFAllocatorNull, nullptr, 0, sizeof(bytes), 0, &contiguous);
    if (!result) result = CMBlockBufferCreateEmpty(nullptr, 2, 0, &segmented);
    if (!result) result = CMBlockBufferAppendMemoryBlock(segmented, first, sizeof(first),
        kCFAllocatorNull, nullptr, 0, sizeof(first), 0);
    if (!result) result = CMBlockBufferAppendMemoryBlock(segmented, second, sizeof(second),
        kCFAllocatorNull, nullptr, 0, sizeof(second), 0);
    bool passed = !result;
    if (passed) {
        std::vector<uint8_t> output{0,0,0,1,0x67};
        passed = avc::appendBlock(contiguous, 4, output) == avc::BufferPath::Borrowed && output == expected;
        output = {0,0,0,1,0x67};
        passed &= avc::appendBlock(segmented, 4, output) == avc::BufferPath::Copied && output == expected;
        const auto original = output;
        bytes[3] = 10;
        passed &= avc::appendBlock(contiguous, 4, output) == avc::BufferPath::Invalid && output == original;
        passed &= avc::appendBlock(nullptr, 4, output) == avc::BufferPath::Invalid && output == original;
    }
    if (contiguous) CFRelease(contiguous);
    if (segmented) CFRelease(segmented);
    if (!passed) { std::fprintf(stderr, "FAIL CMBlockBuffer Annex B paths: %d\n", int(result)); return 1; }
    std::puts("PASS: borrowed contiguous H264, copied split NAL prefix and unchanged output on invalid input");
    return 0;
}
