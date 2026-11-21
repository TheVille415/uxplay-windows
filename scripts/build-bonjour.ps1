<# Prepares the x64 or ARM64 Bonjour SDK required by uxplay-windows.
   Downloads, patches, and builds dnssd.dll and mDNSResponder when needed. #>
[CmdletBinding()]
param(
    [string]$ProjectRoot,

    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",

    # MSVC platform toolset for the mDNSResponder projects, e.g. v143 (VS 2022)
    # or v145 (VS 2026). Detected with vswhere when omitted: v143 is preferred
    # when installed, otherwise the newest installed toolset is used.
    [ValidatePattern("^v\d{3}$")]
    [string]$PlatformToolset,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

$msbuildPlatform = if ($Architecture -eq "arm64") { "ARM64" } else { "x64" }
$sourcePlatformDirectory = if ($Architecture -eq "arm64") { "arm64" } else { "x64" }
$sdk = Join-Path $ProjectRoot "Bonjour SDK"
$required = @(
    (Join-Path $sdk "Include\dns_sd.h"),
    (Join-Path $sdk "Lib\x64\dnssd.lib"),
    (Join-Path $sdk "Bin\$Architecture\dnssd.dll"),
    (Join-Path $sdk "Bin\$Architecture\mDNSResponder.exe"),
    (Join-Path $sdk "build-info.json")
)
if ($Architecture -eq "arm64") {
    $required += (Join-Path $sdk "Lib\arm64\dnssd.lib")
}

$cacheValid = @($required | Where-Object { -not (Test-Path $_) }).Count -eq 0
if ($cacheValid) {
    try {
        $buildInfo = Get-Content `
            -LiteralPath (Join-Path $sdk "build-info.json") `
            -Raw |
            ConvertFrom-Json
        $cacheValid = $buildInfo.architecture -eq $Architecture
    }
    catch {
        $cacheValid = $false
    }
}

if (-not $Force -and $cacheValid) {
    Write-Host "Bonjour SDK $Architecture is already available."
    return
}

$defaultToolset = "v143"

# Each Visual Studio installation's MSBuild only sees the toolsets installed
# into that installation, so pair every toolset with its own MSBuild.exe.
function Get-InstalledToolsets {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        return @()
    }

    $installations = & $vswhere `
        -all `
        -prerelease `
        -products * `
        -requires Microsoft.Component.MSBuild `
        -property installationPath
    $found = @()
    foreach ($installation in $installations) {
        $msbuildPath = Join-Path $installation "MSBuild\Current\Bin\MSBuild.exe"
        if (-not (Test-Path -LiteralPath $msbuildPath)) {
            continue
        }
        $toolsetRoots = Get-ChildItem `
            -Path (Join-Path $installation "MSBuild\Microsoft\VC\v*\Platforms\$msbuildPlatform\PlatformToolsets") `
            -Directory `
            -ErrorAction SilentlyContinue
        foreach ($toolsetRoot in $toolsetRoots) {
            Get-ChildItem -LiteralPath $toolsetRoot.FullName -Directory |
                Where-Object { $_.Name -match "^v\d{3}$" } |
                ForEach-Object {
                    $found += [pscustomobject]@{
                        Toolset = $_.Name
                        Version = [int]$_.Name.Substring(1)
                        MSBuild = $msbuildPath
                    }
                }
        }
    }
    return $found
}

$installedToolsets = @(Get-InstalledToolsets)
$selected = $null
if ($PlatformToolset) {
    $selected = $installedToolsets |
        Where-Object { $_.Toolset -eq $PlatformToolset } |
        Select-Object -First 1
} else {
    $selected = $installedToolsets |
        Where-Object { $_.Toolset -eq $defaultToolset } |
        Select-Object -First 1
    if (-not $selected) {
        $selected = $installedToolsets |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
    }
}

if ($selected) {
    $msbuild = $selected.MSBuild
    $PlatformToolset = $selected.Toolset
} else {
    # No vswhere match: fall back to an MSBuild on PATH (e.g. a Developer
    # PowerShell) and trust the requested or default toolset.
    $msbuildCommand = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    $msbuild = if ($msbuildCommand) { $msbuildCommand.Source } else { $null }
    if (-not $PlatformToolset) {
        $PlatformToolset = $defaultToolset
    }
}

