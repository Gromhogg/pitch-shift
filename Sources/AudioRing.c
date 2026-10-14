// See AudioRing.h. The writer only moves `written`, the reader only moves `read`; each reads the other's counter
// with acquire/release order so the sound itself is always complete before the other side sees it.
#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AudioRing {
    float *left, *right;
    int capacity;
    atomic_llong written;   // total frames ever written
    atomic_llong read;      // total frames ever read or skipped
    atomic_int playing;     // reader state for audio_ring_play
    atomic_int dropouts, skips, overflows;
};

AudioRing *audio_ring_new(int capacityFrames) {
    AudioRing *ring = calloc(1, sizeof(AudioRing));
    if (!ring) return NULL;
    ring->capacity = capacityFrames > 0 ? capacityFrames : 1;
    ring->left = calloc((size_t)ring->capacity, sizeof(float));
    ring->right = calloc((size_t)ring->capacity, sizeof(float));
    if (!ring->left || !ring->right) { audio_ring_free(ring); return NULL; }
    return ring;
}

void audio_ring_free(AudioRing *ring) {
    if (!ring) return;
    free(ring->left);
    free(ring->right);
    free(ring);
}

int audio_ring_count(const AudioRing *ring) {
    long long w = atomic_load_explicit(&((AudioRing *)ring)->written, memory_order_acquire);
    long long r = atomic_load_explicit(&((AudioRing *)ring)->read, memory_order_acquire);
    return (int)(w - r);
}

int audio_ring_capacity(const AudioRing *ring) { return ring->capacity; }

// Copies `frames` into or out of the ring starting at absolute position `pos`, wrapping around the end.
static void copy_in(AudioRing *ring, long long pos, const float *src, float *dst, int frames) {
    int start = (int)(pos % ring->capacity);
    int first = frames < ring->capacity - start ? frames : ring->capacity - start;
    memcpy(dst + start, src, (size_t)first * sizeof(float));
    if (frames > first) memcpy(dst, src + first, (size_t)(frames - first) * sizeof(float));
}

static void copy_out(AudioRing *ring, long long pos, const float *src, float *dst, int frames) {
    int start = (int)(pos % ring->capacity);
    int first = frames < ring->capacity - start ? frames : ring->capacity - start;
    memcpy(dst, src + start, (size_t)first * sizeof(float));
    if (frames > first) memcpy(dst + first, src, (size_t)(frames - first) * sizeof(float));
}

int audio_ring_write(AudioRing *ring, const float *left, const float *right, int frames) {
    long long w = atomic_load_explicit(&ring->written, memory_order_relaxed);
    long long r = atomic_load_explicit(&ring->read, memory_order_acquire);
    int space = ring->capacity - (int)(w - r);
    int n = frames < space ? frames : space;
    if (n < frames) atomic_fetch_add_explicit(&ring->overflows, 1, memory_order_relaxed);
    if (n <= 0) return 0;
    copy_in(ring, w, left, ring->left, n);
    copy_in(ring, w, right ? right : left, ring->right, n);
    atomic_store_explicit(&ring->written, w + n, memory_order_release);
    return n;
}

int audio_ring_read(AudioRing *ring, float *left, float *right, int frames) {
    long long r = atomic_load_explicit(&ring->read, memory_order_relaxed);
    long long w = atomic_load_explicit(&ring->written, memory_order_acquire);
    int have = (int)(w - r);
    int n = frames < have ? frames : have;
    if (n <= 0) return 0;
    copy_out(ring, r, ring->left, left, n);
    copy_out(ring, r, ring->right, right, n);
    atomic_store_explicit(&ring->read, r + n, memory_order_release);
    return n;
}

void audio_ring_skip(AudioRing *ring, int frames) {
    long long r = atomic_load_explicit(&ring->read, memory_order_relaxed);
    long long w = atomic_load_explicit(&ring->written, memory_order_acquire);
    int have = (int)(w - r);
    int n = frames < have ? frames : have;
    if (n > 0) atomic_store_explicit(&ring->read, r + n, memory_order_release);
}

void audio_ring_play(AudioRing *ring, float *left, float *right, int frames, int startFrames, int maxFrames) {
    int count = audio_ring_count(ring);
    int playing = atomic_load_explicit(&ring->playing, memory_order_relaxed);
    if (!playing && count >= startFrames + frames) {
        // Start with exactly the cushion waiting, so a burst that came in at once doesn't become extra delay.
        audio_ring_skip(ring, count - startFrames - frames);
        playing = 1;
    } else if (playing && count > maxFrames + frames) {
        audio_ring_skip(ring, count - startFrames - frames);
        atomic_fetch_add_explicit(&ring->skips, 1, memory_order_relaxed);
    }
    int got = 0;
    if (playing) {
        got = audio_ring_read(ring, left, right, frames);
        if (got < frames) {  // ran dry: wait for the cushion to fill again
            playing = 0;
            atomic_fetch_add_explicit(&ring->dropouts, 1, memory_order_relaxed);
        }
    }
    if (got < frames) {
        memset(left + got, 0, (size_t)(frames - got) * sizeof(float));
        memset(right + got, 0, (size_t)(frames - got) * sizeof(float));
    }
    atomic_store_explicit(&ring->playing, playing, memory_order_relaxed);
}

int audio_ring_dropouts(const AudioRing *ring) { return atomic_load_explicit(&((AudioRing *)ring)->dropouts, memory_order_relaxed); }
int audio_ring_skips(const AudioRing *ring) { return atomic_load_explicit(&((AudioRing *)ring)->skips, memory_order_relaxed); }
int audio_ring_overflows(const AudioRing *ring) { return atomic_load_explicit(&((AudioRing *)ring)->overflows, memory_order_relaxed); }
int audio_ring_is_playing(const AudioRing *ring) { return atomic_load_explicit(&((AudioRing *)ring)->playing, memory_order_relaxed); }
