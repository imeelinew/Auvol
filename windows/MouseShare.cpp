#include "AuvolCore.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <objbase.h>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#ifndef HID_USAGE_PAGE_GENERIC
#define HID_USAGE_PAGE_GENERIC ((USHORT)0x01)
#endif
#ifndef HID_USAGE_GENERIC_MOUSE
#define HID_USAGE_GENERIC_MOUSE ((USHORT)0x02)
#endif

namespace {

constexpr UINT32 kMagic = 0x31494c41u; // ALI1
constexpr UINT8 kTypeSet = 1;
constexpr UINT8 kTypeAck = 2;
constexpr UINT8 kTypeEvent = 3;
constexpr UINT16 kPort = 7780;
constexpr size_t kStateBytes = 24;
constexpr size_t kEventBytes = 28;
constexpr ULONG_PTR kInjectMagic = 0x4155564Cul;
constexpr UINT kHotkeyId = 1;
constexpr UINT kHotkeyCapturedMessage = WM_APP + 1;
constexpr UINT kRefreshCaptureMessage = WM_APP + 2;
constexpr UINT kRefreshHotkeyMessage = WM_APP + 3;
constexpr auto kHeartbeatInterval = std::chrono::milliseconds(500);
constexpr auto kPeerTimeout = std::chrono::milliseconds(1500);
constexpr size_t kEventQueueCapacity = 4096;

struct WireState {
    UINT64 version = 0;
    UINT64 originID = 0;
    bool enabled = false;
    UINT8 host = 0;
};

struct QueuedMouseEvent {
    INT16 dx = 0;
    INT16 dy = 0;
    INT16 wheel = 0;
    INT16 hwheel = 0;
    UINT8 buttons = 0;
    UINT64 captureGeneration = 0;
};

bool Outranks(const WireState& left, const WireState& right) {
    return left.version != right.version
        ? left.version > right.version
        : left.originID > right.originID;
}

bool SameKey(const WireState& left, const WireState& right) {
    return left.version == right.version && left.originID == right.originID;
}

void Put16(void* destination, UINT16 value) {
    memcpy(destination, &value, sizeof(value));
}

void Put32(void* destination, UINT32 value) {
    memcpy(destination, &value, sizeof(value));
}

void Put64(void* destination, UINT64 value) {
    memcpy(destination, &value, sizeof(value));
}

UINT16 Get16(const void* source) {
    UINT16 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

UINT32 Get32(const void* source) {
    UINT32 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

UINT64 Get64(const void* source) {
    UINT64 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

UINT64 GenerateID() {
    GUID guid = {};
    UINT64 first = 0;
    UINT64 second = 0;
    if (SUCCEEDED(CoCreateGuid(&guid))) {
        memcpy(&first, &guid, sizeof(first));
        memcpy(&second, reinterpret_cast<const BYTE*>(&guid) + sizeof(first),
               sizeof(second));
    } else {
        LARGE_INTEGER counter = {};
        QueryPerformanceCounter(&counter);
        first = static_cast<UINT64>(counter.QuadPart);
        second = GetTickCount64() ^ GetCurrentProcessId();
    }
    const UINT64 value = first ^ second;
    return value == 0 ? 1 : value;
}

UINT64 ReadQword(HKEY key, const wchar_t* name) {
    UINT64 value = 0;
    DWORD type = 0;
    DWORD size = sizeof(value);
    return RegQueryValueExW(key, name, nullptr, &type,
                            reinterpret_cast<BYTE*>(&value), &size) == ERROR_SUCCESS &&
           type == REG_QWORD
        ? value : 0;
}

void WriteQword(HKEY key, const wchar_t* name, UINT64 value) {
    RegSetValueExW(key, name, 0, REG_QWORD,
                   reinterpret_cast<const BYTE*>(&value), sizeof(value));
}

std::wstring HotkeyDisplay(UINT modifiers, UINT vk) {
    std::wstring text;
    if (modifiers & MOD_CONTROL) text += L"Ctrl";
    if (modifiers & MOD_ALT) {
        if (!text.empty()) text += L" + ";
        text += L"Alt";
    }
    if (modifiers & MOD_SHIFT) {
        if (!text.empty()) text += L" + ";
        text += L"Shift";
    }
    if (modifiers & MOD_WIN) {
        if (!text.empty()) text += L" + ";
        text += L"Win";
    }
    if (!text.empty()) text += L" + ";
    if (vk >= 'A' && vk <= 'Z') text += static_cast<wchar_t>(vk);
    else if (vk >= '0' && vk <= '9') text += static_cast<wchar_t>(vk);
    else {
        wchar_t buffer[16] = {};
        swprintf_s(buffer, L"Vk%d", vk);
        text += buffer;
    }
    return text;
}

std::mutex g_mutex;
std::string g_peerIP;
std::string g_localIP;
bool g_stateLoaded = false;
UINT64 g_deviceID = 0;
UINT64 g_clock = 0;
WireState g_winner;
std::optional<WireState> g_pending;
unsigned g_attemptsSent = 0;
std::chrono::steady_clock::time_point g_nextSend;
UINT g_hotkeyModifiers = MOD_CONTROL | MOD_ALT;
UINT g_hotkeyVk = 'M';
auvol::MouseShareCallback g_callback;

std::atomic<bool> g_running{false};
std::atomic<bool> g_peerAlive{false};
std::atomic<ULONGLONG> g_peerLeaseDeadline{0};
std::atomic<bool> g_captureActive{false};
std::atomic<bool> g_capturingHotkey{false};
std::atomic<SOCKET> g_socket{INVALID_SOCKET};
std::atomic<HWND> g_window{nullptr};
std::atomic<UINT64> g_endpointGeneration{1};
std::atomic<UINT64> g_captureGeneration{1};
std::thread g_udpThread;
std::thread g_eventThread;
std::thread g_messageThread;

HHOOK g_mouseHook = nullptr;       // Message thread only.
HHOOK g_keyboardHook = nullptr;    // Message thread only.
bool g_rawInputRegistered = false; // Message thread only.
bool g_cursorHidden = false;       // Message thread only.
UINT8 g_physicalButtons = 0;       // Message thread only.

std::mutex g_injectionMutex;
UINT8 g_injectedButtons = 0;
UINT64 g_incomingEventSessionID = 0;
UINT32 g_lastIncomingSequence = 0;

std::array<QueuedMouseEvent, kEventQueueCapacity> g_eventQueue;
std::atomic<size_t> g_eventQueueWrite{0};
std::atomic<size_t> g_eventQueueRead{0};
HANDLE g_eventReady = nullptr;
UINT64 g_eventSessionID = 0;

void NotifyUI() {
    auvol::MouseShareCallback callback;
    bool enabled = false;
    UINT8 host = 0;
    UINT modifiers = 0;
    UINT vk = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        callback = g_callback;
        enabled = g_winner.enabled;
        host = g_winner.host;
        modifiers = g_hotkeyModifiers;
        vk = g_hotkeyVk;
    }
    const bool capturing = g_capturingHotkey.load(std::memory_order_acquire);
    if (callback) {
        callback(enabled, host, capturing,
                 capturing ? L"按下新快捷键…" : HotkeyDisplay(modifiers, vk));
    }
}

void PersistLocked() {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Auvol", 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return;
    }
    WriteQword(key, L"MouseDeviceID", g_deviceID);
    WriteQword(key, L"MouseClock", g_clock);
    WriteQword(key, L"MouseWinnerVersion", g_winner.version);
    WriteQword(key, L"MouseWinnerOrigin", g_winner.originID);
    const DWORD flags = (g_winner.enabled ? 1u : 0u) | (g_winner.host ? 2u : 0u);
    RegSetValueExW(key, L"MouseWinnerFlags", 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&flags), sizeof(flags));
    const DWORD modifiers = g_hotkeyModifiers;
    const DWORD vk = g_hotkeyVk;
    RegSetValueExW(key, L"MouseHotkeyModifiers", 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&modifiers), sizeof(modifiers));
    RegSetValueExW(key, L"MouseHotkeyVk", 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&vk), sizeof(vk));
    RegCloseKey(key);
}

