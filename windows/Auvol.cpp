// Auvol Windows transport core: bidirectional WASAPI <-> ALV2 UDP float32 PCM.

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <commctrl.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <shellapi.h>

#include "resource.h"
#include "AuvolCore.h"

#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

static constexpr UINT32 MAGIC = 0x32564c41u; // Wire bytes: ALV2
static constexpr UINT16 TYPE_CONFIG = 0;
static constexpr UINT16 TYPE_AUDIO = 1;
static constexpr UINT16 CONFIG_HEADER_BYTES = 28;
static constexpr UINT16 AUDIO_HEADER_BYTES = 32;
static constexpr UINT16 CHANNELS = 2;
static constexpr UINT16 MAX_PACKET_FRAMES = 160;
static constexpr UINT16 AUDIO_FLAG_DISCONTINUITY = 1;

#ifndef WAVE_FORMAT_EXTENSIBLE
#define WAVE_FORMAT_EXTENSIBLE 0xFFFE
#endif

struct WaveFormatExt {
    WAVEFORMATEX Format;
    WORD validBitsPerSample;
    DWORD channelMask;
    GUID subFormat;
};

static const GUID SUBTYPE_FLOAT = {
    0x00000003, 0x0000, 0x0010,
    {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}
};

static HWND g_mainWindow = nullptr;
static HWND g_ipEdit = nullptr;
static HWND g_modeCombo = nullptr;
static HWND g_connectButton = nullptr;
static HWND g_disconnectButton = nullptr;
static HWND g_statusLabel = nullptr;
static HWND g_statsLabel = nullptr;
static std::string g_savedIP = "192.168.101.162";
static int g_savedMode = 0;
static bool g_savedRunning = false;
static std::atomic<bool> g_running{false};
static std::atomic<bool> g_connected{false};
static std::atomic<int> g_desiredMode{0};
static std::atomic<UINT64> g_controlGeneration{0};
static HANDLE g_controlEvent = nullptr;
static std::thread g_audioThread;
static std::string g_autoConnectIP;
static int g_autoMode = 0;
static std::mutex g_callbackMutex;
static auvol::TextCallback g_statusCallback;
static auvol::TextCallback g_statsCallback;
static auvol::RunningCallback g_runningCallback;
static auvol::ModeCallback g_modeCallback;

static bool SessionCurrent(UINT64 generation, int mode) {
    return g_running.load(std::memory_order_acquire) &&
           g_controlGeneration.load(std::memory_order_acquire) == generation &&
           g_desiredMode.load(std::memory_order_acquire) == mode;
}

class EndpointMonitor final : public IMMNotificationClient {
public:
    EndpointMonitor(HANDLE changedEvent, std::wstring activeDeviceID)
        : changedEvent_(changedEvent), activeDeviceID_(std::move(activeDeviceID)) {}

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&references_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const LONG remaining = InterlockedDecrement(&references_);
        if (remaining == 0) delete this;
        return static_cast<ULONG>(remaining);
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interfaceID,
                                             void** result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (IsEqualIID(interfaceID, __uuidof(IUnknown)) ||
            IsEqualIID(interfaceID, __uuidof(IMMNotificationClient))) {
            *result = static_cast<IMMNotificationClient*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow,
                                                     ERole role,
                                                     LPCWSTR) override {
        if (flow == eRender && (role == eConsole || role == eMultimedia)) {
            SetEvent(changedEvent_);
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }

    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR deviceID) override {
        signalIfActive(deviceID);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR deviceID,
                                                   DWORD) override {
        signalIfActive(deviceID);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR,
                                                     const PROPERTYKEY) override {
        return S_OK;
    }

private:
    void signalIfActive(LPCWSTR deviceID) {
        if (deviceID && activeDeviceID_ == deviceID) SetEvent(changedEvent_);
    }

    ~EndpointMonitor() = default;
    LONG references_ = 1;
    HANDLE changedEvent_ = nullptr;
    std::wstring activeDeviceID_;
};

static bool DeviceID(IMMDevice* device, std::wstring* result) {
    if (!device || !result) return false;
    LPWSTR value = nullptr;
    const HRESULT status = device->GetId(&value);
    if (FAILED(status) || !value) return false;
    *result = value;
    CoTaskMemFree(value);
    return true;
}

static bool DefaultEndpointMatches(IMMDeviceEnumerator* enumerator,
                                   const std::wstring& expectedID) {
    if (!enumerator || expectedID.empty()) return false;
    IMMDevice* current = nullptr;
    const HRESULT status = enumerator->GetDefaultAudioEndpoint(
        eRender, eConsole, &current
    );
    if (FAILED(status) || !current) return false;
    std::wstring currentID;
    const bool matched = DeviceID(current, &currentID) && currentID == expectedID;
    current->Release();
    return matched;
}

static void Put16(void* destination, UINT16 value) {
    memcpy(destination, &value, sizeof(value));
}

static void Put32(void* destination, UINT32 value) {
    memcpy(destination, &value, sizeof(value));
}

static void Put64(void* destination, UINT64 value) {
    memcpy(destination, &value, sizeof(value));
}

static UINT16 Get16(const void* source) {
    UINT16 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

static UINT32 Get32(const void* source) {
    UINT32 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

static UINT64 Get64(const void* source) {
    UINT64 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

static void PostText(UINT message, std::string text) {
    auvol::TextCallback callback;
    {
        std::lock_guard<std::mutex> lock(g_callbackMutex);
        callback = message == WM_APP + 1 ? g_statusCallback : g_statsCallback;
    }
    if (callback) {
        callback(std::move(text));
        return;
    }
    auto* payload = new std::string(std::move(text));
    if (!PostMessageA(g_mainWindow, message, 0,
                      reinterpret_cast<LPARAM>(payload))) {
        delete payload;
    }
}

static void NotifyRunning(bool running) {
    auvol::RunningCallback callback;
    {
        std::lock_guard<std::mutex> lock(g_callbackMutex);
        callback = g_runningCallback;
    }
    if (callback) callback(running);
}

static void NotifyMode(int mode) {
    auvol::ModeCallback callback;
    {
        std::lock_guard<std::mutex> lock(g_callbackMutex);
        callback = g_modeCallback;
    }
    if (callback) {
        callback(mode);
    } else if (g_mainWindow) {
        PostMessageW(g_mainWindow, WM_APP + 5,
                     static_cast<WPARAM>(mode), 0);
    }
}

static void PostStatus(const std::string& text) {
    PostText(WM_APP + 1, "Status: " + text);
}

static double PeakDBFS(float peak) {
    return peak > 0.000001f ? 20.0 * std::log10(static_cast<double>(peak))
                            : -120.0;
}

static void AccumulatePeak(std::atomic<float>* destination, float peak) {
    float current = destination->load(std::memory_order_relaxed);
    while (peak > current &&
           !destination->compare_exchange_weak(current, peak,
                                               std::memory_order_relaxed,
                                               std::memory_order_relaxed)) {
    }
}

static UINT32 NewStreamID() {
    LARGE_INTEGER counter = {};
    QueryPerformanceCounter(&counter);
    UINT32 value = counter.LowPart ^ counter.HighPart ^
                   GetCurrentProcessId() ^ GetTickCount();
    return value == 0 ? 1 : value;
}

static constexpr UINT32 DIRECTION_MAGIC = 0x31434c41u; // Wire bytes: ALC1
static constexpr UINT8 DIRECTION_SET = 1;
static constexpr UINT8 DIRECTION_ACK = 2;
static constexpr UINT16 DIRECTION_PORT = 7778;
static constexpr size_t DIRECTION_PACKET_BYTES = 24;

struct DirectionState {
    UINT64 version = 0;
    UINT64 originID = 0;
    UINT8 direction = 0;
};

static bool DirectionOutranks(const DirectionState& left,
                              const DirectionState& right) {
    return left.version != right.version
        ? left.version > right.version
        : left.originID > right.originID;
}

static bool DirectionSameKey(const DirectionState& left,
                             const DirectionState& right) {
    return left.version == right.version && left.originID == right.originID;
}

static std::mutex g_directionMutex;
static std::string g_directionPeerIP;
static bool g_directionStateLoaded = false;
static UINT64 g_directionDeviceID = 0;
static UINT64 g_directionClock = 0;
static DirectionState g_directionWinner;
static std::optional<DirectionState> g_directionPending;
static unsigned g_directionAttemptsSent = 0;
static std::chrono::steady_clock::time_point g_directionNextSend;
static std::atomic<bool> g_directionControlRunning{false};
static std::atomic<SOCKET> g_directionSocket{INVALID_SOCKET};
static std::thread g_directionThread;

static void ApplySynchronizedMode(int mode);

static UINT64 GenerateDirectionDeviceID() {
    GUID guid = {};
    UINT64 first = 0;
    UINT64 second = 0;
    if (SUCCEEDED(CoCreateGuid(&guid))) {
        static_assert(sizeof(guid) == sizeof(first) + sizeof(second));
        memcpy(&first, &guid, sizeof(first));
        memcpy(&second, reinterpret_cast<const BYTE*>(&guid) + sizeof(first),
               sizeof(second));
    } else {
        LARGE_INTEGER counter = {};
        QueryPerformanceCounter(&counter);
        first = static_cast<UINT64>(counter.QuadPart);
        second = GetTickCount64() ^ static_cast<UINT64>(GetCurrentProcessId());
    }
    const UINT64 value = first ^ second;
    return value == 0 ? 1 : value;
}

static UINT64 ReadUserQword(HKEY key, const wchar_t* name) {
    UINT64 value = 0;
    DWORD type = 0;
    DWORD size = sizeof(value);
    return RegQueryValueExW(key, name, nullptr, &type,
                            reinterpret_cast<BYTE*>(&value), &size) == ERROR_SUCCESS &&
           type == REG_QWORD
        ? value : 0;
}

static void WriteUserQword(HKEY key, const wchar_t* name, UINT64 value) {
    RegSetValueExW(key, name, 0, REG_QWORD,
                   reinterpret_cast<const BYTE*>(&value), sizeof(value));
}

static void PersistDirectionStateLocked() {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Auvol", 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return;
    }
    WriteUserQword(key, L"ControlDeviceID", g_directionDeviceID);
    WriteUserQword(key, L"ControlClock", g_directionClock);
    WriteUserQword(key, L"ControlWinnerVersion", g_directionWinner.version);
    WriteUserQword(key, L"ControlWinnerOrigin", g_directionWinner.originID);
    const DWORD direction = g_directionWinner.direction;
    RegSetValueExW(key, L"ControlWinnerDirection", 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&direction), sizeof(direction));
    RegCloseKey(key);
}

static void EnsureDirectionStateLoadedLocked() {
    if (g_directionStateLoaded) return;
    g_directionStateLoaded = true;
    g_directionWinner.direction = g_savedMode == 1 ? 1 : 0;

    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Auvol", 0,
                      KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
        g_directionDeviceID = ReadUserQword(key, L"ControlDeviceID");
        g_directionClock = ReadUserQword(key, L"ControlClock");
        g_directionWinner.version = ReadUserQword(key, L"ControlWinnerVersion");
        g_directionWinner.originID = ReadUserQword(key, L"ControlWinnerOrigin");
        DWORD direction = g_directionWinner.direction;
        DWORD type = 0;
        DWORD size = sizeof(direction);
        if (RegQueryValueExW(key, L"ControlWinnerDirection", nullptr, &type,
                             reinterpret_cast<BYTE*>(&direction), &size) == ERROR_SUCCESS &&
            type == REG_DWORD && direction <= 1 && g_directionWinner.version > 0) {
            g_directionWinner.direction = static_cast<UINT8>(direction);
        }
        RegCloseKey(key);
    }
    if (g_directionDeviceID == 0) {
        g_directionDeviceID = GenerateDirectionDeviceID();
    }
    g_directionClock = std::max(g_directionClock, g_directionWinner.version);
    PersistDirectionStateLocked();
}

