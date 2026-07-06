// Auvol — Windows audio sender
// WASAPI loopback (default render device) -> UDP float32 PCM -> Mac receiver
// Build: x86_64-w64-mingw32-g++ -std=c++17 -O2 -static -o Auvol.exe auvol.cpp \
//          -lole32 -lws2_32 -lksuser -lgdi32 -lcomctl32 -luxtheme -mwindows

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <commctrl.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

#include <thread>
#include <atomic>
#include <vector>
#include <cstring>
#include <cstdio>
#include <chrono>
#include <string>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "uxtheme.lib")

// ---- Protocol ----
static const UINT32 MAGIC        = 0x414C5631u;
static const UINT32 TYPE_CONFIG  = 0;
static const UINT32 TYPE_AUDIO   = 1;
static const UINT32 FRAME_FRAMES = 120;

#ifndef WAVE_FORMAT_EXTENSIBLE
#define WAVE_FORMAT_EXTENSIBLE 0xFFFE
#endif

struct WaveFormatExt {
    WAVEFORMATEX Format;
    WORD  wValidBitsPerSample;
    DWORD dwChannelMask;
    GUID  SubFormat;
};

static const GUID SUBTYPE_FLOAT = {
    0x00000003, 0x0000, 0x0010,
    {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}
};

// ---- Globals ----
static HWND hMain, hIpEdit, hConnectBtn, hDisconnectBtn, hStatusLabel, hStatsLabel;
static std::atomic<bool> g_running{false};
static std::atomic<bool> g_connected{false};
static std::thread g_audioThread;
static std::atomic<UINT64> g_packetsSent{0};
static std::string g_statusText("Idle");
static std::string g_statsText;

static void UpdateStatus(const char* s) {
    g_statusText = s;
    PostMessage(hMain, WM_APP + 1, 0, 0);
}

static void UpdateStats(UINT64 packets) {
    char buf[128];
    snprintf(buf, sizeof(buf), "Packets sent: %llu", (unsigned long long)packets);
    g_statsText = buf;
    PostMessage(hMain, WM_APP + 2, 0, 0);
}

