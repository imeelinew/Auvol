#pragma once

#include "MainWindow.g.h"

namespace winrt::Auvol::implementation
{
    struct MainWindow : MainWindowT<MainWindow>
    {
        MainWindow();

        void TransportButton_Click(IInspectable const&,
                                   Microsoft::UI::Xaml::RoutedEventArgs const&);
        void DirectionButton_Click(IInspectable const& sender,
                                   Microsoft::UI::Xaml::RoutedEventArgs const&);
        void PeerIpTextBox_TextChanged(IInspectable const&,
                                      Microsoft::UI::Xaml::Controls::TextChangedEventArgs const&);

    private:
        HWND m_hwnd = nullptr;
        int m_mode = 0;
        bool m_running = false;

        void ConfigureWindow();
        void InstallCoreCallbacks();
        void ApplyInitialSettings();
        void OnClosed(IInspectable const&, Microsoft::UI::Xaml::WindowEventArgs const&);
        void UpdateStatus(std::string const& text);
        void UpdateStats(std::string const& text);
        void UpdateRunning(bool running);
        void UpdateMode(int mode);
        void ResetStats();
        bool PeerAddressIsValid();
        std::string PeerAddress();
    };
}

namespace winrt::Auvol::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};
}
