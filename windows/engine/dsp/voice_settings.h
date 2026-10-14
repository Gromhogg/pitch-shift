// The voice's Rubber Band settings, all in one place so they're easy to change.
// They match the Mac app: Rubber Band's live shifter with the short window.
//   Natural = keep the voice's character (formants preserved)
//   Cartoon = chipmunk / monster (formants move with the pitch)
#pragma once
#include <rubberband/rubberband-c.h>

namespace ps::voice_settings {

constexpr int kWindow = RubberBandLiveOptionWindowShort;
constexpr int kNatural = RubberBandLiveOptionFormantPreserved;
constexpr int kCartoon = RubberBandLiveOptionFormantShifted;

// Options for rubberband_live_new and rubberband_live_set_formant_option.
inline int options(bool natural) { return kWindow | (natural ? kNatural : kCartoon); }

// Extra formant scale (1.0 = Rubber Band's default for the chosen style).
constexpr double kFormantScale = 1.0;

}  // namespace ps::voice_settings