void EnsureStateLocked() {
    if (g_stateLoaded) return;
    g_stateLoaded = true;
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Auvol", 0,
                      KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
        g_deviceID = ReadQword(key, L"MouseDeviceID");
        g_clock = ReadQword(key, L"MouseClock");
        g_winner.version = ReadQword(key, L"MouseWinnerVersion");
        g_winner.originID = ReadQword(key, L"MouseWinnerOrigin");
        DWORD flags = 0;
        DWORD type = 0;
        DWORD size = sizeof(flags);
        if (RegQueryValueExW(key, L"MouseWinnerFlags", nullptr, &type,
                             reinterpret_cast<BYTE*>(&flags), &size) == ERROR_SUCCESS &&
            type == REG_DWORD && g_winner.version > 0) {
            g_winner.enabled = (flags & 1) != 0;
            g_winner.host = (flags & 2) ? 1 : 0;
        }
        DWORD modifiers = g_hotkeyModifiers;
        DWORD vk = g_hotkeyVk;
        size = sizeof(modifiers);
        if (RegQueryValueExW(key, L"MouseHotkeyModifiers", nullptr, &type,
                             reinterpret_cast<BYTE*>(&modifiers), &size) == ERROR_SUCCESS &&
            type == REG_DWORD) {
            g_hotkeyModifiers = modifiers;
        }
        size = sizeof(vk);
        if (RegQueryValueExW(key, L"MouseHotkeyVk", nullptr, &type,
                             reinterpret_cast<BYTE*>(&vk), &size) == ERROR_SUCCESS &&
            type == REG_DWORD && vk != 0) {
            g_hotkeyVk = vk;
        }
        RegCloseKey(key);
    }
    if (g_deviceID == 0) g_deviceID = GenerateID();
    g_clock = std::max(g_clock, g_winner.version);
    if (g_winner.version == 0 || g_winner.originID == 0) {
        ++g_clock;
        if (g_clock == 0) g_clock = 1;
        g_winner = {g_clock, g_deviceID, false, 0};
    }
    PersistLocked();
}

void PublishLocked() {
    EnsureStateLocked();
    g_clock = std::max(g_clock, g_winner.version) + 1;
    if (g_clock == 0) g_clock = 1;
    g_winner.version = g_clock;
    g_winner.originID = g_deviceID;
    g_pending = g_winner;
    g_attemptsSent = 0;
    g_nextSend = std::chrono::steady_clock::now();
    PersistLocked();
}

bool PeerAddress(sockaddr_in* address) {
    if (!address) return false;
    *address = {};
    address->sin_family = AF_INET;
    address->sin_port = htons(kPort);
    std::string peer;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        peer = g_peerIP;
    }
    return inet_pton(AF_INET, peer.c_str(), &address->sin_addr) == 1;
}

