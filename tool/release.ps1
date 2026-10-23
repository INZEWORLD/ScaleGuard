# Publishes a ScaleGuard release to GitHub.
#
#   $env:GITHUB_TOKEN = "<token with repo scope>"
#   tool\release.ps1 -Version 1.1.2
#
# Asset names carry the platform's own version:
#   ScaleGuard-Setup-<version>.exe
#   ScaleGuard-android-<version>.apk
#
# The app updater and the website read those names instead of relying on the
# release tag. That makes a platform-only release safe: Windows can keep
# `ScaleGuard-Setup-1.1.1.exe` while Android gets `ScaleGuard-android-1.1.2.apk`,
# and neither platform is offered the other one's old build.
#
# Android-only example (tag v1.1.2, old Windows installer):
#   tool\release.ps1 -Version 1.1.2 `
#       -SetupPath build\dist\ScaleGuard-Setup-1.1.1.exe `
#       -WindowsVersion 1.1.1
#
# Existing assets with the same names are replaced, which makes the script safe
# to re-run after a rebuild.

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$WindowsVersion = '',
    [string]$AndroidVersion = '',
    [string]$SetupPath = '',
    [string]$ApkPath = '',
    [string]$Repo = 'INZEWORLD/ScaleGuard',
    [string]$Notes = '',
    [string]$Token = $env:GITHUB_TOKEN
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'build\dist'
$tag = "v$Version"

if (-not $WindowsVersion) { $WindowsVersion = $Version }
if (-not $AndroidVersion) { $AndroidVersion = $Version }

$setup = if ($SetupPath) {
    if ([IO.Path]::IsPathRooted($SetupPath)) { $SetupPath } else { Join-Path $root $SetupPath }
} else {
    Join-Path $dist "ScaleGuard-Setup-$WindowsVersion.exe"
}
$apk = if ($ApkPath) {
    if ([IO.Path]::IsPathRooted($ApkPath)) { $ApkPath } else { Join-Path $root $ApkPath }
} else {
    Join-Path $dist 'ScaleGuard-android.apk'
}

$setupAsset = "ScaleGuard-Setup-$WindowsVersion.exe"
$apkAsset = "ScaleGuard-android-$AndroidVersion.apk"

if (-not $Token) { throw 'Set GITHUB_TOKEN or pass -Token.' }
if (-not (Test-Path $setup)) { throw "Missing installer: $setup" }
if (-not (Test-Path $apk)) { throw "Missing APK: $apk" }

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'ScaleGuard-Release'
}

function Invoke-GitHub($method, $uri, $body) {
    $params = @{ Method = $method; Uri = $uri; Headers = $headers }
    if ($null -ne $body) {
        $params.ContentType = 'application/json; charset=utf-8'
        $params.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8))
    }
    return Invoke-RestMethod @params
}

Write-Host "[release] $tag -> $Repo"

$release = $null
try {
    $release = Invoke-GitHub 'GET' "https://api.github.com/repos/$Repo/releases/tags/$tag" $null
    Write-Host "[release] release already exists (id $($release.id))"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
}

if ($null -eq $release) {
    if (-not $Notes) {
        $Notes = "ScaleGuard $Version`n`nАвтоматическая сборка из ветки main."
    }
    $payload = @{
        tag_name         = $tag
        name             = "ScaleGuard $Version"
        body             = $Notes
        draft            = $false
        prerelease       = $false
        generate_release_notes = $true
    }
    $release = Invoke-GitHub 'POST' "https://api.github.com/repos/$Repo/releases" $payload
    Write-Host "[release] created (id $($release.id))"
}

# Replace stale assets with the same versioned names. Stable names from older
# releases are deliberately left alone: they are still a useful fallback for
# anyone holding an old direct link.
$assetNames = @($setupAsset, $apkAsset)
foreach ($asset in @($release.assets)) {
    if ($assetNames -contains $asset.name) {
        try {
            Invoke-GitHub 'DELETE' "https://api.github.com/repos/$Repo/releases/assets/$($asset.id)" $null | Out-Null
            Write-Host "[release] removed old asset $($asset.name)"
        } catch { Write-Warning "could not remove $($asset.name): $_" }
    }
}

function Upload-Asset($path, $name, $label) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $uri = "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets?name=$name&label=$([Uri]::EscapeDataString($label))"
    Write-Host ("[release] uploading {0} ({1:N1} MB)..." -f $name, ($bytes.Length / 1MB))
    $result = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers `
        -ContentType 'application/octet-stream' -Body $bytes -TimeoutSec 900
    Write-Host "[release] done: $($result.browser_download_url)"
}

Upload-Asset $setup $setupAsset 'Windows installer'
Upload-Asset $apk $apkAsset 'Android APK'

$latest = Invoke-GitHub 'GET' "https://api.github.com/repos/$Repo/releases/latest" $null
Write-Host ''
Write-Host "[release] latest is now $($latest.tag_name)"
Write-Host "[release] page: https://github.com/$Repo/releases/tag/$tag"
Write-Host "[release] Windows asset: $setupAsset"
Write-Host "[release] Android asset: $apkAsset"
Write-Host "[release] website resolves both from the latest release automatically."
