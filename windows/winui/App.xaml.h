#pragma once

#include "App.xaml.g.h"

namespace winrt::Auvol::implementation
{
    struct App : AppT<App>
    {
        App();
        ~App();
        void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

    private:
        Microsoft::UI::Xaml::Window m_window{ nullptr };
        HANDLE m_instanceMutex = nullptr;
    };
}
