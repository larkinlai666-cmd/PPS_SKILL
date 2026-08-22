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
# A directory proves nothing. The template defaults Main to '.', and a probe
# that passes on the repository root would let a fresh project claim a
# behavioral check it does not have: that is how the wired system dies while
# the gate is green. Refuse it and demand a real entry point.
if ($mainRel -eq '.' -or $mainRel -eq './') {
    Write-Output "e2e probe: Main is '$mainRel' (the repository root) - a directory is not a product entry point."
    Write-Output "Set Hot State 'Main:' to the artifact this product ships (script, binary, entry file),"
    Write-Output 'or replace scripts/e2e_probe.ps1 with a probe that exercises the real user path.'
    exit 1
}
if (Test-Path -LiteralPath (Join-Path $rootFull $mainRel) -PathType Container) {
    Write-Output "e2e probe: Main artifact '$mainRel' is a directory; name the entry file inside it instead."
    Write-Output 'A directory existing proves nothing about the product; the gate must not stamp on that.'
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $rootFull $mainRel) -PathType Leaf)) {
    Write-Output "e2e probe: Main artifact '$mainRel' is not reachable"
    exit 1
}
$mapText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_MAP.md'), [System.Text.Encoding]::UTF8)
if ($mapText -notmatch '(?m)^\|\s*C-') {
    Write-Output 'e2e probe: PROJECT_MAP.md declares no component row'
    exit 1
}
Write-Output "e2e probe: main artifact '$mainRel' reachable and component map populated"
exit 0
