#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif

#include "../AuvolCore.h"

#include <cstdio>

using namespace winrt::Microsoft::UI::Xaml;
using namespace winrt::Microsoft::UI::Xaml::Controls;
using namespace winrt::Microsoft::UI::Xaml::Media;

namespace
{
    std::string Metric(std::string const& text, std::string const& label)
    {
        const auto start = text.find(label);
        if (start == std::string::npos) return {};
        const auto valueStart = start + label.size();
        const auto end = text.find("  ", valueStart);
        return text.substr(valueStart, end == std::string::npos
            ? std::string::npos : end - valueStart);
    }

    std::string Trim(std::string value)
    {
        const auto first = value.find_first_not_of(' ');
        if (first == std::string::npos) return {};
        const auto last = value.find_last_not_of(' ');
        return value.substr(first, last - first + 1);
    }

    std::string FirstToken(std::string const& value)
    {
        const auto end = value.find(' ');
        return value.substr(0, end);
    }

    long long ParseCount(std::string const& value)
    {
        if (value.empty()) return 0;
        try {
            return std::stoll(value);
        } catch (...) {
            return 0;
        }
    }

    std::string LocalizedStatus(std::string value)
    {
        struct Translation {
            std::string_view english;
            std::string_view chinese;
        };
        static constexpr Translation translations[] = {
            { "Idle", "选择方向后开始传输" },
            { "Direction control could not initialize Winsock", "无法初始化传输方向控制网络" },
            { "Direction control socket could not be opened", "无法打开传输方向控制套接字" },
            { "Direction control UDP port 7778 is unavailable", "传输方向控制端口 UDP 7778 不可用" },
            { "Switching direction from peer...", "正在根据对端请求切换方向…" },
            { "Cannot open the Windows output device", "无法打开 Windows 输出设备" },
            { "Cannot identify the Windows output device", "无法识别 Windows 输出设备" },
            { "Cannot monitor the Windows output device", "无法监视 Windows 输出设备" },
            { "Cannot observe Windows output changes", "无法监听 Windows 输出设备变化" },
            { "Windows output does not accept 32-bit stereo PCM at the Mac sample rate", "Windows 输出设备不支持 Mac 采样率下的 32 位立体声 PCM" },
            { "Cannot create low-latency output renderer", "无法创建低延迟音频输出" },
            { "Cannot start Windows audio output", "无法启动 Windows 音频输出" },
            { "Windows output changed; reconnecting automatically", "输出设备已变化，正在重新连接…" },
            { "Windows default output changed; reconnecting automatically", "默认输出已变化，正在重新连接…" },
            { "Windows output was invalidated; reconnecting automatically", "输出设备已失效，正在重新连接…" },
            { "Windows output buffer failed; reconnecting automatically", "输出缓冲区错误，正在重新连接…" },
            { "Windows output commit failed; reconnecting automatically", "输出提交失败，正在重新连接…" },
            { "COM initialization failed for output playback", "音频播放的 COM 初始化失败" },
            { "WSAStartup failed", "Windows 网络初始化失败" },
            { "Invalid destination or UDP socket failure", "目标地址无效或 UDP 套接字创建失败" },
            { "COM initialization failed", "COM 初始化失败" },
            { "Audio device enumeration failed", "无法枚举音频设备" },
            { "No default output device", "未找到默认音频输出设备" },
            { "Cannot identify the default output; retrying", "无法识别默认输出设备，正在重试…" },
            { "Cannot monitor the default output; retrying", "无法监视默认输出设备，正在重试…" },
            { "Cannot observe output changes; retrying", "无法监听输出设备变化，正在重试…" },
            { "Audio endpoint activation failed", "音频端点激活失败" },
            { "Cannot read the output mix format", "无法读取输出设备的混音格式" },
            { "Default output must be stereo float32 (use VB-Cable)", "默认输出设备必须使用 32 位浮点立体声格式" },
            { "Low-latency audio client is unavailable", "低延迟音频客户端不可用" },
            { "Cannot set low-latency audio properties", "无法设置低延迟音频属性" },
            { "Cannot query the minimum audio-engine period", "无法查询音频引擎的最小周期" },
            { "Cannot create the period-control event", "无法创建周期控制事件" },
            { "Cannot register the period-control event", "无法注册周期控制事件" },
            { "Cannot create the period-control renderer", "无法创建周期控制输出" },
            { "Cannot prime the period-control renderer", "无法预热周期控制输出" },
            { "Cannot create the audio event", "无法创建音频事件" },
            { "WASAPI event registration failed", "WASAPI 事件注册失败" },
            { "WASAPI capture service failed", "WASAPI 音频采集服务启动失败" },
            { "Period-control renderer failed to start", "周期控制输出启动失败" },
            { "WASAPI start failed", "WASAPI 启动失败" },
            { "Audio event wait failed; retrying automatically", "等待音频事件失败，正在重试…" },
            { "Windows output changed; rebuilding capture automatically", "输出设备已变化，正在重建采集…" },
            { "Audio engine was invalidated; retrying automatically", "音频引擎已失效，正在重试…" },
            { "Audio engine buffer failed; retrying automatically", "音频引擎缓冲区错误，正在重试…" },
            { "Capture device was invalidated; retrying automatically", "采集设备已失效，正在重试…" },
            { "Capture buffer read failed; retrying automatically", "读取采集缓冲区失败，正在重试…" },
            { "Capture release failed; retrying automatically", "释放采集缓冲区失败，正在重试…" },
            { "Default output changed; rebuilding capture automatically", "默认输出已变化，正在重建采集…" },
            { "Audio engine stopped responding; retrying automatically", "音频引擎停止响应，正在重试…" },
            { "UDP port 7777 is unavailable", "UDP 端口 7777 不可用" },
            { "Listening for Mac audio on UDP 7777", "正在等待 Mac 音频" },
            { "Recovering automatically...", "正在自动恢复…" },
            { "Switching direction automatically...", "正在自动切换方向…" },
            { "Selected headphones are on Windows; switching direction...", "指定耳机已成为 Windows 默认输出，正在切换…" },
        };
        for (auto const& translation : translations) {
            if (value == translation.english) {
                return std::string(translation.chinese);
            }
        }
        if (value.rfind("Minimum engine period rejected ", 0) == 0) {
            return "系统拒绝最小音频引擎周期";
        }
        if (value.rfind("WASAPI initialize failed ", 0) == 0) {
            return "WASAPI 初始化失败";
        }
        if (value.find("receiving Mac audio") != std::string::npos) {
            return "正在播放 Mac 音频";
        }
        if (value.find("engine period") != std::string::npos ||
            value.find("->") != std::string::npos) {
            return "正在向 Mac 发送 Windows 音频";
        }
        return value;
    }
}

