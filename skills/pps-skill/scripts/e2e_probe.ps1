#!/usr/bin/env pwsh
#Requires -Version 5.1
[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

# Minimal behavioral probe. REPLACE the assertion below with the real user
# path: launch the product, call the entry point, or exercise the installed
# copy. The gate requires a behavioral check that names a real artifact, but it
# cannot judge whether the assertion is strong enough - that is the owner's
# duty.

$ErrorActionPreference = 'Stop'
$rootFull = (Resolve-Path -LiteralPath $Root).Path

$stateText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$hotMatch = [regex]::Match($stateText, '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$mainRel = ''
if ($hotMatch.Success) {
    $mainMatch = [regex]::Match($hotMatch.Groups['body'].Value, '(?m)^-\s+Main:\s*(.*?)\s*$')
    if ($mainMatch.Success) { $mainRel = $mainMatch.Groups[1].Value }
}

if ([string]::IsNullOrWhiteSpace($mainRel)) {
    Write-Output 'e2e probe: no Main declared in Hot State'
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $rootFull $mainRel))) {
    Write-Output "e2e probe: Main artifact '$mainRel' is not reachable"
    exit 1
}
$mapText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_MAP.md'), [System.Text.Encoding]::UTF8)
if ($mapText -notmatch '(?m)^\|\s*C-') {
    Write-Output 'e2e probe: PROJECT_MAP.md declares no component row'
    exit 1
}
Write-Output 'e2e probe: main artifact reachable and component map populated'
exit 0
