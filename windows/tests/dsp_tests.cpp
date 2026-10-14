// Tests for the sound math. These run on Windows (GitHub) and on the Mac:
//   cmake -S windows -B build-mac && cmake --build build-mac && ./build-mac/dsp_tests
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <random>

#include "dsp/analysis.h"
#include "dsp/booster.h"
#include "dsp/cushion.h"
#include "dsp/drift_buffer.h"
#include "dsp/music_shifter.h"
#include "dsp/voice_shifter.h"
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

TEST_CASE("music shifter: how long the sound takes to come through") {
    const int rate = 48000;
    MusicShifter shifter(rate, 2, 12.0);
    // Silence, then a 440 Hz tone that starts at exactly 1 s.
    auto in = make_tone(440.0, 0.25, rate, 2, 3.0);
    std::fill(in.begin(), in.begin() + rate * 2, 0.0f);
    std::vector<float> out;
    // Remember how much had gone in each time sound came out, like it would live.
    std::vector<std::pair<size_t, size_t>> out_vs_in;
    for (size_t i = 0; i < in.size() / 2; i += 480) {
        shifter.process(in.data() + i * 2, 480, out);
        out_vs_in.push_back({out.size() / 2, i + 480});
    }
    const auto left = take_channel(out, 2, 0);
    const double t = onset_time(left.data(), left.size(), rate, 880.0, -30.0);
    REQUIRE(t > 0);
    const size_t onset_out = size_t(t * rate);
    size_t in_when_out = 0;
    for (const auto& [o, i] : out_vs_in)
        if (o > onset_out) {
            in_when_out = i;
            break;
        }
    // The tone went in at 1 s; it came out once `in_when_out` frames had gone in.
    const double delay_ms = (double(in_when_out) / rate - 1.0) * 1000;
    MESSAGE("Rubber Band R3 delay: about " << delay_ms << " ms (start delay says "
                                           << shifter.start_delay() * 1000.0 / rate << " ms)");
    CHECK(delay_ms > 20);
    CHECK(delay_ms < 250);
}

TEST_CASE("cushion: waits for 50 ms, then plays") {
    Cushion c(2, 2400, 7200);
    std::vector<float> in(480 * 2, 0.5f), out(480 * 2);
    for (int i = 0; i < 4; ++i) c.push(in.data(), 480);  // 40 ms
    c.pull(out.data(), 480);
    CHECK_FALSE(c.playing());
    CHECK(out[0] == 0.0f);
    c.push(in.data(), 480);  // 50 ms (waiting doesn't use up any sound)
    c.pull(out.data(), 480);
    CHECK(c.playing());
    CHECK(out[0] == 0.5f);
}

TEST_CASE("cushion: drops new sound above 150 ms and counts it") {
    Cushion c(2, 2400, 7200);
    std::vector<float> in(480 * 2, 0.5f);
    for (int i = 0; i < 15; ++i) c.push(in.data(), 480);  // exactly 150 ms
    CHECK(c.skips() == 0);
    c.push(in.data(), 480);
    CHECK(c.skips() == 1);
    CHECK(c.queued_frames() == 7200);
}

TEST_CASE("cushion: running dry counts a dropout and refills") {
    Cushion c(2, 2400, 7200);
    std::vector<float> in(480 * 2, 0.5f), out(480 * 2);
    for (int i = 0; i < 5; ++i) c.push(in.data(), 480);
    for (int i = 0; i < 5; ++i) c.pull(out.data(), 480);
    CHECK(c.dropouts() == 0);
    c.pull(out.data(), 480);
    CHECK(c.dropouts() == 1);
    CHECK_FALSE(c.playing());
}

TEST_CASE("booster: quieted sound comes back exactly x1000") {
    Booster b(2, 1000.0f);
    auto tone = make_tone(440.0, 0.25 * 0.001, 48000, 2, 1.0);
    for (size_t i = 0; i < tone.size() / 2; i += 480) b.process(tone.data() + i * 2, 480);
    const auto left = take_channel(tone, 2, 0);
    const auto m = measure_tone(left.data(), left.size(), 48000, 440.0);
    CHECK(m.level_db == doctest::Approx(to_db(0.25)).epsilon(1e-4));
    CHECK(b.guarded() == 0);
}

TEST_CASE("booster: sound that wasn't quieted doesn't blast, and the boost comes back") {
    Booster b(2, 1000.0f);
    auto loud = make_tone(440.0, 0.5, 48000, 2, 0.2);     // an app that wasn't turned down yet
    auto quiet = make_tone(440.0, 0.0005, 48000, 2, 1.0);  // then it is
    std::vector<float> all = loud;
    all.insert(all.end(), quiet.begin(), quiet.end());
    float peak = 0;
    for (size_t i = 0; i < all.size() / 2; i += 480) {
        b.process(all.data() + i * 2, 480);
        for (size_t k = 0; k < 960; ++k) peak = std::max(peak, std::fabs(all[i * 2 + k]));
    }
    CHECK(peak <= 0.91f);
    CHECK(b.guarded() > 0);
    CHECK(b.current_gain() == doctest::Approx(1000.0f));
}

