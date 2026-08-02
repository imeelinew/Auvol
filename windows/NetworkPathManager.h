#pragma once

#include <functional>
#include <atomic>
#include <mutex>
#include <string>
#include <thread>

namespace auvol {

struct NetworkPathSelection {
    std::string peerIP;
    std::string localIP;
    bool wired = false;
};

using NetworkPathCallback = std::function<void(NetworkPathSelection)>;

/// Discovers an Auvol peer on a directly reachable Ethernet segment without
/// changing the ALV2 audio or ALC1 direction-control packets.
class NetworkPathManager final {
public:
    NetworkPathManager() = default;
    ~NetworkPathManager();

    NetworkPathManager(const NetworkPathManager&) = delete;
    NetworkPathManager& operator=(const NetworkPathManager&) = delete;

    void setCallback(NetworkPathCallback callback);
    void start(const std::string& fallbackPeerIP);
    void stop();
    void setFallbackPeerIP(const std::string& peerIP);

private:
    void run();

    std::mutex mutex_;
    NetworkPathCallback callback_;
    std::string fallbackPeerIP_;
    NetworkPathSelection active_;
    bool hasActive_ = false;
    std::atomic<bool> running_{false};
    std::thread thread_;
};

} // namespace auvol