namespace winrt::Auvol::implementation
{
    MainWindow::MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar(true);
        SetTitleBar(AppTitleBar());
        ConfigureWindow();
        InstallCoreCallbacks();
        Closed({ this, &MainWindow::OnClosed });
        ApplyInitialSettings();
    }

    void MainWindow::ConfigureWindow()
    {
        Window window = *this;
        window.as<IWindowNative>()->get_WindowHandle(&m_hwnd);
        const UINT dpi = GetDpiForWindow(m_hwnd);
        const double scale = static_cast<double>(dpi) / 96.0;
        const int width = static_cast<int>(760 * scale);
        const int height = static_cast<int>(880 * scale);
        SetWindowPos(m_hwnd, nullptr, 0, 0, width, height,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);

        RECT windowRect{};
        GetWindowRect(m_hwnd, &windowRect);
        MONITORINFO monitor{ sizeof(monitor) };
        GetMonitorInfoW(MonitorFromWindow(m_hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
        const int x = monitor.rcWork.left +
            (monitor.rcWork.right - monitor.rcWork.left - width) / 2;
        const int y = monitor.rcWork.top +
            (monitor.rcWork.bottom - monitor.rcWork.top - height) / 2;
        SetWindowPos(m_hwnd, nullptr, x, y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

        const auto smallIcon = LoadImageW(nullptr, L"Assets\\Auvol.ico", IMAGE_ICON,
            GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
            LR_LOADFROMFILE | LR_SHARED);
        const auto largeIcon = LoadImageW(nullptr, L"Assets\\Auvol.ico", IMAGE_ICON,
            GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON),
            LR_LOADFROMFILE | LR_SHARED);
        SendMessageW(m_hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(smallIcon));
        SendMessageW(m_hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(largeIcon));
    }

    void MainWindow::InstallCoreCallbacks()
    {
        const auto dispatcher = DispatcherQueue();
        const auto weak = get_weak();
        auvol::SetCallbacks(
            [dispatcher, weak](std::string text) {
                dispatcher.TryEnqueue([weak, text = std::move(text)] {
                    if (const auto self = weak.get()) self->UpdateStatus(text);
                });
            },
            [dispatcher, weak](std::string text) {
                dispatcher.TryEnqueue([weak, text = std::move(text)] {
                    if (const auto self = weak.get()) self->UpdateStats(text);
                });
            },
            [dispatcher, weak](bool running) {
                dispatcher.TryEnqueue([weak, running] {
                    if (const auto self = weak.get()) self->UpdateRunning(running);
                });
            },
            [dispatcher, weak](int mode) {
                dispatcher.TryEnqueue([weak, mode] {
                    if (const auto self = weak.get()) self->UpdateMode(mode);
                });
            },
            [dispatcher, weak](bool enabled,
                               std::string followedOutputName,
                               std::string currentOutputName,
                               bool currentOutputAvailable) {
                dispatcher.TryEnqueue([
                    weak,
                    enabled,
                    followedOutputName = std::move(followedOutputName),
                    currentOutputName = std::move(currentOutputName),
                    currentOutputAvailable
                ] {
                    if (const auto self = weak.get()) {
                        self->UpdateAutoFollow(
                            enabled,
                            followedOutputName,
                            currentOutputName,
                            currentOutputAvailable
                        );
                    }
                });
            });
    }

    void MainWindow::ApplyInitialSettings()
    {
        auvol::RegisterLoginLaunch();
        const auto settings = auvol::LoadSettings();
        m_mode = settings.mode == 1 ? 1 : 0;
        std::string peer = settings.peerIP;
        int commandMode = m_mode;
        const auto commandPeer = auvol::CommandLinePeer(&commandMode);
        if (!commandPeer.empty()) {
            peer = commandPeer;
            m_mode = commandMode == 1 ? 1 : 0;
        }

        PeerIpTextBox().Text(winrt::to_hstring(peer));
        SendModeButton().IsChecked(m_mode == 0);
        ReceiveModeButton().IsChecked(m_mode == 1);
        m_applyingAutoFollow = true;
        AutoFollowToggle().IsOn(settings.autoFollowEnabled);
        m_applyingAutoFollow = false;
        FollowedOutputText().Text(settings.followedOutputName.empty()
            ? L"未选择"
            : winrt::to_hstring(settings.followedOutputName));
        UseCurrentOutputButton().IsEnabled(false);
        DeviceLabel().Text(m_mode == 0 ? L"采集设备" : L"播放设备");
        DeviceValue().Text(L"—");
        auvol::StartDirectionControl(peer);
        auvol::StartAutoDirectionMonitor();

        if ((!commandPeer.empty() || settings.running) && PeerAddressIsValid()) {
            auvol::Start(PeerAddress(), m_mode);
        }
    }

    void MainWindow::TransportButton_Click(IInspectable const&,
                                            RoutedEventArgs const&)
    {
        if (m_running) {
            auvol::Stop();
            UpdateStatus("Status: Idle");
            ResetStats();
            return;
        }
        if (!PeerAddressIsValid()) {
            TransportInfoBar().Severity(InfoBarSeverity::Warning);
            TransportInfoBar().Title(L"IP 地址无效");
            TransportInfoBar().Message(L"请输入 Mac 的有效 IPv4 地址。");
            return;
        }
        TransportInfoBar().Severity(InfoBarSeverity::Informational);
        TransportInfoBar().Title(L"正在启动");
        TransportInfoBar().Message(L"正在启动音频传输…");
        if (!auvol::Start(PeerAddress(), m_mode)) {
            TransportInfoBar().Severity(InfoBarSeverity::Error);
            TransportInfoBar().Title(L"启动失败");
            TransportInfoBar().Message(L"无法启动音频传输");
        }
    }

    void MainWindow::DirectionButton_Click(IInspectable const& sender,
                                            RoutedEventArgs const&)
    {
        m_mode = sender == ReceiveModeButton() ? 1 : 0;
        SendModeButton().IsChecked(m_mode == 0);
        ReceiveModeButton().IsChecked(m_mode == 1);
        DeviceLabel().Text(m_mode == 0 ? L"采集设备" : L"播放设备");
        ResetStats();
        auvol::SwitchMode(m_mode);
        auvol::SaveSettings(PeerAddress(), m_mode, m_running);
    }

    void MainWindow::PeerIpTextBox_TextChanged(IInspectable const&,
        TextChangedEventArgs const&)
    {
        if (PeerAddressIsValid()) {
            auvol::SetDirectionControlPeer(PeerAddress());
        }
        if (!m_running) {
            TransportButton().IsEnabled(PeerAddressIsValid());
        }
    }

    void MainWindow::AutoFollowToggle_Toggled(IInspectable const&,
                                               RoutedEventArgs const&)
    {
        if (m_applyingAutoFollow) return;
        auvol::SetAutoFollowEnabled(AutoFollowToggle().IsOn());
    }

    void MainWindow::UseCurrentOutputButton_Click(IInspectable const&,
                                                   RoutedEventArgs const&)
    {
        if (!auvol::UseCurrentOutputForAutoFollow()) {
            TransportInfoBar().Severity(InfoBarSeverity::Warning);
            TransportInfoBar().Title(L"没有可用输出");
            TransportInfoBar().Message(L"请先让耳机成为 Windows 默认输出。");
        }
    }

    void MainWindow::UpdateStatus(std::string const& text)
    {
        std::string clean = text;
        if (clean.rfind("Status: ", 0) == 0) clean.erase(0, 8);
        const bool idle = clean == "Idle";
        const bool error = clean.find("Cannot") != std::string::npos ||
                           clean.find("failed") != std::string::npos ||
                           clean.find("unavailable") != std::string::npos;
        const bool recovering = clean.find("retry") != std::string::npos ||
                                clean.find("Recover") != std::string::npos ||
                                clean.find("reconnect") != std::string::npos ||
                                clean.find("Switching") != std::string::npos;
        TransportInfoBar().Severity(idle ? InfoBarSeverity::Informational :
            error ? InfoBarSeverity::Error :
            recovering ? InfoBarSeverity::Warning : InfoBarSeverity::Success);
        TransportInfoBar().Title(idle ? L"已暂停" : error ? L"传输错误" :
            recovering ? L"正在恢复" : L"已连接");
        TransportInfoBar().Message(winrt::to_hstring(LocalizedStatus(clean)));
        ConnectionStateText().Text(idle ? L"空闲" : recovering ? L"正在恢复" :
            error ? L"需要处理" : m_running ? L"运行中" : L"空闲");
    }

    void MainWindow::UpdateStats(std::string const& text)
    {
        const auto signal = Trim(Metric(text, "Signal:"));
        const auto render = Trim(Metric(text, "Render:"));
        const auto errors = Trim(Metric(text, "Errors:"));
        const auto lost = Trim(Metric(text, "Lost:"));
        const bool receiving = !render.empty();

        if (signal.empty()) {
            SignalValue().Text(L"—");
        } else {
            const auto token = FirstToken(signal);
            SignalValue().Text(winrt::to_hstring(
                token == "silent" || token == "Silent" ? "静音" : token));
        }

        DeviceLabel().Text(receiving ? L"播放设备" : L"采集设备");
        DeviceValue().Text(m_deviceName.empty()
            ? L"—"
            : winrt::to_hstring(m_deviceName));

        if (!m_running) {
            QualityValue().Text(L"—");
            return;
        }

        if (receiving) {
            const long long lostCount = ParseCount(lost);
            QualityValue().Text(lostCount > 0
                ? winrt::to_hstring("丢包 " + lost)
                : L"正常");
        } else {
            const long long errorCount = ParseCount(errors);
            QualityValue().Text(errorCount > 0
                ? winrt::to_hstring("错误 " + errors)
                : L"正常");
        }
    }

    void MainWindow::UpdateRunning(bool running)
    {
        m_running = running;
        PeerIpTextBox().IsEnabled(!running);
        TransportButton().Content(winrt::box_value(
            running ? L"停止传输" : L"开始传输"));
        TransportButton().IsEnabled(running || PeerAddressIsValid());
        ConnectionStateText().Text(running ? L"运行中" : L"空闲");
        StateDot().Fill(Application::Current().Resources().Lookup(
            winrt::box_value(running ? L"SystemFillColorSuccessBrush" :
                                      L"TextFillColorTertiaryBrush")).as<Brush>());
        DeviceLabel().Text(m_mode == 0 ? L"采集设备" : L"播放设备");
        if (!running) ResetStats();
    }

    void MainWindow::UpdateMode(int mode)
    {
        m_mode = mode == 1 ? 1 : 0;
        SendModeButton().IsChecked(m_mode == 0);
        ReceiveModeButton().IsChecked(m_mode == 1);
        DeviceLabel().Text(m_mode == 0 ? L"采集设备" : L"播放设备");
        ResetStats();
        auvol::SaveSettings(PeerAddress(), m_mode, m_running);
    }

    void MainWindow::UpdateAutoFollow(bool enabled,
                                      std::string const& followedOutputName,
                                      std::string const& currentOutputName,
                                      bool currentOutputAvailable)
    {
        m_applyingAutoFollow = true;
        AutoFollowToggle().IsOn(enabled);
        m_applyingAutoFollow = false;
        FollowedOutputText().Text(followedOutputName.empty()
            ? L"未选择"
            : winrt::to_hstring(followedOutputName));
        m_deviceName = currentOutputAvailable ? currentOutputName : std::string{};
        DeviceValue().Text(m_deviceName.empty()
            ? L"—"
            : winrt::to_hstring(m_deviceName));
        UseCurrentOutputButton().IsEnabled(currentOutputAvailable);
    }

    void MainWindow::ResetStats()
    {
        SignalValue().Text(L"—");
        QualityValue().Text(L"—");
        DeviceValue().Text(m_deviceName.empty()
            ? L"—"
            : winrt::to_hstring(m_deviceName));
    }

    bool MainWindow::PeerAddressIsValid()
    {
        const auto value = PeerAddress();
        int a = -1, b = -1, c = -1, d = -1;
        char trailing = 0;
        if (sscanf_s(value.c_str(), "%d.%d.%d.%d%c",
                     &a, &b, &c, &d, &trailing, 1) != 4) return false;
        return a >= 0 && a <= 255 && b >= 0 && b <= 255 &&
               c >= 0 && c <= 255 && d >= 0 && d <= 255;
    }

    std::string MainWindow::PeerAddress()
    {
        return winrt::to_string(PeerIpTextBox().Text());
    }

    void MainWindow::OnClosed(IInspectable const&, WindowEventArgs const&)
    {
        auvol::Shutdown();
    }
}
