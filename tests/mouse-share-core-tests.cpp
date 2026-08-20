#include "../windows/MouseShare.cpp"

#include <iostream>

namespace {

bool Check(bool condition, const char* message) {
    if (!condition) std::cerr << message << '\n';
    return condition;
}

} // namespace

int main() {
    bool passed = true;

    g_stateLoaded = true;
    g_winner = {1, 1, true, 0};
    g_eventReady = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    passed &= Check(g_eventReady != nullptr, "failed to create sender event");
    g_peerAlive.store(true, std::memory_order_release);
    g_peerLeaseDeadline.store(GetTickCount64() + 1500,
                              std::memory_order_release);

    passed &= Check(!DesiredCapture(),
                    "Windows-host mode must not install an input hook");
    g_winner.host = 1;
    passed &= Check(DesiredCapture(),
                    "Mac-host mode should capture with a live peer");
    g_peerLeaseDeadline.store(GetTickCount64() - 1,
                              std::memory_order_release);
    passed &= Check(!DesiredCapture(),
                    "an expired peer lease must fail open");

    std::array<UINT8, kEventBytes> packet = {};
    Put32(packet.data(), kMagic);
    packet[4] = kTypeEvent;
    packet[5] = 0x1f;
    Put16(packet.data() + 8, static_cast<UINT16>(-17));
    Put16(packet.data() + 10, 23);
    Put16(packet.data() + 12, 120);
    Put16(packet.data() + 14, static_cast<UINT16>(-120));
    Put32(packet.data() + 16, 1);
    Put64(packet.data() + 20, 0x1122334455667788ull);
    QueuedMouseEvent decoded;
    UINT32 sequence = 0;
    UINT64 session = 0;
    passed &= Check(ParseEvent(packet.data(), static_cast<int>(packet.size()),
                               &decoded, &sequence, &session),
                    "valid event packet was rejected");
    passed &= Check(decoded.dx == -17 && decoded.dy == 23 &&
                        decoded.wheel == 120 && decoded.hwheel == -120 &&
                        decoded.buttons == 0x1f && sequence == 1 &&
                        session == 0x1122334455667788ull,
                    "event packet did not round-trip");
    Put64(packet.data() + 20, 0);
    passed &= Check(!ParseEvent(packet.data(), static_cast<int>(packet.size()),
                                &decoded, &sequence, &session),
                    "zero session ID must be rejected");

    std::vector<INPUT> inputs;
    AddButtonInputs(0, 0x1f, inputs);
    passed &= Check(inputs.size() == 5,
                    "all five mouse buttons must be preserved");

    if (g_eventReady) {
        CloseHandle(g_eventReady);
        g_eventReady = nullptr;
    }
    return passed ? 0 : 1;
}
