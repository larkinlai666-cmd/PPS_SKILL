[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Core,
    [switch]$Plan,
    [switch]$Apply,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
if ($Plan -and $Apply) { throw 'Use either -Plan or -Apply, not both.' }
if ($Apply -and -not $Yes) { throw 'System installation requires both -Apply and -Yes.' }
if ($Yes -and -not $Apply) { throw '-Yes is valid only with -Apply.' }
if ($Core -and -not [string]::IsNullOrWhiteSpace($Root)) {
    throw 'Use either -Core or -Root, not both.'
}
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)
$manifest = Join-Path $rootFull 'ENVIRONMENT.md'
$lines = if ($Core) {
    @()
} else {
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Missing environment manifest: $manifest"
    }
    [System.IO.File]::ReadAllLines($manifest, [System.Text.Encoding]::UTF8)
}
function Get-ToolchainField([string]$Name) {
    $inside = $false
    foreach ($line in $lines) {
        if ($line -match '^## Toolchain Manifest\s*$') { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside -and $line.StartsWith("- ${Name}:")) {
            return $line.Substring(("- ${Name}:").Length).Trim()
        }
    }
    return $null
}
function Get-ProjectCommandField([string]$Name) {
    $inside = $false
    foreach ($line in $lines) {
        if ($line -match '^## Project Commands\s*$') { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside -and $line.StartsWith("- ${Name}:")) {
            return $line.Substring(("- ${Name}:").Length).Trim()
        }
    }
    return $null
}

$requiredRaw = if ($Core) { 'git,gh' } else { Get-ToolchainField 'Required' }
$optionalRaw = if ($Core) { 'rg,python,imagemagick,pandoc' } else { Get-ToolchainField 'Optional' }
$dependencyRaw = if ($Core) { 'none' } else { Get-ToolchainField 'Dependency manifests' }
$environmentVerify = if ($Core) { 'none' } else { Get-ProjectCommandField 'Environment verify' }
if ([string]::IsNullOrWhiteSpace($dependencyRaw)) { $dependencyRaw = 'none' }
if ([string]::IsNullOrWhiteSpace($environmentVerify)) { $environmentVerify = 'none' }
$managerPolicy = if ($Core) { 'auto' } else { Get-ToolchainField 'Package manager' }
$installPolicy = if ($Core) { 'project-local-first' } else { Get-ToolchainField 'Install policy' }
if (@($requiredRaw, $optionalRaw, $managerPolicy, $installPolicy) | Where-Object { [string]::IsNullOrWhiteSpace($_) }) {
    throw 'ENVIRONMENT.md has an incomplete Toolchain Manifest.'
}
if ($installPolicy -ne 'project-local-first') {
    throw 'Install policy must be project-local-first.'
}

