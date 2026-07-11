#import "SystemAudioSender.h"

#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum {
    kAuvolMagic = 0x32564c41u,
    kAuvolConfigType = 0,
    kAuvolAudioType = 1,
    kAuvolConfigBytes = 28,
    kAuvolAudioBytes = 32,
    kAuvolChannels = 2,
    kAuvolMaximumPacketFrames = 160,
};

struct AuvolSystemAudioSender {
    AudioObjectID tapID;
    AudioObjectID aggregateDeviceID;
    AudioDeviceIOProcID ioProcID;
    int socketFD;
    struct sockaddr_in destination;
    uint32_t streamID;
    uint32_t sequence;
    uint32_t sampleRate;
    uint32_t capturePeriodFrames;
    uint32_t inputBytesPerFrame;
    uint32_t sourceOutputDeviceID;
    uint64_t nextFrame;
    uint64_t nextConfigFrame;
    _Atomic uint64_t capturedFrames;
    _Atomic uint64_t packetsSent;
    _Atomic uint64_t sendErrors;
    _Atomic uint64_t callbackCount;
    _Atomic uint64_t lastCallbackMachTime;
    _Atomic uint32_t capturePeakBits;
};

static void Write16(uint8_t *destination, uint16_t value) {
    memcpy(destination, &value, sizeof(value));
}

static void Write32(uint8_t *destination, uint32_t value) {
    memcpy(destination, &value, sizeof(value));
}

static void Write64(uint8_t *destination, uint64_t value) {
    memcpy(destination, &value, sizeof(value));
}

static uint32_t NewStreamID(void) {
    uint64_t time = mach_continuous_time();
    uint32_t value = (uint32_t)time ^ (uint32_t)(time >> 32) ^
        (uint32_t)getpid();
    return value == 0 ? 1 : value;
}

