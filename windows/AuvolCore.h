#pragma once

#include <functional>
#include <string>

namespace auvol {

struct Settings {
    std::string peerIP;
    int mode = 0;
    bool running = false;
    bool autoFollowEnabled = false;
    std::string followedOutputName;
};

using TextCallback = std::function<void(std::string)>;
using RunningCallback = std::function<void(bool)>;
using ModeCallback = std::function<void(int)>;
using AutoFollowCallback = std::function<void(
    bool enabled,
    std::string followedOutputName,
    std::string currentOutputName,
    bool currentOutputAvailable)>;

void SetCallbacks(TextCallback status,
                  TextCallback stats,
                  RunningCallback running,
                  ModeCallback mode,
                  AutoFollowCallback autoFollow);
Settings LoadSettings();
void SaveSettings(const std::string& peerIP, int mode, bool running);
void RegisterLoginLaunch();
std::string CommandLinePeer(int* mode);
void StartDirectionControl(const std::string& peerIP);
void SetDirectionControlPeer(const std::string& peerIP);
void StartAutoDirectionMonitor();
void SetAutoFollowEnabled(bool enabled);
bool UseCurrentOutputForAutoFollow();

bool Start(const std::string& peerIP, int mode);
void Stop();
void SwitchMode(int mode);
bool IsRunning();
void Shutdown();

using MouseShareCallback = std::function<void(bool enabled,
                                              int cursorHost,
                                              bool capturingHotkey,
                                              std::wstring hotkeyDisplay)>;
void SetMouseShareCallback(MouseShareCallback callback);
void StartMouseShare(const std::string& peerIP);
void SetMouseSharePeer(const std::string& peerIP);
void SetMouseShareEndpoint(const std::string& peerIP, const std::string& localIP);
void SetMouseShareEnabled(bool enabled);
void SetMouseCursorHost(int host);
void BeginMouseHotkeyCapture();
void CancelMouseHotkeyCapture();
void StopMouseShare();

} // namespace auvol
