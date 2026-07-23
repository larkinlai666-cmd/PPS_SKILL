[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$rootFull = [System.IO.Path]::GetFullPath($Root)
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) {
    Write-Error "PPS pre-commit: git is unavailable."
    exit 1
}

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

$repositoryProbe = Invoke-NativeProbe {
    & $git.Source -C $rootFull rev-parse --show-toplevel 2>$null
}
$topLevel = $repositoryProbe.Text
if ($repositoryProbe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($topLevel)) {
    Write-Error "PPS pre-commit: not inside a Git repository."
    exit 1
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
$snapshot = Join-Path $tempBase ("pps-pre-commit-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $snapshot | Out-Null
    $prefix = $snapshot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    function Export-StagedPath([string]$RelativePath) {
        if (Test-Path -LiteralPath (Join-Path $snapshot $RelativePath)) {
            return
        }
        $pathProbe = Invoke-NativeProbe {
            & $git.Source -C $topLevel cat-file -e ":$RelativePath" 2>$null
        }
        if ($pathProbe.Code -ne 0) {
            return
        }
        & $git.Source -C $topLevel checkout-index "--prefix=$prefix" -- $RelativePath
        if ($LASTEXITCODE -ne 0) {
            throw "PPS pre-commit: could not materialize staged path: $RelativePath"
        }
    }

    function Export-StagedAnchor([string]$RelativePath) {
        if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq '.') {
            return
        }
        if (Test-Path -LiteralPath (Join-Path $snapshot $RelativePath)) {
            return
        }
        $objectProbe = Invoke-NativeProbe {
            & $git.Source -C $topLevel cat-file -t ":$RelativePath" 2>$null
        }
        $objectType = $objectProbe.Text
        if ($objectProbe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($objectType)) {
            return
        }
        if ($objectType -eq 'tree') {
            New-Item -ItemType Directory -Path (Join-Path $snapshot $RelativePath) -Force | Out-Null
        } else {
            Export-StagedPath $RelativePath
        }
    }

    foreach ($relative in @(
        'README.md',
        'AGENTS.md',
        'PROJECT_STATE.md',
        'DECISIONS.md',
        'CONTEXT.md',
        'PROJECT_MAP.md',
        'ENVIRONMENT.md',
        'ASSETS.md',
        'SOURCE_INDEX.md',
        'docs/CURRENT_REVIEW_EVIDENCE.md',
        'scripts/asset_check.ps1',
        'scripts/asset_check.sh',
        'scripts/status_check.ps1',
        'scripts/status_check.sh',
        'scripts/validate_project.ps1',
        'scripts/validate_project.sh',
        'scripts/environment_doctor.ps1',
        'scripts/environment_doctor.sh',
        'scripts/resume_packet.ps1',
        'scripts/resume_packet.sh'
    )) {
        Export-StagedPath $relative
    }

    $statePath = Join-Path $snapshot 'PROJECT_STATE.md'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $stateText = [System.IO.File]::ReadAllText(
            $statePath,
            [System.Text.Encoding]::UTF8
        )
        $hotStateMatch = [regex]::Match(
            $stateText,
            '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)'
        )
        if ($hotStateMatch.Success) {
            $hotState = $hotStateMatch.Groups['body'].Value
            foreach ($name in @('Main', 'Map', 'Environment', 'Capsule', 'Coverage')) {
                $fieldMatch = [regex]::Match(
                    $hotState,
                    '(?m)^-\s+' + [regex]::Escape($name) + ':\s*(.*?)\s*$'
                )
                if (-not $fieldMatch.Success) { continue }
                $relative = $fieldMatch.Groups[1].Value.Trim()
                if ([string]::IsNullOrWhiteSpace($relative) -or
                    [System.IO.Path]::IsPathRooted($relative) -or
                    $relative.Contains('\') -or
                    $relative -match '(^|/)\.\.(/|$)') {
                    continue
                }
                Export-StagedAnchor $relative
            }
        }
    }

    $contextPath = Join-Path $snapshot 'CONTEXT.md'
    if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
        $contextText = [System.IO.File]::ReadAllText($contextPath, [System.Text.Encoding]::UTF8)
        $worksetMatch = [regex]::Match(
            $contextText,
            '(?ms)^##\s+Workset Manifest\s*\r?\n(?<body>.*?)(?=^##\s+|\z)'
        )
        if ($worksetMatch.Success) {
            $workset = $worksetMatch.Groups['body'].Value
            $readMatch = [regex]::Match($workset, '(?m)^-\s+Read:\s*(.*?)\s*$')
            if ($readMatch.Success -and $readMatch.Groups[1].Value.Trim() -ne 'none') {
                foreach ($relative in @($readMatch.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() })) {
                    if ([string]::IsNullOrWhiteSpace($relative) -or
                        [System.IO.Path]::IsPathRooted($relative) -or
                        $relative.Contains('\') -or
                        $relative -match '(^|/)\.\.(/|$)') {
                        continue
                    }
                    Export-StagedAnchor $relative
                }
            }
            $mapPath = Join-Path $snapshot 'PROJECT_MAP.md'
            if (Test-Path -LiteralPath $mapPath -PathType Leaf) {
                $mapText = [System.IO.File]::ReadAllText($mapPath, [System.Text.Encoding]::UTF8)
                $mapRows = [regex]::Matches(
                    $mapText,
                    '(?m)^\|\s*C-[^|]+\|\s*(?<root>[^|]*?)\s*\|'
                )
                foreach ($row in $mapRows) {
                    $relative = $row.Groups['root'].Value.Trim()
                    if ([string]::IsNullOrWhiteSpace($relative) -or
                        [System.IO.Path]::IsPathRooted($relative) -or
                        $relative.Contains('\') -or
                        $relative -match '(^|/)\.\.(/|$)') {
                        continue
                    }
                    Export-StagedAnchor $relative
                }
            }
        }
    }

    $validator = Join-Path $snapshot 'scripts/validate_project.ps1'
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        Write-Error "PPS pre-commit: staged validator missing at scripts/validate_project.ps1."
        exit 1
    }

    $engine = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -eq $engine) {
        $engine = Get-Command powershell -ErrorAction Stop
    }
    & $engine.Source -NoProfile -ExecutionPolicy Bypass -File $validator -Root $snapshot -Quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Error "PPS pre-commit: staged project validation failed; commit blocked."
        exit 1
    }
} finally {
    $resolvedSnapshot = [System.IO.Path]::GetFullPath($snapshot)
    $tempPrefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedSnapshot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedSnapshot).StartsWith("pps-pre-commit-")) {
        if (Test-Path -LiteralPath $resolvedSnapshot) {
            Remove-Item -LiteralPath $resolvedSnapshot -Recurse -Force
        }
    } else {
        Write-Warning "PPS pre-commit: refusing unexpected cleanup target: $resolvedSnapshot"
    }
}

$staged = @(& $git.Source -C $topLevel diff --cached --name-only)
$contentChanged = @(
    $staged | Where-Object {
        $_ -match '^(docs/|assets/|prototypes/|README\.md$|AGENTS\.md$|DECISIONS\.md$|CONTEXT\.md$|PROJECT_MAP\.md$|ENVIRONMENT\.md$|ASSETS\.md$|SOURCE_INDEX\.md$)'
    }
).Count -gt 0
$stateChanged = $staged -contains 'PROJECT_STATE.md'

if ($contentChanged -and -not $stateChanged) {
    Write-Warning "PPS pre-commit: content changed without PROJECT_STATE.md."
    Write-Warning "Update the current package, next action, and Updated field when this commit closes work."
}

exit 0
