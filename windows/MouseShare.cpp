#include "AuvolCore.h"

#define OEMRESOURCE
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

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
constexpr size_t kEventBytes = 20;
constexpr ULONG_PTR kInjectMagic = 0x4155564Cul;
constexpr UINT kHotkeyId = 1;
constexpr UINT kHotkeyCapturedMessage = WM_APP + 1;

struct WireState {
    UINT64 version = 0;
    UINT64 originID = 0;
    bool enabled = false;
    UINT8 host = 0;
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

UINT64 GenerateDeviceID() {
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

HCURSOR MakeBlankCursor() {
    const int size = 32;
    std::vector<BYTE> andMask(size * size / 8, 0xFF);
    std::vector<BYTE> xorMask(size * size / 8, 0);
    return CreateCursor(GetModuleHandleW(nullptr), 0, 0, size, size,
                        andMask.data(), xorMask.data());
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
std::atomic<bool> g_running{false};
std::atomic<SOCKET> g_socket{INVALID_SOCKET};
std::thread g_udpThread;
std::thread g_messageThread;
HWND g_window = nullptr;
HHOOK g_mouseHook = nullptr;
HHOOK g_keyboardHook = nullptr;
HCURSOR g_blankCursor = nullptr;
bool g_cursorHidden = false;
bool g_capturingHotkey = false;
UINT g_hotkeyModifiers = MOD_CONTROL | MOD_ALT;
UINT g_hotkeyVk = 'M';
UINT32 g_eventSequence = 0;
UINT32 g_lastIncomingSequence = 0;
UINT8 g_buttons = 0;
UINT8 g_injectedButtons = 0;
bool g_hasPhysicalMouse = false;
std::chrono::steady_clock::time_point g_lastPhysical;
auvol::MouseShareCallback g_callback;

void NotifyUI() {
    auvol::MouseShareCallback callback;
    bool enabled = false;
    UINT8 host = 0;
    bool capturing = false;
    UINT modifiers = 0;
    UINT vk = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        callback = g_callback;
        enabled = g_winner.enabled;
        host = g_winner.host;
        capturing = g_capturingHotkey;
        modifiers = g_hotkeyModifiers;
        vk = g_hotkeyVk;
    }
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
    if (g_deviceID == 0) g_deviceID = GenerateDeviceID();
    g_clock = std::max(g_clock, g_winner.version);
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

void HideSystemCursor() {
    if (g_cursorHidden) return;
    if (!g_blankCursor) g_blankCursor = MakeBlankCursor();
    if (!g_blankCursor) return;
    SetSystemCursor(CopyCursor(g_blankCursor), OCR_NORMAL);
    SetSystemCursor(CopyCursor(g_blankCursor), OCR_IBEAM);
    SetSystemCursor(CopyCursor(g_blankCursor), OCR_HAND);
    SetSystemCursor(CopyCursor(g_blankCursor), OCR_APPSTARTING);
    g_cursorHidden = true;
}

void RestoreSystemCursor() {
    SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0);
    g_cursorHidden = false;
}

bool ShouldForwardLocked() {
    const auto now = std::chrono::steady_clock::now();
    g_hasPhysicalMouse = g_hasPhysicalMouse &&
        (now - g_lastPhysical) < std::chrono::milliseconds(800);
    return g_winner.enabled && g_winner.host == 1 && g_hasPhysicalMouse;
}

void UpdateCursorLocked() {
    if (ShouldForwardLocked()) HideSystemCursor();
    else RestoreSystemCursor();
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

void SendEvent(INT16 dx, INT16 dy, INT16 wheel, INT16 hwheel, UINT8 buttons) {
    SOCKET socketFD = g_socket.load(std::memory_order_acquire);
    sockaddr_in destination = {};
    if (socketFD == INVALID_SOCKET || !PeerAddress(&destination)) return;
    std::array<UINT8, kEventBytes> packet = {};
    Put32(packet.data(), kMagic);
    packet[4] = kTypeEvent;
    packet[5] = buttons;
    Put16(packet.data() + 8, static_cast<UINT16>(dx));
    Put16(packet.data() + 10, static_cast<UINT16>(dy));
    Put16(packet.data() + 12, static_cast<UINT16>(wheel));
    Put16(packet.data() + 14, static_cast<UINT16>(hwheel));
    UINT32 sequence = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_eventSequence;
        if (g_eventSequence == 0) g_eventSequence = 1;
        sequence = g_eventSequence;
    }
    Put32(packet.data() + 16, sequence);
    sendto(socketFD, reinterpret_cast<const char*>(packet.data()),
           static_cast<int>(packet.size()), 0,
           reinterpret_cast<const sockaddr*>(&destination), sizeof(destination));
}

void InjectButtons(UINT8 next) {
    const UINT8 changed = g_injectedButtons ^ next;
    std::vector<INPUT> inputs;
    auto push = [&](DWORD flags) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = flags;
        input.mi.dwExtraInfo = kInjectMagic;
        inputs.push_back(input);
    };
    if (changed & 1) push(next & 1 ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
    if (changed & 2) push(next & 2 ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP);
    if (changed & 4) push(next & 4 ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP);
    if (changed & 8) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = next & 8 ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
        input.mi.mouseData = XBUTTON1;
        input.mi.dwExtraInfo = kInjectMagic;
        inputs.push_back(input);
    }
    if (changed & 16) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = next & 16 ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
        input.mi.mouseData = XBUTTON2;
        input.mi.dwExtraInfo = kInjectMagic;
        inputs.push_back(input);
    }
    if (!inputs.empty()) {
        SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
    }
    g_injectedButtons = next;
}