static bool DirectionAddress(const std::string& peerIP,
                             sockaddr_in* address) {
    if (!address) return false;
    *address = {};
    address->sin_family = AF_INET;
    address->sin_port = htons(DIRECTION_PORT);
    return inet_pton(AF_INET, peerIP.c_str(), &address->sin_addr) == 1;
}

static bool DirectionSourceMatchesPeer(const sockaddr_in& source) {
    std::string peerIP;
    {
        std::lock_guard<std::mutex> lock(g_directionMutex);
        peerIP = g_directionPeerIP;
    }
    sockaddr_in peer = {};
    return DirectionAddress(peerIP, &peer) &&
           source.sin_addr.s_addr == peer.sin_addr.s_addr;
}

static std::array<UINT8, DIRECTION_PACKET_BYTES> DirectionPacket(
    UINT8 type, const DirectionState& state) {
    std::array<UINT8, DIRECTION_PACKET_BYTES> packet = {};
    Put32(packet.data(), DIRECTION_MAGIC);
    packet[4] = type;
    packet[5] = state.direction;
    Put64(packet.data() + 8, state.version);
    Put64(packet.data() + 16, state.originID);
    return packet;
}

static bool ParseDirectionPacket(const UINT8* bytes, int length,
                                 UINT8* type, DirectionState* state) {
    if (!bytes || !type || !state || length != DIRECTION_PACKET_BYTES ||
        Get32(bytes) != DIRECTION_MAGIC ||
        (bytes[4] != DIRECTION_SET && bytes[4] != DIRECTION_ACK) ||
        bytes[5] > 1 || bytes[6] != 0 || bytes[7] != 0) {
        return false;
    }
    *type = bytes[4];
    state->direction = bytes[5];
    state->version = Get64(bytes + 8);
    state->originID = Get64(bytes + 16);
    return state->version != 0 && state->originID != 0;
}

static void SendDirectionState(SOCKET socketFD, UINT8 type,
                               const DirectionState& state,
                               const sockaddr_in& destination) {
    const auto packet = DirectionPacket(type, state);
    sendto(socketFD, reinterpret_cast<const char*>(packet.data()),
           static_cast<int>(packet.size()), 0,
           reinterpret_cast<const sockaddr*>(&destination),
           sizeof(destination));
}

static void PublishDirection(int mode) {
    std::lock_guard<std::mutex> lock(g_directionMutex);
    EnsureDirectionStateLoadedLocked();
    g_directionClock = std::max(g_directionClock, g_directionWinner.version) + 1;
    if (g_directionClock == 0) g_directionClock = 1;
    g_directionWinner = {
        g_directionClock,
        g_directionDeviceID,
        static_cast<UINT8>(mode == 1 ? 1 : 0)
    };
    g_directionPending = g_directionWinner;
    g_directionAttemptsSent = 0;
    g_directionNextSend = std::chrono::steady_clock::now();
    PersistDirectionStateLocked();
}

static void MaybeSendPendingDirection(SOCKET socketFD) {
    std::optional<DirectionState> state;
    std::string peerIP;
    const auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lock(g_directionMutex);
        if (!g_directionPending || now < g_directionNextSend) return;
        if (g_directionAttemptsSent >= 4) {
            g_directionPending.reset();
            return;
        }
        state = g_directionPending;
        peerIP = g_directionPeerIP;
        static constexpr std::chrono::milliseconds delays[] = {
            std::chrono::milliseconds(150),
            std::chrono::milliseconds(400),
            std::chrono::milliseconds(900),
            std::chrono::milliseconds(1000)
        };
        g_directionNextSend = now + delays[g_directionAttemptsSent];
        ++g_directionAttemptsSent;
    }
    sockaddr_in destination = {};
    if (state && DirectionAddress(peerIP, &destination)) {
        SendDirectionState(socketFD, DIRECTION_SET, *state, destination);
    }
}

static void ReceiveDirectionPacket(SOCKET socketFD, const UINT8* bytes,
                                   int length, const sockaddr_in& source) {
    if (!DirectionSourceMatchesPeer(source)) return;
    UINT8 type = 0;
    DirectionState incoming;
    if (!ParseDirectionPacket(bytes, length, &type, &incoming)) return;

    bool applyDirection = false;
    DirectionState response;
    {
        std::lock_guard<std::mutex> lock(g_directionMutex);
        EnsureDirectionStateLoadedLocked();
        bool changed = false;
        if (incoming.version > g_directionClock) {
            g_directionClock = incoming.version;
            changed = true;
        }
        if (DirectionOutranks(incoming, g_directionWinner)) {
            g_directionWinner = incoming;
            applyDirection = true;
            changed = true;
            if (g_directionPending &&
                DirectionOutranks(incoming, *g_directionPending)) {
                g_directionPending.reset();
            }
        }
        if (type == DIRECTION_ACK && g_directionPending &&
            (DirectionSameKey(incoming, *g_directionPending) ||
             DirectionOutranks(incoming, *g_directionPending))) {
            g_directionPending.reset();
        }
        if (changed) PersistDirectionStateLocked();
        response = g_directionWinner;
    }

    if (applyDirection) {
        ApplySynchronizedMode(incoming.direction == 1 ? 1 : 0);
    }
    if (type == DIRECTION_SET) {
        SendDirectionState(socketFD, DIRECTION_ACK, response, source);
    }
}

static void DirectionControlThread() {
    WSADATA winsock = {};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        PostStatus("Direction control could not initialize Winsock");
        g_directionControlRunning.store(false, std::memory_order_release);
        return;
    }

    SOCKET socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socketFD == INVALID_SOCKET) {
        PostStatus("Direction control socket could not be opened");
        g_directionControlRunning.store(false, std::memory_order_release);
        WSACleanup();
        return;
    }
    BOOL exclusive = TRUE;
    setsockopt(socketFD, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
               reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons(DIRECTION_PORT);
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(socketFD, reinterpret_cast<const sockaddr*>(&local),
             sizeof(local)) == SOCKET_ERROR) {
        closesocket(socketFD);
        PostStatus("Direction control UDP port 7778 is unavailable");
        g_directionControlRunning.store(false, std::memory_order_release);
        WSACleanup();
        return;
    }
    u_long nonblocking = 1;
    ioctlsocket(socketFD, FIONBIO, &nonblocking);
    g_directionSocket.store(socketFD, std::memory_order_release);

    while (g_directionControlRunning.load(std::memory_order_acquire)) {
        MaybeSendPendingDirection(socketFD);
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(socketFD, &readable);
        timeval timeout = {0, 50000};
        const int selected = select(0, &readable, nullptr, nullptr, &timeout);
        if (selected == SOCKET_ERROR) {
            if (!g_directionControlRunning.load(std::memory_order_acquire)) break;
            Sleep(50);
            continue;
        }
        if (selected <= 0 || !FD_ISSET(socketFD, &readable)) continue;

        while (true) {
            std::array<UINT8, 64> bytes = {};
            sockaddr_in source = {};
            int sourceBytes = sizeof(source);
            const int count = recvfrom(socketFD,
                reinterpret_cast<char*>(bytes.data()),
                static_cast<int>(bytes.size()), 0,
                reinterpret_cast<sockaddr*>(&source), &sourceBytes);
            if (count == SOCKET_ERROR) {
                if (WSAGetLastError() == WSAEWOULDBLOCK) break;
                break;
            }
            ReceiveDirectionPacket(socketFD, bytes.data(), count, source);
        }
    }

    SOCKET expected = socketFD;
    if (g_directionSocket.compare_exchange_strong(expected, INVALID_SOCKET,
                                                   std::memory_order_acq_rel)) {
        closesocket(socketFD);
    }
    WSACleanup();
}