// ---- Audio capture + send thread ----
static void AudioThread(const std::string& targetIp, UINT16 port) {
    WSADATA wsa = {};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        UpdateStatus("WSAStartup failed");
        return;
    }

    SOCKET sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock == INVALID_SOCKET) {
        UpdateStatus("socket() failed");
        WSACleanup();
        return;
    }

    sockaddr_in dst = {};
    dst.sin_family = AF_INET;
    dst.sin_port = htons(port);
    if (inet_pton(AF_INET, targetIp.c_str(), &dst.sin_addr) != 1) {
        UpdateStatus("Invalid IP address");
        closesocket(sock);
        WSACleanup();
        return;
    }

    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
        UpdateStatus("CoInitializeEx failed");
        closesocket(sock);
        WSACleanup();
        return;
    }

    IMMDeviceEnumerator*  enumr   = nullptr;
    IMMDevice*            device  = nullptr;
    IAudioClient*         client  = nullptr;
    IAudioCaptureClient*  capture = nullptr;
    WAVEFORMATEX*         mixFmt  = nullptr;
    bool started = false;

    auto cleanup = [&]() {
        if (started && client) client->Stop();
        if (client)  client->Release();
        if (capture) capture->Release();
        if (device)  device->Release();
        if (enumr)   enumr->Release();
        if (mixFmt)  CoTaskMemFree(mixFmt);
        closesocket(sock);
        CoUninitialize();
        WSACleanup();
    };

    HRESULT hr;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void**)&enumr);
    if (FAILED(hr)) { UpdateStatus("CoCreateInstance failed"); cleanup(); return; }
    hr = enumr->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) { UpdateStatus("No audio device"); cleanup(); return; }
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&client);
    if (FAILED(hr)) { UpdateStatus("Activate failed"); cleanup(); return; }
    hr = client->GetMixFormat(&mixFmt);
    if (FAILED(hr)) { UpdateStatus("GetMixFormat failed"); cleanup(); return; }

    bool isFloat = (mixFmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT);
    if (mixFmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        WaveFormatExt* ext = (WaveFormatExt*)mixFmt;
        isFloat = (ext->SubFormat == SUBTYPE_FLOAT);
    }
    if (!isFloat || mixFmt->wBitsPerSample != 32) {
        UpdateStatus("Mix format is not float32");
        cleanup();
        return;
    }
    if (mixFmt->nChannels != 2) {
        UpdateStatus("Not stereo");
        cleanup();
        return;
    }

    {
        char buf[256];
        snprintf(buf, sizeof(buf), "Capturing %u Hz -> %s:%u",
                 mixFmt->nSamplesPerSec, targetIp.c_str(), port);
        UpdateStatus(buf);
    }

    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_LOOPBACK,
                            10000000, 0, mixFmt, nullptr);
    if (FAILED(hr)) { UpdateStatus("Initialize failed"); cleanup(); return; }
    hr = client->GetService(__uuidof(IAudioCaptureClient), (void**)&capture);
    if (FAILED(hr)) { UpdateStatus("GetService failed"); cleanup(); return; }
    hr = client->Start();
    if (FAILED(hr)) { UpdateStatus("Start failed"); cleanup(); return; }
    started = true;

    {
        UINT32 sr = mixFmt->nSamplesPerSec;
        UINT32 ch = mixFmt->nChannels;
        UINT32 ff = FRAME_FRAMES;

        UINT8 cfgPkt[20];
        memcpy(cfgPkt + 0,  &MAGIC, 4);
        memcpy(cfgPkt + 4,  &TYPE_CONFIG, 4);
        memcpy(cfgPkt + 8,  &sr, 4);
        memcpy(cfgPkt + 12, &ch, 4);
        memcpy(cfgPkt + 16, &ff, 4);
        sendto(sock, (const char*)cfgPkt, 20, 0, (sockaddr*)&dst, sizeof(dst));

        std::vector<float> stage;
        stage.reserve(FRAME_FRAMES * 2 * 8);
        const size_t payloadFloats = (size_t)FRAME_FRAMES * 2;
        const size_t payloadBytes  = payloadFloats * 4;
        std::vector<UINT8> audioPkt(20 + payloadBytes);
        memcpy(audioPkt.data() + 0, &MAGIC, 4);
        memcpy(audioPkt.data() + 4, &TYPE_AUDIO, 4);

        UINT32 seq = 0;
        auto lastCfg  = std::chrono::steady_clock::now();
        auto lastStat = lastCfg;
        REFERENCE_TIME period = 100000;
        client->GetDevicePeriod(&period, nullptr);
        DWORD sleepMs = (DWORD)(period / 10000 / 2);
        if (sleepMs == 0) sleepMs = 1;

        while (g_running.load()) {
            Sleep(sleepMs);

            for (;;) {
                UINT32 pktFrames = 0;
                hr = capture->GetNextPacketSize(&pktFrames);
                if (FAILED(hr) || pktFrames == 0) break;
                BYTE* data = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
                if (FAILED(hr)) break;
                if (frames > 0 && data) {
                    const float* src = (const float*)data;
                    stage.insert(stage.end(), src, src + (size_t)frames * 2);
                }
                capture->ReleaseBuffer(frames);
            }

            while (stage.size() >= payloadFloats) {
                UINT64 ts = (UINT64)std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count();
                memcpy(audioPkt.data() + 8,  &seq, 4);
                memcpy(audioPkt.data() + 12, &ts,  8);
                memcpy(audioPkt.data() + 20, stage.data(), payloadBytes);
                sendto(sock, (const char*)audioPkt.data(), (int)audioPkt.size(), 0,
                       (sockaddr*)&dst, sizeof(dst));
                seq++;
                g_packetsSent.store(seq);
                stage.erase(stage.begin(), stage.begin() + payloadFloats);
            }

            auto now = std::chrono::steady_clock::now();
            if (now - lastCfg > std::chrono::seconds(1)) {
                sendto(sock, (const char*)cfgPkt, 20, 0,
                       (sockaddr*)&dst, sizeof(dst));
                lastCfg = now;
            }
            if (now - lastStat > std::chrono::seconds(2)) {
                UpdateStats(seq);
                lastStat = now;
            }
        }
    }

    UpdateStatus("Stopped");
    cleanup();
}