bool SourceMatchesPeer(const sockaddr_in& source) {
    sockaddr_in peer = {};
    return PeerAddress(&peer) && source.sin_addr.s_addr == peer.sin_addr.s_addr;
}

std::array<UINT8, kStateBytes> StatePacket(UINT8 type, const WireState& state) {
    std::array<UINT8, kStateBytes> packet = {};
    Put32(packet.data(), kMagic);
    packet[4] = type;
    packet[5] = static_cast<UINT8>((state.enabled ? 1 : 0) | (state.host ? 2 : 0));
    Put64(packet.data() + 8, state.version);
    Put64(packet.data() + 16, state.originID);
    return packet;
}

void SendState(SOCKET socketFD, UINT8 type, const WireState& state,
               const sockaddr_in& destination) {
    const auto packet = StatePacket(type, state);
    sendto(socketFD, reinterpret_cast<const char*>(packet.data()),
           static_cast<int>(packet.size()), 0,
           reinterpret_cast<const sockaddr*>(&destination), sizeof(destination));
}

void RepairLegacySystemCursor() {
    // The previous implementation replaced global cursor resources. Reload the
    // user's configured scheme once, never from an input callback.
    SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0);
}

void HideCursorForCapture() {
    if (g_cursorHidden) return;
    SetCursor(nullptr);
    g_cursorHidden = true;
}

void RestoreCursorAfterCapture() {
    if (!g_cursorHidden) return;
    SetCursor(LoadCursorW(nullptr, IDC_ARROW));
    g_cursorHidden = false;
}