static void StopDirectionControl() {
    g_directionControlRunning.store(false, std::memory_order_release);
    const SOCKET socketFD = g_directionSocket.exchange(
        INVALID_SOCKET, std::memory_order_acq_rel);
    if (socketFD != INVALID_SOCKET) closesocket(socketFD);
    if (g_directionThread.joinable()) g_directionThread.join();
}

static void ApplySynchronizedMode(int mode) {
    const int normalized = mode == 1 ? 1 : 0;
    const int previous = g_desiredMode.exchange(normalized,
                                                 std::memory_order_acq_rel);
    if (previous != normalized &&
        g_connected.load(std::memory_order_acquire)) {
        g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
        if (g_controlEvent) SetEvent(g_controlEvent);
        PostStatus("Switching direction from peer...");
    }
    NotifyMode(normalized);
}

class DatagramSender {
public:
    ~DatagramSender() {
        close();
    }

    void close() {
        if (socket_ != INVALID_SOCKET) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
        }
    }

    bool open(const std::string& targetIP, UINT16 port) {
        socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socket_ == INVALID_SOCKET) {
            return false;
        }

        int sendBuffer = 1 << 20;
        setsockopt(socket_, SOL_SOCKET, SO_SNDBUF,
                   reinterpret_cast<const char*>(&sendBuffer),
                   sizeof(sendBuffer));
        int trafficClass = 0xb8; // Expedited forwarding when the network honors DSCP.
        setsockopt(socket_, IPPROTO_IP, IP_TOS,
                   reinterpret_cast<const char*>(&trafficClass),
                   sizeof(trafficClass));

        destination_ = {};
        destination_.sin_family = AF_INET;
        destination_.sin_port = htons(port);
        return inet_pton(AF_INET, targetIP.c_str(),
                         &destination_.sin_addr) == 1;
    }

    bool sendConfig(UINT32 streamID,
                    UINT32 sampleRate,
                    UINT32 capturePeriodFrames) {
        std::array<UINT8, CONFIG_HEADER_BYTES> packet = {};
        Put32(packet.data() + 0, MAGIC);
        Put16(packet.data() + 4, TYPE_CONFIG);
        Put16(packet.data() + 6, CONFIG_HEADER_BYTES);
        Put32(packet.data() + 8, streamID);
        Put32(packet.data() + 12, sampleRate);
        Put16(packet.data() + 16, CHANNELS);
        Put16(packet.data() + 18, MAX_PACKET_FRAMES);
        Put32(packet.data() + 20, capturePeriodFrames);
        return send(packet.data(), packet.size());
    }

    bool sendAudio(UINT32 streamID,
                   UINT32 sequence,
                   UINT64 firstFrame,
                   const float* samples,
                   UINT16 frames,
                   UINT16 flags,
                   bool silent) {
        std::array<UINT8,
                   AUDIO_HEADER_BYTES + MAX_PACKET_FRAMES * CHANNELS * 4> packet = {};
        Put32(packet.data() + 0, MAGIC);
        Put16(packet.data() + 4, TYPE_AUDIO);
        Put16(packet.data() + 6, AUDIO_HEADER_BYTES);
        Put32(packet.data() + 8, streamID);
        Put32(packet.data() + 12, sequence);
        Put64(packet.data() + 16, firstFrame);
        Put16(packet.data() + 24, frames);
        Put16(packet.data() + 26, CHANNELS);
        Put16(packet.data() + 28, flags);

        const size_t payloadBytes = static_cast<size_t>(frames) * CHANNELS * 4;
        if (silent) {
            memset(packet.data() + AUDIO_HEADER_BYTES, 0, payloadBytes);
        } else {
            memcpy(packet.data() + AUDIO_HEADER_BYTES, samples, payloadBytes);
        }
        return send(packet.data(), AUDIO_HEADER_BYTES + payloadBytes);
    }

private:
    bool send(const void* bytes, size_t length) {
        const int result = sendto(
            socket_,
            reinterpret_cast<const char*>(bytes),
            static_cast<int>(length),
            0,
            reinterpret_cast<const sockaddr*>(&destination_),
            sizeof(destination_)
        );
        return result == static_cast<int>(length);
    }

    SOCKET socket_ = INVALID_SOCKET;
    sockaddr_in destination_ = {};
};

struct IncomingConfig {
    UINT32 streamID = 0;
    UINT32 sampleRate = 0;
    UINT32 sourcePeriodFrames = 0;
};

class StereoJitterRing {
public:
    explicit StereoJitterRing(UINT64 capacityFrames)
        : capacity_(capacityFrames), samples_(capacityFrames * CHANNELS) {}

    bool push(const float* source, UINT32 frames) {
        const UINT64 write = writeFrames_.load(std::memory_order_relaxed);
        const UINT64 consumed = consumedFrames_.load(std::memory_order_acquire);
        if (write - consumed + frames >= capacity_) return false;
        for (UINT32 frame = 0; frame < frames; ++frame) {
            const UINT64 index = (write + frame) % capacity_;
            samples_[index * CHANNELS] = source[frame * CHANNELS];
            samples_[index * CHANNELS + 1] = source[frame * CHANNELS + 1];
        }
        writeFrames_.store(write + frames, std::memory_order_release);
        return true;
    }

    bool pushSilence(UINT32 frames) {
        const UINT64 write = writeFrames_.load(std::memory_order_relaxed);
        const UINT64 consumed = consumedFrames_.load(std::memory_order_acquire);
        if (write - consumed + frames >= capacity_) return false;
        for (UINT32 frame = 0; frame < frames; ++frame) {
            const UINT64 index = (write + frame) % capacity_;
            samples_[index * CHANNELS] = 0;
            samples_[index * CHANNELS + 1] = 0;
        }
        writeFrames_.store(write + frames, std::memory_order_release);
        return true;
    }

    void render(float* destination, UINT32 frames, UINT32 targetFrames,
                double* rateCorrection, double* integralCorrection,
                std::atomic<UINT64>* starvedFrames) {
        const UINT64 write = writeFrames_.load(std::memory_order_acquire);
        const double available = static_cast<double>(write) - readPosition_;
        if (!primed_) {
            if (available < targetFrames + 2) {
                memset(destination, 0, static_cast<size_t>(frames) * CHANNELS * sizeof(float));
                return;
            }
            primed_ = true;
        }

        const double normalizedError = (available - targetFrames) /
            static_cast<double>(targetFrames);
        *integralCorrection = std::clamp(*integralCorrection + normalizedError * 0.000005,
                                         -0.0015, 0.0015);
        *rateCorrection = std::clamp(normalizedError * 0.00035 + *integralCorrection,
                                     -0.0015, 0.0015);
        const double step = 1.0 + *rateCorrection;
        const double required = static_cast<double>(frames) * step + 2.0;
        if (available < required) {
            memset(destination, 0, static_cast<size_t>(frames) * CHANNELS * sizeof(float));
            primed_ = false;
            starvedFrames->fetch_add(frames, std::memory_order_relaxed);
            return;
        }

        for (UINT32 frame = 0; frame < frames; ++frame) {
            const UINT64 floorFrame = static_cast<UINT64>(readPosition_);
            const double fraction = readPosition_ - static_cast<double>(floorFrame);
            const UINT64 nextFrame = floorFrame + 1;
            const UINT64 firstIndex = floorFrame % capacity_;
            const UINT64 secondIndex = nextFrame % capacity_;
            for (UINT32 channel = 0; channel < CHANNELS; ++channel) {
                const float first = samples_[firstIndex * CHANNELS + channel];
                const float second = samples_[secondIndex * CHANNELS + channel];
                destination[frame * CHANNELS + channel] = first +
                    static_cast<float>((second - first) * fraction);
            }
            readPosition_ += step;
        }
        consumedFrames_.store(static_cast<UINT64>(readPosition_),
                              std::memory_order_release);
    }

    void discardAllAndReprime() {
        const UINT64 write = writeFrames_.load(std::memory_order_acquire);
        readPosition_ = static_cast<double>(write);
        consumedFrames_.store(write, std::memory_order_release);
        primed_ = false;
    }

    double bufferedFrames() const {
        const UINT64 write = writeFrames_.load(std::memory_order_acquire);
        const UINT64 consumed = consumedFrames_.load(std::memory_order_acquire);
        return write >= consumed ? static_cast<double>(write - consumed) : 0.0;
    }

private:
    const UINT64 capacity_;
    std::vector<float> samples_;
    std::atomic<UINT64> writeFrames_{0};
    std::atomic<UINT64> consumedFrames_{0};
    double readPosition_ = 0;
    bool primed_ = false;
};

