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
}

namespace winrt::Auvol::implementation
{
    MainWindow::MainWindow()
    {
        InitializeComponent();
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
        const int height = static_cast<int>(800 * scale);
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
            TransportInfoBar().Title(L"Invalid IP address");
            TransportInfoBar().Message(L"Enter a valid IPv4 address for the peer Mac.");
            return;
        }
        TransportInfoBar().Severity(InfoBarSeverity::Informational);
        TransportInfoBar().Title(L"Starting");
        TransportInfoBar().Message(L"Opening the audio engine and network transport…");
        if (!auvol::Start(PeerAddress(), m_mode)) {
            TransportInfoBar().Severity(InfoBarSeverity::Error);
            TransportInfoBar().Title(L"Could not start");
            TransportInfoBar().Message(L"The transport controller could not be started.");
        }
    }

    void MainWindow::DirectionButton_Click(IInspectable const& sender,
                                            RoutedEventArgs const&)
    {
        m_mode = sender == ReceiveModeButton() ? 1 : 0;
        SendModeButton().IsChecked(m_mode == 0);
        ReceiveModeButton().IsChecked(m_mode == 1);
        RateLabel().Text(m_mode == 0 ? L"CAPTURE · FRAMES/S" : L"RENDER · FRAMES/S");
        ResetStats();
        auvol::SwitchMode(m_mode);
        auvol::SaveSettings(PeerAddress(), m_mode, m_running);
    }

    void MainWindow::PeerIpTextBox_TextChanged(IInspectable const&,
        TextChangedEventArgs const&)
    {
        if (!m_running) {
            TransportButton().IsEnabled(PeerAddressIsValid());
        }
    }

    void MainWindow::UpdateStatus(std::string const& text)
    {
        std::string clean = text;
        if (clean.rfind("Status: ", 0) == 0) clean.erase(0, 8);
        const bool error = clean.find("Cannot") != std::string::npos ||
                           clean.find("failed") != std::string::npos ||
                           clean.find("unavailable") != std::string::npos;
        const bool recovering = clean.find("retry") != std::string::npos ||
                                clean.find("Recover") != std::string::npos ||
                                clean.find("reconnect") != std::string::npos ||
                                clean.find("Switching") != std::string::npos;
        TransportInfoBar().Severity(error ? InfoBarSeverity::Error :
            recovering ? InfoBarSeverity::Warning : InfoBarSeverity::Success);
        TransportInfoBar().Title(error ? L"Transport error" :
            recovering ? L"Recovering" : L"Connected");
        TransportInfoBar().Message(winrt::to_hstring(clean));
        ConnectionStateText().Text(recovering ? L"Recovering" :
            error ? L"Attention" : m_running ? L"Running" : L"Idle");
    }

    void MainWindow::UpdateStats(std::string const& text)
    {
        RawStatsText().Text(winrt::to_hstring(text));
        const auto packets = Trim(Metric(text, "Packets:"));
        const auto signal = Trim(Metric(text, "Signal:"));
        const auto capture = Trim(Metric(text, "Capture:"));
        const auto render = Trim(Metric(text, "Render:"));
        const auto errors = Trim(Metric(text, "Errors:"));
        const auto lost = Trim(Metric(text, "Lost:"));
        const auto queue = Trim(Metric(text, "Queue:"));
        PacketsValue().Text(winrt::to_hstring(packets.empty() ? "0" : packets));
        SignalValue().Text(winrt::to_hstring(signal.empty() ? "—" : FirstToken(signal)));
        const bool receiving = !render.empty();
        RateLabel().Text(receiving ? L"RENDER · FRAMES/S" : L"CAPTURE · FRAMES/S");
        RateValue().Text(winrt::to_hstring(FirstToken(receiving ? render : capture)));
        const std::string quality = receiving
            ? "Lost " + (lost.empty() ? std::string("0") : lost) +
              " · " + (queue.empty() ? std::string("—") : queue)
            : "Errors " + (errors.empty() ? std::string("0") : errors);
        QualityValue().Text(winrt::to_hstring(quality));
    }

    void MainWindow::UpdateRunning(bool running)
    {
        m_running = running;
        PeerIpTextBox().IsEnabled(!running);
        TransportButton().Content(winrt::box_value(
            running ? L"Stop transport" : L"Start transport"));
        TransportButton().IsEnabled(running || PeerAddressIsValid());
        ConnectionStateText().Text(running ? L"Running" : L"Idle");
        StateDot().Fill(Application::Current().Resources().Lookup(
            winrt::box_value(running ? L"SystemFillColorSuccessBrush" :
                                      L"TextFillColorTertiaryBrush")).as<Brush>());
        if (!running) ResetStats();
    }

    void MainWindow::ResetStats()
    {
        PacketsValue().Text(L"0");
        SignalValue().Text(L"—");
        RateValue().Text(L"—");
        QualityValue().Text(L"—");
        RawStatsText().Text(L"No transport data yet");
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
