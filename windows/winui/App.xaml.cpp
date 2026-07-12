#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

namespace winrt::Auvol::implementation
{
    App::App()
    {
        InitializeComponent();
    }

    App::~App()
    {
        if (m_instanceMutex) {
            ReleaseMutex(m_instanceMutex);
            CloseHandle(m_instanceMutex);
        }
    }

    void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&)
    {
        m_instanceMutex = CreateMutexW(nullptr, TRUE,
            L"Global\\AuvolTransportSingleInstance");
        if (!m_instanceMutex || GetLastError() == ERROR_ALREADY_EXISTS) {
            MessageBoxW(nullptr, L"Auvol is already running.", L"Auvol",
                        MB_OK | MB_ICONINFORMATION);
            ExitProcess(0);
        }
        m_window = winrt::make<MainWindow>();
        m_window.Activate();
    }
}