class ReceiverSession {
public:
    ReceiverSession() : ring_(96'000) {}

    ~ReceiverSession() { stop(); }

    bool start(UINT16 port) {
        socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socket_ == INVALID_SOCKET) return false;
        int receiveBuffer = 1 << 20;
        setsockopt(socket_, SOL_SOCKET, SO_RCVBUF,
                   reinterpret_cast<const char*>(&receiveBuffer), sizeof(receiveBuffer));
        int exclusive = 1;
        if (setsockopt(socket_, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
                       reinterpret_cast<const char*>(&exclusive),
                       sizeof(exclusive)) != 0) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
            return false;
        }
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(socket_, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
            return false;
        }
        running_.store(true);
        networkThread_ = std::thread(&ReceiverSession::networkLoop, this);
        playbackThread_ = std::thread(&ReceiverSession::playbackLoop, this);
        return true;
    }

    void stop() {
        running_.store(false);
        configChanged_.notify_all();
        if (socket_ != INVALID_SOCKET) {
            shutdown(socket_, SD_BOTH);
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
        }
        if (networkThread_.joinable()) networkThread_.join();
        if (playbackThread_.joinable()) playbackThread_.join();
    }

    void postStats() {
        char text[256] = {};
        const UINT32 sampleRate = sampleRate_.load(std::memory_order_relaxed);
        const double queuedMs = sampleRate == 0 ? 0 :
            ring_.bufferedFrames() / sampleRate * 1000.0;
        const float peak = ingressPeak_.exchange(0, std::memory_order_relaxed);
        const UINT64 rendered = renderedFrames_.load(std::memory_order_relaxed);
        const auto now = std::chrono::steady_clock::now();
        const double elapsed = std::max(
            0.001,
            std::chrono::duration<double>(now - lastStatsTime_).count()
        );
        const UINT64 renderedDelta = rendered >= lastRenderedFrames_
            ? rendered - lastRenderedFrames_ : rendered;
        lastRenderedFrames_ = rendered;
        lastStatsTime_ = now;
        snprintf(text, sizeof(text),
                 "Packets: %llu  Signal: %.1f dBFS  Render: %.0f frames/s  Lost: %llu  Queue: %.1f ms",
                 static_cast<unsigned long long>(packets_.load()),
                 PeakDBFS(peak), static_cast<double>(renderedDelta) / elapsed,
                 static_cast<unsigned long long>(lost_.load()),
                 queuedMs);
        PostText(WM_APP + 2, text);
    }

private:
    bool acceptConfig(const UINT8* packet, int length) {
        if (length != CONFIG_HEADER_BYTES || Get32(packet) != MAGIC ||
            Get16(packet + 4) != TYPE_CONFIG ||
            Get16(packet + 6) != CONFIG_HEADER_BYTES) return false;
        IncomingConfig next = {
            Get32(packet + 8), Get32(packet + 12), Get32(packet + 20)
        };
        if (next.streamID == 0 || next.sampleRate < 8'000 ||
            next.sampleRate > 192'000 || next.sourcePeriodFrames == 0 ||
            Get16(packet + 16) != CHANNELS || Get16(packet + 18) == 0) return false;
        std::lock_guard<std::mutex> lock(configMutex_);
        if (config_.streamID == next.streamID && config_.sampleRate == next.sampleRate &&
            config_.sourcePeriodFrames == next.sourcePeriodFrames) return true;
        config_ = next;
        expectedFrame_ = 0;
        expectedSequence_ = 0;
        haveExpectedFrame_ = false;
        haveSequence_ = false;
        configVersion_.fetch_add(1, std::memory_order_release);
        sampleRate_.store(next.sampleRate, std::memory_order_relaxed);
        configChanged_.notify_all();
        return true;
    }

    void acceptAudio(const UINT8* packet, int length) {
        if (length < AUDIO_HEADER_BYTES || Get32(packet) != MAGIC ||
            Get16(packet + 4) != TYPE_AUDIO || Get16(packet + 6) != AUDIO_HEADER_BYTES) return;
        const UINT32 streamID = Get32(packet + 8);
        const UINT32 sequence = Get32(packet + 12);
        const UINT64 firstFrame = Get64(packet + 16);
        const UINT16 frames = Get16(packet + 24);
        const UINT16 channels = Get16(packet + 26);
        const UINT16 flags = Get16(packet + 28);
        if (frames == 0 || frames > MAX_PACKET_FRAMES || channels != CHANNELS ||
            length != static_cast<int>(AUDIO_HEADER_BYTES +
                                       frames * CHANNELS * sizeof(float))) return;

        IncomingConfig config;
        {
            std::lock_guard<std::mutex> lock(configMutex_);
            config = config_;
        }
        if (streamID == 0 || streamID != config.streamID) return;
        bool resetTimeline = (flags & AUDIO_FLAG_DISCONTINUITY) != 0;
        if (haveExpectedFrame_) {
            if (firstFrame < expectedFrame_) {
                const UINT64 backwards = expectedFrame_ - firstFrame;
                if (backwards > static_cast<UINT64>(config.sampleRate / 100)) {
                    resetTimeline = true;
                } else if (!resetTimeline) {
                    late_.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
            }
            const UINT64 gap = firstFrame >= expectedFrame_
                ? firstFrame - expectedFrame_ : 0;
            if (gap > 0) {
                if (gap < static_cast<UINT64>(config.sampleRate / 20)) {
                    if (!ring_.pushSilence(static_cast<UINT32>(gap))) {
                        overflow_.fetch_add(gap, std::memory_order_relaxed);
                    }
                } else {
                    resetTimeline = true;
                    glitches_.fetch_add(1, std::memory_order_relaxed);
                }
            }
        }
        if (resetTimeline) {
            haveExpectedFrame_ = false;
            haveSequence_ = false;
            configVersion_.fetch_add(1, std::memory_order_release);
            configChanged_.notify_all();
        }
        if (haveSequence_) {
            const UINT32 gap = sequence - expectedSequence_;
            if (gap > 0 && gap < 10'000) lost_.fetch_add(gap, std::memory_order_relaxed);
        }
        const float* samples = reinterpret_cast<const float*>(packet + AUDIO_HEADER_BYTES);
        float peak = 0;
        for (UINT32 index = 0; index < static_cast<UINT32>(frames) * CHANNELS; ++index) {
            peak = std::max(peak, std::fabs(samples[index]));
        }
        AccumulatePeak(&ingressPeak_, peak);
        if (!ring_.push(samples, frames)) overflow_.fetch_add(frames, std::memory_order_relaxed);
        expectedFrame_ = firstFrame + frames;
        expectedSequence_ = sequence + 1;
        haveExpectedFrame_ = true;
        haveSequence_ = true;
        packets_.fetch_add(1, std::memory_order_relaxed);
    }

    void networkLoop() {
        std::array<UINT8, 2048> packet = {};
        while (running_.load()) {
            const int length = recv(socket_, reinterpret_cast<char*>(packet.data()),
                                    static_cast<int>(packet.size()), 0);
            if (length <= 0) break;
            if (length >= 12 && Get16(packet.data() + 4) == TYPE_CONFIG) {
                acceptConfig(packet.data(), length);
            } else {
                acceptAudio(packet.data(), length);
            }
        }
    }

    bool waitForConfig(IncomingConfig* result, UINT32* version) {
        std::unique_lock<std::mutex> lock(configMutex_);
        configChanged_.wait(lock, [&] {
            return !running_.load() || configVersion_.load(std::memory_order_acquire) != 0;
        });
        if (!running_.load()) return false;
        *result = config_;
        *version = configVersion_.load(std::memory_order_acquire);
        return true;
    }

    bool renderConfig(const IncomingConfig& config, UINT32 version) {
        IMMDeviceEnumerator* enumerator = nullptr;
        IMMDevice* device = nullptr;
        IAudioClient3* client = nullptr;
        IAudioRenderClient* render = nullptr;
        HANDLE event = nullptr;
        HANDLE endpointChanged = nullptr;
        HANDLE mmcss = nullptr;
        EndpointMonitor* monitor = nullptr;
        std::wstring activeDeviceID;
        bool monitorRegistered = false;
        bool started = false;
        auto finish = [&] {
            if (started && client) client->Stop();
            if (monitorRegistered && enumerator && monitor) {
                enumerator->UnregisterEndpointNotificationCallback(monitor);
            }
            if (monitor) monitor->Release();
            if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
            if (event) CloseHandle(event);
            if (endpointChanged) CloseHandle(endpointChanged);
            if (render) render->Release();
            if (client) client->Release();
            if (device) device->Release();
            if (enumerator) enumerator->Release();
        };

        HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                          CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                          reinterpret_cast<void**>(&enumerator));
        if (FAILED(result) || FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)) ||
            FAILED(device->Activate(__uuidof(IAudioClient3), CLSCTX_ALL, nullptr,
                                    reinterpret_cast<void**>(&client)))) {
            PostStatus("Cannot open the Windows output device");
            finish();
            return false;
        }
        if (!DeviceID(device, &activeDeviceID)) {
            PostStatus("Cannot identify the Windows output device");
            finish();
            return false;
        }
        endpointChanged = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!endpointChanged) {
            PostStatus("Cannot monitor the Windows output device");
            finish();
            return false;
        }
        monitor = new EndpointMonitor(endpointChanged, activeDeviceID);
        if (FAILED(enumerator->RegisterEndpointNotificationCallback(monitor))) {
            PostStatus("Cannot observe Windows output changes");
            finish();
            return false;
        }
        monitorRegistered = true;

        WAVEFORMATEX format = {};
        format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
        format.nChannels = CHANNELS;
        format.nSamplesPerSec = config.sampleRate;
        format.wBitsPerSample = 32;
        format.nBlockAlign = CHANNELS * sizeof(float);
        format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
        format.cbSize = 0;
        AudioClientProperties properties = {};
        properties.cbSize = sizeof(properties);
        properties.eCategory = AudioCategory_GameMedia;
        client->SetClientProperties(&properties);
        UINT32 defaultPeriod = 0, fundamentalPeriod = 0, minimumPeriod = 0, maximumPeriod = 0;
        result = client->GetSharedModeEnginePeriod(&format, &defaultPeriod,
                                                   &fundamentalPeriod, &minimumPeriod,
                                                   &maximumPeriod);
        if (FAILED(result) || minimumPeriod == 0 ||
            FAILED(client->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                                        minimumPeriod, &format, nullptr))) {
            PostStatus("Windows output does not accept 32-bit stereo PCM at the Mac sample rate");
            finish();
            return false;
        }
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event || FAILED(client->SetEventHandle(event)) ||
            FAILED(client->GetService(__uuidof(IAudioRenderClient),
                                      reinterpret_cast<void**>(&render)))) {
            PostStatus("Cannot create low-latency output renderer");
            finish();
            return false;
        }
        UINT32 bufferFrames = 0;
        client->GetBufferSize(&bufferFrames);
        BYTE* silence = nullptr;
        if (FAILED(render->GetBuffer(bufferFrames, &silence)) ||
            FAILED(render->ReleaseBuffer(bufferFrames, AUDCLNT_BUFFERFLAGS_SILENT)) ||
            FAILED(client->Start())) {
            PostStatus("Cannot start Windows audio output");
            finish();
            return false;
        }
        started = true;
        DWORD taskIndex = 0;
        mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
        char status[192] = {};
        const double periodMs = static_cast<double>(minimumPeriod) / config.sampleRate * 1000.0;
        snprintf(status, sizeof(status), "%u Hz, %.1f ms output period; receiving Mac audio",
                 config.sampleRate, periodMs);
        PostStatus(status);

        double rateCorrection = 0;
        double integralCorrection = 0;
        const UINT32 targetFrames = std::max<UINT32>(1, config.sampleRate * 12 / 1000);
        ring_.discardAllAndReprime();
        auto lastEndpointCheck = std::chrono::steady_clock::now();
        while (running_.load() && configVersion_.load(std::memory_order_acquire) == version) {
            HANDLE waits[2] = {event, endpointChanged};
            const DWORD waited = WaitForMultipleObjects(2, waits, FALSE, 50);
            if (waited == WAIT_FAILED || waited == WAIT_OBJECT_0 + 1) {
                PostStatus("Windows output changed; reconnecting automatically");
                break;
            }
            const auto now = std::chrono::steady_clock::now();
            if (now - lastEndpointCheck >= std::chrono::milliseconds(500)) {
                if (!DefaultEndpointMatches(enumerator, activeDeviceID)) {
                    PostStatus("Windows default output changed; reconnecting automatically");
                    break;
                }
                lastEndpointCheck = now;
            }
            if (waited == WAIT_TIMEOUT) continue;
            UINT32 padding = 0;
            if (FAILED(client->GetCurrentPadding(&padding))) {
                PostStatus("Windows output was invalidated; reconnecting automatically");
                break;
            }
            if (padding >= bufferFrames) continue;
            const UINT32 writable = bufferFrames - padding;
            BYTE* bytes = nullptr;
            if (FAILED(render->GetBuffer(writable, &bytes))) {
                PostStatus("Windows output buffer failed; reconnecting automatically");
                break;
            }
            ring_.render(reinterpret_cast<float*>(bytes), writable, targetFrames,
                         &rateCorrection, &integralCorrection, &starved_);
            if (FAILED(render->ReleaseBuffer(writable, 0))) {
                PostStatus("Windows output commit failed; reconnecting automatically");
                break;
            }
            renderedFrames_.fetch_add(writable, std::memory_order_relaxed);
            ratePPM_.store(rateCorrection * 1'000'000.0, std::memory_order_relaxed);
        }
        finish();
        return true;
    }

    void playbackLoop() {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com)) {
            PostStatus("COM initialization failed for output playback");
            return;
        }
        while (running_.load()) {
            IncomingConfig config;
            UINT32 version = 0;
            if (!waitForConfig(&config, &version)) break;
            renderConfig(config, version);
            if (running_.load() && configVersion_.load() == version) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
        }
        CoUninitialize();
    }

    StereoJitterRing ring_;
    SOCKET socket_ = INVALID_SOCKET;
    std::atomic<bool> running_{false};
    std::thread networkThread_;
    std::thread playbackThread_;
    std::mutex configMutex_;
    std::condition_variable configChanged_;
    IncomingConfig config_;
    std::atomic<UINT32> configVersion_{0};
    UINT64 expectedFrame_ = 0;
    UINT32 expectedSequence_ = 0;
    bool haveExpectedFrame_ = false;
    bool haveSequence_ = false;
    std::atomic<UINT64> packets_{0};
    std::atomic<UINT64> lost_{0};
    std::atomic<UINT64> late_{0};
    std::atomic<UINT64> glitches_{0};
    std::atomic<UINT64> overflow_{0};
    std::atomic<UINT64> starved_{0};
    std::atomic<UINT32> sampleRate_{0};
    std::atomic<double> ratePPM_{0};
    std::atomic<float> ingressPeak_{0};
    std::atomic<UINT64> renderedFrames_{0};
    UINT64 lastRenderedFrames_ = 0;
    std::chrono::steady_clock::time_point lastStatsTime_ =
        std::chrono::steady_clock::now();
};