static uint32_t FloatBits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float BitsFloat(uint32_t bits) {
    float value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void AccumulateCapturePeak(AuvolSystemAudioSender *sender,
                                  float peak) {
    const uint32_t desired = FloatBits(peak);
    uint32_t current = atomic_load_explicit(&sender->capturePeakBits,
                                            memory_order_relaxed);
    while (desired > current &&
           !atomic_compare_exchange_weak_explicit(&sender->capturePeakBits,
                                                  &current, desired,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
    }
}

static void SetError(char *destination, uint32_t capacity, const char *message) {
    if (!destination || capacity == 0) return;
    snprintf(destination, capacity, "%s", message);
}

static bool SendBytes(AuvolSystemAudioSender *sender,
                      const void *bytes,
                      size_t length) {
    const ssize_t sent = sendto(sender->socketFD, bytes, length, 0,
                                (const struct sockaddr *)&sender->destination,
                                sizeof(sender->destination));
    if (sent == (ssize_t)length) return true;
    atomic_fetch_add_explicit(&sender->sendErrors, 1, memory_order_relaxed);
    return false;
}

static void SendConfig(AuvolSystemAudioSender *sender) {
    uint8_t packet[kAuvolConfigBytes] = {};
    Write32(packet + 0, kAuvolMagic);
    Write16(packet + 4, kAuvolConfigType);
    Write16(packet + 6, kAuvolConfigBytes);
    Write32(packet + 8, sender->streamID);
    Write32(packet + 12, sender->sampleRate);
    Write16(packet + 16, kAuvolChannels);
    Write16(packet + 18, kAuvolMaximumPacketFrames);
    Write32(packet + 20, sender->capturePeriodFrames);
    SendBytes(sender, packet, sizeof(packet));
}

static void SendAudio(AuvolSystemAudioSender *sender,
                      uint64_t firstFrame,
                      const AudioBufferList *input,
                      uint32_t offset,
                      uint16_t frames) {
    uint8_t packet[kAuvolAudioBytes + kAuvolMaximumPacketFrames * kAuvolChannels * sizeof(float)] = {};
    Write32(packet + 0, kAuvolMagic);
    Write16(packet + 4, kAuvolAudioType);
    Write16(packet + 6, kAuvolAudioBytes);
    Write32(packet + 8, sender->streamID);
    Write32(packet + 12, sender->sequence++);
    Write64(packet + 16, firstFrame + offset);
    Write16(packet + 24, frames);
    Write16(packet + 26, kAuvolChannels);

    float *destination = (float *)(packet + kAuvolAudioBytes);
    if (input->mNumberBuffers == 1) {
        const AudioBuffer *buffer = &input->mBuffers[0];
        const float *source = (const float *)buffer->mData;
        memcpy(destination, source + (size_t)offset * kAuvolChannels,
               (size_t)frames * kAuvolChannels * sizeof(float));
    } else if (input->mNumberBuffers >= 2) {
        const float *left = (const float *)input->mBuffers[0].mData + offset;
        const float *right = (const float *)input->mBuffers[1].mData + offset;
        for (uint16_t index = 0; index < frames; ++index) {
            destination[index * 2] = left[index];
            destination[index * 2 + 1] = right[index];
        }
    } else {
        return;
    }

    const size_t bytes = kAuvolAudioBytes +
        (size_t)frames * kAuvolChannels * sizeof(float);
    if (SendBytes(sender, packet, bytes)) {
        atomic_fetch_add_explicit(&sender->packetsSent, 1, memory_order_relaxed);
    }
}

static OSStatus SenderIOProc(AudioObjectID device,
                             const AudioTimeStamp *now,
                             const AudioBufferList *input,
                             const AudioTimeStamp *inputTime,
                             AudioBufferList *output,
                             const AudioTimeStamp *outputTime,
                             void *context) {
    (void)device;
    (void)now;
    (void)output;
    (void)outputTime;
    AuvolSystemAudioSender *sender = context;
    if (!sender) return noErr;
    atomic_fetch_add_explicit(&sender->callbackCount, 1,
                              memory_order_relaxed);
    atomic_store_explicit(&sender->lastCallbackMachTime,
                          mach_continuous_time(), memory_order_relaxed);
    if (!input || input->mNumberBuffers == 0 ||
        !input->mBuffers[0].mData) return noErr;

    const uint32_t bytesPerFrame = input->mNumberBuffers == 1
        ? sender->inputBytesPerFrame
        : (uint32_t)sizeof(float);
    const uint32_t frames = bytesPerFrame == 0 ? 0 :
        input->mBuffers[0].mDataByteSize / bytesPerFrame;
    if (frames == 0) return noErr;

    float peak = 0;
    if (input->mNumberBuffers == 1) {
        const float *samples = input->mBuffers[0].mData;
        const size_t sampleCount = (size_t)frames * kAuvolChannels;
        for (size_t index = 0; index < sampleCount; ++index) {
            peak = fmaxf(peak, fabsf(samples[index]));
        }
    } else {
        const float *left = input->mBuffers[0].mData;
        const float *right = input->mBuffers[1].mData;
        for (uint32_t index = 0; index < frames; ++index) {
            peak = fmaxf(peak, fabsf(left[index]));
            peak = fmaxf(peak, fabsf(right[index]));
        }
    }
    AccumulateCapturePeak(sender, peak);

    uint64_t firstFrame = sender->nextFrame;
    if (inputTime && (inputTime->mFlags & kAudioTimeStampSampleTimeValid) &&
        inputTime->mSampleTime >= 0) {
        firstFrame = (uint64_t)inputTime->mSampleTime;
    }
    if (firstFrame >= sender->nextConfigFrame) {
        SendConfig(sender);
        sender->nextConfigFrame = firstFrame + sender->sampleRate / 2;
    }

    for (uint32_t offset = 0; offset < frames;) {
        const uint16_t chunk = (uint16_t)((frames - offset) > kAuvolMaximumPacketFrames
            ? kAuvolMaximumPacketFrames : frames - offset);
        SendAudio(sender, firstFrame, input, offset, chunk);
        offset += chunk;
    }
    sender->nextFrame = firstFrame + frames;
    atomic_fetch_add_explicit(&sender->capturedFrames, frames, memory_order_relaxed);
    return noErr;
}

static bool ReadTapFormat(AudioObjectID tap,
                          AudioStreamBasicDescription *format) {
    AudioObjectPropertyAddress formatAddress = {
        kAudioTapPropertyFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*format);
    return AudioObjectGetPropertyData(tap, &formatAddress, 0, NULL, &size,
                                      format) == noErr;
}

static bool ReadAggregatePeriod(AudioObjectID device, uint32_t *periodFrames) {
    AudioObjectPropertyAddress periodAddress = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*periodFrames);
    return AudioObjectGetPropertyData(device, &periodAddress, 0, NULL, &size,
                                      periodFrames) == noErr;
}

static bool ReadDefaultSystemOutputDevice(AudioObjectID *outputDevice) {
    if (!outputDevice) return false;
    *outputDevice = kAudioObjectUnknown;
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*outputDevice);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                      &defaultOutputAddress, 0, NULL, &size,
                                      outputDevice) == noErr &&
        *outputDevice != kAudioObjectUnknown;
}

