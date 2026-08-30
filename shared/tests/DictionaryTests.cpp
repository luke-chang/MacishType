// Self-test for the reference-counted dictionary store. It links against
// nothing but macishtype-shared (whole archive) and ICU, so building it is
// also the acceptance check that this library stays consumable by a host that
// embeds no JS runtime.

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <utility>

#include "MacishType/AssociatedDictionary.h"
#include "MacishType/Intl.h"
#include "MacishType/Logger.h"
#include "MacishType/RefCountedDictionary.h"

namespace {

using MacishType::AssociatedDictionary;
using MacishType::IntlCache;
using MacishType::Logger;
using MacishType::RefCountedDictionary;

struct Checks {
    int failures = 0;

    void expect(bool ok, const char *what) {
        if (!ok) {
            std::fprintf(stderr, "FAIL: %s\n", what);
            ++failures;
        }
    }
};

// Counts what the store actually did: the parser emits one "N prefixes" line
// per load and one fault per unreadable file, so a sink is enough to observe
// sharing without widening the public API.
class CountingLogger : public Logger {
public:
    int loads = 0;
    int unloads = 0;
    int shares = 0;
    int faults = 0;

    void write(Level level, std::string_view message,
               const std::source_location &) override {
        if (level == Level::Fault) {
            ++faults;
        }
        if (message.find(" prefixes") != std::string_view::npos) {
            ++loads;
        }
        if (message.find(": unloaded") != std::string_view::npos) {
            ++unloads;
        }
        if (message.find("acquired (refcount=2)") != std::string_view::npos) {
            ++shares;
        }
    }
};

int parseCount = 0;

std::string countingParse(const std::filesystem::path &path) {
    ++parseCount;
    std::ifstream stream(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(stream)),
                       std::istreambuf_iterator<char>());
}

// Taking the handle by reference hides the self-move from the compiler's
// self-move diagnostic while still exercising the guard.
void selfMove(RefCountedDictionary<std::string>::Handle &handle) {
    handle = std::move(handle);
}

// Scratch directory, unique per concurrently running test binary:
// create_directory reports whether it was this call that created it.
class ScratchDir {
public:
    ScratchDir() {
        auto base = std::filesystem::temp_directory_path();
        for (int attempt = 0; attempt < 1000; ++attempt) {
            auto candidate =
                base / ("macishtype-shared-test-" + std::to_string(attempt));
            std::error_code error;
            if (std::filesystem::create_directory(candidate, error)) {
                path_ = candidate;
                return;
            }
        }
    }

    ~ScratchDir() {
        std::error_code error;
        std::filesystem::remove_all(path_, error);
    }

    ScratchDir(const ScratchDir &) = delete;
    ScratchDir &operator=(const ScratchDir &) = delete;

    const std::filesystem::path &path() const { return path_; }

private:
    std::filesystem::path path_;
};

void writeFile(const std::filesystem::path &path, std::string_view content) {
    std::ofstream stream(path, std::ios::binary);
    stream.write(content.data(), static_cast<std::streamsize>(content.size()));
}

// U+2699 U+FE0E: two code points, one grapheme cluster. Spelled as bytes so
// no editor or encoding step can normalize the variation selector away.
constexpr const char *kCluster = "\xE2\x9A\x99\xEF\xB8\x8E";