TEST_CASE("voice cushion: small delay, no gaps when the clocks drift, no clicks") {
    for (double ratio : {1.0, 1.002, 0.998}) {
        DriftBuffer d(48000);
        const auto tone = make_tone(300.0, 0.5, 48000, 1, 30.0);
        std::vector<float> out;
        std::vector<float> chunk(480);
        double produced = 0;
        size_t pos = 0;
        double hi = 0;
        uint64_t dropouts_after_start = 0;
        for (int block = 0; block < 2800; ++block) {
            // The voice arrives in uneven bursts (like Rubber Band's output), `ratio` times as fast as the cable takes it.
            produced += 480 * ratio;
            if (block % 3 == 2) {
                const size_t want = size_t(produced) - pos;
                if (pos + want > tone.size()) break;
                d.push(tone.data() + pos, want);
                pos += want;
            }
            d.pull(chunk.data(), 480);
            out.insert(out.end(), chunk.begin(), chunk.end());
            if (block == 100) dropouts_after_start = d.dropouts();
            if (block > 300) hi = std::max(hi, d.queued_ms());
        }
        MESSAGE("ratio " << ratio << ": most waiting " << hi << " ms, trims " << d.trims() << ", repeats "
                         << d.repeats() << ", gaps " << d.dropouts());
        CHECK(d.dropouts() == dropouts_after_start);
        CHECK(hi <= 60.0);
        float jump = 0;
        for (size_t i = 48000; i + 1 < out.size(); ++i) jump = std::max(jump, std::fabs(out[i + 1] - out[i]));
        CHECK(jump < 0.08f);
    }
}

TEST_CASE("voice shifter: 0 half-steps passes the voice through") {
    VoiceShifter v(48000, 0.0, true);
    const auto in = make_vowel(120, 48000, 0.5);
    std::vector<float> out;
    v.process(in.data(), in.size(), out);
    CHECK(out == in);
}

TEST_CASE("voice shifter: how long the voice takes to come through") {
    const int rate = 48000;
    VoiceShifter v(rate, 4.0, true);
    auto in = make_tone(300.0, 0.3, rate, 1, 3.0);
    std::fill(in.begin(), in.begin() + rate, 0.0f);  // silence, then a tone from 1 s
    std::vector<float> out;
    std::vector<std::pair<size_t, size_t>> out_vs_in;
    for (size_t i = 0; i < in.size(); i += 480) {
        v.process(in.data() + i, 480, out);
        out_vs_in.push_back({out.size(), i + 480});
    }
    const double t = onset_time(out.data(), out.size(), rate, 300.0 * std::pow(2.0, 4.0 / 12), -30.0);
    REQUIRE(t > 0);
    size_t in_when_out = 0;
    for (const auto& [o, i] : out_vs_in)
        if (o > size_t(t * rate)) {
            in_when_out = i;
            break;
        }
    const double delay_ms = (double(in_when_out) / rate - 1.0) * 1000;
    MESSAGE("voice Rubber Band delay: about " << delay_ms << " ms");
    CHECK(delay_ms < 120);
}

TEST_CASE("voice shifter: keeps the sound above 10 kHz (no hiss band, no missing top)") {
    const int rate = 48000;
    // A bright "sss": noise shaped toward the top, plus a vowel.
    auto in = make_vowel(140, rate, 3.0, 0.2);
    std::mt19937 rng(7);
    std::normal_distribution<float> noise(0.0f, 0.05f);
    float prev = 0;
    for (auto& v : in) {
        const float n = noise(rng);
        v += n - prev;  // differenced noise leans toward high frequencies
        prev = n;
    }
    auto top_energy = [&](const float* x, size_t n) {
        double e = 0;
        for (double hz = 10000; hz <= 20000; hz += 250) {
            e += tone_amplitude(x, n, rate, hz) * tone_amplitude(x, n, rate, hz);
        }
        return 10 * std::log10(e + 1e-30);
    };
    VoiceShifter v(rate, 4.0, true);
    std::vector<float> out;
    for (size_t i = 0; i < in.size(); i += 480) v.process(in.data() + i, 480, out);
    REQUIRE(out.size() > size_t(rate) * 2);
    const double before = top_energy(in.data() + rate, size_t(rate));
    const double after = top_energy(out.data() + out.size() - size_t(rate), size_t(rate));
    MESSAGE("energy above 10 kHz: before " << before << " dB, after " << after << " dB");
    CHECK(std::fabs(after - before) < 6.0);
}

TEST_CASE("voice shifter: Natural keeps the voice's resonances, Cartoon moves them") {
    const int rate = 48000;
    const auto in = make_vowel(120, rate, 3.0);
    const double in_centroid = spectral_centroid(in.data() + rate, size_t(rate), rate, 300, 4000);
    const double in_f0 = estimate_f0(in.data() + rate, size_t(rate), rate, 70, 400);
    double centroid[2], f0[2];
    for (int natural = 0; natural < 2; ++natural) {
        VoiceShifter v(rate, 4.0, natural == 1);
        std::vector<float> out;
        for (size_t i = 0; i < in.size(); i += 480) v.process(in.data() + i, std::min<size_t>(480, in.size() - i), out);
        REQUIRE(out.size() > size_t(rate) * 2);
        const float* tail = out.data() + out.size() - size_t(rate);
        centroid[natural] = spectral_centroid(tail, size_t(rate), rate, 300, 4000);
        f0[natural] = estimate_f0(tail, size_t(rate), rate, 70, 400);
    }
    const double expect_f0 = in_f0 * std::pow(2.0, 4.0 / 12);
    MESSAGE("input: f0 " << in_f0 << " Hz, centroid " << in_centroid << " Hz");
    MESSAGE("natural: f0 " << f0[1] << " Hz, centroid " << centroid[1] << " Hz (ratio " << centroid[1] / in_centroid << ")");
    MESSAGE("cartoon: f0 " << f0[0] << " Hz, centroid " << centroid[0] << " Hz (ratio " << centroid[0] / in_centroid << ")");
    CHECK(f0[1] == doctest::Approx(expect_f0).epsilon(0.03));
    CHECK(f0[0] == doctest::Approx(expect_f0).epsilon(0.03));
    CHECK(centroid[1] / in_centroid == doctest::Approx(1.0).epsilon(0.08));
    CHECK(centroid[0] / in_centroid > 1.15);
}