static bool ReadDefaultSystemOutputUID(CFStringRef *outputUID,
                                       AudioObjectID *outputDevice) {
    if (!ReadDefaultSystemOutputDevice(outputDevice)) return false;
    AudioObjectPropertyAddress uidAddress = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*outputUID);
    return AudioObjectGetPropertyData(*outputDevice, &uidAddress, 0, NULL, &size,
                                      outputUID) == noErr && *outputUID;
}

AuvolSystemAudioSender *auvol_system_audio_sender_start(
    const char *targetIP,
    uint16_t port,
    char *errorText,
    uint32_t errorTextCapacity
) {
    if (!targetIP || targetIP[0] == '\0') {
        SetError(errorText, errorTextCapacity, "Enter the Windows IP address");
        return NULL;
    }

    AuvolSystemAudioSender *sender = calloc(1, sizeof(*sender));
    CATapDescription *tapDescription = nil;
    NSDictionary *subTap = nil;
    NSString *aggregateUID = nil;
    NSDictionary *aggregate = nil;
    AudioStreamBasicDescription format = {};
    bool formatReady = false;
    CFStringRef outputUID = NULL;
    if (!sender) {
        SetError(errorText, errorTextCapacity, "Cannot allocate sender");
        return NULL;
    }
    sender->socketFD = -1;
    sender->tapID = kAudioObjectUnknown;
    sender->aggregateDeviceID = kAudioObjectUnknown;
    sender->streamID = NewStreamID();

    sender->socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sender->socketFD < 0) {
        SetError(errorText, errorTextCapacity, "Cannot open UDP socket");
        goto failed;
    }
    int bufferSize = 1 << 20;
    setsockopt(sender->socketFD, SOL_SOCKET, SO_SNDBUF, &bufferSize,
               sizeof(bufferSize));
    int dscp = 0xb8;
    setsockopt(sender->socketFD, IPPROTO_IP, IP_TOS, &dscp, sizeof(dscp));
    sender->destination.sin_family = AF_INET;
    sender->destination.sin_port = htons(port);
    if (inet_pton(AF_INET, targetIP, &sender->destination.sin_addr) != 1) {
        SetError(errorText, errorTextCapacity, "Invalid Windows IP address");
        goto failed;
    }

    tapDescription =
        [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    tapDescription.name = @"Auvol system-audio sender";
    tapDescription.UUID = [NSUUID UUID];
    tapDescription.privateTap = YES;
    tapDescription.muteBehavior = CATapUnmuted;
    if (AudioHardwareCreateProcessTap(tapDescription, &sender->tapID) != noErr) {
        SetError(errorText, errorTextCapacity,
                 "System audio capture permission was denied");
        goto failed;
    }

    AudioObjectID outputDevice = kAudioObjectUnknown;
    if (!ReadDefaultSystemOutputUID(&outputUID, &outputDevice)) {
        SetError(errorText, errorTextCapacity, "Cannot read the Mac system output device");
        goto failed;
    }
    sender->sourceOutputDeviceID = outputDevice;

    subTap = @{
        @kAudioSubTapUIDKey: tapDescription.UUID.UUIDString,
        @kAudioSubTapDriftCompensationKey: @YES,
    };
    aggregateUID = [NSString stringWithFormat:@"com.eli.Auvol.tap.%@",
                    [[NSUUID UUID] UUIDString]];
    aggregate = @{
        @kAudioAggregateDeviceNameKey: @"Auvol System Audio",
        @kAudioAggregateDeviceUIDKey: aggregateUID,
        @kAudioAggregateDeviceMainSubDeviceKey: (__bridge NSString *)outputUID,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceSubDeviceListKey: @[
            @{ @kAudioSubDeviceUIDKey: (__bridge NSString *)outputUID },
        ],
        @kAudioAggregateDeviceTapListKey: @[ subTap ],
    };
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate,
                                           &sender->aggregateDeviceID) != noErr) {
        SetError(errorText, errorTextCapacity, "Cannot create system audio tap");
        goto failed;
    }
    CFRelease(outputUID);
    outputUID = NULL;

    for (int attempt = 0; attempt < 100; ++attempt) {
        if (ReadTapFormat(sender->tapID, &format)) {
            formatReady = true;
            break;
        }
        usleep(10000);
    }
    if (!formatReady ||
        format.mSampleRate < 8000 || format.mSampleRate > 192000 ||
        format.mChannelsPerFrame != kAuvolChannels ||
        format.mBitsPerChannel != 32 ||
        (format.mBytesPerFrame != sizeof(float) &&
         format.mBytesPerFrame != kAuvolChannels * sizeof(float)) ||
        !(format.mFormatFlags & kAudioFormatFlagIsFloat)) {
        SetError(errorText, errorTextCapacity,
                 "System audio tap is not stereo float32 PCM");
        goto failed;
    }
    sender->sampleRate = (uint32_t)format.mSampleRate;
    sender->inputBytesPerFrame = format.mBytesPerFrame;
    if (!ReadAggregatePeriod(sender->aggregateDeviceID,
                             &sender->capturePeriodFrames)) {
        sender->capturePeriodFrames = 512;
    }
    sender->nextConfigFrame = 0;

    const OSStatus createProc = AudioDeviceCreateIOProcID(
        sender->aggregateDeviceID, SenderIOProc, sender, &sender->ioProcID
    );
    if (createProc != noErr ||
        AudioDeviceStart(sender->aggregateDeviceID, sender->ioProcID) != noErr) {
        SetError(errorText, errorTextCapacity, "Cannot start system audio capture");
        goto failed;
    }
    return sender;