// ---- Window proc ----
static LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        CreateWindowW(L"STATIC", L"Mac IP address:",
            WS_CHILD | WS_VISIBLE, 20, 20, 200, 18, hWnd, nullptr, nullptr, nullptr);
        hIpEdit = CreateWindowW(L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL,
            20, 42, 300, 24, hWnd, (HMENU)101, nullptr, nullptr);
        hConnectBtn = CreateWindowW(L"BUTTON", L"Connect",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            20, 80, 100, 32, hWnd, (HMENU)102, nullptr, nullptr);
        hDisconnectBtn = CreateWindowW(L"BUTTON", L"Disconnect",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_DISABLED,
            130, 80, 100, 32, hWnd, (HMENU)103, nullptr, nullptr);
        hStatusLabel = CreateWindowW(L"STATIC", L"Status: Idle",
            WS_CHILD | WS_VISIBLE, 20, 130, 320, 20, hWnd, (HMENU)104, nullptr, nullptr);
        hStatsLabel = CreateWindowW(L"STATIC", L"Packets sent: 0",
            WS_CHILD | WS_VISIBLE, 20, 150, 320, 20, hWnd, (HMENU)105, nullptr, nullptr);
        SendMessage(hIpEdit, EM_SETLIMITTEXT, 45, 0);
        SetWindowText(hIpEdit, L"192.168.101.162");
        EnableWindow(hDisconnectBtn, FALSE);
        return 0;
    }
    case WM_COMMAND: {
        WORD id = LOWORD(wParam);
        if (id == 102 && !g_connected.load()) {
            char ip[64] = {};
            GetWindowTextA(hIpEdit, ip, sizeof(ip));
            if (strlen(ip) == 0) {
                MessageBoxA(hWnd, "Please enter the Mac IP address", "Auvol", MB_OK | MB_ICONWARNING);
                return 0;
            }
            g_running.store(true);
            g_connected.store(true);
            g_packetsSent.store(0);
            EnableWindow(hIpEdit, FALSE);
            EnableWindow(hConnectBtn, FALSE);
            EnableWindow(hDisconnectBtn, TRUE);
            g_audioThread = std::thread(AudioThread, std::string(ip), (UINT16)7777);
        } else if (id == 103 && g_connected.load()) {
            g_running.store(false);
            g_connected.store(false);
            if (g_audioThread.joinable()) g_audioThread.join();
            EnableWindow(hIpEdit, TRUE);
            EnableWindow(hConnectBtn, TRUE);
            EnableWindow(hDisconnectBtn, FALSE);
            SetWindowTextA(hStatusLabel, "Status: Idle");
            SetWindowTextA(hStatsLabel, "Packets sent: 0");
        }
        return 0;
    }
    case WM_APP + 1: {
        std::string s = "Status: " + g_statusText;
        SetWindowTextA(hStatusLabel, s.c_str());
        return 0;
    }
    case WM_APP + 2: {
        SetWindowTextA(hStatsLabel, g_statsText.c_str());
        return 0;
    }
    case WM_CLOSE:
        if (g_connected.load()) {
            g_running.store(false);
            g_connected.store(false);
            if (g_audioThread.joinable()) g_audioThread.join();
        }
        DestroyWindow(hWnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hWnd, msg, wParam, lParam);
}

// ---- Entry point ----
int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int show) {
    InitCommonControls();

    WNDCLASSW wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"AuvolMain";
    RegisterClassW(&wc);

    hMain = CreateWindowExW(0, L"AuvolMain", L"Auvol — Audio Sender",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 380, 240,
        nullptr, nullptr, hInst, nullptr);

    ShowWindow(hMain, show);
    UpdateWindow(hMain);

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return (int)msg.wParam;
}

// mingw: allow console entry to call GUI main
int main() {
    HINSTANCE hInst = GetModuleHandle(nullptr);
    return wWinMain(hInst, nullptr, GetCommandLineW(), SW_SHOWDEFAULT);
}
