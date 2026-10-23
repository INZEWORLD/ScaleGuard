# Собирает ScaleGuard-Setup-<версия>.exe: свой установщик на WinForms,
# без Inno. Внутрь вшиваются payload.zip и uninstall.exe.
#
# Запуск: powershell -ExecutionPolicy Bypass -File tool\build_setup.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'installer'
$assets = Join-Path $installer 'assets'
$distNew = Join-Path $root 'build\dist-new'
$build = Join-Path $root 'build\installer'
$out = Join-Path $root 'build\dist'
$version = '1.1.2'
$setupName = "ScaleGuard-Setup-$version.exe"

New-Item -ItemType Directory -Force -Path $build, $out | Out-Null

$runner = Join-Path $root 'build\windows\x64\release\runner'
$runnerExe = Join-Path $runner 'ScaleGuard.exe'
if (-not (Test-Path $runnerExe)) { throw "Сначала соберите приложение: tool\build_windows.bat release" }

# The installer payload is the whole runner bundle, not just the executable:
# flutter_windows.dll, icudtl.dat, the plugin DLLs, the flutter_assets tree and
# the core\ directory all have to travel together. A stale dist-new made an
# installer that launched an old engine next to a new app.so, so the directory
# is rebuilt from the build output on every run.
Write-Host '[setup] синхронизируем ПК-бандл...'
if (Test-Path $distNew) { Remove-Item $distNew -Recurse -Force }
New-Item -ItemType Directory -Force -Path $distNew | Out-Null
Get-ChildItem $runner -Force |
  Where-Object { $_.Name -ne 'CMakeFiles' -and $_.Name -ne 'cmake_install.cmake' } |
  Copy-Item -Destination $distNew -Recurse -Force

Write-Host '[setup] упаковываю payload.zip...'
$zip = Join-Path $build 'payload.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
  $distNew, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Write-Host ("[setup] payload: {0:N1} МБ" -f ((Get-Item $zip).Length / 1MB))

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$refs = @(
  'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll'
) | ForEach-Object { '/r:' + (Join-Path 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319' $_) }

# 1. Маленький uninstall.exe — его кладём в папку установки.
$uninstall = Join-Path $build 'uninstall.exe'
Write-Host '[setup] собираю uninstall.exe...'
& $csc /nologo /target:winexe /codepage:65001 /optimize+ `
  "/win32icon:$assets\icon.ico" "/win32manifest:$installer\app.manifest" `
  "/out:$uninstall" @refs "/resource:$assets\logo-green.png,SgLogo" `
  "$installer\Uninstall.cs" "$installer\Ui.cs"
if ($LASTEXITCODE -ne 0) { throw 'uninstall.exe: ошибка компиляции' }

# 2. Сам установщик.
$setup = Join-Path $out $setupName
Write-Host '[setup] собираю установщик...'
& $csc /nologo /target:winexe /codepage:65001 /optimize+ `
  "/win32icon:$assets\icon.ico" "/win32manifest:$installer\app.manifest" `
  "/out:$setup" @refs `
  "/resource:$zip,ScaleGuardPayload" `
  "/resource:$uninstall,ScaleGuardUninstaller" `
  "/resource:$assets\logo-green.png,SgLogo" `
  "/resource:$assets\back.png,SgBack" `
  "$installer\Setup.cs" "$installer\Ui.cs"
if ($LASTEXITCODE -ne 0) { throw 'setup: ошибка компиляции' }

Write-Host ("[setup] готово: {0} ({1:N1} МБ)" -f $setup, ((Get-Item $setup).Length / 1MB))