void AddButtonInputs(UINT8 current, UINT8 next, std::vector<INPUT>& inputs) {
    const UINT8 changed = current ^ next;
    auto push = [&](DWORD flags, DWORD data = 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = flags;
        input.mi.mouseData = data;
        input.mi.dwExtraInfo = kInjectMagic;
        inputs.push_back(input);
    };
    if (changed & 1) push(next & 1 ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
    if (changed & 2) push(next & 2 ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP);
    if (changed & 4) push(next & 4 ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP);
    if (changed & 8) {
        push(next & 8 ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON1);
    }
    if (changed & 16) {
        push(next & 16 ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON2);
    }
}

void ResetInjectedInput() {
    std::lock_guard<std::mutex> lock(g_injectionMutex);
    if (g_injectedButtons != 0) {
        std::vector<INPUT> inputs;
        AddButtonInputs(g_injectedButtons, 0, inputs);
        if (!inputs.empty()) {
            SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
        }
    }
    g_injectedButtons = 0;
    g_incomingEventSessionID = 0;
    g_lastIncomingSequence = 0;
}

void PostCaptureRefresh() {
    if (HWND window = g_window.load(std::memory_order_acquire)) {
        PostMessageW(window, kRefreshCaptureMessage, 0, 0);
    }
}

void SetPeerAlive(bool alive) {
    if (!alive) g_peerLeaseDeadline.store(0, std::memory_order_release);
    const bool previous = g_peerAlive.exchange(alive, std::memory_order_acq_rel);
    if (previous == alive) return;
    if (!alive) ResetInjectedInput();
    PostCaptureRefresh();
}

bool PeerLeaseIsValid() {
    const ULONGLONG deadline =
        g_peerLeaseDeadline.load(std::memory_order_acquire);
    return deadline != 0 && GetTickCount64() <= deadline;
}

void NotePeerActivity() {
    g_peerLeaseDeadline.store(
        GetTickCount64() + static_cast<ULONGLONG>(kPeerTimeout.count()),
        std::memory_order_release);
    SetPeerAlive(true);
}

bool DesiredCapture() {
    if (!g_eventReady || !g_peerAlive.load(std::memory_order_acquire) ||
        !PeerLeaseIsValid()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureStateLocked();
    return g_winner.enabled && g_winner.host == 1;
}

bool SetRawInputRegistration(HWND window, bool enabled) {
    RAWINPUTDEVICE device = {};
    device.usUsagePage = HID_USAGE_PAGE_GENERIC;
    device.usUsage = HID_USAGE_GENERIC_MOUSE;
    device.dwFlags = enabled ? RIDEV_INPUTSINK : RIDEV_REMOVE;
    device.hwndTarget = enabled ? window : nullptr;
    return RegisterRawInputDevices(&device, 1, sizeof(device)) == TRUE;
}

UINT8 CurrentPhysicalButtons() {
    UINT8 buttons = 0;
    if (GetAsyncKeyState(VK_LBUTTON) & 0x8000) buttons |= 1;
    if (GetAsyncKeyState(VK_RBUTTON) & 0x8000) buttons |= 2;
    if (GetAsyncKeyState(VK_MBUTTON) & 0x8000) buttons |= 4;
    if (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) buttons |= 8;
    if (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) buttons |= 16;
    return buttons;
}

LRESULT CALLBACK MouseHook(int code, WPARAM wParam, LPARAM lParam);
LRESULT CALLBACK KeyboardHook(int code, WPARAM wParam, LPARAM lParam);

void DisableCaptureOnMessageThread(HWND window) {
    g_captureActive.store(false, std::memory_order_release);
    g_captureGeneration.fetch_add(1, std::memory_order_acq_rel);
    if (g_mouseHook) {
        UnhookWindowsHookEx(g_mouseHook);
        g_mouseHook = nullptr;
    }
    if (g_rawInputRegistered) {
        SetRawInputRegistration(window, false);
        g_rawInputRegistered = false;
    }
    g_physicalButtons = 0;
    RestoreCursorAfterCapture();
}

void RefreshCaptureOnMessageThread(HWND window) {
    const bool desired = DesiredCapture();
    if (!desired) {
        DisableCaptureOnMessageThread(window);
        return;
    }
    if (g_captureActive.load(std::memory_order_acquire) &&
        g_mouseHook && g_rawInputRegistered) {
        return;
    }

    DisableCaptureOnMessageThread(window);
    if (!SetRawInputRegistration(window, true)) return;
    g_rawInputRegistered = true;
    g_mouseHook = SetWindowsHookExW(WH_MOUSE_LL, MouseHook, nullptr, 0);
    if (!g_mouseHook) {
        SetRawInputRegistration(window, false);
        g_rawInputRegistered = false;
        return;
    }
    g_physicalButtons = CurrentPhysicalButtons();
    g_captureGeneration.fetch_add(1, std::memory_order_acq_rel);
    g_captureActive.store(true, std::memory_order_release);
}

bool EnqueueMouseEvent(const QueuedMouseEvent& event) {
    const size_t write = g_eventQueueWrite.load(std::memory_order_relaxed);
    const size_t next = (write + 1) % kEventQueueCapacity;
    if (next == g_eventQueueRead.load(std::memory_order_acquire)) return false;
    g_eventQueue[write] = event;
    g_eventQueueWrite.store(next, std::memory_order_release);
    if (g_eventReady) SetEvent(g_eventReady);
    return true;
}

bool DequeueMouseEvent(QueuedMouseEvent* event) {
    if (!event) return false;
    const size_t read = g_eventQueueRead.load(std::memory_order_relaxed);
    if (read == g_eventQueueWrite.load(std::memory_order_acquire)) return false;
    *event = g_eventQueue[read];
    g_eventQueueRead.store((read + 1) % kEventQueueCapacity,
                           std::memory_order_release);
    return true;
}

void SendQueuedEvent(SOCKET socketFD, const sockaddr_in& destination,
                     const QueuedMouseEvent& event, UINT32 sequence) {
    std::array<UINT8, kEventBytes> packet = {};
    Put32(packet.data(), kMagic);
    packet[4] = kTypeEvent;
    packet[5] = event.buttons & 0x1f;
    Put16(packet.data() + 8, static_cast<UINT16>(event.dx));
    Put16(packet.data() + 10, static_cast<UINT16>(event.dy));
    Put16(packet.data() + 12, static_cast<UINT16>(event.wheel));
    Put16(packet.data() + 14, static_cast<UINT16>(event.hwheel));
    Put32(packet.data() + 16, sequence);
    Put64(packet.data() + 20, g_eventSessionID);
    sendto(socketFD, reinterpret_cast<const char*>(packet.data()),
           static_cast<int>(packet.size()), 0,
           reinterpret_cast<const sockaddr*>(&destination), sizeof(destination));
}

void EventSenderThread() {
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    UINT32 sequence = 0;
    while (g_running.load(std::memory_order_acquire)) {
        WaitForSingleObject(g_eventReady, 500);
        QueuedMouseEvent event;
        while (DequeueMouseEvent(&event)) {
            if (!g_running.load(std::memory_order_acquire)) return;
            if (!g_captureActive.load(std::memory_order_acquire) ||
                !g_peerAlive.load(std::memory_order_acquire) ||
                !PeerLeaseIsValid() ||
                event.captureGeneration !=
                    g_captureGeneration.load(std::memory_order_acquire)) {
                continue;
            }
            const SOCKET socketFD = g_socket.load(std::memory_order_acquire);
            sockaddr_in destination = {};
            if (socketFD == INVALID_SOCKET || !PeerAddress(&destination)) continue;
            ++sequence;
            if (sequence == 0) sequence = 1;
            SendQueuedEvent(socketFD, destination, event, sequence);
        }
    }
}

void InjectEvent(INT16 dx, INT16 dy, INT16 wheel, INT16 hwheel, UINT8 buttons,
                 UINT32 sequence, UINT64 sessionID) {
    bool accept = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        accept = g_winner.enabled && g_winner.host == 0;
    }
    if (!accept || !g_peerAlive.load(std::memory_order_acquire)) return;

    std::lock_guard<std::mutex> lock(g_injectionMutex);
    if (g_incomingEventSessionID != sessionID) {
        if (g_injectedButtons != 0) {
            std::vector<INPUT> releases;
            AddButtonInputs(g_injectedButtons, 0, releases);
            if (!releases.empty()) {
                SendInput(static_cast<UINT>(releases.size()), releases.data(), sizeof(INPUT));
            }
        }
        g_injectedButtons = 0;
        g_incomingEventSessionID = sessionID;
        g_lastIncomingSequence = 0;
    } else if (g_lastIncomingSequence != 0) {
        const INT32 delta = static_cast<INT32>(sequence - g_lastIncomingSequence);
        if (delta <= 0) return;
    }
    g_lastIncomingSequence = sequence;

    std::vector<INPUT> inputs;
    if (dx != 0 || dy != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_MOVE;
        input.mi.dx = dx;
        input.mi.dy = dy;
        input.mi.dwExtraInfo = kInjectMagic;
        inputs.push_back(input);
    }
    AddButtonInputs(g_injectedButtons, buttons & 0x1f, inputs);
    g_injectedButtons = buttons & 0x1f;
    if (wheel != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_WHEEL;
        input.mi.mouseData = static_cast<DWORD>(wheel);
        input.mi.dwExtraInfo = kInjectMagic;
        inputs.push_back(input);
    }
    if (hwheel != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
        input.mi.mouseData = static_cast<DWORD>(hwheel);
        input.mi.dwExtraInfo = kInjectMagic;
        inputs.push_back(input);
    }
    if (!inputs.empty()) {
        SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
    }
}

bool ParseState(const UINT8* bytes, int length, UINT8* type, WireState* state) {
    if (!bytes || !type || !state || length != static_cast<int>(kStateBytes) ||
        Get32(bytes) != kMagic ||
        (bytes[4] != kTypeSet && bytes[4] != kTypeAck) ||
        bytes[6] != 0 || bytes[7] != 0) {
        return false;
    }
    *type = bytes[4];
    state->enabled = (bytes[5] & 1) != 0;
    state->host = (bytes[5] & 2) ? 1 : 0;
    state->version = Get64(bytes + 8);
    state->originID = Get64(bytes + 16);
    return state->version != 0 && state->originID != 0;
}

bool ParseEvent(const UINT8* bytes, int length, QueuedMouseEvent* event,
                UINT32* sequence, UINT64* sessionID) {
    if (!bytes || !event || !sequence || !sessionID ||
        length != static_cast<int>(kEventBytes) || Get32(bytes) != kMagic ||
        bytes[4] != kTypeEvent || bytes[6] != 0 || bytes[7] != 0) {
        return false;
    }
    event->buttons = bytes[5] & 0x1f;
    event->dx = static_cast<INT16>(Get16(bytes + 8));
    event->dy = static_cast<INT16>(Get16(bytes + 10));
    event->wheel = static_cast<INT16>(Get16(bytes + 12));
    event->hwheel = static_cast<INT16>(Get16(bytes + 14));
    *sequence = Get32(bytes + 16);
    *sessionID = Get64(bytes + 20);
    return *sequence != 0 && *sessionID != 0;
}

void ApplyIncomingState(const WireState& incoming) {
    bool changed = false;
    bool resetInput = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        if (incoming.version > g_clock) {
            g_clock = incoming.version;
            changed = true;
        }
        if (Outranks(incoming, g_winner)) {
            g_winner = incoming;
            changed = true;
            if (g_pending && Outranks(incoming, *g_pending)) g_pending.reset();
        }
        if (changed) PersistLocked();
        resetInput = !g_winner.enabled || g_winner.host != 0;
    }
    if (resetInput) ResetInjectedInput();
    if (changed) {
        PostCaptureRefresh();
        NotifyUI();
    }
}

