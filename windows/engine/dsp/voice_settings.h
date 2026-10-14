// The voice's Rubber Band settings, all in one place so they're easy to change. They match the Mac app:
// the full real-time stretcher (R3 "finer" engine) with the short window and high pitch consistency.
// (Rubber Band's separate "live shifter" is not used: it only keeps formants up to about 10 kHz and
// adds a hiss band above that, which sounded like a "Z" on every word.)
// The voice style is a number from 0 to 1 (the slider):
//   0 = Natural: keeps the voice's character (formants stay put)
//   1 = Cartoon: chipmunk / monster (formants move with the pitch)
//   in between: the formants move part of the way
#pragma once
#include <rubberband/RubberBandStretcher.h>

#include <algorithm>
#include <cmath>

namespace ps::voice_settings {

using RB = RubberBand::RubberBandStretcher;

// Formants are always "preserved"; the style then sets how far they move (formant_scale).
inline int options() {
    return RB::OptionProcessRealTime | RB::OptionEngineFiner | RB::OptionWindowShort | RB::OptionPitchHighConsistency |
           RB::OptionFormantPreserved;
}

// How far the formants move for a style from 0 to 1: they end up moved by pitch^cartoon (not at all for Natural,
// as much as the pitch for Cartoon). Rubber Band counts this from the already shifted sound, so it gets
// pitch^(cartoon - 1). At 0 it gets 0, meaning "keep the formants" (exactly the old Natural); at 1 it gets 1,
// meaning "leave them where the pitch puts them" (exactly the old Cartoon).
inline double formant_scale(double half_steps, double cartoon) {
    return cartoon <= 0 ? 0.0 : std::pow(2.0, half_steps / 12.0 * (std::min(cartoon, 1.0) - 1.0));
}

// A new style glides there, so moving the slider never clicks: all the way from 0 to 1 in this time.
constexpr double kStyleGlideSeconds = 0.15;

constexpr size_t kMaxProcess = 4096;  // largest piece handed to Rubber Band at once

// The cushion between the voice and the virtual cable (see drift_buffer.h).
constexpr double kSpareMs = 20;      // keep this much extra waiting after each piece is taken
constexpr double kTrimAboveMs = 25;  // if the extra never dropped below this for 0.5 s, trim back to kSpareMs
constexpr double kLowMs = 5;         // if it dropped below this, play a little again (the clocks drift)

}  // namespace ps::voice_settings
