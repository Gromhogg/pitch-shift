// Test-only settings for the Advanced engine (used by the test programs, not by the app).
// Call right after advanced_new, before the first advanced_process / advanced_set_semis.
#ifndef ADVANCED_TUNING_H
#define ADVANCED_TUNING_H
#include "AdvancedChain.h"
#ifdef __cplusplus
extern "C" {
#endif

// key / default:
//   "recipe" 3       3: balanced3 (research round 4, the app's recipe); 2: balanced2 (round 3: blend ramp for +3..+7 with
//                    the unfolded low band riding in the main shifter, no fold floor, EQ without the deeper low cuts)
//   "fold2" 1        second fold (N-24) for N > +15 (0: the one fold keeps going up with N)
//   "floor2" 1       fold floor for the second fold too (its sub bass goes one level up); 0 = none
//   "floorhz" 35, "floorout" 30   fold floor and the fold's output high-pass on +3..+7 (Hz)
//   "airmin" 7000    pitch-down: the unshifted top band never starts below this (Hz)
//   "catchup" 2      a new amount's shifters are fed up to this many times faster than real time while they catch up
//   "fadems" 80      crossfade from the old amount to the new one (ms)
//   "foldstart" 3, "foldfull" 7   fold weight ramps from 0 at foldstart to 1 at foldfull (half-steps)
//   "keepfadems" 30  fade-in of `keep` when it starts (0 = none, for tests)
//   "limiter" 1      safety limiter on (0: gain always 1; its 2 ms delay stays, so the latency doesn't change)
// Returns 0 if the key is unknown.
int advanced_tune(AdvancedChain *chain, const char *key, double value);

// What the safety limiter has done so far.
typedef struct {
    double maxReductionDb;      // largest gain reduction (dB, 0 = never acted)
    long long samplesLimited;   // frames with gain below 1 (includes the long, tiny tail of each release)
    long long samplesLimitedOver01dB;  // frames with more than 0.1 dB of gain reduction
    long long samples;          // frames processed
    long long roundingClamps;   // samples the final rounding guard had to clip (should stay 0)
} AdvancedLimiterStats;
void advanced_limiter_stats(const AdvancedChain *chain, AdvancedLimiterStats *stats);

#ifdef __cplusplus
}
#endif
#endif