bool ReceivePacket(SOCKET socketFD, const UINT8* bytes, int length,
                   const sockaddr_in& source) {
    if (!SourceMatchesPeer(source)) return false;

    QueuedMouseEvent event;
    UINT32 sequence = 0;
    UINT64 sessionID = 0;
    if (ParseEvent(bytes, length, &event, &sequence, &sessionID)) {
        NotePeerActivity();
        InjectEvent(event.dx, event.dy, event.wheel, event.hwheel,
                    event.buttons, sequence, sessionID);
        return true;
    }

    UINT8 type = 0;
    WireState incoming;
    if (!ParseState(bytes, length, &type, &incoming)) return false;
    NotePeerActivity();
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (incoming.version > g_clock) g_clock = incoming.version;
        if (type == kTypeAck && g_pending &&
            (SameKey(incoming, *g_pending) || Outranks(incoming, *g_pending))) {
            g_pending.reset();
        }
    }
    ApplyIncomingState(incoming);
    if (type == kTypeSet) {
        WireState response;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            response = g_winner;
        }
        SendState(socketFD, kTypeAck, response, source);
    }
    return true;
}

void MaybeSendPending(SOCKET socketFD) {
    std::optional<WireState> state;
    const auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_pending || now < g_nextSend) return;
        if (g_attemptsSent >= 4) {
            g_pending.reset();
            return;
        }
        state = g_pending;
        static constexpr std::chrono::milliseconds delays[] = {
            std::chrono::milliseconds(150),
            std::chrono::milliseconds(400),
            std::chrono::milliseconds(900),
            std::chrono::milliseconds(1000)
        };
        g_nextSend = now + delays[g_attemptsSent];
        ++g_attemptsSent;
    }
    sockaddr_in destination = {};
    if (state && PeerAddress(&destination)) {
        SendState(socketFD, kTypeSet, *state, destination);
    }
}

void SendHeartbeat(SOCKET socketFD) {
    WireState state;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        state = g_winner;
    }
    sockaddr_in destination = {};
    if (PeerAddress(&destination)) {
        SendState(socketFD, kTypeAck, state, destination);
    }
}

SOCKET OpenSocket() {
    SOCKET socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socketFD == INVALID_SOCKET) return INVALID_SOCKET;
    BOOL exclusive = TRUE;
    setsockopt(socketFD, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
               reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
    int trafficClass = 0xb8;
    setsockopt(socketFD, IPPROTO_IP, IP_TOS,
               reinterpret_cast<const char*>(&trafficClass), sizeof(trafficClass));
    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons(kPort);
    std::string localIP;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        localIP = g_localIP;
    }
    if (!localIP.empty()) {
        if (inet_pton(AF_INET, localIP.c_str(), &local.sin_addr) != 1) {
            closesocket(socketFD);
            return INVALID_SOCKET;
        }
    } else {
        local.sin_addr.s_addr = htonl(INADDR_ANY);
    }
    if (bind(socketFD, reinterpret_cast<const sockaddr*>(&local),
             sizeof(local)) == SOCKET_ERROR) {
        closesocket(socketFD);
        return INVALID_SOCKET;
    }
    u_long nonblocking = 1;
    ioctlsocket(socketFD, FIONBIO, &nonblocking);
    return socketFD;
}

