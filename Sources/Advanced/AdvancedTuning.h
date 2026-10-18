// Test-only settings for the Advanced engine (used by the test programs, not by the app).
// Call right after advanced_new, before the first advanced_process / advanced_set_semis.
#ifndef ADVANCED_TUNING_H
#define ADVANCED_TUNING_H
#include "AdvancedChain.h"
#ifdef __cplusplus
extern "C" {
#endif

// key / default:
//   "recipe" 5       5: recipe 4 plus the pitch-aware tone fix (the app's recipe: the EQ knows which way the pitch
//                    went; the recipe 5 knobs below); 4: balanced3 with the bass fix (steep, power-keeping fold floor
//                    at 45 Hz; going up, the EQ treats the bass like the rest instead of cutting moved bass notes);
//                    3: balanced3 exactly as in 2.0.0 (research round 4: floor at 35 Hz with LR4 splits, deeper EQ
//                    cuts below 100 Hz both ways); 2: balanced2 (round 3: blend ramp for +3..+7 with the unfolded low
//                    band riding in the main shifter, no fold floor, EQ without the deeper low cuts).
//                    Set "recipe" first: it resets "floorhz" and all the recipe 5 knobs to its own values (recipes
//                    2-4: every recipe 5 knob off, so the output is exactly that recipe's).
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
// Recipe 5 knobs (value with recipe 5; with recipes 2-4 they are off):
//   "edgefix" 1      the EQ's prediction counts a frequency on a band edge in both bands, as its measurement does
//                    (0: in the lower band only, which made the EQ boost the bass a little)
//   "up25" .. "up12800", "dn25" .. "dn12800"   target offsets (dB) going up / down, one knot per octave at
//                    25 x 2^i Hz (25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800), in between on a log scale,
//                    flat past the ends. Scaled by min(1, |N| / offn). Recipe 5: dn100 1, dn200 0.5, dn800 -0.5,
//                    dn1600 -0.5, up800 -0.5, up1600 -0.5, the rest 0.
//   "offn" 8         amount (half-steps) from which the offsets and "subhz" apply in full
//   "lowcapdn" 3     going down: largest boost below 70 Hz (dB); -99 = off (use "lowcap")
//   "midcutdn" 9     going down: deepest cut of the 250 Hz filter (dB; the other mid filters stay at 6); -1 = off
//   "midcutup" 8     going up: deepest cut of the 500 Hz, 1 kHz and 2 kHz filters (dB); -1 = off
//   "topcutup" 3     going up: deepest cut from 7 kHz up (dB; the 8 kHz and 11.3 kHz filters may go 1 dB further),
//                    so the top stays closer to normal mode's; -1 = off
//   "subhz" 40       going down: 4th-order high-pass on the shifted sound (Hz, scaled by min(1, |N| / offn)): the
//                    original's deep bass moved below 40 Hz; 0 = none
//   "airbw" 1        going down: the split to the unshifted top is a Butterworth 4 (its two sides add up to full
//                    power) instead of a Linkwitz-Riley 4 (a -3 dB dip at the split, 7-15 kHz)
//   "fastrel" 25     limiter: release time (ms) after a short over (shorter than 5 ms); longer ones keep 120 ms.
//                    0 = always 120 ms
//   "guard" 0        limiter headroom guard: while the limiter works more than 1 % of an EQ period, the bass filters'
//                    boost is trimmed 0.5 dB per period (back 0.05 dB per period), at most this many dB; 0 = off
// Bass / treble setting (advanced_set_tone):
//   "tonelohz" 150, "tonehihz" 5000   corner of the low shelf and of the high shelf (Hz)
// Auto EQ (advanced_set_auto_eq):
//   "aeqrange" 8     largest automatic gain, up or down (dB, 0..15)
//   "aeqattack" 300, "aeqrelease" 1500   time constants (ms) of a cut (a section too loud is pulled down) and of a
//                    lift (a section too quiet is brought up)
//   "aeqwindow" 1000 how much sound each level is measured over (ms, 1 block .. 5000). The first plan was 400 / 80 /
//                    600 ms; on the test songs it matched worse and wobbled more. Tuned on 6 songs x 8 amounts (and
//                    checked on 2 more): range 8 / 300 / 1500 ms match as well as 6 / 200 / 1000 and move 20 % less
//                    (notes, "Auto EQ")
//   "aeqf1" 80, "aeqf2" 250, "aeqf3" 2000, "aeqf4" 8000   the crossovers between the five sections (Hz; kept
//                    rising by at least a third of an octave and under 0.45 x the sample rate)
//   "aeqfloor" -60   a section quieter than this (dBFS) in both the original and the sound is left at 0 dB
//   "aeqlowhz" 20    Sub is measured from here up (a 2nd-order high-pass on the measuring only; 0 = from 0 Hz)
//   "aeqweight" 1    the totals that keep the overall level are weighted like a loudness meter (K-weighting at each
//                    section's middle); 0 = plain power (a bass cut then lifts the other sections more)
//   "aeqkeep" 1      take back out the level change the smoothing makes (cuts are faster than lifts, so the gains
//                    alone drift down); 0 = leave it
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
