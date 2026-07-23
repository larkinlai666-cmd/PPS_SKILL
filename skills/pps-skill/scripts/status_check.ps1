[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Full
)

$ErrorActionPreference = "Stop"
$rootFull = [System.IO.Path]::GetFullPath($Root)
$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host "PPS status: PROJECT_STATE.md not found in $rootFull"
    exit 1
}

$stateText = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)

function Get-StateField([string]$Name) {
    $pattern = '(?m)^-\s+' + [regex]::Escape($Name) + ':\s*(.*?)\s*$'
    $match = [regex]::Match($stateText, $pattern)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return '<missing>'
}

foreach ($name in @('Protocol', 'Profile', 'Stage', 'Main', 'Package', 'Status', 'Blockers', 'Next')) {
    Write-Host "${name}: $(Get-StateField $name)"
}

$contextPath = Join-Path $rootFull 'CONTEXT.md'
if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    $contextLines = [System.IO.File]::ReadAllLines($contextPath, [System.Text.Encoding]::UTF8).Count
    Write-Host "Context-Lines: $contextLines"
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitMarker = Join-Path $rootFull '.git'
    if (Test-Path -LiteralPath $gitMarker) {
        $branch = & git -C $rootFull branch --show-current 2>$null
        $dirty = @(& git -C $rootFull status --porcelain 2>$null).Count
        Write-Host "Git-Branch: $branch"
        Write-Host "Git-Dirty: $dirty"
        if ($Full) {
            & git -C $rootFull status --short
        }
    } else {
        Write-Host "Git: not initialized"
    }
}

if ($Full -and (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    Write-Host ""
    Write-Host "=== CONTEXT.md ==="
    Get-Content -LiteralPath $contextPath -Encoding UTF8
}

$validator = Join-Path $rootFull 'scripts/validate_project.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    Write-Host "PPS validation: validator missing"
    exit 1
}

$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) {
    $engine = Get-Command powershell -ErrorAction Stop
}
& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $validator -Root $rootFull -Quiet
exit $LASTEXITCODE