void ClosePublishedSocket(SOCKET* socketFD) {
    if (!socketFD || *socketFD == INVALID_SOCKET) return;
    SOCKET expected = *socketFD;
    if (g_socket.compare_exchange_strong(expected, INVALID_SOCKET,
                                         std::memory_order_acq_rel)) {
        closesocket(*socketFD);
    }
    *socketFD = INVALID_SOCKET;
}

void UdpThread() {
    WSADATA winsock = {};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return;

    SOCKET socketFD = INVALID_SOCKET;
    UINT64 endpointGeneration = 0;
    auto nextHeartbeat = std::chrono::steady_clock::now();
    auto lastPeerPacket = std::chrono::steady_clock::now();

    while (g_running.load(std::memory_order_acquire)) {
        const UINT64 currentEndpoint =
            g_endpointGeneration.load(std::memory_order_acquire);
        if (socketFD == INVALID_SOCKET || currentEndpoint != endpointGeneration) {
            ClosePublishedSocket(&socketFD);
            SetPeerAlive(false);
            endpointGeneration = currentEndpoint;
            socketFD = OpenSocket();
            if (socketFD == INVALID_SOCKET) {
                Sleep(200);
                continue;
            }
            g_socket.store(socketFD, std::memory_order_release);
            nextHeartbeat = std::chrono::steady_clock::now();
        }

        MaybeSendPending(socketFD);
        const auto now = std::chrono::steady_clock::now();
        if (now >= nextHeartbeat) {
            SendHeartbeat(socketFD);
            nextHeartbeat = now + kHeartbeatInterval;
        }
        if (g_peerAlive.load(std::memory_order_acquire) &&
            now - lastPeerPacket > kPeerTimeout) {
            SetPeerAlive(false);
        }

        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(socketFD, &readable);
        timeval timeout = {0, 20000};
        const int selected = select(0, &readable, nullptr, nullptr, &timeout);
        if (selected == SOCKET_ERROR) {
            if (!g_running.load(std::memory_order_acquire)) break;
            if (g_endpointGeneration.load(std::memory_order_acquire) !=
                endpointGeneration) {
                continue;
            }
            Sleep(20);
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
            if (ReceivePacket(socketFD, bytes.data(), count, source)) {
                lastPeerPacket = std::chrono::steady_clock::now();
            }
        }
    }

    SetPeerAlive(false);
    ClosePublishedSocket(&socketFD);
    WSACleanup();
}

LRESULT CALLBACK MouseHook(int code, WPARAM wParam, LPARAM lParam) {
    if (code < 0) return CallNextHookEx(g_mouseHook, code, wParam, lParam);
    if (lParam && g_captureActive.load(std::memory_order_acquire)) {
        if (!PeerLeaseIsValid()) {
            g_captureActive.store(false, std::memory_order_release);
            g_captureGeneration.fetch_add(1, std::memory_order_acq_rel);
            RestoreCursorAfterCapture();
            PostCaptureRefresh();
            return CallNextHookEx(g_mouseHook, code, wParam, lParam);
        }
        const auto* info = reinterpret_cast<MSLLHOOKSTRUCT*>(lParam);
        if ((info->flags & LLMHF_INJECTED) == 0 &&
            info->dwExtraInfo != kInjectMagic) {
            HideCursorForCapture();
            return 1;
        }
    }
    return CallNextHookEx(g_mouseHook, code, wParam, lParam);
}

bool IsModifierVk(UINT vk) {
    return vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU ||
           vk == VK_LSHIFT || vk == VK_RSHIFT || vk == VK_LCONTROL ||
           vk == VK_RCONTROL || vk == VK_LMENU || vk == VK_RMENU ||
           vk == VK_LWIN || vk == VK_RWIN;
}

LRESULT CALLBACK KeyboardHook(int code, WPARAM wParam, LPARAM lParam) {
    if (code >= 0 && g_capturingHotkey.load(std::memory_order_acquire) &&
        (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN) && lParam) {
        const auto* info = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
        if (!IsModifierVk(info->vkCode)) {
            UINT modifiers = 0;
            if (GetAsyncKeyState(VK_CONTROL) & 0x8000) modifiers |= MOD_CONTROL;
            if (GetAsyncKeyState(VK_MENU) & 0x8000) modifiers |= MOD_ALT;
            if (GetAsyncKeyState(VK_SHIFT) & 0x8000) modifiers |= MOD_SHIFT;
            if ((GetAsyncKeyState(VK_LWIN) | GetAsyncKeyState(VK_RWIN)) & 0x8000) {
                modifiers |= MOD_WIN;
            }
            if (modifiers != 0) {
                {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    g_hotkeyModifiers = modifiers;
                    g_hotkeyVk = info->vkCode;
                    PersistLocked();
                }
                g_capturingHotkey.store(false, std::memory_order_release);
                if (HWND window = g_window.load(std::memory_order_acquire)) {
                    PostMessageW(window, kHotkeyCapturedMessage, 0, 0);
                }
                return 1;
            }
        }
        return 1;
    }
    return CallNextHookEx(g_keyboardHook, code, wParam, lParam);
}