static void AudioThread(std::string targetIP, UINT16 port, UINT64 generation) {
    WSADATA winsock = {};
    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice* device = nullptr;
    IAudioClient* client = nullptr;
    IAudioCaptureClient* capture = nullptr;
    IAudioClient3* periodClient = nullptr;
    IAudioRenderClient* periodRender = nullptr;
    WAVEFORMATEX* mixFormat = nullptr;
    HANDLE audioEvent = nullptr;
    HANDLE periodEvent = nullptr;
    HANDLE endpointChanged = nullptr;
    HANDLE mmcssHandle = nullptr;
    EndpointMonitor* monitor = nullptr;
    std::wstring activeDeviceID;
    bool monitorRegistered = false;
    bool clientStarted = false;
    bool periodClientStarted = false;
    bool comInitialized = false;
    bool winsockInitialized = false;
    DatagramSender sender;

    auto finish = [&]() {
        if (clientStarted && client) client->Stop();
        if (periodClientStarted && periodClient) periodClient->Stop();
        if (monitorRegistered && enumerator && monitor) {
            enumerator->UnregisterEndpointNotificationCallback(monitor);
        }
        if (monitor) monitor->Release();
        if (mmcssHandle) AvRevertMmThreadCharacteristics(mmcssHandle);
        if (audioEvent) CloseHandle(audioEvent);
        if (periodEvent) CloseHandle(periodEvent);
        if (endpointChanged) CloseHandle(endpointChanged);
        if (capture) capture->Release();
        if (periodRender) periodRender->Release();
        if (periodClient) periodClient->Release();
        if (client) client->Release();
        if (device) device->Release();
        if (enumerator) enumerator->Release();
        if (mixFormat) CoTaskMemFree(mixFormat);
        if (comInitialized) CoUninitialize();
        sender.close();
        if (winsockInitialized) WSACleanup();
    };

    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        PostStatus("WSAStartup failed");
        finish();
        return;
    }
    winsockInitialized = true;

    if (!sender.open(targetIP, port)) {
        PostStatus("Invalid destination or UDP socket failure");
        finish();
        return;
    }

    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(comResult)) {
        PostStatus("COM initialization failed");
        finish();
        return;
    }
    comInitialized = true;

    HRESULT result = CoCreateInstance(
        __uuidof(MMDeviceEnumerator),
        nullptr,
        CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator),
        reinterpret_cast<void**>(&enumerator)
    );
    if (FAILED(result)) {
        PostStatus("Audio device enumeration failed");
        finish();
        return;
    }
    result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(result)) {
        PostStatus("No default output device");
        finish();
        return;
    }
    if (!DeviceID(device, &activeDeviceID)) {
        PostStatus("Cannot identify the default output; retrying");
        finish();
        return;
    }
    endpointChanged = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!endpointChanged) {
        PostStatus("Cannot monitor the default output; retrying");
        finish();
        return;
    }
    monitor = new EndpointMonitor(endpointChanged, activeDeviceID);
    if (FAILED(enumerator->RegisterEndpointNotificationCallback(monitor))) {
        PostStatus("Cannot observe output changes; retrying");
        finish();
        return;
    }
    monitorRegistered = true;
    result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(&client));
    if (FAILED(result)) {
        PostStatus("Audio endpoint activation failed");
        finish();
        return;
    }
    result = client->GetMixFormat(&mixFormat);
    if (FAILED(result)) {
        PostStatus("Cannot read the output mix format");
        finish();
        return;
    }

    bool isFloat32 = mixFormat->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (mixFormat->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        const auto* extended = reinterpret_cast<const WaveFormatExt*>(mixFormat);
        isFloat32 = IsEqualGUID(extended->subFormat, SUBTYPE_FLOAT);
    }
    if (!isFloat32 || mixFormat->wBitsPerSample != 32 ||
        mixFormat->nChannels != CHANNELS) {
        PostStatus("Default output must be stereo float32 (use VB-Cable)");
        finish();
        return;
    }

    // A loopback stream cannot use InitializeSharedAudioStream itself. A silent
    // render client on the same endpoint requests the minimum shared-engine
    // period; the event-driven loopback stream then observes that faster engine.
    result = device->Activate(__uuidof(IAudioClient3), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(&periodClient));
    if (FAILED(result)) {
        PostStatus("Low-latency audio client is unavailable");
        finish();
        return;
    }

    AudioClientProperties properties = {};
    properties.cbSize = sizeof(properties);
    properties.bIsOffload = FALSE;
    properties.eCategory = AudioCategory_GameMedia;
    properties.Options = AUDCLNT_STREAMOPTIONS_NONE;
    result = periodClient->SetClientProperties(&properties);
    if (FAILED(result)) {
        PostStatus("Cannot set low-latency audio properties");
        finish();
        return;
    }

    UINT32 defaultPeriodFrames = 0;
    UINT32 fundamentalPeriodFrames = 0;
    UINT32 minimumPeriodFrames = 0;
    UINT32 maximumPeriodFrames = 0;
    result = periodClient->GetSharedModeEnginePeriod(
        mixFormat,
        &defaultPeriodFrames,
        &fundamentalPeriodFrames,
        &minimumPeriodFrames,
        &maximumPeriodFrames
    );
    if (FAILED(result) || minimumPeriodFrames == 0) {
        PostStatus("Cannot query the minimum audio-engine period");
        finish();
        return;
    }

    periodEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!periodEvent) {
        PostStatus("Cannot create the period-control event");
        finish();
        return;
    }
    result = periodClient->InitializeSharedAudioStream(
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        minimumPeriodFrames,
        mixFormat,
        nullptr
    );
    if (FAILED(result)) {
        char text[128] = {};
        snprintf(text, sizeof(text),
                 "Minimum engine period rejected (0x%08lx)",
                 static_cast<unsigned long>(result));
        PostStatus(text);
        finish();
        return;
    }
    UINT32 activeEnginePeriodFrames = minimumPeriodFrames;
    WAVEFORMATEX* activeEngineFormat = nullptr;
    UINT32 queriedEnginePeriodFrames = 0;
    if (SUCCEEDED(periodClient->GetCurrentSharedModeEnginePeriod(
            &activeEngineFormat, &queriedEnginePeriodFrames)) &&
        queriedEnginePeriodFrames > 0) {
        activeEnginePeriodFrames = queriedEnginePeriodFrames;
    }
    if (activeEngineFormat) {
        CoTaskMemFree(activeEngineFormat);
    }
    result = periodClient->SetEventHandle(periodEvent);
    if (FAILED(result)) {
        PostStatus("Cannot register the period-control event");
        finish();
        return;
    }
    result = periodClient->GetService(__uuidof(IAudioRenderClient),
                                      reinterpret_cast<void**>(&periodRender));
    if (FAILED(result)) {
        PostStatus("Cannot create the period-control renderer");
        finish();
        return;
    }

    UINT32 periodBufferFrames = 0;
    periodClient->GetBufferSize(&periodBufferFrames);
    BYTE* initialSilence = nullptr;
    result = periodRender->GetBuffer(periodBufferFrames, &initialSilence);
    if (FAILED(result) ||
        FAILED(periodRender->ReleaseBuffer(periodBufferFrames,
                                           AUDCLNT_BUFFERFLAGS_SILENT))) {
        PostStatus("Cannot prime the period-control renderer");
        finish();
        return;
    }

    audioEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!audioEvent) {
        PostStatus("Cannot create the audio event");
        finish();
        return;
    }

    result = client->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        0,
        0,
        mixFormat,
        nullptr
    );
    if (FAILED(result)) {
        char text[96] = {};
        snprintf(text, sizeof(text), "WASAPI initialize failed (0x%08lx)",
                 static_cast<unsigned long>(result));
        PostStatus(text);
        finish();
        return;
    }
    result = client->SetEventHandle(audioEvent);
    if (FAILED(result)) {
        PostStatus("WASAPI event registration failed");
        finish();
        return;
    }
    result = client->GetService(__uuidof(IAudioCaptureClient),
                                reinterpret_cast<void**>(&capture));
    if (FAILED(result)) {
        PostStatus("WASAPI capture service failed");
        finish();
        return;
    }

    UINT32 capturePeriodFrames = 0;
    client->GetBufferSize(&capturePeriodFrames);
    const UINT32 loopbackBufferFrames = capturePeriodFrames;
    capturePeriodFrames = activeEnginePeriodFrames;

    DWORD taskIndex = 0;
    mmcssHandle = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);

    const UINT32 streamID = NewStreamID();
    UINT32 sequence = 0;
    UINT64 packetsSent = 0;
    UINT64 sendErrors = 0;

    sender.sendConfig(streamID, mixFormat->nSamplesPerSec,
                      capturePeriodFrames);
    result = periodClient->Start();
    if (FAILED(result)) {
        PostStatus("Period-control renderer failed to start");
        finish();
        return;
    }
    periodClientStarted = true;
    result = client->Start();
    if (FAILED(result)) {
        PostStatus("WASAPI start failed");
        finish();
        return;
    }
    clientStarted = true;

    char status[256] = {};
    const double periodMs = static_cast<double>(capturePeriodFrames) /
                            mixFormat->nSamplesPerSec * 1000.0;
    snprintf(status, sizeof(status),
             "%u Hz, %.1f ms engine period (loopback buffer %u) -> %s:%u",
             static_cast<unsigned int>(mixFormat->nSamplesPerSec),
             periodMs, loopbackBufferFrames, targetIP.c_str(), port);
    PostStatus(status);

    auto lastConfig = std::chrono::steady_clock::now();
    auto lastStats = lastConfig;
    auto lastEndpointCheck = lastConfig;
    auto lastEngineProgress = lastConfig;
    UINT64 capturedFrames = 0;
    UINT64 lastCapturedFrames = 0;
    float intervalPeak = 0;
    bool sessionFailed = false;
    HANDLE waitHandles[4] = {audioEvent, periodEvent, endpointChanged, g_controlEvent};
    while (SessionCurrent(generation, 0)) {
        const DWORD waitResult = WaitForMultipleObjects(4, waitHandles,
                                                        FALSE, 50);
        if (waitResult == WAIT_FAILED) {
            PostStatus("Audio event wait failed; retrying automatically");
            break;
        }
        if (waitResult == WAIT_OBJECT_0 + 2) {
            PostStatus("Windows output changed; rebuilding capture automatically");
            break;
        }
        if (waitResult == WAIT_OBJECT_0 + 3) {
            break;
        }

        if (waitResult == WAIT_OBJECT_0 || waitResult == WAIT_OBJECT_0 + 1) {
            lastEngineProgress = std::chrono::steady_clock::now();
        }

        if (waitResult == WAIT_OBJECT_0 + 1) {
            UINT32 paddingFrames = 0;
            if (FAILED(periodClient->GetCurrentPadding(&paddingFrames))) {
                PostStatus("Audio engine was invalidated; retrying automatically");
                break;
            }
            if (paddingFrames < periodBufferFrames) {
                const UINT32 writableFrames = periodBufferFrames - paddingFrames;
                BYTE* silence = nullptr;
                if (FAILED(periodRender->GetBuffer(writableFrames, &silence)) ||
                    FAILED(periodRender->ReleaseBuffer(
                        writableFrames, AUDCLNT_BUFFERFLAGS_SILENT))) {
                    PostStatus("Audio engine buffer failed; retrying automatically");
                    break;
                }
            }
        }

        if (waitResult == WAIT_OBJECT_0 || waitResult == WAIT_OBJECT_0 + 1) {
            while (SessionCurrent(generation, 0)) {
                UINT32 nextFrames = 0;
                result = capture->GetNextPacketSize(&nextFrames);
                if (FAILED(result)) {
                    PostStatus("Capture device was invalidated; retrying automatically");
                    sessionFailed = true;
                    break;
                }
                if (nextFrames == 0) break;

                BYTE* bytes = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                UINT64 devicePosition = 0;
                UINT64 qpcPosition = 0;
                result = capture->GetBuffer(&bytes, &frames, &flags,
                                            &devicePosition, &qpcPosition);
                if (FAILED(result)) {
                    PostStatus("Capture buffer read failed; retrying automatically");
                    sessionFailed = true;
                    break;
                }

                const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                const bool discontinuity =
                    (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0;
                const float* source = reinterpret_cast<const float*>(bytes);
                if (!silent) {
                    const UINT32 sampleCount = frames * CHANNELS;
                    for (UINT32 index = 0; index < sampleCount; ++index) {
                        intervalPeak = std::max(intervalPeak,
                                                std::fabs(source[index]));
                    }
                }
                UINT32 offset = 0;
                while (offset < frames) {
                    const UINT16 chunk = static_cast<UINT16>(
                        (frames - offset) > MAX_PACKET_FRAMES
                            ? MAX_PACKET_FRAMES
                            : frames - offset
                    );
                    const UINT16 packetFlags = discontinuity && offset == 0
                        ? AUDIO_FLAG_DISCONTINUITY
                        : 0;
                    const float* chunkSource = silent
                        ? nullptr
                        : source + static_cast<size_t>(offset) * CHANNELS;
                    if (sender.sendAudio(streamID, sequence,
                                         devicePosition + offset,
                                         chunkSource, chunk, packetFlags,
                                         silent)) {
                        ++packetsSent;
                    } else {
                        ++sendErrors;
                    }
                    ++sequence;
                    offset += chunk;
                }
                capturedFrames += frames;
                if (FAILED(capture->ReleaseBuffer(frames))) {
                    PostStatus("Capture release failed; retrying automatically");
                    sessionFailed = true;
                    break;
                }
            }
        }
        if (sessionFailed) break;

        const auto now = std::chrono::steady_clock::now();
        if (now - lastEndpointCheck >= std::chrono::milliseconds(500)) {
            if (!DefaultEndpointMatches(enumerator, activeDeviceID)) {
                PostStatus("Default output changed; rebuilding capture automatically");
                break;
            }
            lastEndpointCheck = now;
        }
        if (now - lastEngineProgress >= std::chrono::milliseconds(1500)) {
            PostStatus("Audio engine stopped responding; retrying automatically");
            break;
        }
        if (now - lastConfig >= std::chrono::milliseconds(500)) {
            if (!sender.sendConfig(streamID, mixFormat->nSamplesPerSec,
                                   capturePeriodFrames)) {
                ++sendErrors;
            }
            lastConfig = now;
        }
        if (now - lastStats >= std::chrono::seconds(1)) {
            const double seconds = std::max(
                0.001, std::chrono::duration<double>(now - lastStats).count());
            const UINT64 deltaFrames = capturedFrames - lastCapturedFrames;
            char stats[256] = {};
            snprintf(stats, sizeof(stats),
                     "Packets: %llu  Signal: %.1f dBFS  Capture: %.0f frames/s  Errors: %llu",
                     static_cast<unsigned long long>(packetsSent),
                     PeakDBFS(intervalPeak), static_cast<double>(deltaFrames) / seconds,
                     static_cast<unsigned long long>(sendErrors));
            PostText(WM_APP + 2, stats);
            lastCapturedFrames = capturedFrames;
            intervalPeak = 0;
            lastStats = now;
        }
    }

    finish();
}

