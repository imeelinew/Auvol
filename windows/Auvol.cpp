// Auvol Windows sender: event-driven WASAPI loopback -> ALV2 UDP float32 PCM.

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <commctrl.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <shellapi.h>

#include "resource.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

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
static HWND g_connectButton = nullptr;
static HWND g_disconnectButton = nullptr;
static HWND g_statusLabel = nullptr;
static HWND g_statsLabel = nullptr;
static std::atomic<bool> g_running{false};
static std::atomic<bool> g_connected{false};
static std::thread g_audioThread;
static std::string g_autoConnectIP;

static void Put16(void* destination, UINT16 value) {
    memcpy(destination, &value, sizeof(value));
}

static void Put32(void* destination, UINT32 value) {
    memcpy(destination, &value, sizeof(value));
}

static void Put64(void* destination, UINT64 value) {
    memcpy(destination, &value, sizeof(value));
}

static void PostText(UINT message, std::string text) {
    auto* payload = new std::string(std::move(text));
    if (!PostMessageA(g_mainWindow, message, 0,
                      reinterpret_cast<LPARAM>(payload))) {
        delete payload;
    }
}

static void PostStatus(const std::string& text) {
    PostText(WM_APP + 1, "Status: " + text);
}

static void PostStats(UINT64 packets, UINT64 errors) {
    char text[192] = {};
    snprintf(text, sizeof(text), "Packets: %llu    Send errors: %llu",
             static_cast<unsigned long long>(packets),
             static_cast<unsigned long long>(errors));
    PostText(WM_APP + 2, text);
}

