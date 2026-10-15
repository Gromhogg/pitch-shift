// Test-only settings for the Advanced engine (used by the test programs, not by the app).
// Call right after advanced_new, before the first advanced_process / advanced_set_semis.
#ifndef ADVANCED_TUNING_H
#define ADVANCED_TUNING_H
#include "AdvancedChain.h"
#ifdef __cplusplus
extern "C" {
#endif

// key / default:
//   "recipe" 4       4: balanced3 with the bass fix (the app's recipe after 2.0.0: steep, power-keeping fold floor at
//                    45 Hz; going up, the EQ treats the bass like the rest instead of cutting moved bass notes);
//                    3: balanced3 exactly as in 2.0.0 (research round 4: floor at 35 Hz with LR4 splits, deeper EQ
//                    cuts below 100 Hz both ways); 2: balanced2 (round 3: blend ramp for +3..+7 with the unfolded low
//                    band riding in the main shifter, no fold floor, EQ without the deeper low cuts).
//                    Set "recipe" first: it resets "floorhz" to its own default.
//   "fold2" 1        second fold (N-24) for N > +15 (0: the one fold keeps going up with N)
//   "floor2" 1       fold floor for the second fold too (its sub bass goes one level up); 0 = none
//   "floorhz" 45, "floorendhz" 35, "floor2hz" 35, "floorout" 30   fold floor up to +8 (35 with recipe 3), the
//                    floor it eases to by +11 (recipe 4 only), the second fold's floor, and the fold's output
//                    high-pass on +3..+7 (Hz)
//   "airmin" 7000    pitch-down: the unshifted top band never starts below this (Hz)
//   "catchup" 2      a new amount's shifters are fed up to this many times faster than real time while they catch up
//   "fadems" 80      crossfade from the old amount to the new one (ms)
//   "foldstart" 3, "foldfull" 7   fold weight ramps from 0 at foldstart to 1 at foldfull (half-steps)
//   "keepfadems" 30  fade-in of `keep` when it starts (0 = none, for tests)
//   "limiter" 1      safety limiter on (0: gain always 1; its 2 ms delay stays, so the latency doesn't change)
//   "lowcap" 6       EQ: largest boost below 70 Hz (dB)
//   "eqalpha" 1      EQ strength: 1 = full, 0 = EQ off (its filters stay flat)
// Returns 0 if the key is unknown.
int advanced_tune(AdvancedChain *chain, const char *key, double value);

// The EQ gains applied right now in the chain being heard (dB): filter 0 is a low shelf at 44 Hz, 1-8 are peaks at
// 62.5, 125, 250, 500, 1000, 2000, 4000, 8000 Hz, 9 is a high shelf at 11.3 kHz. All 0 while the amount heard is 0.
void advanced_eq_gains(const AdvancedChain *chain, double g[10]);

// The EQ's last fit, per 1/3-octave band (band j is centred at 1000 x 10^((j-16)/10) Hz: 25 Hz .. 16 kHz):
// want = the change the band asked for (dB, before any limits), target = what the filters were fitted to (after the
// limits, the strength and the smoothing). Either may be NULL. Copies the first n bands; returns the band count (29).
int advanced_eq_bands(const AdvancedChain *chain, double *want, double *target, int n);

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