static void ReceiverThread(std::string ignoredTargetIP, UINT16 port,
                           UINT64 generation) {
    (void)ignoredTargetIP;
    WSADATA winsock = {};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        PostStatus("WSAStartup failed");
        return;
    }
    ReceiverSession receiver;
    if (!receiver.start(port)) {
        PostStatus("UDP port 7777 is unavailable");
        WSACleanup();
        return;
    }
    PostStatus("Listening for Mac audio on UDP 7777");
    auto lastStats = std::chrono::steady_clock::now();
    while (SessionCurrent(generation, 1)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        const auto now = std::chrono::steady_clock::now();
        if (now - lastStats >= std::chrono::seconds(1)) {
            receiver.postStats();
            lastStats = now;
        }
    }
    receiver.stop();
    WSACleanup();
}

static void SupervisorThread(std::string targetIP, UINT16 port) {
    unsigned retryAttempt = 0;
    while (g_running.load(std::memory_order_acquire)) {
        const UINT64 generation =
            g_controlGeneration.load(std::memory_order_acquire);
        const int mode = g_desiredMode.load(std::memory_order_acquire);
        const auto started = std::chrono::steady_clock::now();
        if (mode == 1) {
            ReceiverThread(targetIP, port, generation);
        } else {
            AudioThread(targetIP, port, generation);
        }
        if (!g_running.load(std::memory_order_acquire)) break;

        if (generation != g_controlGeneration.load(std::memory_order_acquire) ||
            mode != g_desiredMode.load(std::memory_order_acquire)) {
            retryAttempt = 0;
            continue;
        }
        const auto lived = std::chrono::steady_clock::now() - started;
        if (lived >= std::chrono::seconds(5)) retryAttempt = 0;
        static constexpr DWORD delays[] = {100, 250, 500, 1000, 2000};
        const DWORD delay = delays[std::min<unsigned>(
            retryAttempt, static_cast<unsigned>(std::size(delays) - 1))];
        ++retryAttempt;
        PostStatus("Recovering automatically...");
        WaitForSingleObject(g_controlEvent, delay);
    }
    g_connected.store(false, std::memory_order_release);
    NotifyRunning(false);
    if (g_mainWindow) PostMessageA(g_mainWindow, WM_APP + 3, 0, 0);
}