void InjectEvent(INT16 dx, INT16 dy, INT16 wheel, INT16 hwheel, UINT8 buttons,
                 UINT32 sequence) {
    bool enabled = false;
    UINT8 host = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        enabled = g_winner.enabled;
        host = g_winner.host;
        if (g_lastIncomingSequence != 0) {
            const INT32 delta = static_cast<INT32>(sequence - g_lastIncomingSequence);
            if (delta <= 0) return;
        }
        g_lastIncomingSequence = sequence;
    }
    if (!enabled || host != 0) return;
    if (dx != 0 || dy != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_MOVE;
        input.mi.dx = dx;
        input.mi.dy = dy;
        input.mi.dwExtraInfo = kInjectMagic;
        SendInput(1, &input, sizeof(INPUT));
    }
    InjectButtons(buttons);
    if (wheel != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_WHEEL;
        input.mi.mouseData = static_cast<DWORD>(wheel);
        input.mi.dwExtraInfo = kInjectMagic;
        SendInput(1, &input, sizeof(INPUT));
    }
    if (hwheel != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
        input.mi.mouseData = static_cast<DWORD>(hwheel);
        input.mi.dwExtraInfo = kInjectMagic;
        SendInput(1, &input, sizeof(INPUT));
    }
}

void ApplyIncomingState(const WireState& incoming) {
    bool changed = false;
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
        UpdateCursorLocked();
    }
    if (changed) NotifyUI();
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

void ReceivePacket(SOCKET socketFD, const UINT8* bytes, int length,
                   const sockaddr_in& source) {
    if (!SourceMatchesPeer(source)) return;
    if (length == static_cast<int>(kEventBytes) && Get32(bytes) == kMagic &&
        bytes[4] == kTypeEvent) {
        InjectEvent(static_cast<INT16>(Get16(bytes + 8)),
                    static_cast<INT16>(Get16(bytes + 10)),
                    static_cast<INT16>(Get16(bytes + 12)),
                    static_cast<INT16>(Get16(bytes + 14)),
                    bytes[5], Get32(bytes + 16));
        return;
    }
    UINT8 type = 0;
    WireState incoming;
    if (!ParseState(bytes, length, &type, &incoming)) return;
    if (incoming.version != 0) {
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
        inet_pton(AF_INET, localIP.c_str(), &local.sin_addr);
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

void UdpThread() {
    WSADATA winsock = {};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return;
    SOCKET socketFD = OpenSocket();
    if (socketFD == INVALID_SOCKET) {
        WSACleanup();
        return;
    }
    g_socket.store(socketFD, std::memory_order_release);
    auto nextHeartbeat = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (g_running.load(std::memory_order_acquire)) {
        MaybeSendPending(socketFD);
        const auto now = std::chrono::steady_clock::now();
        if (now >= nextHeartbeat) {
            SendHeartbeat(socketFD);
            nextHeartbeat = now + std::chrono::seconds(5);
        }
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(socketFD, &readable);
        timeval timeout = {0, 50000};
        const int selected = select(0, &readable, nullptr, nullptr, &timeout);
        if (selected == SOCKET_ERROR) {
            if (!g_running.load(std::memory_order_acquire)) break;
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
            ReceivePacket(socketFD, bytes.data(), count, source);
        }
    }
    SOCKET expected = socketFD;
    if (g_socket.compare_exchange_strong(expected, INVALID_SOCKET,
                                         std::memory_order_acq_rel)) {
        closesocket(socketFD);
    }
    WSACleanup();
}

LRESULT CALLBACK MouseHook(int code, WPARAM wParam, LPARAM lParam) {
    if (code >= 0 && lParam) {
        const auto* info = reinterpret_cast<MSLLHOOKSTRUCT*>(lParam);
        if ((info->flags & LLMHF_INJECTED) == 0 &&
            info->dwExtraInfo != kInjectMagic) {
            bool swallow = false;
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                EnsureStateLocked();
                g_hasPhysicalMouse = true;
                g_lastPhysical = std::chrono::steady_clock::now();
                swallow = ShouldForwardLocked();
                UpdateCursorLocked();
            }
            if (swallow) return 1;
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
    if (code >= 0 && g_capturingHotkey &&
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
                    g_capturingHotkey = false;
                    PersistLocked();
                }
                if (g_window) PostMessageW(g_window, kHotkeyCapturedMessage, 0, 0);
                return 1;
            }
        }
        return 1;
    }
    return CallNextHookEx(g_keyboardHook, code, wParam, lParam);
}

