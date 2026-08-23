[CmdletBinding()]
param(
    [string]$Root,
    [string]$Mode = "dry-run",
    [switch]$Confirm,
    [switch]$WithMultitask,
    [string]$RollbackDir
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
$rootFull = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw "migrate_project: project root is not a directory: $rootFull"
}

function Die([string]$Message) {
    Write-Host "migrate_project: $Message"
    exit 2
}

$scriptDir = $PSScriptRoot
$skillRoot = Split-Path $scriptDir -Parent
$schemaSrc = Join-Path $skillRoot 'references/state-machine.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    if ($Mode -ne 'rollback') { Die "cannot resolve the current state: PROJECT_STATE.md is missing" }
}
$stateText = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
} else {
    ''
}
$hotMatch = [regex]::Match(
    $stateText, '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$hotBody = if ($hotMatch.Success) { $hotMatch.Groups['body'].Value } else { '' }
$protocol = [regex]::Match($hotBody, '(?m)^-\s+Protocol:\s*(.*?)\s*$').Groups[1].Value.Trim()
$packageId = [regex]::Match($hotBody, '(?m)^-\s+Package:\s*(.*?)\s*$').Groups[1].Value.Trim()
$coverageRel = [regex]::Match($hotBody, '(?m)^-\s+Coverage:\s*(.*?)\s*$').Groups[1].Value.Trim()

# The protocol contract gates the upgrade modes; a rollback must stay
# available even when the project state is half-migrated.
if ($Mode -ne 'rollback') {
    if ([string]::IsNullOrWhiteSpace($packageId)) {
        Die "cannot resolve the current package from PROJECT_STATE.md"
    }
    if ([string]::IsNullOrWhiteSpace($protocol)) {
        Die "cannot resolve the current protocol from PROJECT_STATE.md"
    }
    if ($protocol -eq 'PPS/1.2') { Die "the project already declares PPS/1.2" }
    if ($protocol -notin @('PPS/1.0', 'PPS/1.1')) {
        Die "unsupported source protocol: $protocol"
    }
}

$today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')

function Get-FileSha([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Get-DecisionId([string]$RootPath) {
    $decisionsPath = Join-Path $RootPath 'DECISIONS.md'
    $usedIds = @()
    if (Test-Path -LiteralPath $decisionsPath -PathType Leaf) {
        $usedIds = [regex]::Matches(
            [System.IO.File]::ReadAllText($decisionsPath, [System.Text.Encoding]::UTF8),
            '(?m)^###\s+(D-[A-Za-z0-9-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    }
    for ($n = 1; $n -lt 1000; $n++) {
        $candidate = 'D-MIGRATE-' + $n.ToString('000')
        if ($candidate -notin $usedIds) { return $candidate }
    }
    Die 'no free D-MIGRATE decision id available'
}

$decisionId = if ($Mode -ne 'rollback') { Get-DecisionId $rootFull } else { 'D-MIGRATE-000' }

function Get-DecisionText {
    @"

### $decisionId [active]
- Date: $today
- Decision: approve
- Subject: PPS/1.2 core migration
- Summary: Authorize upgrading this project from $protocol to PPS/1.2. Pre-layer history predates the typed layers; no historical merge is guessed into a relation.
"@
}

function Get-EventText {
    "- $today`: [$packageId] migration_authorized $decisionId | files: scripts/, AGENTS.md, CONTEXT.md, DECISIONS.md, EVENTS.md, .pps/verify-manifest.txt | verify: validate_project pass | pending: review migrated coverage evidence"
}

function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Show-DryRun {
    Write-Host "== PPS $protocol -> 1.2 migration plan (dry run) =="
    Write-Host "project:  $rootFull"
    Write-Host "package:  $packageId"
    Write-Host ''
    Write-Host 'Core upgrade (always):'
    Write-Host ' 1. Refresh scripts/ with the 1.2 gate, validator, and evidence engine'
    Write-Host ' 2. Ensure .pps/verify-manifest.txt exists'
    Write-Host ' 3. Ensure AGENTS.md opens with a Red Lines section'
    Write-Host " 4. Upgrade bare 'Present' coverage cells to explicit evidence"
    Write-Host " 5. Add '(opened DATE)' to proposals that lack it"
    Write-Host " 6. Append $decisionId to DECISIONS.md AND the active authority block"
    Write-Host ' 7. Create EVENTS.md if missing and record migration_authorized'
    Write-Host " 8. Flip Hot State 'Protocol:' to PPS/1.2"
    Write-Host ' 9. Run validate_project on both available engines, then the verify'
    Write-Host '    gate on this platform; any failure rolls back automatically'
    if ($WithMultitask) {
        Write-Host ''
        Write-Host 'Multitask opt-in (-WithMultitask):'
        Write-Host ' A. Create TASK_INDEX.md with one integrator bootstrap task'
        Write-Host ' B. Create MERGES.md'
        Write-Host " C. Add 'Writer: T-001' to Hot State"
    } else {
        Write-Host ''
        Write-Host 'Multitask layer: NOT enabled. A single-task project stays single-task;'
        Write-Host 'run again with -WithMultitask only when several long tasks coexist.'
    }
}

function Invoke-Rollback([string]$BackupDir) {
    $backupFull = [System.IO.Path]::GetFullPath($BackupDir)
    if (-not (Test-Path -LiteralPath $backupFull -PathType Container)) {
        Die 'rollback needs a backup directory created by -Mode apply'
    }
    $manifestPath = Join-Path $backupFull 'files.sha256'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Die "backup $backupFull has no hash manifest"
    }
    # Restore every pre-apply file; delete files apply created.
    $backupFiles = Get-ChildItem -LiteralPath $backupFull -File -Recurse | Where-Object {
        $_.Name -notin @('files.sha256', 'validate-bash.log', 'validate-ps.log', 'gate.log', 'preapply.files', 'restored.files', 'pps.preapply')
    }
    $preapply = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($bf in $backupFiles) {
        $rel = $bf.FullName.Substring($backupFull.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $dst = Join-Path $rootFull $rel
        $null = New-Item -ItemType Directory -Path (Split-Path $dst) -Force
        Copy-Item -LiteralPath $bf.FullName -Destination $dst -Force
        $null = $preapply.Add($rel)
    }
    $currentFiles = Get-ChildItem -LiteralPath $rootFull -File -Recurse | Where-Object {
        -not $_.FullName.StartsWith((Join-Path $rootFull '.git'), [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $_.FullName.StartsWith((Join-Path $rootFull '.pps'), [System.StringComparison]::OrdinalIgnoreCase)
    }
    foreach ($cf in $currentFiles) {
        $rel = $cf.FullName.Substring($rootFull.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if (-not $preapply.Contains($rel)) {
            Remove-Item -LiteralPath $cf.FullName -Force
        }
    }
    # Byte identity: every restored file must match the pre-apply hash.
    $mismatch = $false
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath, [System.Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $want = $line.Substring(0, 64)
        $rel = $line.Substring(66)
        $checkPath = Join-Path $rootFull $rel
        if (-not (Test-Path -LiteralPath $checkPath -PathType Leaf)) {
            Write-Host "migrate_project: rollback mismatch: $rel is missing"
            $mismatch = $true
            continue
        }
        if ((Get-FileSha $checkPath) -ne $want) {
            Write-Host "migrate_project: rollback mismatch: $rel hash differs"
            $mismatch = $true
        }
    }
    if ($mismatch) {
        Write-Host "migrate_project: rollback FAILED to restore byte identity; inspect $rootFull against $backupFull"
        exit 1
    }
    # Remove .pps state the migration's own runs created.
    $ppsPreapplyPath = Join-Path $backupFull 'pps.preapply'
    if (Test-Path -LiteralPath $ppsPreapplyPath -PathType Leaf) {
        $ppsPreapply = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal)
        foreach ($rel in [System.IO.File]::ReadAllLines($ppsPreapplyPath, [System.Text.Encoding]::UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($rel)) { $null = $ppsPreapply.Add($rel) }
        }
        $ppsDir = Join-Path $rootFull '.pps'
        if (Test-Path -LiteralPath $ppsDir -PathType Container) {
            foreach ($pf in @(Get-ChildItem -LiteralPath $ppsDir -File -Recurse)) {
                if ($pf.FullName -like '*migration-backup-*') { continue }
                $rel = $pf.FullName.Substring($rootFull.Length).TrimStart(
                    [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                if (-not $ppsPreapply.Contains($rel)) {
                    Remove-Item -LiteralPath $pf.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Write-Host "migration rolled back from $backupFull (file set and hashes verified)"
}

function Invoke-Apply {
    if (-not $Confirm) { Die '-Mode apply requires -Confirm' }
    $ts = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $backup = Join-Path $rootFull ".pps/migration-backup-$ts"
    $null = New-Item -ItemType Directory -Path $backup -Force
    $backupLog = Join-Path $backup 'gate.log'

    # Backup with hash manifest + pre-existing .pps set.
    $manifestLines = [System.Collections.Generic.List[string]]::new()
    $preapplyFiles = Get-ChildItem -LiteralPath $rootFull -File -Recurse | Where-Object {
        -not $_.FullName.StartsWith((Join-Path $rootFull '.git'), [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $_.FullName.StartsWith((Join-Path $rootFull '.pps'), [System.StringComparison]::OrdinalIgnoreCase)
    }
    foreach ($pf in $preapplyFiles) {
        $rel = $pf.FullName.Substring($rootFull.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $dst = Join-Path $backup $rel
        $null = New-Item -ItemType Directory -Path (Split-Path $dst) -Force
        Copy-Item -LiteralPath $pf.FullName -Destination $dst
        $manifestLines.Add((Get-FileSha $pf.FullName) + '  ' + $rel)
    }
    Write-Utf8 (Join-Path $backup 'files.sha256') ([string]::Join("`n", $manifestLines) + "`n")
    $ppsDir = Join-Path $rootFull '.pps'
    $ppsPreapply = @()
    if (Test-Path -LiteralPath $ppsDir -PathType Container) {
        $ppsPreapply = @(Get-ChildItem -LiteralPath $ppsDir -File -Recurse | Where-Object {
            -not $_.FullName -like '*migration-backup-*'
        } | ForEach-Object {
            $_.FullName.Substring($rootFull.Length).TrimStart(
                [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        })
    }
    Write-Utf8 (Join-Path $backup 'pps.preapply') ([string]::Join("`n", $ppsPreapply) + "`n")
    Write-Host "migration backup: $backup"

    # ---- 1. Refresh the 1.2 scripts -----------------------------------------
    foreach ($scriptName in @(
        'status_check.ps1', 'status_check.sh',
        'validate_project.ps1', 'validate_project.sh',
        'environment_doctor.ps1', 'environment_doctor.sh',
        'resume_packet.ps1', 'resume_packet.sh',
        'asset_check.ps1', 'asset_check.sh',
        'readiness_check.ps1', 'readiness_check.sh',
        'verify_gate.ps1', 'verify_gate.sh',
        'project_verify.ps1', 'project_verify.sh',
        'append_event.ps1', 'append_event.sh',
        'boundary_check.ps1', 'boundary_check.sh',
        'session_begin.ps1', 'session_begin.sh',
        'migrate_project.ps1', 'migrate_project.sh',
        'e2e_probe.ps1', 'e2e_probe.sh',
        'pre-commit', 'pre-commit.ps1'
    )) {
        $src = Join-Path $scriptDir $scriptName
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $rootFull "scripts/$scriptName") -Force
        }
    }
    $pySrc = Join-Path $scriptDir 'pps_evidence.py'
    if (Test-Path -LiteralPath $pySrc -PathType Leaf) {
        Copy-Item -LiteralPath $pySrc -Destination (Join-Path $rootFull 'scripts/pps_evidence.py') -Force
    }
    if (Test-Path -LiteralPath $schemaSrc -PathType Leaf) {
        Copy-Item -LiteralPath $schemaSrc -Destination (Join-Path $rootFull 'scripts/state-machine.json') -Force
    }

    # ---- 2. Check manifest ---------------------------------------------------
    $manifestPath = Join-Path $rootFull '.pps/verify-manifest.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $null = New-Item -ItemType Directory -Path $ppsDir -Force
        $manifestText = "# PPS check manifest - check_id`tplatform`tcwd`ttimeout_s`texpected_exit`tcommand`tnote`nM-001`tpowershell`t.`t60`t0`t& ./scripts/project_verify.ps1 -Root .`tgate entry runs all project checks`nM-001`tbash`t.`t60`t0`tbash scripts/project_verify.sh .`tgate entry runs all project checks`n"
        Write-Utf8 $manifestPath $manifestText
    }

    # ---- 2b. .gitignore ------------------------------------------------------
    $gitignorePath = Join-Path $rootFull '.gitignore'
    if (-not (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
        Write-Utf8 $gitignorePath ".pps/`nlocal-task-output/`n"
    } else {
        $giText = [System.IO.File]::ReadAllText($gitignorePath, [System.Text.Encoding]::UTF8)
        if ($giText -notmatch '(?m)^\.pps/$') { $giText += "`n.pps/`n" }
        if ($giText -notmatch '(?m)^local-task-output/$') { $giText += "local-task-output/`n" }
        Write-Utf8 $gitignorePath $giText
    }

    # ---- 3. Red Lines section ------------------------------------------------
    $agentsPath = Join-Path $rootFull 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
        Write-Utf8 $agentsPath "# AGENTS.md`n`n## Red Lines`n`n- 暂无项目红线。第一次事故复盘后在此追加，勿删除本节。`n"
    } else {
        $agentsText = [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8)
        if ($agentsText -notmatch '(?m)^##\s+Red Lines\s*$') {
            $insert = "`n## Red Lines`n`n- 暂无项目红线。第一次事故复盘后在此追加，勿删除本节。`n"
            $h1 = [regex]::Match($agentsText, '(?m)^#\s+.*$')
            if ($h1.Success) {
                $agentsText = $agentsText.Substring(0, $h1.Index + $h1.Length) + $insert + $agentsText.Substring($h1.Index + $h1.Length)
            } else {
                $agentsText = $insert + $agentsText
            }
            Write-Utf8 $agentsPath $agentsText
        }
    }

    # ---- 4/5. Coverage evidence + proposal dates + Verify routing ------------
    $contextPath = Join-Path $rootFull 'CONTEXT.md'
    $coveragePath = if (-not [string]::IsNullOrWhiteSpace($coverageRel)) {
        Join-Path $rootFull $coverageRel
    } else {
        ''
    }
    $bareIds = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($coveragePath) -and
        (Test-Path -LiteralPath $coveragePath -PathType Leaf)) {
        $covLines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in [System.IO.File]::ReadAllLines($coveragePath, [System.Text.Encoding]::UTF8)) {
            if ($line -match '^\|' ) {
                $cells = $line.Split('|')
                if ($cells.Count -ge 5) {
                    $evidenceCell = $cells[$cells.Count - 2].Trim()
                    if ($evidenceCell -eq 'Present' -or $evidenceCell -eq 'present') {
                        $idCell = $cells[1].Trim()
                        $null = $bareIds.Add($idCell)
                        $replacement = if ($idCell -eq 'M-001') {
                            ' verify_gate: structural validation checks manifest IDs '
                        } elseif ($idCell -eq 'M-002') {
                            ' verify_gate: close requires gate pass and verify stamp '
                        } else {
                            " manual: migrated from $protocol; bind a real check "
                        }
                        $cells[$cells.Count - 2] = $replacement
                        $line = [string]::Join('|', $cells)
                    }
                }
            }
            $covLines.Add($line)
        }
        if ($bareIds.Count -gt 0) {
            Write-Utf8 $coveragePath ([string]::Join("`n", $covLines) + "`n")
        }
        # The migration decision gains a coverage row once it enters the
        # Workset Manifest Decisions below.
        $covText = [System.IO.File]::ReadAllText($coveragePath, [System.Text.Encoding]::UTF8)
        if ($covText -notmatch ('(?m)^\|\s*' + [regex]::Escape($decisionId) + '\s*\|')) {
            $covText = $covText.TrimEnd() + "`n| $decisionId | Migration authorization | ``DECISIONS.md`` / Active Authority Index | verify_gate: structural validation checks manifest IDs |`n"
            Write-Utf8 $coveragePath $covText
        }
    }
    $manualIds = @($bareIds | Where-Object { $_ -notin @('M-001', 'M-002') } | Sort-Object -Unique)
    if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
        $contextText = [System.IO.File]::ReadAllText($contextPath, [System.Text.Encoding]::UTF8)
        # Verify declaration must route through the gate entry.
        if ($contextText -notmatch '(?m)^-\s+Verify:.*verify_gate') {
            $contextText = [regex]::Replace(
                $contextText,
                '(?m)^-\s+Verify:.*$',
                '- Verify: Run scripts/verify_gate.* (structural validation plus declared project checks); extend the gate with stack-specific checks after bootstrap.',
                1)
        }
        # Proposals without an opened date.
        $contextText = [regex]::Replace(
            $contextText,
            '(?m)^(- P-[A-Za-z0-9_-]+:)(?![\s\S]*\(opened \d{4}-\d{2}-\d{2}\))(.*)$',
            { param($m) $m.Groups[1].Value + ' (opened ' + $today + '):' + $m.Groups[2].Value })
        # The new active decision joins the Workset Manifest Decisions.
        $contextText = [regex]::Replace(
            $contextText,
            '(?m)^-\s+Decisions:\s*none\s*$',
            '- Decisions: ' + $decisionId,
            1)
        Write-Utf8 $contextPath $contextText
    }
    # Manual evidence must stay openly pending in Hot State Next.
    if ($manualIds.Count -gt 0) {
        $stateText = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
        $stateText = [regex]::Replace(
            $stateText,
            '(?m)^(\s*-\s+Next:.*)$',
            { param($m) $m.Groups[1].Value + ' Coverage evidence review: ' + [string]::Join(' ', $manualIds) },
            1)
        Write-Utf8 $statePath $stateText
    }

    # ---- 6. Decision record + active block + event ---------------------------
    $decisionsPath = Join-Path $rootFull 'DECISIONS.md'
    if (-not (Test-Path -LiteralPath $decisionsPath -PathType Leaf)) {
        Write-Utf8 $decisionsPath "# Authority and Decisions`n`n## Active Authority Index`n`n<!-- PPS:ACTIVE:BEGIN -->`n<!-- PPS:ACTIVE:END -->`n`n## Authority Records`n`n## Status Events`n`n## Next ID Hints`n"
    }
    $decisionsText = [System.IO.File]::ReadAllText($decisionsPath, [System.Text.Encoding]::UTF8)
    if ($decisionsText -notmatch '<!-- PPS:ACTIVE:BEGIN -->') {
        $block = "`n## Active Authority Index`n`n<!-- PPS:ACTIVE:BEGIN -->`n<!-- PPS:ACTIVE:END -->`n"
        $h1 = [regex]::Match($decisionsText, '(?m)^#\s+.*$')
        if ($h1.Success) {
            $decisionsText = $decisionsText.Substring(0, $h1.Index + $h1.Length) + $block + $decisionsText.Substring($h1.Index + $h1.Length)
        } else {
            $decisionsText = $block + $decisionsText
        }
    }
    if ($decisionsText -notmatch ('### ' + [regex]::Escape($decisionId) + ' ')) {
        $decisionsText += (Get-DecisionText)
    }
    if ($decisionsText -notmatch [regex]::Escape('`' + $decisionId + '`')) {
        $decisionsText = [regex]::Replace(
            $decisionsText,
            '(<!-- PPS:ACTIVE:BEGIN -->\r?\n)',
            "`$1- ``$decisionId```n",
            1)
    }
    Write-Utf8 $decisionsPath $decisionsText

    $eventsPath = Join-Path $rootFull 'EVENTS.md'
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
        Write-Utf8 $eventsPath "# Events`n`n## Events`n`n"
    }
    $eventsText = [System.IO.File]::ReadAllText($eventsPath, [System.Text.Encoding]::UTF8)
    if ($eventsText -notmatch [regex]::Escape("[$packageId] migration_authorized")) {
        $eventsText += (Get-EventText) + "`n"
        Write-Utf8 $eventsPath $eventsText
    }

    # ---- 7. Multitask opt-in -------------------------------------------------
    if ($WithMultitask) {
        $taskIndexPath = Join-Path $rootFull 'TASK_INDEX.md'
        if (-not (Test-Path -LiteralPath $taskIndexPath -PathType Leaf)) {
            Write-Utf8 $taskIndexPath "## Task Index`n`n### T-001`n- Title: Migration bootstrap integrator`n- Role: integrator`n- Status: active`n- Active Package: $packageId`n- Capsule: CONTEXT.md`n- Output Root: none`n- External Locator: none`n"
        }
        $mergesPath = Join-Path $rootFull 'MERGES.md'
        if (-not (Test-Path -LiteralPath $mergesPath -PathType Leaf)) {
            Write-Utf8 $mergesPath "# Merges`n`n## Merge Receipts`n`n<!-- No typed merge receipts yet. Pre-layer history predates this layer and is deliberately not guessed into relations. -->`n"
        }
        $stateText = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
        if ($stateText -notmatch '(?m)^-\s+Writer:') {
            $stateText = [regex]::Replace(
                $stateText,
                '(?m)^(-\s+Protocol:.*)$',
                "`$1`n- Writer: T-001",
                1)
            Write-Utf8 $statePath $stateText
        }
    }

    # ---- 8. Protocol flip ----------------------------------------------------
    $stateText = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
    $stateText = [regex]::Replace($stateText, '(?m)^-\s+Protocol:\s*PPS/1\.[01]\s*$', '- Protocol: PPS/1.2', 1)
    Write-Utf8 $statePath $stateText

    # ---- 9. Validation gate ---------------------------------------------------
    $bashGate = Join-Path $rootFull 'scripts/validate_project.sh'
    if (Test-Path -LiteralPath $bashGate -PathType Leaf) {
        & bash $bashGate $rootFull *> (Join-Path $backup 'validate-bash.log')
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'migrate_project: PPS/1.2 validation FAILED on the migrated state:'
            Get-Content -LiteralPath (Join-Path $backup 'validate-bash.log') | Write-Host
            Invoke-Rollback $backup
            exit 1
        }
    }
    $psValidator = Join-Path $rootFull 'scripts/validate_project.ps1'
    if (Test-Path -LiteralPath $psValidator -PathType Leaf) {
        & $psValidator -Root $rootFull -Quiet *> (Join-Path $backup 'validate-ps.log')
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'migrate_project: PPS/1.2 validation FAILED under PowerShell on the migrated state:'
            Get-Content -LiteralPath (Join-Path $backup 'validate-ps.log') | Write-Host
            Invoke-Rollback $backup
            exit 1
        }
    }
    $psSession = Join-Path $rootFull 'scripts/session_begin.ps1'
    $psGate = Join-Path $rootFull 'scripts/verify_gate.ps1'
    if ((Test-Path -LiteralPath $psSession -PathType Leaf) -and
        (Test-Path -LiteralPath $psGate -PathType Leaf)) {
        $gateOk = $true
        & $psSession -Root $rootFull *> $backupLog
        if ($LASTEXITCODE -ne 0) { $gateOk = $false }
        if ($gateOk) {
            & $psGate -Root $rootFull *>> $backupLog
            if ($LASTEXITCODE -ne 0) { $gateOk = $false }
        }
        if (-not $gateOk) {
            Write-Host 'migrate_project: the PPS/1.2 verify gate FAILED on the migrated state:'
            Get-Content -LiteralPath $backupLog | Select-Object -Last 30 | Write-Host
            Invoke-Rollback $backup
            exit 1
        }
    }

    Write-Host "migration applied and verified; backup: $backup"
    Write-Host 'protocol: PPS/1.2'
    if ($WithMultitask) {
        Write-Host 'multitask layer: enabled (TASK_INDEX.md, MERGES.md, Writer: T-001)'
    } else {
        Write-Host 'multitask layer: NOT enabled (single-task stays single-task; opt in with -WithMultitask when needed)'
    }
    Write-Host "NOTICE: review the coverage rows marked 'manual: migrated from PPS/1.1' in Hot State Next, then bind real checks."
}

switch ($Mode) {
    'dry-run' { Show-DryRun }
    'apply' { Invoke-Apply }
    'rollback' { Invoke-Rollback $RollbackDir }
    default { Die "unknown mode: $Mode" }
}