failed:
    if (outputUID) CFRelease(outputUID);
    auvol_system_audio_sender_stop(sender);
    return NULL;
}

void auvol_system_audio_sender_stop(AuvolSystemAudioSender *sender) {
    if (!sender) return;
    if (sender->ioProcID) {
        AudioDeviceStop(sender->aggregateDeviceID, sender->ioProcID);
        AudioDeviceDestroyIOProcID(sender->aggregateDeviceID, sender->ioProcID);
    }
    if (sender->aggregateDeviceID != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(sender->aggregateDeviceID);
    }
    if (sender->tapID != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(sender->tapID);
    }
    if (sender->socketFD >= 0) close(sender->socketFD);
    free(sender);
}

void auvol_system_audio_sender_snapshot(
    AuvolSystemAudioSender *sender,
    AuvolSystemAudioSenderStats *stats
) {
    if (!stats) return;
    memset(stats, 0, sizeof(*stats));
    if (!sender) return;
    stats->capturedFrames = atomic_load_explicit(&sender->capturedFrames,
                                                  memory_order_relaxed);
    stats->packetsSent = atomic_load_explicit(&sender->packetsSent,
                                              memory_order_relaxed);
    stats->sendErrors = atomic_load_explicit(&sender->sendErrors,
                                              memory_order_relaxed);
    stats->callbackCount = atomic_load_explicit(&sender->callbackCount,
                                                memory_order_relaxed);
    stats->sampleRate = sender->sampleRate;
    stats->capturePeriodFrames = sender->capturePeriodFrames;
    stats->sourceOutputDeviceID = sender->sourceOutputDeviceID;
    AudioObjectID currentOutput = kAudioObjectUnknown;
    if (ReadDefaultSystemOutputDevice(&currentOutput)) {
        stats->currentOutputDeviceID = currentOutput;
    }
    const uint32_t peakBits = atomic_exchange_explicit(
        &sender->capturePeakBits, 0, memory_order_relaxed);
    stats->capturePeak = BitsFloat(peakBits);
    const uint64_t lastCallback = atomic_load_explicit(
        &sender->lastCallbackMachTime, memory_order_relaxed);
    if (lastCallback == 0) {
        stats->callbackAgeMs = -1;
    } else {
        mach_timebase_info_data_t timebase = {};
        mach_timebase_info(&timebase);
        const uint64_t elapsed = mach_continuous_time() - lastCallback;
        stats->callbackAgeMs = (double)elapsed * (double)timebase.numer /
            (double)timebase.denom / 1.0e6;
    }
}