void HandleRawInput(HRAWINPUT handle) {
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
        dx = static_cast<INT16>(mouse.lLastX);
        dy = static_cast<INT16>(mouse.lLastY);
    }
    UINT8 buttons = 0;
    INT16 wheel = 0;
    INT16 hwheel = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (mouse.usButtonFlags & RI_MOUSE_LEFT_BUTTON_DOWN) g_buttons |= 1;
        if (mouse.usButtonFlags & RI_MOUSE_LEFT_BUTTON_UP) g_buttons &= ~1;
        if (mouse.usButtonFlags & RI_MOUSE_RIGHT_BUTTON_DOWN) g_buttons |= 2;
        if (mouse.usButtonFlags & RI_MOUSE_RIGHT_BUTTON_UP) g_buttons &= ~2;
        if (mouse.usButtonFlags & RI_MOUSE_MIDDLE_BUTTON_DOWN) g_buttons |= 4;
        if (mouse.usButtonFlags & RI_MOUSE_MIDDLE_BUTTON_UP) g_buttons &= ~4;
        if (mouse.usButtonFlags & RI_MOUSE_BUTTON_4_DOWN) g_buttons |= 8;
        if (mouse.usButtonFlags & RI_MOUSE_BUTTON_4_UP) g_buttons &= ~8;
        if (mouse.usButtonFlags & RI_MOUSE_BUTTON_5_DOWN) g_buttons |= 16;
        if (mouse.usButtonFlags & RI_MOUSE_BUTTON_5_UP) g_buttons &= ~16;
        if (mouse.usButtonFlags & RI_MOUSE_WHEEL) {
            wheel = static_cast<INT16>(mouse.usButtonData);
        }
        if (mouse.usButtonFlags & RI_MOUSE_HWHEEL) {
            hwheel = static_cast<INT16>(mouse.usButtonData);
        }
        buttons = g_buttons;
        if (!ShouldForwardLocked()) return;
    }
    SendEvent(dx, dy, wheel, hwheel, buttons);
}

void ToggleHost() {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        if (!g_winner.enabled) return;
        g_winner.host = g_winner.host == 0 ? 1 : 0;
        PublishLocked();
        UpdateCursorLocked();
    }
    NotifyUI();
}

