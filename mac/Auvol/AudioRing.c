#include "AudioRing.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

struct AuvolAudioRing {
    float *samples;
    uint32_t capacity;
    uint32_t mask;

    _Atomic uint64_t writePosition;
    _Atomic uint64_t readPosition;
    _Atomic uint64_t pushedFrames;
    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t underrunFrames;
    _Atomic uint64_t overflowFrames;
    _Atomic uint32_t lastRenderFrames;
    _Atomic uint32_t maxRenderFrames;
    _Atomic bool playbackEnabled;

    float lastLeft;
    float lastRight;
    bool starved;
};

static uint32_t next_power_of_two(uint32_t value) {
    uint32_t result = 1;
    while (result < value && result < (1u << 30)) {
        result <<= 1;
    }
    return result;
}

static uint32_t available_frames(const AuvolAudioRing *ring,
                                 memory_order writeOrder,
                                 memory_order readOrder) {
    const uint64_t write = atomic_load_explicit(&ring->writePosition, writeOrder);
    const uint64_t read = atomic_load_explicit(&ring->readPosition, readOrder);
    const uint64_t available = write >= read ? write - read : 0;
    return (uint32_t)(available > ring->capacity ? ring->capacity : available);
}

AuvolAudioRing *auvol_ring_create(uint32_t capacityFrames) {
    if (capacityFrames == 0) {
        return NULL;
    }

    AuvolAudioRing *ring = calloc(1, sizeof(AuvolAudioRing));
    if (!ring) {
        return NULL;
    }

    ring->capacity = next_power_of_two(capacityFrames);
    ring->mask = ring->capacity - 1;
    ring->samples = calloc((size_t)ring->capacity * 2, sizeof(float));
    if (!ring->samples) {
        free(ring);
        return NULL;
    }
    return ring;
}

void auvol_ring_destroy(AuvolAudioRing *ring) {
    if (!ring) {
        return;
    }
    free(ring->samples);
    free(ring);
}

void auvol_ring_reset(AuvolAudioRing *ring) {
    if (!ring) {
        return;
    }
    atomic_store_explicit(&ring->writePosition, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->readPosition, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->pushedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->underrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->overflowFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->lastRenderFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->maxRenderFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->playbackEnabled, false, memory_order_release);
    ring->lastLeft = 0;
    ring->lastRight = 0;
    ring->starved = false;
}

void auvol_ring_set_playback_enabled(AuvolAudioRing *ring, uint32_t enabled) {
    if (!ring) {
        return;
    }
    atomic_store_explicit(&ring->playbackEnabled, enabled != 0,
                          memory_order_release);
}

static uint32_t reserve_write(AuvolAudioRing *ring,
                              uint32_t frames,
                              uint64_t *writePosition) {
    if (!ring || frames == 0 || frames > ring->capacity) {
        return 0;
    }

    const uint64_t write = atomic_load_explicit(&ring->writePosition,
                                                memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&ring->readPosition,
                                               memory_order_acquire);
    const uint64_t used = write >= read ? write - read : ring->capacity;
    if (used > ring->capacity || frames > ring->capacity - used) {
        atomic_fetch_add_explicit(&ring->overflowFrames, frames,
                                  memory_order_relaxed);
        return 0;
    }
    *writePosition = write;
    return frames;
}

static void commit_write(AuvolAudioRing *ring,
                         uint64_t writePosition,
                         uint32_t frames) {
    atomic_store_explicit(&ring->writePosition, writePosition + frames,
                          memory_order_release);
    atomic_fetch_add_explicit(&ring->pushedFrames, frames,
                              memory_order_relaxed);
}

uint32_t auvol_ring_write(AuvolAudioRing *ring,
                          const float *interleavedStereo,
                          uint32_t frames) {
    if (!interleavedStereo) {
        return 0;
    }

    uint64_t writePosition = 0;
    if (!reserve_write(ring, frames, &writePosition)) {
        return 0;
    }

    const uint32_t start = (uint32_t)writePosition & ring->mask;
    const uint32_t first = frames < ring->capacity - start
        ? frames
        : ring->capacity - start;
    memcpy(ring->samples + (size_t)start * 2,
           interleavedStereo,
           (size_t)first * 2 * sizeof(float));
    if (frames > first) {
        memcpy(ring->samples,
               interleavedStereo + (size_t)first * 2,
               (size_t)(frames - first) * 2 * sizeof(float));
    }
    commit_write(ring, writePosition, frames);
    return frames;
}

uint32_t auvol_ring_write_silence(AuvolAudioRing *ring, uint32_t frames) {
    uint64_t writePosition = 0;
    if (!reserve_write(ring, frames, &writePosition)) {
        return 0;
    }

    const uint32_t start = (uint32_t)writePosition & ring->mask;
    const uint32_t first = frames < ring->capacity - start
        ? frames
        : ring->capacity - start;
    memset(ring->samples + (size_t)start * 2,
           0,
           (size_t)first * 2 * sizeof(float));
    if (frames > first) {
        memset(ring->samples,
               0,
               (size_t)(frames - first) * 2 * sizeof(float));
    }
    commit_write(ring, writePosition, frames);
    return frames;
}

