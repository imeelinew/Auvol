#ifndef AUVOL_AUDIO_RING_H
#define AUVOL_AUDIO_RING_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AuvolAudioRing AuvolAudioRing;

typedef struct {
    uint64_t pushedFrames;
    uint64_t renderedFrames;
    uint64_t underrunFrames;
    uint64_t overflowFrames;
    uint32_t availableFrames;
    uint32_t lastRenderFrames;
    uint32_t maxRenderFrames;
} AuvolAudioRingStats;

AuvolAudioRing *auvol_ring_create(uint32_t capacityFrames);
void auvol_ring_destroy(AuvolAudioRing *ring);
void auvol_ring_reset(AuvolAudioRing *ring);
void auvol_ring_set_playback_enabled(AuvolAudioRing *ring, uint32_t enabled);

uint32_t auvol_ring_write(AuvolAudioRing *ring,
                          const float *interleavedStereo,
                          uint32_t frames);
uint32_t auvol_ring_write_silence(AuvolAudioRing *ring, uint32_t frames);
uint32_t auvol_ring_available(const AuvolAudioRing *ring);
uint32_t auvol_ring_discard(AuvolAudioRing *ring, uint32_t frames);

void auvol_ring_render_stereo(AuvolAudioRing *ring,
                              float *left,
                              float *right,
                              uint32_t frames);
void auvol_ring_snapshot(const AuvolAudioRing *ring,
                         AuvolAudioRingStats *stats);

#ifdef __cplusplus
}
#endif

#endif
