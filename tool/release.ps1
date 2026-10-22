# Publishes a ScaleGuard release to GitHub.
#
#   $env:GITHUB_TOKEN = "<token with repo scope>"
#   tool\release.ps1 -Version 1.1.1
#
# The updater in the app reads /releases/latest, so the release must be
# published (not draft) and must contain the two assets it looks for:
#   ScaleGuard-Setup-<version>.exe   (Windows)
#   ScaleGuard-android.apk           (Android)
#
# Existing assets with the same names are replaced, which makes the script safe
# to re-run after a rebuild.

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Repo = 'INZEWORLD/ScaleGuard',
    [string]$Notes = '',
    [string]$Token = $env:GITHUB_TOKEN
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'build\dist'
$tag = "v$Version"
$setup = Join-Path $dist "ScaleGuard-Setup-$Version.exe"
$apk = Join-Path $dist 'ScaleGuard-android.apk'

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

# Replace stale assets with the same names.
foreach ($asset in @($release.assets)) {
    if ($asset.name -eq 'ScaleGuard-android.apk' -or $asset.name -eq "ScaleGuard-Setup-$Version.exe") {
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

Upload-Asset $setup "ScaleGuard-Setup-$Version.exe" 'Windows installer'
Upload-Asset $apk 'ScaleGuard-android.apk' 'Android APK'

$latest = Invoke-GitHub 'GET' "https://api.github.com/repos/$Repo/releases/latest" $null
Write-Host ''
Write-Host "[release] latest is now $($latest.tag_name)"
Write-Host "[release] page: https://github.com/$Repo/releases/tag/$tag"
