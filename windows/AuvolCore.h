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

void SetCallbacks(TextCallback status,
                  TextCallback stats,
                  RunningCallback running);
Settings LoadSettings();
void SaveSettings(const std::string& peerIP, int mode, bool running);
void RegisterLoginLaunch();
std::string CommandLinePeer(int* mode);

bool Start(const std::string& peerIP, int mode);
void Stop();
void SwitchMode(int mode);
bool IsRunning();
void Shutdown();

} // namespace auvol