uint32_t auvol_ring_available(const AuvolAudioRing *ring) {
    return ring ? available_frames(ring, memory_order_acquire,
                                   memory_order_acquire) : 0;
}

uint32_t auvol_ring_discard(AuvolAudioRing *ring, uint32_t frames) {
    if (!ring || frames == 0) {
        return 0;
    }
    const uint64_t read = atomic_load_explicit(&ring->readPosition,
                                               memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&ring->writePosition,
                                                memory_order_acquire);
    const uint64_t rawAvailable = write >= read ? write - read : 0;
    const uint32_t available = (uint32_t)(rawAvailable > ring->capacity
        ? ring->capacity
        : rawAvailable);
    const uint32_t discarded = frames < available ? frames : available;
    atomic_store_explicit(&ring->readPosition, read + discarded,
                          memory_order_release);
    return discarded;
}

static void update_max_render_frames(AuvolAudioRing *ring, uint32_t frames) {
    uint32_t current = atomic_load_explicit(&ring->maxRenderFrames,
                                            memory_order_relaxed);
    while (frames > current &&
           !atomic_compare_exchange_weak_explicit(&ring->maxRenderFrames,
                                                  &current,
                                                  frames,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
    }
}

void auvol_ring_render_stereo(AuvolAudioRing *ring,
                              float *left,
                              float *right,
                              uint32_t frames) {
    if (!ring || !left || !right || frames == 0) {
        return;
    }

    atomic_store_explicit(&ring->lastRenderFrames, frames, memory_order_relaxed);
    update_max_render_frames(ring, frames);

    if (!atomic_load_explicit(&ring->playbackEnabled, memory_order_acquire)) {
        memset(left, 0, (size_t)frames * sizeof(float));
        memset(right, 0, (size_t)frames * sizeof(float));
        return;
    }

    const uint64_t readPosition = atomic_load_explicit(&ring->readPosition,
                                                       memory_order_relaxed);
    const uint64_t writePosition = atomic_load_explicit(&ring->writePosition,
                                                        memory_order_acquire);
    const uint64_t rawAvailable = writePosition >= readPosition
        ? writePosition - readPosition
        : 0;
    const uint32_t available = (uint32_t)(rawAvailable > ring->capacity
        ? ring->capacity
        : rawAvailable);
    const uint32_t readable = frames < available ? frames : available;
    const uint32_t start = (uint32_t)readPosition & ring->mask;

    for (uint32_t i = 0; i < readable; ++i) {
        const uint32_t index = (start + i) & ring->mask;
        left[i] = ring->samples[(size_t)index * 2];
        right[i] = ring->samples[(size_t)index * 2 + 1];
    }

    if (readable > 0) {
        ring->lastLeft = left[readable - 1];
        ring->lastRight = right[readable - 1];
    }

    if (ring->starved && readable > 0) {
        const uint32_t fadeFrames = readable < 64 ? readable : 64;
        for (uint32_t i = 0; i < fadeFrames; ++i) {
            const float gain = (float)(i + 1) / (float)fadeFrames;
            left[i] *= gain;
            right[i] *= gain;
        }
        ring->starved = false;
    }

    if (readable < frames) {
        const uint32_t missing = frames - readable;
        const uint32_t fadeFrames = missing < 64 ? missing : 64;
        for (uint32_t i = 0; i < missing; ++i) {
            float gain = 0;
            if (i < fadeFrames) {
                gain = 1.0f - (float)(i + 1) / (float)fadeFrames;
            }
            left[readable + i] = ring->lastLeft * gain;
            right[readable + i] = ring->lastRight * gain;
        }
        ring->lastLeft = 0;
        ring->lastRight = 0;
        ring->starved = true;
        atomic_fetch_add_explicit(&ring->underrunFrames, missing,
                                  memory_order_relaxed);
    }

    atomic_store_explicit(&ring->readPosition, readPosition + readable,
                          memory_order_release);
    atomic_fetch_add_explicit(&ring->renderedFrames, frames,
                              memory_order_relaxed);
}

void auvol_ring_snapshot(const AuvolAudioRing *ring,
                         AuvolAudioRingStats *stats) {
    if (!stats) {
        return;
    }
    memset(stats, 0, sizeof(*stats));
    if (!ring) {
        return;
    }

    stats->pushedFrames = atomic_load_explicit(&ring->pushedFrames,
                                               memory_order_relaxed);
    stats->renderedFrames = atomic_load_explicit(&ring->renderedFrames,
                                                 memory_order_relaxed);
    stats->underrunFrames = atomic_load_explicit(&ring->underrunFrames,
                                                 memory_order_relaxed);
    stats->overflowFrames = atomic_load_explicit(&ring->overflowFrames,
                                                 memory_order_relaxed);
    stats->availableFrames = auvol_ring_available(ring);
    stats->lastRenderFrames = atomic_load_explicit(&ring->lastRenderFrames,
                                                   memory_order_relaxed);
    stats->maxRenderFrames = atomic_load_explicit(&ring->maxRenderFrames,
                                                  memory_order_relaxed);
}