void testRefCounting(Checks &checks, const std::filesystem::path &dir) {
    const auto alpha = dir / "alpha.txt";
    const auto beta = dir / "beta.txt";
    writeFile(alpha, "alpha");
    writeFile(beta, "beta");

    RefCountedDictionary<std::string> registry(countingParse);
    parseCount = 0;

    auto first = registry.acquire(alpha);
    auto second = registry.acquire(alpha);
    checks.expect(parseCount == 1, "the same path is parsed once");
    checks.expect(&first.value() == &second.value(),
                  "both handles see one parsed value");
    checks.expect(first.value() == "alpha", "the parser result is returned");

    first.reset();
    auto third = registry.acquire(alpha);
    checks.expect(parseCount == 1, "still loaded while a handle lives");

    second.reset();
    third.reset();
    auto fourth = registry.acquire(alpha);
    checks.expect(parseCount == 2, "reparsed after the last handle dropped");

    selfMove(fourth);
    checks.expect(static_cast<bool>(fourth), "self-move keeps the handle");

    auto moved = registry.acquire(beta);
    checks.expect(parseCount == 3, "a second path is parsed separately");
    fourth = std::move(moved);
    checks.expect(!moved, "a moved-from handle is empty");
    checks.expect(fourth.value() == "beta", "move-assignment takes the value");
    auto fifth = registry.acquire(alpha);
    checks.expect(parseCount == 4,
                  "move-assignment released what the target held");

    auto unset = registry.acquire({});
    checks.expect(!unset, "an empty path yields an empty handle");
    checks.expect(parseCount == 4, "an empty path parses nothing");
}

void testAssociatedDictionary(Checks &checks, const std::filesystem::path &dir,
                              CountingLogger &logger) {
    const auto table = dir / "AssociatedDictionary.test.txt";
    writeFile(table, std::string("# comment\n") + kCluster + "\tone two\n");

    IntlCache cache;
    const std::string held = std::string("A") + kCluster;

    logger.loads = 0;
    logger.unloads = 0;
    logger.shares = 0;
    {
        auto held1 = AssociatedDictionary::acquire(table);
        auto held2 = AssociatedDictionary::acquire(table);
        checks.expect(logger.loads == 1,
                      "AssociatedDictionary::acquire shares one parse");
        checks.expect(logger.shares == 1,
                      "the shared acquire reports the raised refcount");
        checks.expect(logger.unloads == 0,
                      "nothing unloads while a handle is held");

        auto followups = held1.followups(cache, held);
        checks.expect(followups.size() == 2 && followups[0] == "one" &&
                          followups[1] == "two",
                      "lookup keys on the whole trailing grapheme cluster");
        checks.expect(held2.followups(cache, "A").empty(),
                      "a cluster with no entry has no follow-ups");
    }
    checks.expect(logger.unloads == 1,
                  "releasing the last handle unloads the table");
    auto reacquired = AssociatedDictionary::acquire(table);
    checks.expect(logger.loads == 2,
                  "reparsed after every handle was released");
    checks.expect(reacquired.followups(cache, held).size() == 2,
                  "the reloaded table answers the same");

    const auto missing = dir / "AssociatedDictionary.absent.txt";
    logger.faults = 0;
    auto absent = AssociatedDictionary::acquire(missing);
    checks.expect(static_cast<bool>(absent),
                  "an unreadable table still yields an engaged handle");
    checks.expect(absent.followups(cache, held).empty(),
                  "an unreadable table has no follow-ups");
    checks.expect(logger.faults == 1, "an unreadable table faults once");
    auto absentAgain = AssociatedDictionary::acquire(missing);
    checks.expect(logger.faults == 1,
                  "the second acquire reuses the cached empty table");

    AssociatedDictionary::Handle empty;
    checks.expect(!empty, "a default-constructed handle is empty");
    checks.expect(empty.followups(cache, held).empty(),
                  "an empty handle answers with no follow-ups");
    checks.expect(!AssociatedDictionary::acquire({}),
                  "an empty path yields an empty handle");
}

} // namespace

int main() {
    Checks checks;
    ScratchDir scratch;
    if (scratch.path().empty()) {
        std::fprintf(stderr, "FAIL: could not create a scratch directory\n");
        return 1;
    }

    CountingLogger logger;
    MacishType::setLogger(&logger);

    testRefCounting(checks, scratch.path());
    testAssociatedDictionary(checks, scratch.path(), logger);

    MacishType::setLogger(nullptr);

    if (checks.failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", checks.failures);
        return 1;
    }
    std::printf("all checks passed\n");
    return 0;
}
