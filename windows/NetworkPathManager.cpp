#include "NetworkPathManager.h"

#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <utility>
#include <vector>

namespace {

constexpr UINT32 kDiscoveryMagic = 0x31505541u; // Wire bytes: AUP1.
constexpr UINT8 kDiscoveryRequest = 1;
constexpr UINT8 kDiscoveryResponse = 2;
constexpr UINT16 kDiscoveryPort = 7779;
constexpr size_t kDiscoveryPacketBytes = 32;

struct EthernetCandidate {
    ULONG interfaceIndex = 0;
    IN_ADDR localAddress = {};
    IN_ADDR broadcastAddress = {};
    std::string localIP;
};

struct ProbeResult {
    bool found = false;
    auvol::NetworkPathSelection selection;
};

void Put32(UINT8* destination, UINT32 value) {
    memcpy(destination, &value, sizeof(value));
}

void Put64(UINT8* destination, UINT64 value) {
    memcpy(destination, &value, sizeof(value));
}

UINT32 Get32(const UINT8* source) {
    UINT32 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

UINT64 Get64(const UINT8* source) {
    UINT64 value = 0;
    memcpy(&value, source, sizeof(value));
    return value;
}

UINT64 NewNonce() {
    LARGE_INTEGER counter = {};
    QueryPerformanceCounter(&counter);
    return static_cast<UINT64>(counter.QuadPart) ^
           (static_cast<UINT64>(GetCurrentProcessId()) << 32) ^
           GetTickCount64();
}

std::array<UINT8, kDiscoveryPacketBytes> DiscoveryPacket(
    UINT8 type, UINT64 deviceID, UINT64 nonce) {
    std::array<UINT8, kDiscoveryPacketBytes> packet = {};
    Put32(packet.data(), kDiscoveryMagic);
    packet[4] = type;
    packet[5] = 1;
    Put64(packet.data() + 8, deviceID);
    Put64(packet.data() + 16, nonce);
    return packet;
}

bool ParseDiscoveryPacket(const UINT8* bytes, int length,
                          UINT8* type, UINT64* deviceID, UINT64* nonce) {
    if (!bytes || length != static_cast<int>(kDiscoveryPacketBytes) ||
        Get32(bytes) != kDiscoveryMagic || bytes[5] != 1 ||
        bytes[6] != 0 || bytes[7] != 0 || !type || !deviceID || !nonce) {
        return false;
    }
    if (bytes[4] != kDiscoveryRequest && bytes[4] != kDiscoveryResponse) {
        return false;
    }
    *type = bytes[4];
    *deviceID = Get64(bytes + 8);
    *nonce = Get64(bytes + 16);
    return *deviceID != 0 && *nonce != 0;
}

std::string IPv4String(const IN_ADDR& address) {
    char buffer[INET_ADDRSTRLEN] = {};
    if (!InetNtopA(AF_INET, &address, buffer, sizeof(buffer))) return {};
    return buffer;
}

std::vector<EthernetCandidate> EnumerateEthernetCandidates() {
    ULONG bufferLength = 16 * 1024;
    std::vector<BYTE> buffer(bufferLength);
    auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    ULONG result = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX,
                                        nullptr, adapters, &bufferLength);
    if (result == ERROR_BUFFER_OVERFLOW) {
        buffer.resize(bufferLength);
        adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
        result = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX,
                                      nullptr, adapters, &bufferLength);
    }
    if (result != NO_ERROR) return {};

    std::vector<EthernetCandidate> candidates;
    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
        if (adapter->OperStatus != IfOperStatusUp ||
            adapter->IfType != IF_TYPE_ETHERNET_CSMACD) {
            continue;
        }
        for (auto* unicast = adapter->FirstUnicastAddress;
             unicast; unicast = unicast->Next) {
            if (!unicast->Address.lpSockaddr ||
                unicast->Address.lpSockaddr->sa_family != AF_INET ||
                unicast->OnLinkPrefixLength > 32) {
                continue;
            }
            const auto* address = reinterpret_cast<const sockaddr_in*>(
                unicast->Address.lpSockaddr);
            const UINT32 localHost = ntohl(address->sin_addr.s_addr);
            const UINT32 prefix = unicast->OnLinkPrefixLength;
            const UINT32 mask = prefix == 0 ? 0 : 0xffffffffu << (32 - prefix);
            IN_ADDR broadcast = {};
            broadcast.s_addr = htonl((localHost & mask) | ~mask);
            const std::string localIP = IPv4String(address->sin_addr);
            if (localIP.empty() || localIP == "127.0.0.1") continue;
            candidates.push_back({adapter->IfIndex, address->sin_addr,
                                  broadcast, localIP});
        }
    }
    return candidates;
}

