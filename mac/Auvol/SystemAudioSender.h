#pragma once

#include <stdint.h>

typedef struct AuvolSystemAudioSender AuvolSystemAudioSender;

typedef struct AuvolSystemAudioSenderStats {
    uint64_t capturedFrames;
    uint64_t packetsSent;
    uint64_t sendErrors;
    uint64_t callbackCount;
    uint32_t sampleRate;
    uint32_t capturePeriodFrames;
    uint32_t sourceOutputDeviceID;
    uint32_t currentOutputDeviceID;
    float capturePeak;
    double callbackAgeMs;
} AuvolSystemAudioSenderStats;

AuvolSystemAudioSender *auvol_system_audio_sender_start(
    const char *targetIP,
    uint16_t port,
    char *errorText,
    uint32_t errorTextCapacity
);

void auvol_system_audio_sender_stop(AuvolSystemAudioSender *sender);

void auvol_system_audio_sender_snapshot(
    AuvolSystemAudioSender *sender,
    AuvolSystemAudioSenderStats *stats
);