static void SetConnectedControls(bool connected) {
    EnableWindow(g_ipEdit, !connected);
    EnableWindow(g_modeCombo, TRUE);
    EnableWindow(g_connectButton, !connected);
    EnableWindow(g_disconnectButton, connected);
}

static void JoinAudioThread() {
    if (g_audioThread.joinable()) {
        g_audioThread.join();
    }
}

static void WriteUserDword(HKEY key, const wchar_t* name, DWORD value) {
    RegSetValueExW(key, name, 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&value), sizeof(value));
}

static void SaveUserSettings(bool running) {
    char targetIP[64] = {};
    if (g_ipEdit) GetWindowTextA(g_ipEdit, targetIP, sizeof(targetIP));
    const LRESULT selected = g_modeCombo
        ? SendMessageW(g_modeCombo, CB_GETCURSEL, 0, 0) : g_savedMode;
    auvol::SaveSettings(targetIP[0] ? targetIP : g_savedIP,
                        selected == 1 ? 1 : 0, running);
}

static void LoadUserSettings() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Auvol", 0,
                      KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return;

    char targetIP[64] = {};
    DWORD type = 0;
    DWORD size = sizeof(targetIP);
    if (RegQueryValueExA(key, "PeerIP", nullptr, &type,
                         reinterpret_cast<BYTE*>(targetIP), &size) == ERROR_SUCCESS &&
        type == REG_SZ && targetIP[0] != '\0') {
        targetIP[sizeof(targetIP) - 1] = '\0';
        g_savedIP = targetIP;
    }
    DWORD value = 0;
    size = sizeof(value);
    if (RegQueryValueExW(key, L"Mode", nullptr, &type,
                         reinterpret_cast<BYTE*>(&value), &size) == ERROR_SUCCESS &&
        type == REG_DWORD) {
        g_savedMode = value == 1 ? 1 : 0;
    }
    value = 0;
    size = sizeof(value);
    if (RegQueryValueExW(key, L"Running", nullptr, &type,
                         reinterpret_cast<BYTE*>(&value), &size) == ERROR_SUCCESS &&
        type == REG_DWORD) {
        g_savedRunning = value != 0;
    }
    RegCloseKey(key);
}

static void RegisterLoginLaunch() {
    wchar_t executable[MAX_PATH] = {};
    if (!GetModuleFileNameW(nullptr, executable, MAX_PATH)) return;
    std::wstring command = L"\"" + std::wstring(executable) + L"\"";
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER,
                        L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                        0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) return;
    RegSetValueExW(key, L"Auvol", 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(command.c_str()),
                   static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
}

static std::string AutoConnectIP() {
    int argumentCount = 0;
    LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &argumentCount);
    if (!arguments) return {};

    std::string result;
    for (int index = 1; index + 1 < argumentCount; ++index) {
        if (wcscmp(arguments[index], L"--send") == 0) {
            g_autoMode = 0;
        } else if (wcscmp(arguments[index], L"--receive") == 0) {
            g_autoMode = 1;
        } else {
            continue;
        }
        const int length = WideCharToMultiByte(CP_UTF8, 0, arguments[index + 1],
                                               -1, nullptr, 0, nullptr, nullptr);
        if (length > 1) {
            result.resize(static_cast<size_t>(length));
            WideCharToMultiByte(CP_UTF8, 0, arguments[index + 1], -1,
                                result.data(), length, nullptr, nullptr);
            result.pop_back();
        }
        break;
    }
    LocalFree(arguments);
    return result;
}

namespace auvol {

void SetCallbacks(TextCallback status,
                  TextCallback stats,
                  RunningCallback running,
                  ModeCallback mode) {
    std::lock_guard<std::mutex> lock(g_callbackMutex);
    g_statusCallback = std::move(status);
    g_statsCallback = std::move(stats);
    g_runningCallback = std::move(running);
    g_modeCallback = std::move(mode);
}

Settings LoadSettings() {
    LoadUserSettings();
    return {g_savedIP, g_savedMode, g_savedRunning};
}

void SaveSettings(const std::string& peerIP, int mode, bool running) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Auvol", 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return;
    }
    const std::string value = peerIP.empty() ? g_savedIP : peerIP;
    const DWORD byteCount = static_cast<DWORD>(value.size() + 1);
    RegSetValueExA(key, "PeerIP", 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(value.c_str()), byteCount);
    WriteUserDword(key, L"Mode", mode == 1 ? 1 : 0);
    WriteUserDword(key, L"Running", running ? 1 : 0);
    RegCloseKey(key);
    g_savedIP = value;
    g_savedMode = mode == 1 ? 1 : 0;
    g_savedRunning = running;
}

void RegisterLoginLaunch() {
    ::RegisterLoginLaunch();
}

std::string CommandLinePeer(int* mode) {
    const std::string peer = AutoConnectIP();
    if (mode) *mode = g_autoMode;
    return peer;
}

void SetDirectionControlPeer(const std::string& peerIP) {
    std::lock_guard<std::mutex> lock(g_directionMutex);
    g_directionPeerIP = peerIP;
}

void StartDirectionControl(const std::string& peerIP) {
    SetDirectionControlPeer(peerIP);
    if (g_directionControlRunning.exchange(true, std::memory_order_acq_rel)) {
        return;
    }
    if (g_directionThread.joinable()) g_directionThread.join();
    {
        std::lock_guard<std::mutex> lock(g_directionMutex);
        EnsureDirectionStateLoadedLocked();
    }
    g_directionThread = std::thread(DirectionControlThread);
}

bool Start(const std::string& peerIP, int mode) {
    if (peerIP.empty() || g_connected.load(std::memory_order_acquire)) {
        return false;
    }
    StartDirectionControl(peerIP);
    if (!g_controlEvent) {
        g_controlEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!g_controlEvent) return false;
    }
    JoinAudioThread();
    g_desiredMode.store(mode == 1 ? 1 : 0, std::memory_order_release);
    g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
    g_running.store(true, std::memory_order_release);
    g_connected.store(true, std::memory_order_release);
    ResetEvent(g_controlEvent);
    g_audioThread = std::thread(SupervisorThread, peerIP,
                                static_cast<UINT16>(7777));
    SaveSettings(peerIP, mode, true);
    NotifyRunning(true);
    return true;
}