SOCKET OpenListener() {
    const SOCKET socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socketFD == INVALID_SOCKET) return INVALID_SOCKET;

    BOOL exclusive = TRUE;
    setsockopt(socketFD, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
               reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons(kDiscoveryPort);
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(socketFD, reinterpret_cast<const sockaddr*>(&local),
             sizeof(local)) == SOCKET_ERROR) {
        closesocket(socketFD);
        return INVALID_SOCKET;
    }
    u_long nonblocking = 1;
    ioctlsocket(socketFD, FIONBIO, &nonblocking);
    return socketFD;
}

SOCKET OpenProbe(const EthernetCandidate& candidate) {
    const SOCKET socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socketFD == INVALID_SOCKET) return INVALID_SOCKET;

    BOOL broadcast = TRUE;
    setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST,
               reinterpret_cast<const char*>(&broadcast), sizeof(broadcast));
    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = 0;
    local.sin_addr = candidate.localAddress;
    if (bind(socketFD, reinterpret_cast<const sockaddr*>(&local),
             sizeof(local)) == SOCKET_ERROR) {
        closesocket(socketFD);
        return INVALID_SOCKET;
    }
    u_long nonblocking = 1;
    ioctlsocket(socketFD, FIONBIO, &nonblocking);
    return socketFD;
}

void DrainRequests(SOCKET listener, UINT64 deviceID) {
    while (true) {
        std::array<UINT8, kDiscoveryPacketBytes> bytes = {};
        sockaddr_in source = {};
        int sourceLength = sizeof(source);
        const int count = recvfrom(
            listener, reinterpret_cast<char*>(bytes.data()),
            static_cast<int>(bytes.size()), 0,
            reinterpret_cast<sockaddr*>(&source), &sourceLength);
        if (count == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEWOULDBLOCK) return;
            return;
        }
        UINT8 type = 0;
        UINT64 requesterID = 0;
        UINT64 nonce = 0;
        if (!ParseDiscoveryPacket(bytes.data(), count, &type, &requesterID,
                                  &nonce) || type != kDiscoveryRequest ||
            requesterID == deviceID) {
            continue;
        }
        const auto response = DiscoveryPacket(kDiscoveryResponse, deviceID, nonce);
        sendto(listener, reinterpret_cast<const char*>(response.data()),
               static_cast<int>(response.size()), 0,
               reinterpret_cast<const sockaddr*>(&source), sourceLength);
    }
}