if (-not $msbuild) {
    $installedList = ($installedToolsets | ForEach-Object Toolset | Sort-Object -Unique) -join ", "
    if (-not $installedList) {
        $installedList = "none"
    }
    throw (
        "Bonjour SDK is missing and no MSBuild with the $PlatformToolset " +
        "$msbuildPlatform C++ toolset was found (installed: $installedList). " +
        "Install Visual Studio Build Tools with the C++ workload, or pass " +
        "-PlatformToolset with an installed toolset."
    )
}
Write-Host "Building Bonjour with PlatformToolset $PlatformToolset using $msbuild"

$architectureOutDir = Join-Path $ProjectRoot "out\$Architecture"
$sourceDir = Join-Path $architectureOutDir "bonjour-source"
if (Test-Path -LiteralPath $sourceDir) {
    $resolvedSource = [IO.Path]::GetFullPath($sourceDir)
    $expectedRoot = [IO.Path]::GetFullPath($architectureOutDir)
    if (-not $resolvedSource.StartsWith(
        $expectedRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove unexpected Bonjour source path: $resolvedSource"
    }
    Remove-Item -LiteralPath $resolvedSource -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceDir) |
    Out-Null

& git clone `
    --branch rel/mDNSResponder-2881 `
    --depth 1 `
    --single-branch `
    https://github.com/apple-oss-distributions/mDNSResponder.git `
    $sourceDir
if ($LASTEXITCODE -ne 0) {
    throw "Unable to clone mDNSResponder."
}

& git -C $sourceDir apply `
    (Join-Path $ProjectRoot "mdnsresponder-patches\2881.patch")
if ($LASTEXITCODE -ne 0) {
    throw "Unable to apply the mDNSResponder patch."
}

& $msbuild `
    (Join-Path $sourceDir "mDNSWindows\DLL\dnssd.vcxproj") `
    /m /t:Build /p:Configuration=Release /p:Platform=$msbuildPlatform `
    "/p:PlatformToolset=$PlatformToolset"
if ($LASTEXITCODE -ne 0) {
    throw "dnssd.dll build failed."
}

& $msbuild `
    (Join-Path $sourceDir "mDNSWindows\SystemService\mDNSResponder.vcxproj") `
    /m /t:Build /p:Configuration=Release /p:Platform=$msbuildPlatform `
    "/p:PlatformToolset=$PlatformToolset"
if ($LASTEXITCODE -ne 0) {
    throw "mDNSResponder.exe build failed."
}

New-Item -ItemType Directory -Force -Path (Join-Path $sdk "Include") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $sdk "Lib\x64") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $sdk "Bin\$Architecture") |
    Out-Null
if ($Architecture -eq "arm64") {
    New-Item -ItemType Directory -Force -Path (Join-Path $sdk "Lib\arm64") |
        Out-Null
}

Copy-Item `
    (Join-Path $sourceDir "mDNSShared\dns_sd.h") `
    (Join-Path $sdk "Include\dns_sd.h") `
    -Force
Copy-Item `
    (Join-Path $sourceDir "mDNSWindows\DLL\$sourcePlatformDirectory\Release\dnssd.lib") `
    (Join-Path $sdk "Lib\x64\dnssd.lib") `
    -Force
if ($Architecture -eq "arm64") {
    # libuxplay currently looks under Lib\x64 on Windows. Keep the native
    # location as well as the compatibility alias until it is configurable.
    Copy-Item `
        (Join-Path $sourceDir "mDNSWindows\DLL\$sourcePlatformDirectory\Release\dnssd.lib") `
        (Join-Path $sdk "Lib\arm64\dnssd.lib") `
        -Force
}
Copy-Item `
    (Join-Path $sourceDir "mDNSWindows\DLL\$sourcePlatformDirectory\Release\dnssd.dll") `
    (Join-Path $sdk "Bin\$Architecture\dnssd.dll") `
    -Force
Copy-Item `
    (Join-Path $sourceDir "mDNSWindows\SystemService\$sourcePlatformDirectory\Release\mDNSResponder.exe") `
    (Join-Path $sdk "Bin\$Architecture\mDNSResponder.exe") `
    -Force

$stamp = [ordered]@{
    source = "apple-oss-distributions/mDNSResponder"
    tag = "rel/mDNSResponder-2881"
    architecture = $Architecture
    platformToolset = $PlatformToolset
    patchSha256 = (
        Get-FileHash `
            (Join-Path $ProjectRoot "mdnsresponder-patches\2881.patch") `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}
$stamp | ConvertTo-Json |
    Set-Content (Join-Path $sdk "build-info.json") -Encoding utf8

Write-Host "Bonjour SDK $Architecture built successfully."
