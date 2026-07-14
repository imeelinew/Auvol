#pragma once

#include <functional>
#include <string>

namespace auvol {

struct Settings {
    std::string peerIP;
    int mode = 0;
    bool running = false;
};

using TextCallback = std::function<void(std::string)>;
using RunningCallback = std::function<void(bool)>;
using ModeCallback = std::function<void(int)>;

void SetCallbacks(TextCallback status,
                  TextCallback stats,
                  RunningCallback running,
                  ModeCallback mode);
Settings LoadSettings();
void SaveSettings(const std::string& peerIP, int mode, bool running);
void RegisterLoginLaunch();
std::string CommandLinePeer(int* mode);
void StartDirectionControl(const std::string& peerIP);
void SetDirectionControlPeer(const std::string& peerIP);

bool Start(const std::string& peerIP, int mode);
void Stop();
void SwitchMode(int mode);
bool IsRunning();
void Shutdown();

} // namespace auvol