void HandleRawInput(HRAWINPUT handle) {
    if (!g_captureActive.load(std::memory_order_acquire)) return;
    UINT size = 0;
    GetRawInputData(handle, RID_INPUT, nullptr, &size, sizeof(RAWINPUTHEADER));
    if (size == 0) return;
    std::vector<BYTE> buffer(size);
    if (GetRawInputData(handle, RID_INPUT, buffer.data(), &size,
                        sizeof(RAWINPUTHEADER)) != size) {
        return;
    }
    const auto* raw = reinterpret_cast<RAWINPUT*>(buffer.data());
    if (raw->header.dwType != RIM_TYPEMOUSE) return;
    const RAWMOUSE& mouse = raw->data.mouse;

    INT16 dx = 0;
    INT16 dy = 0;
    if ((mouse.usFlags & MOUSE_MOVE_ABSOLUTE) == 0) {
        dx = static_cast<INT16>(std::clamp<LONG>(mouse.lLastX, INT16_MIN, INT16_MAX));
        dy = static_cast<INT16>(std::clamp<LONG>(mouse.lLastY, INT16_MIN, INT16_MAX));
    }
    if (mouse.usButtonFlags & RI_MOUSE_LEFT_BUTTON_DOWN) g_physicalButtons |= 1;
    if (mouse.usButtonFlags & RI_MOUSE_LEFT_BUTTON_UP) g_physicalButtons &= ~1;
    if (mouse.usButtonFlags & RI_MOUSE_RIGHT_BUTTON_DOWN) g_physicalButtons |= 2;
    if (mouse.usButtonFlags & RI_MOUSE_RIGHT_BUTTON_UP) g_physicalButtons &= ~2;
    if (mouse.usButtonFlags & RI_MOUSE_MIDDLE_BUTTON_DOWN) g_physicalButtons |= 4;
    if (mouse.usButtonFlags & RI_MOUSE_MIDDLE_BUTTON_UP) g_physicalButtons &= ~4;
    if (mouse.usButtonFlags & RI_MOUSE_BUTTON_4_DOWN) g_physicalButtons |= 8;
    if (mouse.usButtonFlags & RI_MOUSE_BUTTON_4_UP) g_physicalButtons &= ~8;
    if (mouse.usButtonFlags & RI_MOUSE_BUTTON_5_DOWN) g_physicalButtons |= 16;
    if (mouse.usButtonFlags & RI_MOUSE_BUTTON_5_UP) g_physicalButtons &= ~16;
    const INT16 wheel = (mouse.usButtonFlags & RI_MOUSE_WHEEL)
        ? static_cast<INT16>(mouse.usButtonData) : 0;
    const INT16 hwheel = (mouse.usButtonFlags & RI_MOUSE_HWHEEL)
        ? static_cast<INT16>(mouse.usButtonData) : 0;

    QueuedMouseEvent event;
    event.dx = dx;
    event.dy = dy;
    event.wheel = wheel;
    event.hwheel = hwheel;
    event.buttons = g_physicalButtons;
    event.captureGeneration = g_captureGeneration.load(std::memory_order_acquire);
    if (!EnqueueMouseEvent(event)) {
        // A saturated sender must never leave the local pointer swallowed.
        g_captureActive.store(false, std::memory_order_release);
        g_captureGeneration.fetch_add(1, std::memory_order_acq_rel);
        RestoreCursorAfterCapture();
        SetPeerAlive(false);
    }
}

void ToggleHostOnMessageThread(HWND window) {
    bool resetInput = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        if (!g_winner.enabled) return;
        g_winner.host = g_winner.host == 0 ? 1 : 0;
        PublishLocked();
        resetInput = g_winner.host != 0;
    }
    if (resetInput) ResetInjectedInput();
    RefreshCaptureOnMessageThread(window);
    NotifyUI();
}

void RefreshHotkeyOnMessageThread(HWND window) {
    if (g_keyboardHook) {
        UnhookWindowsHookEx(g_keyboardHook);
        g_keyboardHook = nullptr;
    }
    UnregisterHotKey(window, kHotkeyId);
    if (g_capturingHotkey.load(std::memory_order_acquire)) {
        g_keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, nullptr, 0);
    } else {
        UINT modifiers = 0;
        UINT vk = 0;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            modifiers = g_hotkeyModifiers;
            vk = g_hotkeyVk;
        }
        RegisterHotKey(window, kHotkeyId, modifiers | MOD_NOREPEAT, vk);
    }
}

