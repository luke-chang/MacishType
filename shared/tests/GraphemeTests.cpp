// Self-test for the grapheme cluster index. It is the only place the two
// degradation rungs are observable: every host that reaches the contract
// tests has working ICU, so nothing else exercises the code-point or
// raw-byte fallbacks.

#include <string>
#include <vector>

#include "Checks.h"
#include "MacishType/GraphemeIndex.h"
#include "MacishType/Intl.h"

namespace {

using MacishType::GraphemeIndex;
using MacishType::IntlCache;
using MacishType::isSingleGrapheme;

// Spelled as bytes so no editor or encoding step can normalize the combining
// mark or the variation selector into another form.
const std::string kGear = "\xE2\x9A\x99\xEF\xB8\x8E"; // U+2699 U+FE0E
const std::string kEacute = "e\xCC\x81";              // e U+0301
const std::string kWomanLaptop = "\xF0\x9F\x91\xA9\xE2\x80\x8D"
                                "\xF0\x9F\x92\xBB"; // U+1F469 U+200D U+1F4BB
const std::string kHan = "\xE4\xB8\x80";             // U+4E00

// The flag is process-wide, so every block that turns it off must put it back.
class IcuOff {
public:
    IcuOff() { MacishType::setIcuUsable(false); }
    ~IcuOff() { MacishType::setIcuUsable(true); }
    IcuOff(const IcuOff &) = delete;
    IcuOff &operator=(const IcuOff &) = delete;
};

std::vector<size_t> byteBoundaries(const GraphemeIndex &index) {
    std::vector<size_t> offsets;
    for (int i = 0; i <= index.count(); i++) {
        offsets.push_back(index.byteOffset(i));
    }
    return offsets;
}

std::vector<int> utf16Boundaries(const GraphemeIndex &index) {
    std::vector<int> offsets;
    for (int i = 0; i <= index.count(); i++) {
        offsets.push_back(index.utf16Offset(i));
    }
    return offsets;
}

} // namespace

void testGraphemeIndex(Checks &checks) {
    IntlCache cache;
    const std::string text = kGear + kEacute + kWomanLaptop + "x";

    {
        GraphemeIndex index(cache, text);
        checks.expect(index.count() == 4,
                      "clusters are counted, not code points");
        checks.expect(byteBoundaries(index) ==
                          std::vector<size_t>{0, 6, 9, 20, 21},
                      "cluster boundaries land on the expected bytes");
        checks.expect(utf16Boundaries(index) ==
                          std::vector<int>{0, 2, 4, 9, 10},
                      "the same boundaries in UTF-16 units");
        checks.expect(index.cluster(2) == kWomanLaptop,
                      "a cluster reads back whole");
        checks.expect(index.byteOffset(-1) == 0 &&
                          index.byteOffset(index.count() + 5) == text.size(),
                      "byteOffset clamps out-of-range indices");
        checks.expect(index.utf16Offset(-1) == 0 &&
                          index.utf16Offset(index.count() + 5) == 10,
                      "utf16Offset clamps out-of-range indices");
    }

    {
        IcuOff off;
        GraphemeIndex index(cache, text);
        checks.expect(index.count() == 8,
                      "without ICU valid UTF-8 degrades to code points");
        checks.expect(index.byteOffset(1) == 3,
                      "a code-point boundary splits the variation sequence");
        checks.expect(index.byteOffset(index.count()) == text.size(),
                      "the last boundary still ends the string");

        checks.expect(GraphemeIndex(cache, kHan).count() == 1,
                      "a multi-byte code point is one character, not three");
        checks.expect(!isSingleGrapheme(cache, kEacute),
                      "while a combining mark separates from its base");
    }

    {
        const std::string invalid = "\xC3\x28"; // a two-byte lead, then ASCII
        GraphemeIndex index(cache, invalid);
        checks.expect(index.count() == static_cast<int>(invalid.size()) &&
                          index.byteOffset(1) == 1,
                      "invalid UTF-8 degrades to byte indices");
    }

    checks.expect(isSingleGrapheme(cache, "a"),
                  "one ASCII byte is one character");
    checks.expect(!isSingleGrapheme(cache, "Enter"),
                  "a named key is not one character");
    checks.expect(!isSingleGrapheme(cache, ""), "empty text never is");
    checks.expect(isSingleGrapheme(cache, kEacute),
                  "a combining mark stays with its base");
    checks.expect(isSingleGrapheme(cache, kWomanLaptop),
                  "so does a ZWJ sequence");
}
