// A ring of stereo sound shared by one writer thread and one reader thread. No locks and no memory is made after
// audio_ring_new, so the sound threads never wait. Used by "Advanced processing" (AdvancedShifter.swift).
#ifndef AUDIO_RING_H
#define AUDIO_RING_H

typedef struct AudioRing AudioRing;

AudioRing *audio_ring_new(int capacityFrames);
void audio_ring_free(AudioRing *ring);

// Frames waiting to be read.
int audio_ring_count(const AudioRing *ring);
int audio_ring_capacity(const AudioRing *ring);

// Writer side. Returns the frames written; what doesn't fit is dropped (counted in audio_ring_overflows).
int audio_ring_write(AudioRing *ring, const float *left, const float *right, int frames);

// Reader side. Returns the frames read (fewer if the ring holds less).
int audio_ring_read(AudioRing *ring, float *left, float *right, int frames);
// Reader side: throws away up to `frames` of the oldest sound.
void audio_ring_skip(AudioRing *ring, int frames);

// Reader side, for the speakers: fills `frames` with sound, keeping a cushion. It starts (and restarts after
// running dry) once `startFrames` are waiting, and skips old sound when more than `maxFrames` pile up
// (the speakers' clock runs a little slower than the source's). Gaps are filled with silence.
void audio_ring_play(AudioRing *ring, float *left, float *right, int frames, int startFrames, int maxFrames);

// Counters for checks (any thread).
int audio_ring_dropouts(const AudioRing *ring);   // times the cushion ran dry
int audio_ring_skips(const AudioRing *ring);      // times old sound was skipped to stay close to live
int audio_ring_overflows(const AudioRing *ring);  // times the writer found the ring full
int audio_ring_is_playing(const AudioRing *ring);

#endif
