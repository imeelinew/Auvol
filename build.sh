#!/usr/bin/env bash
# Build both platforms from macOS.
#   Mac:     xcodegen + xcodebuild -> Auvol.app
#   Windows: mingw-w64 cross-compile -> Auvol.exe
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Building Mac Auvol.app ..."
( cd "$ROOT/mac" && xcodegen generate )
( cd "$ROOT/mac" && xcodebuild -project Auvol.xcodeproj -scheme Auvol \
    -configuration Release -derivedDataPath build build 2>&1 | tail -3 )
cp -R "$ROOT/mac/build/Build/Products/Release/Auvol.app" "$ROOT/mac/Auvol.app"
echo "    -> $ROOT/mac/Auvol.app"

echo "==> Building Windows Auvol.exe ..."
( cd "$ROOT/windows" && x86_64-w64-mingw32-windres -i Auvol.rc -o Auvol_rc.o )
x86_64-w64-mingw32-g++ -std=c++17 -O2 \
  -D_WIN32_WINNT=0x0600 -DWIN32_LEAN_AND_MEAN -DUNICODE -D_UNICODE \
  -static -static-libgcc -static-libstdc++ \
  -o "$ROOT/windows/Auvol.exe" "$ROOT/windows/Auvol.cpp" "$ROOT/windows/Auvol_rc.o" \
  -lole32 -lws2_32 -lksuser -lgdi32 -lcomctl32 -luxtheme -mwindows
echo "    -> $ROOT/windows/Auvol.exe"

echo "==> Done."