ProbeResult ProbeEthernet(SOCKET listener, UINT64 deviceID,
                          const std::vector<EthernetCandidate>& candidates,
                          const std::atomic<bool>& running) {
    std::vector<SOCKET> probes;
    std::vector<EthernetCandidate> probeCandidates;
    const UINT64 nonce = NewNonce() | 1;
    const auto request = DiscoveryPacket(kDiscoveryRequest, deviceID, nonce);

    for (const auto& candidate : candidates) {
        const SOCKET probe = OpenProbe(candidate);
        if (probe == INVALID_SOCKET) continue;
        sockaddr_in destination = {};
        destination.sin_family = AF_INET;
        destination.sin_port = htons(kDiscoveryPort);
        destination.sin_addr = candidate.broadcastAddress;
        if (sendto(probe, reinterpret_cast<const char*>(request.data()),
                   static_cast<int>(request.size()), 0,
                   reinterpret_cast<const sockaddr*>(&destination),
                   sizeof(destination)) == SOCKET_ERROR) {
            closesocket(probe);
            continue;
        }
        probes.push_back(probe);
        probeCandidates.push_back(candidate);
    }

    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(300);
    ProbeResult result;
    while (running.load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < deadline) {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(listener, &readable);
        for (const SOCKET probe : probes) {
            FD_SET(probe, &readable);
        }
        timeval timeout = {0, 50'000};
        const int selected = select(0, &readable, nullptr, nullptr, &timeout);
        if (selected == SOCKET_ERROR) break;
        if (FD_ISSET(listener, &readable)) {
            DrainRequests(listener, deviceID);
        }
        for (size_t index = 0; index < probes.size(); ++index) {
            if (!FD_ISSET(probes[index], &readable)) continue;
            std::array<UINT8, kDiscoveryPacketBytes> bytes = {};
            sockaddr_in source = {};
            int sourceLength = sizeof(source);
            const int count = recvfrom(
                probes[index], reinterpret_cast<char*>(bytes.data()),
                static_cast<int>(bytes.size()), 0,
                reinterpret_cast<sockaddr*>(&source), &sourceLength);
            UINT8 type = 0;
            UINT64 responderID = 0;
            UINT64 responseNonce = 0;
            if (count > 0 && ParseDiscoveryPacket(bytes.data(), count, &type,
                                                  &responderID, &responseNonce) &&
                type == kDiscoveryResponse && responderID != deviceID &&
                responseNonce == nonce) {
                result.found = true;
                result.selection.peerIP = IPv4String(source.sin_addr);
                result.selection.localIP = probeCandidates[index].localIP;
                result.selection.wired = true;
                break;
            }
        }
        if (result.found) break;
    }
    for (const SOCKET probe : probes) closesocket(probe);
    return result;
}

} // namespace

namespace auvol {

NetworkPathManager::~NetworkPathManager() {
    stop();
}

void NetworkPathManager::setCallback(NetworkPathCallback callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_ = std::move(callback);
}

void NetworkPathManager::setFallbackPeerIP(const std::string& peerIP) {
    std::lock_guard<std::mutex> lock(mutex_);
    fallbackPeerIP_ = peerIP;
}

void NetworkPathManager::start(const std::string& fallbackPeerIP) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        fallbackPeerIP_ = fallbackPeerIP;
    }
    if (running_.exchange(true, std::memory_order_acq_rel)) return;
    if (thread_.joinable()) thread_.join();
    thread_ = std::thread(&NetworkPathManager::run, this);
}

void NetworkPathManager::stop() {
    running_.store(false, std::memory_order_release);
    if (thread_.joinable()) thread_.join();
}

void NetworkPathManager::run() {
    WSADATA winsock = {};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        running_.store(false, std::memory_order_release);
        return;
    }

    const SOCKET listener = OpenListener();
    if (listener == INVALID_SOCKET) {
        WSACleanup();
        running_.store(false, std::memory_order_release);
        return;
    }

    UINT64 deviceID = NewNonce() | 1;
    auto publish = [this](NetworkPathSelection selection) {
        NetworkPathCallback callback;
        bool changed = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            changed = !hasActive_ || active_.peerIP != selection.peerIP ||
                      active_.localIP != selection.localIP ||
                      active_.wired != selection.wired;
            if (changed) {
                active_ = selection;
                hasActive_ = true;
                callback = callback_;
            }
        }
        if (changed && callback) callback(std::move(selection));
    };

    std::string fallback;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        fallback = fallbackPeerIP_;
    }
    publish(NetworkPathSelection{fallback, {}, false});

    unsigned failures = 0;
    while (running_.load(std::memory_order_acquire)) {
        const auto candidates = EnumerateEthernetCandidates();
        const auto result = ProbeEthernet(listener, deviceID, candidates, running_);
        if (result.found) {
            failures = 0;
            publish(result.selection);
        } else if (++failures >= 2) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                fallback = fallbackPeerIP_;
            }
            publish(NetworkPathSelection{fallback, {}, false});
        }
        // Keep the listener active in overlapping windows on both peers;
        // the discovery socket is intentionally separate from audio.
        for (int index = 0; index < 2 &&
             running_.load(std::memory_order_acquire); ++index) {
            Sleep(100);
        }
    }

    closesocket(listener);
    WSACleanup();
}

} // namespace auvol
