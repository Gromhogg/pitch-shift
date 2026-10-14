// The voice's Rubber Band settings, all in one place so they're easy to change. They match the Mac app:
// the full real-time stretcher (R3 "finer" engine) with the short window and high pitch consistency.
// (Rubber Band's separate "live shifter" is not used: it only keeps formants up to about 10 kHz and
// adds a hiss band above that, which sounded like a "Z" on every word.)
//   Natural = keep the voice's character (formants preserved)
//   Cartoon = chipmunk / monster (formants move with the pitch)
#pragma once
#include <rubberband/RubberBandStretcher.h>

namespace ps::voice_settings {

using RB = RubberBand::RubberBandStretcher;

inline int formant_option(bool natural) { return natural ? RB::OptionFormantPreserved : RB::OptionFormantShifted; }

inline int options(bool natural) {
    return RB::OptionProcessRealTime | RB::OptionEngineFiner | RB::OptionWindowShort | RB::OptionPitchHighConsistency |
           formant_option(natural);
}

constexpr size_t kMaxProcess = 4096;  // largest piece handed to Rubber Band at once

// The cushion between the voice and the virtual cable (see drift_buffer.h).
constexpr double kSpareMs = 20;      // keep this much extra waiting after each piece is taken
constexpr double kTrimAboveMs = 25;  // if the extra never dropped below this for 0.5 s, trim back to kSpareMs
constexpr double kLowMs = 5;         // if it dropped below this, play a little again (the clocks drift)

}  // namespace ps::voice_settings
