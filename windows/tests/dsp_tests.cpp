// Tests for the sound math. These run on Windows (GitHub) and on the Mac:
//   cmake -S windows -B build-mac && cmake --build build-mac && ./build-mac/dsp_tests
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <random>

#include "dsp/analysis.h"
#include "dsp/music_shifter.h"
#include "dsp/wav.h"

using namespace ps;

TEST_CASE("measures a tone's pitch, level and cleanliness") {
    const auto tone = make_tone(440.0, 0.25, 48000, 1, 2.0);
    const auto m = measure_tone(tone.data(), tone.size(), 48000, 440.0);
    CHECK(m.frequency == doctest::Approx(440.0).epsilon(1e-5));
    CHECK(m.level_db == doctest::Approx(20 * std::log10(0.25)).epsilon(1e-4));
    CHECK(m.thdn_db < -100);
}

TEST_CASE("finds a tone that is off from the expected pitch") {
    const auto tone = make_tone(493.88, 0.5, 48000, 1, 1.5);
    const auto m = measure_tone(tone.data(), tone.size(), 48000, 440.0);
    CHECK(m.frequency == doctest::Approx(493.88).epsilon(1e-5));
}

TEST_CASE("a very quiet tone boosted 1000 times comes back exactly") {
    auto tone = make_tone(440.0, 0.25 * 0.001, 48000, 1, 1.0);
    const auto quiet = measure_tone(tone.data(), tone.size(), 48000, 440.0);
    CHECK(quiet.level_db == doctest::Approx(to_db(0.25) - 60.0).epsilon(1e-4));
    for (auto& v : tone) v *= 1000.0f;
    const auto boosted = measure_tone(tone.data(), tone.size(), 48000, 440.0);
    CHECK(boosted.level_db == doctest::Approx(to_db(0.25)).epsilon(1e-4));
    CHECK(boosted.thdn_db < -100);
}

TEST_CASE("noise shows up in the cleanliness number") {
    auto tone = make_tone(440.0, 0.5, 48000, 1, 1.0);
    std::mt19937 rng(1);
    std::normal_distribution<float> noise(0.0f, 0.005f);
    for (auto& v : tone) v += noise(rng);
    const auto m = measure_tone(tone.data(), tone.size(), 48000, 440.0);
    // Tone power 0.125, noise power 0.000025 -> about -37 dB.
    CHECK(m.thdn_db == doctest::Approx(-37.0).epsilon(0.02));
}

TEST_CASE("wav files round-trip") {
    const auto tone = make_tone(440.0, 0.25, 48000, 2, 0.1);
    const auto path = (std::filesystem::temp_directory_path() / "ps_dsp_test.wav").string();
    REQUIRE(write_wav(path, tone, 2, 48000));
    const auto back = read_wav(path);
    CHECK(back.channels == 2);
    CHECK(back.rate == 48000);
    REQUIRE(back.samples.size() == tone.size());
    CHECK(back.samples[123] == tone[123]);
    std::filesystem::remove(path);
}

TEST_CASE("music shifter: +2 half-steps turns 440 Hz into 493.9 Hz at the same level") {
    const int rate = 48000;
    MusicShifter shifter(rate, 2, 2.0);
    const auto in = make_tone(440.0, 0.25, rate, 2, 4.0);
    std::vector<float> out;
    for (size_t i = 0; i < in.size() / 2; i += 480) shifter.process(in.data() + i * 2, 480, out);
    REQUIRE(out.size() > size_t(rate) * 2 * 2);
    // Look at the last 1.5 s (after Rubber Band has warmed up).
    const auto left = take_channel(out, 2, 0);
    const size_t n = size_t(rate * 1.5);
    const auto m = measure_tone(left.data() + left.size() - n, n, rate, 493.88);
    MESSAGE("shifted: " << m.frequency << " Hz, level " << m.level_db << " dB, THD+N " << m.thdn_db << " dB");
    CHECK(m.frequency == doctest::Approx(440.0 * std::pow(2.0, 2.0 / 12)).epsilon(0.001));
    CHECK(m.level_db == doctest::Approx(to_db(0.25)).epsilon(0.1));
    CHECK(m.thdn_db < -30);
}

TEST_CASE("music shifter: 0 half-steps passes sound through untouched") {
    MusicShifter shifter(48000, 2, 0.0);
    const auto in = make_tone(440.0, 0.25, 48000, 2, 0.05);
    std::vector<float> out;
    shifter.process(in.data(), in.size() / 2, out);
    CHECK(out == in);
}

TEST_CASE("music shifter: going from 0 to a new amount works") {
    MusicShifter shifter(48000, 2, 0.0);
    const auto in = make_tone(440.0, 0.25, 48000, 2, 3.0);
    std::vector<float> out;
    shifter.process(in.data(), 4800, out);
    shifter.set_half_steps(-3.0);
    out.clear();
    for (size_t i = 4800; i < in.size() / 2; i += 480) shifter.process(in.data() + i * 2, 480, out);
    const auto left = take_channel(out, 2, 0);
    const size_t n = 48000;
    REQUIRE(left.size() > n);
    const auto m = measure_tone(left.data() + left.size() - n, n, 48000, 370.0);
    CHECK(m.frequency == doctest::Approx(440.0 * std::pow(2.0, -3.0 / 12)).epsilon(0.001));
}
