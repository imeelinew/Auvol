#!/usr/bin/env bash
# 改完代码后运行：交叉编译 Windows + 编译 Mac + 推到 Windows 桌面 + 重启 Mac 接收端
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINPS="${WINPS:-$HOME/.codex/skills/windows-tailscale-ssh-control/scripts/winps.sh}"
WIN_HOST="${WIN_HOST:-eli}"
SSH_TARGET="${WIN_HOST}"
MAC_APP="$HOME/Library/Developer/Xcode/DerivedData/Auvol-epibiucsegvaxpezapzhtrsaltoh/Build/Products/Debug/Auvol.app"

echo "==> Windows Auvol.exe"
(
  cd "$ROOT/windows"
  x86_64-w64-mingw32-windres -i Auvol.rc -o Auvol_rc.o
  x86_64-w64-mingw32-g++ -std=c++17 -O2 \
    -D_WIN32_WINNT=0x0A00 -DWIN32_LEAN_AND_MEAN -DUNICODE -D_UNICODE \
    -static -static-libgcc -static-libstdc++ \
    -o Auvol.exe Auvol.cpp Auvol_rc.o \
    -lole32 -lws2_32 -lksuser -lgdi32 -lcomctl32 -luxtheme -lavrt -lshell32 -mwindows
)

echo "==> Mac Auvol.app"
xcodegen generate --spec "$ROOT/mac/project.yml" --project "$ROOT/mac"
xcodebuild -project "$ROOT/mac/Auvol.xcodeproj" -scheme Auvol -configuration Debug build >/dev/null

echo "==> Push to Windows Desktop"
"$WINPS" 'Get-Process Auvol -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2' || true
scp -o ConnectTimeout=20 "$ROOT/windows/Auvol.exe" "${SSH_TARGET}:Desktop/Auvol_new.exe"
"$WINPS" 'Move-Item -Force "$env:USERPROFILE\Desktop\Auvol_new.exe" "$env:USERPROFILE\Desktop\Auvol.exe"'

echo "==> Restart Mac receiver"
pkill -x Auvol 2>/dev/null || true
sleep 0.5
open "$MAC_APP"

echo "==> Done. Windows: Desktop\\Auvol.exe — Disconnect 后重新 Connect。"