static UINT32 NewStreamID() {
    LARGE_INTEGER counter = {};
    QueryPerformanceCounter(&counter);
    UINT32 value = counter.LowPart ^ counter.HighPart ^
                   GetCurrentProcessId() ^ GetTickCount();
    return value == 0 ? 1 : value;
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

static void AudioThread(std::string targetIP, UINT16 port) {
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
    HANDLE mmcssHandle = nullptr;
    bool clientStarted = false;
    bool periodClientStarted = false;
    bool comInitialized = false;
    bool winsockInitialized = false;
    DatagramSender sender;

    auto finish = [&]() {
        if (clientStarted && client) client->Stop();
        if (periodClientStarted && periodClient) periodClient->Stop();
        if (mmcssHandle) AvRevertMmThreadCharacteristics(mmcssHandle);
        if (audioEvent) CloseHandle(audioEvent);
        if (periodEvent) CloseHandle(periodEvent);
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
        g_running.store(false);
        g_connected.store(false);
        PostMessageA(g_mainWindow, WM_APP + 3, 0, 0);
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
    HANDLE waitHandles[2] = {audioEvent, periodEvent};
    while (g_running.load()) {
        const DWORD waitResult = WaitForMultipleObjects(2, waitHandles,
                                                        FALSE, 50);
        if (waitResult == WAIT_FAILED) {
            PostStatus("Audio event wait failed");
            break;
        }

        if (waitResult == WAIT_OBJECT_0 + 1) {
            UINT32 paddingFrames = 0;
            if (SUCCEEDED(periodClient->GetCurrentPadding(&paddingFrames)) &&
                paddingFrames < periodBufferFrames) {
                const UINT32 writableFrames = periodBufferFrames - paddingFrames;
                BYTE* silence = nullptr;
                if (SUCCEEDED(periodRender->GetBuffer(writableFrames, &silence))) {
                    periodRender->ReleaseBuffer(writableFrames,
                                                AUDCLNT_BUFFERFLAGS_SILENT);
                }
            }
        }

        if (waitResult == WAIT_OBJECT_0 || waitResult == WAIT_OBJECT_0 + 1) {
            while (g_running.load()) {
                UINT32 nextFrames = 0;
                result = capture->GetNextPacketSize(&nextFrames);
                if (FAILED(result)) {
                    PostStatus("Capture device was invalidated");
                    g_running.store(false);
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
                    PostStatus("Capture buffer read failed");
                    g_running.store(false);
                    break;
                }

                const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                const bool discontinuity =
                    (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0;
                const float* source = reinterpret_cast<const float*>(bytes);
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
                capture->ReleaseBuffer(frames);
            }
        }

        const auto now = std::chrono::steady_clock::now();
        if (now - lastConfig >= std::chrono::milliseconds(500)) {
            if (!sender.sendConfig(streamID, mixFormat->nSamplesPerSec,
                                   capturePeriodFrames)) {
                ++sendErrors;
            }
            lastConfig = now;
        }
        if (now - lastStats >= std::chrono::seconds(1)) {
            PostStats(packetsSent, sendErrors);
            lastStats = now;
        }
    }

    PostStatus("Stopped");
    finish();
}

static void SetConnectedControls(bool connected) {
    EnableWindow(g_ipEdit, !connected);
    EnableWindow(g_connectButton, !connected);
    EnableWindow(g_disconnectButton, connected);
}

static void JoinAudioThread() {
    if (g_audioThread.joinable()) {
        g_audioThread.join();
    }
}

static std::string AutoConnectIP() {
    int argumentCount = 0;
    LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &argumentCount);
    if (!arguments) return {};

    std::string result;
    for (int index = 1; index + 1 < argumentCount; ++index) {
        if (wcscmp(arguments[index], L"--connect") != 0) continue;
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

static LRESULT CALLBACK WindowProcedure(HWND window,
                                        UINT message,
                                        WPARAM wParam,
                                        LPARAM lParam) {
    switch (message) {
    case WM_CREATE:
        CreateWindowW(L"STATIC", L"Mac IP address:",
                      WS_CHILD | WS_VISIBLE, 20, 20, 300, 18,
                      window, nullptr, nullptr, nullptr);
        g_ipEdit = CreateWindowW(L"EDIT", L"192.168.101.169",
                                 WS_CHILD | WS_VISIBLE | WS_BORDER |
                                     ES_AUTOHSCROLL,
                                 20, 42, 360, 26, window,
                                 reinterpret_cast<HMENU>(101), nullptr, nullptr);
        g_connectButton = CreateWindowW(L"BUTTON", L"Connect",
                                        WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                        20, 82, 110, 32, window,
                                        reinterpret_cast<HMENU>(102), nullptr,
                                        nullptr);
        g_disconnectButton = CreateWindowW(
            L"BUTTON", L"Disconnect",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_DISABLED,
            142, 82, 110, 32, window, reinterpret_cast<HMENU>(103), nullptr,
            nullptr
        );
        g_statusLabel = CreateWindowW(L"STATIC", L"Status: Idle",
                                      WS_CHILD | WS_VISIBLE, 20, 132, 440, 22,
                                      window, reinterpret_cast<HMENU>(104),
                                      nullptr, nullptr);
        g_statsLabel = CreateWindowW(L"STATIC", L"Packets: 0    Send errors: 0",
                                     WS_CHILD | WS_VISIBLE, 20, 158, 440, 22,
                                     window, reinterpret_cast<HMENU>(105),
                                     nullptr, nullptr);
        SendMessageW(g_ipEdit, EM_SETLIMITTEXT, 45, 0);
        if (!g_autoConnectIP.empty()) {
            SetWindowTextA(g_ipEdit, g_autoConnectIP.c_str());
            PostMessageW(window, WM_APP + 4, 0, 0);
        }
        return 0;

    case WM_COMMAND: {
        const WORD controlID = LOWORD(wParam);
        if (controlID == 102 && !g_connected.load()) {
            char targetIP[64] = {};
            GetWindowTextA(g_ipEdit, targetIP, sizeof(targetIP));
            if (targetIP[0] == '\0') {
                MessageBoxW(window, L"Enter the Mac IP address.", L"Auvol",
                            MB_OK | MB_ICONWARNING);
                return 0;
            }
            JoinAudioThread();
            g_running.store(true);
            g_connected.store(true);
            SetConnectedControls(true);
            g_audioThread = std::thread(AudioThread, std::string(targetIP),
                                        static_cast<UINT16>(7777));
        } else if (controlID == 103 && g_connected.load()) {
            g_running.store(false);
            JoinAudioThread();
            SetConnectedControls(false);
            SetWindowTextA(g_statusLabel, "Status: Idle");
            SetWindowTextA(g_statsLabel, "Packets: 0    Send errors: 0");
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

    case WM_CLOSE:
        g_running.store(false);
        JoinAudioThread();
        DestroyWindow(window);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    HANDLE singleInstance = CreateMutexW(
        nullptr, TRUE, L"Local\\AuvolSenderSingleInstance"
    );
    if (!singleInstance || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (singleInstance) CloseHandle(singleInstance);
        MessageBoxW(nullptr, L"Auvol is already running.", L"Auvol",
                    MB_OK | MB_ICONINFORMATION);
        return 0;
    }

    InitCommonControls();
    g_autoConnectIP = AutoConnectIP();

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
        0, L"AuvolMain", L"Auvol — Audio Sender",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 500, 245,
        nullptr, nullptr, instance, nullptr
    );
    ShowWindow(g_mainWindow, showCommand);
    UpdateWindow(g_mainWindow);

    MSG message = {};
    while (GetMessageW(&message, nullptr, 0, 0)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    ReleaseMutex(singleInstance);
    CloseHandle(singleInstance);
    return static_cast<int>(message.wParam);
}

int main() {
    return wWinMain(GetModuleHandleW(nullptr), nullptr, GetCommandLineW(),
                    SW_SHOWDEFAULT);
}