$allowed = @(
    'git', 'gh', 'rg', 'node', 'python', 'powershell',
    'imagemagick', 'ffmpeg', 'pandoc', 'libreoffice', 'poppler', 'rclone'
)
function ConvertTo-Tools([string]$Raw, [string]$Kind) {
    if ($Raw -eq 'none') { return @() }
    if ($Raw.Trim().StartsWith(',') -or $Raw.Trim().EndsWith(',') -or
        $Raw -match ',\s*,') {
        throw "$Kind tool list contains an empty entry."
    }
    $items = @($Raw.Split(',') | ForEach-Object { $_.Trim() })
    foreach ($tool in $items) {
        if ($tool -notin $allowed) { throw "Unsupported $Kind tool: $tool" }
    }
    $duplicates = @($items | Group-Object | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        throw "Duplicate $Kind tool: $($duplicates[0].Name)"
    }
    return $items
}
function Test-Tool([string]$Tool) {
    switch ($Tool) {
        'python' { return $null -ne (Get-Command python3 -ErrorAction SilentlyContinue) -or $null -ne (Get-Command python -ErrorAction SilentlyContinue) }
        'powershell' { return $null -ne (Get-Command pwsh -ErrorAction SilentlyContinue) -or $null -ne (Get-Command powershell -ErrorAction SilentlyContinue) }
        'imagemagick' { return $null -ne (Get-Command magick -ErrorAction SilentlyContinue) -or $null -ne (Get-Command convert -ErrorAction SilentlyContinue) }
        'libreoffice' {
            return $null -ne (Get-Command libreoffice -ErrorAction SilentlyContinue) -or
                $null -ne (Get-Command soffice -ErrorAction SilentlyContinue) -or
                (Test-Path -LiteralPath '/Applications/LibreOffice.app/Contents/MacOS/soffice' -PathType Leaf)
        }
        'poppler' {
            return $null -ne (Get-Command pdftotext -ErrorAction SilentlyContinue) -and
                $null -ne (Get-Command pdftoppm -ErrorAction SilentlyContinue)
        }
        default { return $null -ne (Get-Command $Tool -ErrorAction SilentlyContinue) }
    }
}
function Resolve-Manager([string]$Policy) {
    $commands = @{
        'brew' = 'brew'
        'winget' = 'winget'
        'apt' = 'apt-get'
        'dnf' = 'dnf'
        'pacman' = 'pacman'
    }
    if ($Policy -eq 'manual') { return 'manual' }
    if ($Policy -in $commands.Keys) {
        if ($null -eq (Get-Command $commands[$Policy] -ErrorAction SilentlyContinue)) {
            throw "Selected package manager '$Policy' is not installed."
        }
        return $Policy
    }
    if ($Policy -ne 'auto') { throw "Unsupported package manager policy: $Policy" }
    foreach ($candidate in @(
        @{ Name = 'brew'; Command = 'brew' },
        @{ Name = 'winget'; Command = 'winget' },
        @{ Name = 'apt'; Command = 'apt-get' },
        @{ Name = 'dnf'; Command = 'dnf' },
        @{ Name = 'pacman'; Command = 'pacman' }
    )) {
        if ($null -ne (Get-Command $candidate.Command -ErrorAction SilentlyContinue)) { return $candidate.Name }
    }
    return 'manual'
}
function Get-Package([string]$Manager, [string]$Tool) {
    $key = "${Manager}:${Tool}"
    $mapped = @{
        'winget:git' = 'Git.Git'
        'winget:gh' = 'GitHub.cli'
        'winget:rg' = 'BurntSushi.ripgrep.MSVC'
        'winget:node' = 'OpenJS.NodeJS.LTS'
        'winget:python' = 'Python.Python.3.12'
        'winget:imagemagick' = 'ImageMagick.ImageMagick'
        'winget:ffmpeg' = 'Gyan.FFmpeg'
        'winget:pandoc' = 'JohnMacFarlane.Pandoc'
        'winget:powershell' = 'Microsoft.PowerShell'
        'winget:libreoffice' = 'TheDocumentFoundation.LibreOffice'
        'winget:rclone' = 'Rclone.Rclone'
        'apt:rg' = 'ripgrep'
        'apt:node' = 'nodejs'
        'apt:python' = 'python3'
        'apt:imagemagick' = 'imagemagick'
        'apt:libreoffice' = 'libreoffice'
        'apt:poppler' = 'poppler-utils'
        'apt:rclone' = 'rclone'
        'dnf:rg' = 'ripgrep'
        'dnf:node' = 'nodejs'
        'dnf:python' = 'python3'
        'dnf:imagemagick' = 'ImageMagick'
        'dnf:libreoffice' = 'libreoffice'
        'dnf:poppler' = 'poppler-utils'
        'dnf:rclone' = 'rclone'
        'pacman:rg' = 'ripgrep'
        'pacman:node' = 'nodejs-lts-iron'
        'pacman:python' = 'python'
        'pacman:imagemagick' = 'imagemagick'
        'pacman:libreoffice' = 'libreoffice-fresh'
        'pacman:poppler' = 'poppler'
        'pacman:rclone' = 'rclone'
        'brew:poppler' = 'poppler'
        'brew:rclone' = 'rclone'
    }
    if ($mapped.ContainsKey($key)) { return $mapped[$key] }
    if ($key -in @(
        'brew:powershell', 'brew:libreoffice',
        'apt:powershell', 'dnf:powershell', 'pacman:powershell'
    ) -or $Manager -eq 'winget') {
        return $null
    }
    return $Tool
}

