[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Full,
    [switch]$Fetch
)

$ErrorActionPreference = "Stop"
$fetchFailed = $false
$assetFailed = $false
$rootFull = [System.IO.Path]::GetFullPath($Root)

function Invoke-NativeProbe([scriptblock]$Command) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& $Command)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{
        Code = $exitCode
        Text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    }
}

$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host "PPS status: PROJECT_STATE.md not found in $rootFull"
    exit 1
}

$stateText = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
$hotStateMatch = [regex]::Match(
    $stateText,
    '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)'
)
$hotStateText = if ($hotStateMatch.Success) {
    $hotStateMatch.Groups['body'].Value
} else {
    ''
}

function Get-StateField([string]$Name) {
    $pattern = '(?m)^-\s+' + [regex]::Escape($Name) + ':\s*(.*?)\s*$'
    $match = [regex]::Match($hotStateText, $pattern)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return '<missing>'
}

foreach ($name in @(
    'Protocol', 'Profile', 'Mode', 'Stage', 'Main', 'Map', 'Environment', 'Package', 'Status',
    'Capsule', 'Coverage', 'Blockers', 'Next', 'Updated', 'Device'
)) {
    Write-Host "${name}: $(Get-StateField $name)"
}

$contextPath = Join-Path $rootFull 'CONTEXT.md'
if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    $contextLines = [System.IO.File]::ReadAllLines($contextPath, [System.Text.Encoding]::UTF8).Count
    Write-Host "Context-Lines: $contextLines"
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git) {
    $repositoryProbe = Invoke-NativeProbe {
        & $git.Source -C $rootFull rev-parse --is-inside-work-tree 2>$null
    }
    if ($repositoryProbe.Code -eq 0 -and $repositoryProbe.Text -eq 'true') {
        $branch = ((& $git.Source -C $rootFull branch --show-current 2>$null) | Out-String).Trim()
        $remotes = @(& $git.Source -C $rootFull remote 2>$null)
        if ($remotes.Count -gt 0) {
            Write-Host "Git-Remotes: $($remotes -join ' ')"
            if ($Fetch) {
                & $git.Source -C $rootFull fetch --all --prune
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Git-Fetch: OK"
                } else {
                    Write-Host "Git-Fetch: FAILED"
                    $fetchFailed = $true
                }
            }
        } else {
            Write-Host "Git-Remotes: none"
        }
        $dirty = @(& $git.Source -C $rootFull status --porcelain 2>$null).Count
        Write-Host "Git-Branch: $branch"
        Write-Host "Git-Dirty: $dirty"
        $upstreamProbe = Invoke-NativeProbe {
            & $git.Source -C $rootFull rev-parse --abbrev-ref '@{upstream}' 2>$null
        }
        $upstream = $upstreamProbe.Text
        if ($upstreamProbe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
            $ahead = ((& $git.Source -C $rootFull rev-list --count '@{upstream}..HEAD') | Out-String).Trim()
            $behind = ((& $git.Source -C $rootFull rev-list --count 'HEAD..@{upstream}') | Out-String).Trim()
            Write-Host "Git-Upstream: $upstream"
            Write-Host "Git-Ahead: $ahead"
            Write-Host "Git-Behind: $behind"
        } else {
            Write-Host "Git-Upstream: none"
        }
        if ($Full) {
            & $git.Source -C $rootFull status --short
        }
    } else {
        Write-Host "Git: not initialized"
    }
} else {
    Write-Host "Git: unavailable"
}

if ($Full -and (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    Write-Host ""
    Write-Host "=== CONTEXT.md ==="
    Get-Content -LiteralPath $contextPath -Encoding UTF8
}

$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) {
    $engine = Get-Command powershell -ErrorAction Stop
}
$assetChecker = Join-Path $rootFull 'scripts/asset_check.ps1'
if (Test-Path -LiteralPath $assetChecker -PathType Leaf) {
    Write-Host ''
    Write-Host '=== Asset Readiness (quick) ==='
    & $engine.Source -NoProfile -ExecutionPolicy Bypass -File `
        $assetChecker -Root $rootFull -Quick
    if ($LASTEXITCODE -ne 0) { $assetFailed = $true }
}

$validator = Join-Path $rootFull 'scripts/validate_project.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    Write-Host "PPS validation: validator missing"
    exit 1
}

& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $validator -Root $rootFull -Quiet
$validationStatus = $LASTEXITCODE
if ($validationStatus -ne 0 -or $fetchFailed -or $assetFailed) {
    exit 1
}
exit 0
