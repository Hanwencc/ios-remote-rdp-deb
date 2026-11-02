#include "../native/InputFlow.hpp"
#include <cstdio>
#include <vector>

int main() {
    bool passed = true;
    const auto expect = [&](bool condition, const char *name) {
        if (!condition) { std::fprintf(stderr, "FAIL input flow: %s\n", name); passed = false; }
    };
    using namespace inputFlow;
    expect(usage(0x1e, false) == 4 && usage(0x30, false) == 5, "letter mapping");
    expect(usage(0x1d, false) == 0xe0 && usage(0x1d, true) == 0xe4, "left/right control");
    expect(usage(0x38, false) == 0xe2 && usage(0x38, true) == 0xe6, "left/right option");
    expect(usage(0x1c, false) == 0x28 && usage(0x1c, true) == 0x58, "keypad enter");
    expect(usage(0x48, false) == 0x60 && usage(0x48, true) == 0x52, "keypad versus arrow");
    expect(usage(0x58, false) == 0x45 && !usage(0xff, true), "F12 and unknown scan");
    Keys keys;
    keys.down[0xe4] = true;
    expect(keys.pasteModifiers(), "right control paste");
    keys.down[0xe6] = true;
    expect(!keys.pasteModifiers(), "AltGr is not paste");
    keys = {};
    expect(!keys.control() && !keys.pasteKey, "focus loss resets keys");

    Unicode unicode;
    std::u16string text;
    expect(unicode.feed(0x4e2d, 0, text) == Unicode::Ready && text == u"\u4e2d", "BMP unicode");
    expect(unicode.feed(0xd83c, 1, text) == Unicode::Pending, "high surrogate staged");
    expect(unicode.feed(0xdf31, 2, text) == Unicode::Ready && text == u"\U0001f331", "emoji pair");
    expect(unicode.feed(0xdf31, 3, text) == Unicode::Invalid, "lone low surrogate rejected");
    unicode.feed(0xd83c, 4, text);
    expect(unicode.feed('a', 5, text) == Unicode::Invalid, "broken pair rejected");
    unicode.feed(0xd83c, 6, text);
    expect(unicode.feed(0xdf31, 1007, text) == Unicode::Invalid, "expired pair rejected");
    expect(unicode.feed('\r', 0, text) == Unicode::Ready && text == u"\n", "unicode newline");
    expect(!validText(std::u16string(1, 0)) && !validText(std::u16string(1, 0xd800)), "invalid text rejected");

    std::vector<uint8_t> bytes;
    const auto encode = [&](const std::u16string &value) {
        bytes.clear();
        for (auto c : value) { bytes.push_back(uint8_t(c)); bytes.push_back(uint8_t(c >> 8)); }
        bytes.push_back(0); bytes.push_back(0);
    };
    encode(u"ABC \u4e2d\u6587 \U0001f331\r\nline\rend");
    expect(clipboardText(bytes.data(), bytes.size(), text) && text == u"ABC \u4e2d\u6587 \U0001f331\nline\nend",
           "clipboard UTF-16LE and CRLF normalization");
    expect(!clipboardText(bytes.data(), bytes.size() - 1, text), "odd byte count rejected");
    expect(!clipboardText(bytes.data(), bytes.size() - 2, text), "unterminated text rejected");
    encode(std::u16string({'a', 0, 'b'}));
    expect(!clipboardText(bytes.data(), bytes.size(), text), "embedded terminator rejected");
    encode(std::u16string(1, 0xdc00));
    expect(!clipboardText(bytes.data(), bytes.size(), text), "malformed clipboard surrogate rejected");
    encode(std::u16string(maxTextBytes / 2 - 1, 'a'));
    expect(bytes.size() == maxTextBytes && clipboardText(bytes.data(), bytes.size(), text), "exact 1 MiB accepted");
    bytes.push_back(0); bytes.push_back(0);
    expect(!clipboardText(bytes.data(), bytes.size(), text), "1 MiB plus 2 rejected");
    encode(u"");
    expect(clipboardText(bytes.data(), bytes.size(), text) && text.empty(), "empty clipboard");
    expect(!clipboardText(nullptr, 2, text), "null payload rejected");

    Clipboard clipboard;
    expect(!clipboard.request(0), "no text format");
    clipboard.formats(true);
    expect(clipboard.request(1) && !clipboard.request(2), "one outstanding request");
    expect(!clipboard.expire(3000) && clipboard.expire(3001), "exact timeout threshold");
    expect(!clipboard.request(3002), "late response cannot match a new request");
    expect(!clipboard.response() && clipboard.request(3003), "late response drained without injection");
    clipboard.formats(true);
    expect(!clipboard.response(), "format generation invalidates pending response");
    expect(clipboard.request(3004) && clipboard.response(), "current response accepted once");
    expect(!clipboard.response(), "duplicate response rejected");
    clipboard.request(3005);
    clipboard.wanted = false;
    expect(!clipboard.response(), "focus/new input cancels paste");
    if (!passed) return 1;
    std::puts("PASS: HID mappings, modifiers, Unicode pairs, clipboard validation, 1 MiB boundary, timeout and stale responses");
    return 0;
}