LRESULT CALLBACK MouseWndProc(HWND window, UINT message, WPARAM wParam,
                              LPARAM lParam) {
    switch (message) {
    case WM_INPUT:
        HandleRawInput(reinterpret_cast<HRAWINPUT>(lParam));
        return 0;
    case WM_HOTKEY:
        if (wParam == kHotkeyId) ToggleHost();
        return 0;
    case kHotkeyCapturedMessage: {
        if (g_keyboardHook) {
            UnhookWindowsHookEx(g_keyboardHook);
            g_keyboardHook = nullptr;
        }
        UINT modifiers = 0;
        UINT vk = 0;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            modifiers = g_hotkeyModifiers;
            vk = g_hotkeyVk;
        }
        UnregisterHotKey(window, kHotkeyId);
        RegisterHotKey(window, kHotkeyId, modifiers | MOD_NOREPEAT, vk);
        NotifyUI();
        return 0;
    }
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
    g_window = window;
    RAWINPUTDEVICE device = {};
    device.usUsagePage = HID_USAGE_PAGE_GENERIC;
    device.usUsage = HID_USAGE_GENERIC_MOUSE;
    device.dwFlags = RIDEV_INPUTSINK;
    device.hwndTarget = window;
    RegisterRawInputDevices(&device, 1, sizeof(device));
    UINT modifiers = 0;
    UINT vk = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        modifiers = g_hotkeyModifiers;
        vk = g_hotkeyVk;
    }
    RegisterHotKey(window, kHotkeyId, modifiers | MOD_NOREPEAT, vk);
    g_mouseHook = SetWindowsHookExW(WH_MOUSE_LL, MouseHook, nullptr, 0);
    NotifyUI();
    MSG message = {};
    while (g_running.load(std::memory_order_acquire) && GetMessageW(&message, nullptr, 0, 0)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    UnregisterHotKey(window, kHotkeyId);
    if (g_mouseHook) {
        UnhookWindowsHookEx(g_mouseHook);
        g_mouseHook = nullptr;
    }
    if (g_keyboardHook) {
        UnhookWindowsHookEx(g_keyboardHook);
        g_keyboardHook = nullptr;
    }
    RestoreSystemCursor();
    if (g_blankCursor) {
        DestroyCursor(g_blankCursor);
        g_blankCursor = nullptr;
    }
    g_window = nullptr;
    DestroyWindow(window);
}

void StopMouseShareLocked() {
    g_running.store(false, std::memory_order_release);
    const SOCKET socketFD = g_socket.exchange(INVALID_SOCKET,
                                              std::memory_order_acq_rel);
    if (socketFD != INVALID_SOCKET) closesocket(socketFD);
    if (g_window) PostMessageW(g_window, WM_DESTROY, 0, 0);
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
    RestoreSystemCursor();
    if (g_udpThread.joinable()) g_udpThread.join();
    if (g_messageThread.joinable()) g_messageThread.join();
    g_udpThread = std::thread(UdpThread);
    g_messageThread = std::thread(MessageThread);
}

void SetMouseSharePeer(const std::string& peerIP) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_peerIP = peerIP;
}

void SetMouseShareEndpoint(const std::string& peerIP, const std::string& localIP) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_peerIP = peerIP;
    g_localIP = localIP;
}

void SetMouseShareEnabled(bool enabled) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        if (g_winner.enabled == enabled) return;
        g_winner.enabled = enabled;
        PublishLocked();
        UpdateCursorLocked();
    }
    NotifyUI();
}

void SetMouseCursorHost(int host) {
    const UINT8 normalized = host == 1 ? 1 : 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureStateLocked();
        if (g_winner.host == normalized) return;
        g_winner.host = normalized;
        PublishLocked();
        UpdateCursorLocked();
    }
    NotifyUI();
}

void BeginMouseHotkeyCapture() {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_capturingHotkey = true;
    }
    if (g_window) UnregisterHotKey(g_window, kHotkeyId);
    if (!g_keyboardHook) {
        g_keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, nullptr, 0);
    }
    NotifyUI();
}

void CancelMouseHotkeyCapture() {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_capturingHotkey = false;
    }
    if (g_keyboardHook) {
        UnhookWindowsHookEx(g_keyboardHook);
        g_keyboardHook = nullptr;
    }
    UINT modifiers = 0;
    UINT vk = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        modifiers = g_hotkeyModifiers;
        vk = g_hotkeyVk;
    }
    if (g_window) RegisterHotKey(g_window, kHotkeyId, modifiers | MOD_NOREPEAT, vk);
    NotifyUI();
}

} // namespace auvol

namespace auvol {

void StopMouseShare() {
    StopMouseShareLocked();
    if (g_udpThread.joinable()) g_udpThread.join();
    if (g_messageThread.joinable()) g_messageThread.join();
    RestoreSystemCursor();
}

} // namespace auvol
