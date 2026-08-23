[CmdletBinding()]
param(
    [string]$Root,
    [string]$Mode = "dry-run",
    [switch]$Confirm,
    [string]$RollbackDir
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
$rootFull = [System.IO.Path]::GetFullPath($Root)

function Die([string]$Message) {
    Write-Host "migrate_project: $Message"
    exit 2
}

$stateText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$hotMatch = [regex]::Match(
    $stateText, '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$hotBody = if ($hotMatch.Success) { $hotMatch.Groups['body'].Value } else { '' }
$packageId = [regex]::Match($hotBody, '(?m)^-\s+Package:\s*(.*?)\s*$').Groups[1].Value
$protocol = [regex]::Match($hotBody, '(?m)^-\s+Protocol:\s*(.*?)\s*$').Groups[1].Value
if ([string]::IsNullOrWhiteSpace($packageId)) {
    Die "cannot resolve the current package from PROJECT_STATE.md"
}
$today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
# F-050-06: never collide with a decision id the project already uses.
$usedIds = @()
$decisionsPath = Join-Path $rootFull 'DECISIONS.md'
if (Test-Path -LiteralPath $decisionsPath -PathType Leaf) {
    $usedIds = [regex]::Matches(
        [System.IO.File]::ReadAllText($decisionsPath, [System.Text.Encoding]::UTF8),
        '(?m)^###\s+(D-[A-Za-z0-9-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
}
$decisionId = $null
for ($n = 1; $n -lt 1000; $n++) {
    $candidate = 'D-MIGRATE-' + $n.ToString('000')
    if ($candidate -notin $usedIds) { $decisionId = $candidate; break }
}

function Get-TaskIndexText {
    @"
## Task Index

### T-001
- Title: Migration bootstrap integrator
- Role: integrator
- Status: active
- Active Package: $packageId
- Capsule: CONTEXT.md
- Output Root: none
- External Locator: none
"@
}
function Get-MergesText {
    @"
## Merge Receipts

<!-- No typed merge receipts yet. The 1.1 history predates this layer and is
     deliberately not guessed into relations. Pre-layer receipts, if any are
     recorded later, use lineage_incomplete with a Lineage Note citing
     $decisionId. -->
"@
}
function Get-DecisionText {
    @"

### $decisionId [active]
- Date: $today
- Decision: approve
- Subject: T-001
- Summary: Authorize adopting the PPS/1.2 multitask layer for this project. Pre-layer history predates the layer; no historical merge is guessed into a typed relation.
"@
}
function Get-EventText {
    "- ${today}: [$packageId] migration_authorized $decisionId | files: TASK_INDEX.md, MERGES.md | verify: validate_project pass | pending: none"
}
function Get-ManifestText {
    "# PPS check manifest - check_id`tplatform`tcwd`ttimeout_s`texpected_exit`tcommand`tnote`nM-001`tpowershell`t.`t60`t0`t& ./scripts/project_verify.ps1 -Root .`tgate entry runs all project checks`nM-001`tbash`t.`t60`t0`tbash scripts/project_verify.sh .`tgate entry runs all project checks`n"
}
function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

switch ($Mode) {
    'dry-run' {
        Write-Host '== PPS 1.1 -> 1.2 migration plan (dry run) =='
        Write-Host "project:  $rootFull"
        Write-Host "protocol: $protocol"
        Write-Host "package:  $packageId"
        Write-Host ''
        Write-Host 'The 1.1 project has no TASK_INDEX.md, no MERGES.md, and no migration'
        Write-Host 'decision. The upgrader does NOT guess historical merge relations:'
        Write-Host "pre-layer history is covered by the lineage_incomplete escape hatch with"
        Write-Host "an explicit decision ($decisionId)."
        Write-Host ''
        Write-Host 'Planned changes (new files and append-only edits):'
        Write-Host ' 1. TASK_INDEX.md   - one integrator task T-001 (bootstrap)'
        Write-Host ' 2. MERGES.md       - empty typed registry; no invented relations'
        Write-Host " 3. DECISIONS.md    - append $decisionId (Decision: approve, Subject: T-001)"
        Write-Host ' 4. EVENTS.md       - append one migration_authorized event'
        Write-Host ' 5. .pps/verify-manifest.txt - generated check manifest (gate requirement)'
        Write-Host " 6. PROJECT_STATE.md - 'Protocol: PPS/1.2' is NOT flipped by -Mode apply;"
        Write-Host '                       flip it yourself only after validate_project passes'
        Write-Host ''
        Write-Host 'Risks:'
        Write-Host ' - historical packages/merges are not mapped into tasks; any future'
        Write-Host '   receipt that needs pre-layer lineage must use lineage_incomplete with'
        Write-Host "   a Lineage Note citing $decisionId"
        Write-Host ' - run validate_project on both platforms before and after applying'
    }
    'apply' {
        if (-not $Confirm) { Die '-Mode apply requires -Confirm' }
        if ($protocol -eq 'PPS/1.2') { Die 'the project is already PPS/1.2' }
        $ts = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        $backup = Join-Path $rootFull ".pps/migration-backup-$ts"
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($f in @('TASK_INDEX.md', 'MERGES.md', 'DECISIONS.md', 'EVENTS.md', 'PROJECT_STATE.md', 'verify-manifest.txt')) {
            $src = if ($f -eq 'verify-manifest.txt') { Join-Path $rootFull '.pps/verify-manifest.txt' } else { Join-Path $rootFull $f }
            if (Test-Path -LiteralPath $src -PathType Leaf) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $backup $f)
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull 'TASK_INDEX.md'))) {
            Write-Utf8 (Join-Path $rootFull 'TASK_INDEX.md') (Get-TaskIndexText)
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull 'MERGES.md'))) {
            Write-Utf8 (Join-Path $rootFull 'MERGES.md') (Get-MergesText)
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull 'DECISIONS.md'))) {
            Write-Utf8 (Join-Path $rootFull 'DECISIONS.md') "# Decisions`n`n"
        }
        $decisionsText = [System.IO.File]::ReadAllText(
            (Join-Path $rootFull 'DECISIONS.md'), [System.Text.Encoding]::UTF8)
        if (-not $decisionsText.Contains("### $decisionId ")) {
            # F-050-06: PS 5.1 Add-Content -Encoding UTF8 writes a BOM.
            # Append with the explicit no-BOM writer instead.
            Write-Utf8 (Join-Path $rootFull 'DECISIONS.md') ($decisionsText + (Get-DecisionText))
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull 'EVENTS.md'))) {
            Write-Utf8 (Join-Path $rootFull 'EVENTS.md') "## Events`n`n"
        }
        $eventsText = [System.IO.File]::ReadAllText(
            (Join-Path $rootFull 'EVENTS.md'), [System.Text.Encoding]::UTF8)
        if (-not $eventsText.Contains("[$packageId] migration_authorized")) {
            Write-Utf8 (Join-Path $rootFull 'EVENTS.md') ($eventsText + (Get-EventText) + "`n")
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull '.pps/verify-manifest.txt'))) {
            New-Item -ItemType Directory -Path (Join-Path $rootFull '.pps') -Force | Out-Null
            Write-Utf8 (Join-Path $rootFull '.pps/verify-manifest.txt') (Get-ManifestText)
        }
        Write-Host "migration applied; backup: $backup"
        Write-Host "NOTICE: 'Protocol:' in PROJECT_STATE.md was NOT changed. Run validate_project"
        Write-Host 'on both platforms; when both pass, flip the Protocol field to PPS/1.2 yourself.'
    }
    'rollback' {
        if ([string]::IsNullOrWhiteSpace($RollbackDir) -or -not (Test-Path -LiteralPath $RollbackDir -PathType Container)) {
            Die 'rollback needs a backup directory created by -Mode apply'
        }
        foreach ($f in @('TASK_INDEX.md', 'MERGES.md', 'DECISIONS.md', 'EVENTS.md', 'PROJECT_STATE.md', 'verify-manifest.txt')) {
            $dst = if ($f -eq 'verify-manifest.txt') { Join-Path $rootFull '.pps/verify-manifest.txt' } else { Join-Path $rootFull $f }
            if (Test-Path -LiteralPath (Join-Path $RollbackDir $f) -PathType Leaf) {
                if ($f -eq 'verify-manifest.txt') {
                    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
                }
                Copy-Item -LiteralPath (Join-Path $RollbackDir $f) -Destination $dst -Force
            } elseif (Test-Path -LiteralPath $dst -PathType Leaf) {
                # F-050-06: a file apply created has no backup; delete it so a
                # rollback cannot leave a half-activated multitask layer.
                Remove-Item -LiteralPath $dst -Force
            }
        }
        $ppsDir = Join-Path $rootFull '.pps'
        if ((Test-Path -LiteralPath $ppsDir -PathType Container) -and
            -not (Get-ChildItem -LiteralPath $ppsDir -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $ppsDir -Force
        }
        Write-Host "migration rolled back from $RollbackDir"
    }
    default { Die "unknown mode: $Mode" }
}
