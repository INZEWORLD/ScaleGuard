<#
.SYNOPSIS
  Stages the Flutter Windows engine artifacts and the application's asset
  bundle into the project's `windows/flutter/ephemeral` and `build` trees.

.DESCRIPTION
  `flutter build windows` normally orchestrates this through the CMake target
  `flutter_assemble`, which calls `packages/flutter_tools/bin/tool_backend.bat`.
  That path is unavailable on machines where the "C++ CMake tools for Windows"
  component is missing, so this script performs the same staging with the
  artifacts Flutter has already cached in `bin\cache\artifacts\engine`.

  It is idempotent, and `tool\build_windows.bat` runs it automatically.

.PARAMETER Mode
  debug | profile | release. Defaults to debug.
#>
[CmdletBinding()]
param(
  [ValidateSet('debug', 'profile', 'release')]
  [string]$Mode = 'debug'
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterRoot = Split-Path -Parent (Split-Path -Parent (Get-Command flutter).Source)

$engineDir = Join-Path $flutterRoot 'bin\cache\artifacts\engine\windows-x64'
if (-not (Test-Path $engineDir)) {
  throw "Flutter Windows engine artifacts not found at $engineDir. Run 'flutter precache --windows'."
}

$ephemeral = Join-Path $projectRoot 'windows\flutter\ephemeral'
New-Item -ItemType Directory -Force -Path $ephemeral | Out-Null

# --- engine binaries and headers -------------------------------------------
$engineFiles = @(
  'flutter_windows.dll',
  'flutter_windows.dll.lib',
  'flutter_windows.dll.exp',
  'flutter_windows.h',
  'flutter_export.h',
  'flutter_messenger.h',
  'flutter_plugin_registrar.h',
  'flutter_texture_registrar.h',
  'icudtl.dat'
)
foreach ($name in $engineFiles) {
  Copy-Item (Join-Path $engineDir $name) (Join-Path $ephemeral $name) -Force
}
if (-not (Test-Path (Join-Path $ephemeral 'flutter_windows.dll.pdb')) -and
    (Test-Path (Join-Path $engineDir 'flutter_windows.dll.pdb'))) {
  Copy-Item (Join-Path $engineDir 'flutter_windows.dll.pdb') $ephemeral -Force
}

# --- C++ client wrapper (sources + headers) --------------------------------
$wrapperSource = Join-Path $engineDir 'cpp_client_wrapper'
$wrapperTarget = Join-Path $ephemeral 'cpp_client_wrapper'
New-Item -ItemType Directory -Force -Path $wrapperTarget | Out-Null
Copy-Item (Join-Path $wrapperSource '*') $wrapperTarget -Recurse -Force

# --- generated build metadata ----------------------------------------------
# `generated_config.cmake` is written by the flutter tool. When the tool
# refused to run (as on this machine), it is synthesised here instead so the
# CMake build has everything it needs.
$configFile = Join-Path $ephemeral 'generated_config.cmake'
if (-not (Test-Path $configFile)) {
  $flutterVersion = (& flutter --version --machine | ConvertFrom-Json)
  $dartDefines = @(
    'FLUTTER_BUILD_NAME=1.0.0',
    'FLUTTER_BUILD_NUMBER=1',
    "FLUTTER_VERSION=$($flutterVersion.frameworkVersion)",
    "FLUTTER_CHANNEL=$($flutterVersion.channel)",
    "FLUTTER_DART_VERSION=$($flutterVersion.dartSdkVersion)"
  ) | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }

  $lines = @(
    '# Generated code do not commit.',
    "file(TO_CMAKE_PATH ""$flutterRoot"" FLUTTER_ROOT)",
    "file(TO_CMAKE_PATH ""$projectRoot"" PROJECT_DIR)",
    '',
    'set(FLUTTER_VERSION "1.0.0+1" PARENT_SCOPE)',
    'set(FLUTTER_VERSION_MAJOR 1 PARENT_SCOPE)',
    'set(FLUTTER_VERSION_MINOR 0 PARENT_SCOPE)',
    'set(FLUTTER_VERSION_PATCH 0 PARENT_SCOPE)',
    'set(FLUTTER_VERSION_BUILD 1 PARENT_SCOPE)',
    '',
    '# Environment variables to pass to tool_backend.sh',
    'list(APPEND FLUTTER_TOOL_ENVIRONMENT',
    "  ""FLUTTER_ROOT=$flutterRoot""",
    "  ""PROJECT_DIR=$projectRoot""",
    "  ""FLUTTER_EPHEMERAL_DIR=$ephemeral""",
    '  "FLUTTER_TARGET=lib\main.dart"',
    "  ""DART_DEFINES=$($dartDefines -join ',')""",
    '  "DART_OBFUSCATION=false"',
    '  "TRACK_WIDGET_CREATION=true"',
    '  "TREE_SHAKE_ICONS=false"',
    "  ""PACKAGE_CONFIG=$projectRoot\.dart_tool\package_config.json""",
    ')'
  )
  Set-Content -Path $configFile -Value $lines -Encoding UTF8
  Write-Host "[stage] wrote $configFile"
}

# --- flutter_assets ---------------------------------------------------------
# The app bundle is produced by `flutter assemble`; a previously built bundle is
# reused when the tool cannot run, and a build without assets is still valid for
# verifying that the VPN engine itself works.
$assetsTarget = Join-Path $projectRoot 'build\flutter_assets'
if (-not (Test-Path (Join-Path $assetsTarget 'AssetManifest.bin'))) {
  $candidates = @(
    (Join-Path $projectRoot '.widget_preview\build\flutter_assets'),
    (Join-Path $projectRoot 'build\app\intermediates\flutter\debug\flutter_assets')
  ) | Where-Object { Test-Path (Join-Path $_ 'AssetManifest.bin') }
  if ($candidates.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path $assetsTarget | Out-Null
    Copy-Item (Join-Path $candidates[0] '*') $assetsTarget -Recurse -Force
    Write-Host "[stage] copied flutter_assets from $($candidates[0])"
  } else {
    Write-Warning '[stage] no flutter_assets bundle found; the window will open but may render without assets'
  }
}

Write-Host "[stage] ephemeral ready: $ephemeral"
