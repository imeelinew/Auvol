#!/usr/bin/env bash
# Build and deploy the WinUI Windows app and native macOS app, then restart both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINPS="${WINPS:-$HOME/.codex/skills/windows-tailscale-ssh-control/scripts/winps.sh}"
WIN_HOST="${WIN_HOST:-eli}"
MAC_APP="$HOME/Library/Developer/Xcode/DerivedData/Auvol-epibiucsegvaxpezapzhtrsaltoh/Build/Products/Debug/Auvol.app"

echo "==> Verify Windows connection"
WIN_HOST="$WIN_HOST" "$WINPS" 'hostname; whoami'

echo "==> Sync Windows sources"
WIN_HOST="$WIN_HOST" "$WINPS" 'New-Item -ItemType Directory -Force "C:\dev\Auvol\windows" | Out-Null'
tar \
  --exclude='Auvol.exe' \
  --exclude='Auvol_rc.o' \
  --exclude='winui/.vs' \
  --exclude='winui/packages' \
  --exclude='winui/Debug' \
  --exclude='winui/Release' \
  --exclude='winui/x64' \
  --exclude='winui/Generated Files' \
  -C "$ROOT/windows" -cf - . | ssh "$WIN_HOST" 'tar -xf - -C C:/dev/Auvol/windows'

echo "==> Build Windows WinUI 3 app"
WIN_HOST="$WIN_HOST" "$WINPS" '
$msbuild = "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe"
$project = "C:\dev\Auvol\windows\winui\Auvol.WinUI.vcxproj"
& $msbuild $project -t:Restore -p:Configuration=Release -p:Platform=x64 -m -v:minimal
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $msbuild $project -t:Build -p:Configuration=Release -p:Platform=x64 -m -v:minimal
exit $LASTEXITCODE
'

echo "==> Install and launch Windows app"
WIN_HOST="$WIN_HOST" "$WINPS" '
$source = "C:\dev\Auvol\windows\winui\x64\Release\Auvol.WinUI"
$destination = Join-Path $env:LOCALAPPDATA "Auvol"
Get-Process Auvol -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
New-Item -ItemType Directory -Force $destination | Out-Null
& robocopy $source $destination /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
$copyExit = $LASTEXITCODE
if ($copyExit -ge 8) { throw "robocopy failed with exit code $copyExit" }

$executable = Join-Path $destination "Auvol.exe"
$ruleName = "Auvol LAN Audio"
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
  -Program $executable -Protocol UDP -LocalPort 7777 -RemoteAddress LocalSubnet `
  -Profile Any | Out-Null

$service = New-Object -ComObject "Schedule.Service"
$service.Connect()
$root = $service.GetFolder("\")
$name = "Auvol"
try { $root.DeleteTask($name, 0) } catch {}
$task = $service.NewTask(0)
$task.RegistrationInfo.Description = "Launch the Auvol WinUI desktop application"
$task.Settings.Enabled = $true
$task.Settings.StartWhenAvailable = $true
$task.Principal.LogonType = 3
$task.Principal.RunLevel = 1
$action = $task.Actions.Create(0)
$action.Path = $executable
$action.WorkingDirectory = $destination
$registered = $root.RegisterTaskDefinition($name, $task, 6, $null, $null, 3)
$registered.Run($null) | Out-Null
$root.DeleteTask($name, 0)
$global:LASTEXITCODE = 0
'

echo "==> Build Mac Auvol.app"
(
  pbx="$ROOT/mac/Auvol.xcodeproj/project.pbxproj"
  scheme="$ROOT/mac/Auvol.xcodeproj/xcshareddata/xcschemes/Auvol.xcscheme"
  pbx_backup="$(mktemp)"
  scheme_backup="$(mktemp)"
  cp "$pbx" "$pbx_backup"
  cp "$scheme" "$scheme_backup"
  restore_xcode_files() {
    cp "$pbx_backup" "$pbx"
    cp "$scheme_backup" "$scheme"
    rm -f "$pbx_backup" "$scheme_backup"
  }
  trap restore_xcode_files EXIT
  xcodegen generate --spec "$ROOT/mac/project.yml" --project "$ROOT/mac"
  xcodebuild -project "$ROOT/mac/Auvol.xcodeproj" -scheme Auvol -configuration Debug build >/dev/null
)

echo "==> Restart Mac app"
pkill -x Auvol 2>/dev/null || true
sleep 0.5
open "$MAC_APP"

echo "==> Done. Windows: %LOCALAPPDATA%\Auvol\Auvol.exe"