void Stop() {
    if (!g_connected.load(std::memory_order_acquire) &&
        !g_running.load(std::memory_order_acquire)) {
        return;
    }
    g_running.store(false, std::memory_order_release);
    g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
    if (g_controlEvent) SetEvent(g_controlEvent);
    JoinAudioThread();
    g_connected.store(false, std::memory_order_release);
    SaveSettings(g_savedIP, g_desiredMode.load(std::memory_order_acquire), false);
    NotifyRunning(false);
}

void SwitchMode(int mode) {
    const int normalized = mode == 1 ? 1 : 0;
    g_desiredMode.store(normalized, std::memory_order_release);
    g_savedMode = normalized;
    if (g_connected.load(std::memory_order_acquire)) {
        g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
        if (g_controlEvent) SetEvent(g_controlEvent);
        PostStatus("Switching direction automatically...");
    }
    PublishDirection(normalized);
}

bool IsRunning() {
    return g_running.load(std::memory_order_acquire);
}

void Shutdown() {
    Stop();
    StopDirectionControl();
    {
        std::lock_guard<std::mutex> lock(g_callbackMutex);
        g_statusCallback = {};
        g_statsCallback = {};
        g_runningCallback = {};
        g_modeCallback = {};
    }
    if (g_controlEvent) {
        CloseHandle(g_controlEvent);
        g_controlEvent = nullptr;
    }
}

} // namespace auvol

static LRESULT CALLBACK WindowProcedure(HWND window,
                                        UINT message,
                                        WPARAM wParam,
                                        LPARAM lParam) {
    switch (message) {
    case WM_CREATE:
        CreateWindowW(L"STATIC", L"Peer IP address:",
                      WS_CHILD | WS_VISIBLE, 20, 20, 300, 18,
                      window, nullptr, nullptr, nullptr);
        g_ipEdit = CreateWindowW(L"EDIT", L"",
                                 WS_CHILD | WS_VISIBLE | WS_BORDER |
                                     ES_AUTOHSCROLL,
                                 20, 42, 360, 26, window,
                                 reinterpret_cast<HMENU>(101), nullptr, nullptr);
        CreateWindowW(L"STATIC", L"Direction:",
                      WS_CHILD | WS_VISIBLE, 20, 78, 300, 18,
                      window, nullptr, nullptr, nullptr);
        g_modeCombo = CreateWindowW(L"COMBOBOX", L"",
                                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
                                    20, 100, 360, 100, window,
                                    reinterpret_cast<HMENU>(106), nullptr, nullptr);
        SendMessageW(g_modeCombo, CB_ADDSTRING, 0,
                     reinterpret_cast<LPARAM>(L"Send Windows audio to Mac"));
        SendMessageW(g_modeCombo, CB_ADDSTRING, 0,
                     reinterpret_cast<LPARAM>(L"Receive Mac audio on Windows"));
        SendMessageW(g_modeCombo, CB_SETCURSEL, 0, 0);
        SetWindowTextA(g_ipEdit, g_savedIP.c_str());
        SendMessageW(g_modeCombo, CB_SETCURSEL, g_savedMode, 0);
        g_connectButton = CreateWindowW(L"BUTTON", L"Start",
                                        WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                        20, 142, 110, 32, window,
                                        reinterpret_cast<HMENU>(102), nullptr,
                                        nullptr);
        g_disconnectButton = CreateWindowW(
            L"BUTTON", L"Stop",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_DISABLED,
            142, 142, 110, 32, window, reinterpret_cast<HMENU>(103), nullptr,
            nullptr
        );
        g_statusLabel = CreateWindowW(L"STATIC", L"Status: Idle",
                                      WS_CHILD | WS_VISIBLE, 20, 194, 440, 22,
                                      window, reinterpret_cast<HMENU>(104),
                                      nullptr, nullptr);
        g_statsLabel = CreateWindowW(L"STATIC", L"Packets: 0",
                                     WS_CHILD | WS_VISIBLE, 20, 220, 460, 22,
                                     window, reinterpret_cast<HMENU>(105),
                                     nullptr, nullptr);
        SendMessageW(g_ipEdit, EM_SETLIMITTEXT, 45, 0);
        auvol::StartDirectionControl(g_savedIP);
        if (!g_autoConnectIP.empty()) {
            SetWindowTextA(g_ipEdit, g_autoConnectIP.c_str());
            SendMessageW(g_modeCombo, CB_SETCURSEL, g_autoMode, 0);
            PostMessageW(window, WM_APP + 4, 0, 0);
        } else if (g_savedRunning) {
            PostMessageW(window, WM_APP + 4, 0, 0);
        }
        return 0;

    case WM_COMMAND: {
        const WORD controlID = LOWORD(wParam);
        const WORD notification = HIWORD(wParam);
        if (controlID == 102 && !g_connected.load()) {
            char targetIP[64] = {};
            GetWindowTextA(g_ipEdit, targetIP, sizeof(targetIP));
            if (targetIP[0] == '\0') {
                MessageBoxW(window, L"Enter the Mac IP address.", L"Auvol",
                            MB_OK | MB_ICONWARNING);
                return 0;
            }
            JoinAudioThread();
            const LRESULT mode = SendMessageW(g_modeCombo, CB_GETCURSEL, 0, 0);
            g_desiredMode.store(mode == 1 ? 1 : 0, std::memory_order_release);
            g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
            g_running.store(true, std::memory_order_release);
            g_connected.store(true, std::memory_order_release);
            SetConnectedControls(true);
            ResetEvent(g_controlEvent);
            g_audioThread = std::thread(SupervisorThread, std::string(targetIP),
                                        static_cast<UINT16>(7777));
            SaveUserSettings(true);
        } else if (controlID == 103 && g_connected.load()) {
            g_running.store(false, std::memory_order_release);
            g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
            SetEvent(g_controlEvent);
            JoinAudioThread();
            SetConnectedControls(false);
            SetWindowTextA(g_statusLabel, "Status: Idle");
            SetWindowTextA(g_statsLabel, "Packets: 0");
            SaveUserSettings(false);
        } else if (controlID == 106 && notification == CBN_SELCHANGE) {
            const LRESULT mode = SendMessageW(g_modeCombo, CB_GETCURSEL, 0, 0);
            g_desiredMode.store(mode == 1 ? 1 : 0, std::memory_order_release);
            if (g_connected.load(std::memory_order_acquire)) {
                g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
                SetEvent(g_controlEvent);
                PostStatus("Switching direction automatically...");
            }
            SaveUserSettings(g_connected.load(std::memory_order_acquire));
        }
        return 0;
    }

    case WM_APP + 1:
    case WM_APP + 2: {
        auto* text = reinterpret_cast<std::string*>(lParam);
        if (text) {
            SetWindowTextA(message == WM_APP + 1 ? g_statusLabel : g_statsLabel,
                           text->c_str());
            delete text;
        }
        return 0;
    }

    case WM_APP + 3:
        JoinAudioThread();
        SetConnectedControls(false);
        return 0;

    case WM_APP + 4:
        PostMessageW(window, WM_COMMAND, MAKEWPARAM(102, BN_CLICKED),
                     reinterpret_cast<LPARAM>(g_connectButton));
        return 0;

    case WM_APP + 5:
        SendMessageW(g_modeCombo, CB_SETCURSEL, wParam == 1 ? 1 : 0, 0);
        SaveUserSettings(g_connected.load(std::memory_order_acquire));
        return 0;

    case WM_CLOSE:
        SaveUserSettings(false);
        g_running.store(false, std::memory_order_release);
        g_controlGeneration.fetch_add(1, std::memory_order_acq_rel);
        SetEvent(g_controlEvent);
        JoinAudioThread();
        DestroyWindow(window);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

#ifndef AUVOL_WINUI
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    HANDLE singleInstance = CreateMutexW(
        nullptr, TRUE, L"Global\\AuvolTransportSingleInstance"
    );
    if (!singleInstance || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (singleInstance) CloseHandle(singleInstance);
        MessageBoxW(nullptr, L"Auvol is already running.", L"Auvol",
                    MB_OK | MB_ICONINFORMATION);
        return 0;
    }

    InitCommonControls();
    LoadUserSettings();
    g_autoConnectIP = AutoConnectIP();
    RegisterLoginLaunch();
    g_controlEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!g_controlEvent) {
        MessageBoxW(nullptr, L"Auvol cannot create its recovery controller.",
                    L"Auvol", MB_OK | MB_ICONERROR);
        ReleaseMutex(singleInstance);
        CloseHandle(singleInstance);
        return 1;
    }

    WNDCLASSEXW windowClass = {};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = WindowProcedure;
    windowClass.hInstance = instance;
    windowClass.hIcon = static_cast<HICON>(LoadImageW(
        instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 0, 0,
        LR_DEFAULTSIZE
    ));
    windowClass.hIconSm = static_cast<HICON>(LoadImageW(
        instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0
    ));
    windowClass.hCursor = LoadCursor(nullptr, IDC_ARROW);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    windowClass.lpszClassName = L"AuvolMain";
    RegisterClassExW(&windowClass);

    g_mainWindow = CreateWindowExW(
        0, L"AuvolMain", L"Auvol — Audio Transport",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 500, 305,
        nullptr, nullptr, instance, nullptr
    );
    ShowWindow(g_mainWindow, showCommand);
    UpdateWindow(g_mainWindow);

    MSG message = {};
    while (GetMessageW(&message, nullptr, 0, 0)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    StopDirectionControl();
    CloseHandle(g_controlEvent);
    g_controlEvent = nullptr;
    ReleaseMutex(singleInstance);
    CloseHandle(singleInstance);
    return static_cast<int>(message.wParam);
}

int main() {
    return wWinMain(GetModuleHandleW(nullptr), nullptr, GetCommandLineW(),
                    SW_SHOWDEFAULT);
}
#endif