$required = @(ConvertTo-Tools $requiredRaw 'required')
$optional = @(ConvertTo-Tools $optionalRaw 'optional')
$missingRequired = [System.Collections.Generic.List[string]]::new()
foreach ($tool in $required) {
    if (Test-Tool $tool) { Write-Host "PASS required: $tool" }
    else { Write-Host "MISSING required: $tool"; $missingRequired.Add($tool) }
}
foreach ($tool in $optional) {
    if (Test-Tool $tool) { Write-Host "PASS optional: $tool" }
    else { Write-Host "MISSING optional: $tool" }
}
if ($dependencyRaw -ne 'none') {
    foreach ($relative in @($dependencyRaw.Split(',') | ForEach-Object { $_.Trim() })) {
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [System.IO.Path]::IsPathRooted($relative) -or
            $relative.Contains('\') -or
            $relative -match '(^|/)\.\.(/|$)') {
            throw "Dependency manifest must be an existing safe project-relative file: $relative"
        }
        $path = [System.IO.Path]::GetFullPath((Join-Path $rootFull $relative))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Dependency manifest must be an existing safe project-relative file: $relative"
        }
        Write-Host "PASS dependency manifest: $relative"
    }
}
Write-Host "Declared environment verify: $environmentVerify"
if ($missingRequired.Count -eq 0) {
    Write-Host 'Environment check passed.'
    exit 0
}
if (-not $Plan -and -not $Apply) {
    Write-Error "Environment check failed: $($missingRequired.Count) required tool(s) missing. Run with -Plan to preview explicit installation commands."
    exit 1
}

$manager = Resolve-Manager $managerPolicy
if ($manager -eq 'manual') { throw 'No supported package manager is available; install required tools manually.' }
$packages = [System.Collections.Generic.List[string]]::new()
$manualTools = [System.Collections.Generic.List[string]]::new()
foreach ($tool in $missingRequired) {
    $package = Get-Package $manager $tool
    if ([string]::IsNullOrWhiteSpace($package)) {
        $manualTools.Add($tool)
    } else {
        $packages.Add($package)
    }
}
if ($manualTools.Count -gt 0) {
    throw "No safe automatic package mapping for '$manager': $($manualTools -join ', '). Install those capabilities manually or change the manifest/package-manager policy, then rerun check mode."
}
$packageArray = @($packages)
switch ($manager) {
    'brew' { $command = 'brew'; $arguments = @('install') + $packageArray }
    'winget' { $command = 'winget'; $arguments = @() }
    'apt' { $command = 'apt-get'; $arguments = @('install', '-y') + $packageArray }
    'dnf' { $command = 'dnf'; $arguments = @('install', '-y') + $packageArray }
    'pacman' { $command = 'pacman'; $arguments = @('-S', '--needed', '--noconfirm') + $packageArray }
}
if ($manager -eq 'winget') {
    foreach ($package in $packageArray) {
        Write-Host "Install plan: winget install --id $package --exact --accept-package-agreements --accept-source-agreements"
    }
} else {
    if ($manager -in @('apt', 'dnf', 'pacman') -and
        -not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        $idCommand = Get-Command id -ErrorAction SilentlyContinue
        $isRoot = $null -ne $idCommand -and ((& $idCommand.Source -u) | Out-String).Trim() -eq '0'
        if (-not $isRoot) {
            $sudo = Get-Command sudo -ErrorAction SilentlyContinue
            if ($null -eq $sudo) { throw "Package manager '$manager' requires root privileges or sudo." }
            $arguments = @($command) + $arguments
            $command = $sudo.Source
        }
    }
    Write-Host "Install plan: $command $($arguments -join ' ')"
}
Write-Host 'Optional tools are reported only; they are never auto-installed.'
if ($Plan) { exit 1 }

if ($manager -eq 'winget') {
    foreach ($package in $packageArray) {
        & $command install --id $package --exact `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "Installation command failed with exit code $LASTEXITCODE." }
    }
} else {
    & $command @arguments
    if ($LASTEXITCODE -ne 0) { throw "Installation command failed with exit code $LASTEXITCODE." }
}
Write-Host 'Installation command completed. Rechecking required tools...'
if ($Core) {
    & $PSCommandPath -Core
} else {
    & $PSCommandPath -Root $rootFull
}
exit $LASTEXITCODE