LRESULT CALLBACK MouseWndProc(HWND window, UINT message, WPARAM wParam,
                              LPARAM lParam) {
    switch (message) {
    case WM_INPUT:
        HandleRawInput(reinterpret_cast<HRAWINPUT>(lParam));
        return DefWindowProcW(window, message, wParam, lParam);
    case WM_HOTKEY:
        if (wParam == kHotkeyId) ToggleHostOnMessageThread(window);
        return 0;
    case kHotkeyCapturedMessage:
    case kRefreshHotkeyMessage:
        RefreshHotkeyOnMessageThread(window);
        NotifyUI();
        return 0;
    case kRefreshCaptureMessage:
        RefreshCaptureOnMessageThread(window);
        return 0;
    case WM_CLOSE:
        DestroyWindow(window);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

void MessageThread() {
    WNDCLASSEXW windowClass = { sizeof(windowClass) };
    windowClass.lpfnWndProc = MouseWndProc;
    windowClass.hInstance = GetModuleHandleW(nullptr);
    windowClass.lpszClassName = L"AuvolMouseShare";
    RegisterClassExW(&windowClass);
    HWND window = CreateWindowExW(0, L"AuvolMouseShare", L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr, windowClass.hInstance,
                                  nullptr);
    if (!window) return;
    g_window.store(window, std::memory_order_release);
    if (!g_running.load(std::memory_order_acquire)) {
        DestroyWindow(window);
        g_window.store(nullptr, std::memory_order_release);
        return;
    }

    RefreshHotkeyOnMessageThread(window);
    RefreshCaptureOnMessageThread(window);
    NotifyUI();
    MSG message = {};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    DisableCaptureOnMessageThread(window);
    UnregisterHotKey(window, kHotkeyId);
    if (g_keyboardHook) {
        UnhookWindowsHookEx(g_keyboardHook);
        g_keyboardHook = nullptr;
    }
    g_window.store(nullptr, std::memory_order_release);
    if (IsWindow(window)) DestroyWindow(window);
}

void RequestEndpointRestart() {
    g_endpointGeneration.fetch_add(1, std::memory_order_acq_rel);
    SetPeerAlive(false);
}

} // namespace

namespace auvol {

void SetMouseShareCallback(MouseShareCallback callback) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_callback = std::move(callback);
}

void StartMouseShare(const std::string& peerIP) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_peerIP = peerIP;
        EnsureStateLocked();
        if (g_running.exchange(true, std::memory_order_acq_rel)) return;
    }

    RepairLegacySystemCursor();
    ResetInjectedInput();
    g_peerAlive.store(false, std::memory_order_release);
    g_peerLeaseDeadline.store(0, std::memory_order_release);
    g_captureActive.store(false, std::memory_order_release);
    g_captureGeneration.fetch_add(1, std::memory_order_acq_rel);
    g_eventSessionID = GenerateID();
    g_eventQueueRead.store(0, std::memory_order_release);
    g_eventQueueWrite.store(0, std::memory_order_release);
    g_eventReady = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    if (g_udpThread.joinable()) g_udpThread.join();
    if (g_eventThread.joinable()) g_eventThread.join();
    if (g_messageThread.joinable()) g_messageThread.join();
    g_udpThread = std::thread(UdpThread);
    if (g_eventReady) g_eventThread = std::thread(EventSenderThread);
    g_messageThread = std::thread(MessageThread);
}

void SetMouseSharePeer(const std::string& peerIP) {
    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        changed = g_peerIP != peerIP;
        g_peerIP = peerIP;
    }
    if (changed) RequestEndpointRestart();
}

void SetMouseShareEndpoint(const std::string& peerIP, const std::string& localIP) {
    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        changed = g_peerIP != peerIP || g_localIP != localIP;
        g_peerIP = peerIP;
        g_localIP = localIP;
    }
    if (changed) RequestEndpointRestart();
}

void SetMouseShareEnabled(bool enabled) {
    bool resetInput = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        if (g_winner.enabled == enabled) return;
        g_winner.enabled = enabled;
        PublishLocked();
        resetInput = !enabled || g_winner.host != 0;
    }
    if (resetInput) ResetInjectedInput();
    PostCaptureRefresh();
    NotifyUI();
}

void SetMouseCursorHost(int host) {
    const UINT8 normalized = host == 1 ? 1 : 0;
    bool resetInput = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        if (g_winner.host == normalized) return;
        g_winner.host = normalized;
        PublishLocked();
        resetInput = normalized != 0;
    }
    if (resetInput) ResetInjectedInput();
    PostCaptureRefresh();
    NotifyUI();
}

void BeginMouseHotkeyCapture() {
    g_capturingHotkey.store(true, std::memory_order_release);
    if (HWND window = g_window.load(std::memory_order_acquire)) {
        PostMessageW(window, kRefreshHotkeyMessage, 0, 0);
    }
    NotifyUI();
}

void CancelMouseHotkeyCapture() {
    g_capturingHotkey.store(false, std::memory_order_release);
    if (HWND window = g_window.load(std::memory_order_acquire)) {
        PostMessageW(window, kRefreshHotkeyMessage, 0, 0);
    }
    NotifyUI();
}

void StopMouseShare() {
    g_running.store(false, std::memory_order_release);
    g_captureActive.store(false, std::memory_order_release);
    g_captureGeneration.fetch_add(1, std::memory_order_acq_rel);
    if (g_eventReady) SetEvent(g_eventReady);
    const SOCKET socketFD = g_socket.exchange(INVALID_SOCKET,
                                              std::memory_order_acq_rel);
    if (socketFD != INVALID_SOCKET) closesocket(socketFD);
    if (HWND window = g_window.load(std::memory_order_acquire)) {
        PostMessageW(window, WM_CLOSE, 0, 0);
    }

    if (g_messageThread.joinable()) g_messageThread.join();
    if (g_eventThread.joinable()) g_eventThread.join();
    if (g_udpThread.joinable()) g_udpThread.join();
    if (g_eventReady) {
        CloseHandle(g_eventReady);
        g_eventReady = nullptr;
    }
    SetPeerAlive(false);
    ResetInjectedInput();
}

} // namespace auvol
