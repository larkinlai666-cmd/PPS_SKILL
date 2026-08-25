[CmdletBinding()]
param(
    [string]$Root,
    # Small-context repair: the protocol has always described L0/L1/L2
    # retrieval, but this script only ever emitted one size. -Level emits
    # SUBSETS of the same content: no new sections, no new state, and
    # -Level full is byte-identical to the previous behaviour.
    [ValidateSet('anchor', 'hot', 'full')]
    [string]$Level = 'full'
)

$ErrorActionPreference = 'Stop'
$packetLevel = $Level
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)
$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
$contextPath = Join-Path $rootFull 'CONTEXT.md'
$decisionsPath = Join-Path $rootFull 'DECISIONS.md'
$mapPath = Join-Path $rootFull 'PROJECT_MAP.md'
$validator = Join-Path $rootFull 'scripts/validate_project.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Missing project validator: $validator"
}

$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) { $engine = Get-Command powershell -ErrorAction Stop }
$validationOutput = @(& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $validator -Root $rootFull -Quiet 2>&1)
if ($LASTEXITCODE -ne 0) {
    $validationOutput | Select-Object -First 200 | ForEach-Object { [Console]::Error.WriteLine($_) }
    throw 'Resume packet refused because project validation failed.'
}

$stateLines = [System.IO.File]::ReadAllLines($statePath, [System.Text.Encoding]::UTF8)
$contextLines = [System.IO.File]::ReadAllLines($contextPath, [System.Text.Encoding]::UTF8)
$decisionLines = [System.IO.File]::ReadAllLines($decisionsPath, [System.Text.Encoding]::UTF8)
$mapLines = [System.IO.File]::ReadAllLines($mapPath, [System.Text.Encoding]::UTF8)

function Get-SectionField([string[]]$Lines, [string]$Section, [string]$Field) {
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -eq "## $Section") { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside -and $line.StartsWith("- ${Field}:")) {
            return $line.Substring(("- ${Field}:").Length).Trim()
        }
    }
    return $null
}

function Test-GitRepository([string]$GitCommand, [string]$Path) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 converts expected native stderr into an error
        # record. A non-repository is a normal probe result, so use the native
        # exit code rather than allowing that record to terminate the packet.
        $ErrorActionPreference = 'SilentlyContinue'
        $probeOutput = @(
            & $GitCommand -C $Path rev-parse --is-inside-work-tree 2>$null
        )
        $probeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return $probeExitCode -eq 0 -and
        (($probeOutput -join "`n").Trim() -eq 'true')
}

$packet = [System.Collections.Generic.List[string]]::new()
$packet.Add('# PPS Resume Packet')
$packet.Add('')
$packet.Add('## Hot State')
# anchor level keeps only the fields needed to re-anchor: who/where/what is
# active. Everything else is recoverable by reading the state file.
$hotFields = if ($packetLevel -eq 'anchor') {
    @('Protocol', 'Mode', 'Stage', 'Package', 'Status', 'Next')
} else {
    @('Protocol', 'Profile', 'Mode', 'Stage', 'Main', 'Map', 'Environment', 'Package', 'Status', 'Capsule', 'Coverage', 'Blockers', 'Next', 'Updated', 'Device', 'Writer')
}
foreach ($field in $hotFields) {
    $value = Get-SectionField $stateLines 'Hot State' $field
    if (-not [string]::IsNullOrWhiteSpace($value)) { $packet.Add("- ${field}: $value") }
}

# R1: the packet is the authority after a context reset, so it must carry the
# objective itself — not only the one-line package Goal. Bounded like the red
# lines: truncate on a byte budget rather than dropping the section.
$objectiveBody = [System.Collections.Generic.List[string]]::new()
$insideObjective = $false
foreach ($line in $stateLines) {
    if ($line -match '^##\s+Objective\s*$') { $insideObjective = $true; continue }
    if ($insideObjective -and $line -match '^##\s') { break }
    if ($insideObjective -and -not [string]::IsNullOrWhiteSpace($line)) {
        $objectiveBody.Add($line)
    }
}
if ($objectiveBody.Count -gt 0) {
    $packet.Add('')
    $packet.Add('## Objective')
    $objectiveBudget = 800
    $objectiveUsed = 0
    $objectiveTruncated = $false
    foreach ($line in $objectiveBody) {
        $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
        if (($objectiveUsed + $lineBytes) -gt $objectiveBudget) {
            $objectiveTruncated = $true
            break
        }
        $packet.Add($line)
        $objectiveUsed += $lineBytes
    }
    if ($objectiveTruncated) {
        $packet.Add('- Objective truncated; read PROJECT_STATE.md for the full statement.')
    }
}

$agentsPath = Join-Path $rootFull 'AGENTS.md'
if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    $agentsLines = [System.IO.File]::ReadAllLines($agentsPath, [System.Text.Encoding]::UTF8)
    $redLines = [System.Collections.Generic.List[string]]::new()
    $insideRed = $false
    $insideRedComment = $false
    foreach ($line in $agentsLines) {
        if ($line -match '^##\s+Red Lines\s*$') { $insideRed = $true; continue }
        if ($insideRed -and $line -match '^## ') { break }
        # Take every non-empty line, not only "- " bullets: numbered items and
        # bold headers are red lines too, and dropping them made the packet
        # claim a project had no engineering red lines at all. Skip HTML
        # comments: template guidance is not a red line and must not consume
        # the byte budget.
        if ($insideRed) {
            if ($line -match '<!--') { $insideRedComment = $true }
            if ($line -match '-->') { $insideRedComment = $false; continue }
            if (-not $insideRedComment -and -not [string]::IsNullOrWhiteSpace($line)) {
                $redLines.Add($line)
            }
        }
    }
    if ($redLines.Count -gt 0) {
        $packet.Add('')
        $packet.Add('## Red Lines')
        # Budget by bytes so the shape of the list cannot silently truncate it.
        # Red lines are a guardrail and are never dropped, but a re-anchor
        # pull can afford less of them than a cold start.
        $redBudget = if ($packetLevel -eq 'anchor') { 600 } else { 1500 }
        $redUsed = 0
        $redTruncated = $false
        foreach ($line in $redLines) {
            $lineSize = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
            if (($redUsed + $lineSize) -gt $redBudget) { $redTruncated = $true; break }
            $packet.Add($line)
            $redUsed += $lineSize
        }
        if ($redTruncated) {
            $packet.Add('- Red Lines truncated; read AGENTS.md for the full list.')
        }
    }
}

$eventsPath = Join-Path $rootFull 'EVENTS.md'
if ((Test-Path -LiteralPath $eventsPath -PathType Leaf) -and $packetLevel -ne 'anchor') {
    $eventsLines = [System.IO.File]::ReadAllLines($eventsPath, [System.Text.Encoding]::UTF8)
    $eventEntries = [System.Collections.Generic.List[string]]::new()
    $insideEvents = $false
    foreach ($line in $eventsLines) {
        if ($line -match '^##\s+Events\s*$') { $insideEvents = $true; continue }
        if ($insideEvents -and $line -match '^## ') { $insideEvents = $false; continue }
        if ($insideEvents -and $line.StartsWith('- ')) { $eventEntries.Add($line) }
    }
    $packet.Add('')
    $packet.Add('## Recent Events')
    foreach ($line in @($eventEntries | Select-Object -Last 5)) { $packet.Add($line) }
}

$packet.Add('')
$packet.Add('## Workset')
# anchor level keeps the write boundary and its verification: those are the
# constraints an agent violates when its working memory has rotted.
$worksetFields = if ($packetLevel -eq 'anchor') {
    @('Read', 'Write', 'Verify', 'Excluded')
} else {
    @('Methods', 'Facts', 'Decisions', 'Sources', 'Assets', 'Components', 'Read', 'Write', 'Verify', 'Excluded', 'Coverage')
}
foreach ($field in $worksetFields) {
    $value = Get-SectionField $contextLines 'Workset Manifest' $field
    if (-not [string]::IsNullOrWhiteSpace($value)) { $packet.Add("- ${field}: $value") }
}

$packet.Add('')
$packet.Add('## Current Package')
foreach ($field in @('ID', 'Goal', 'Output anchor', 'Allowed change', 'Forbidden change')) {
    $value = Get-SectionField $contextLines 'Current Package' $field
    if (-not [string]::IsNullOrWhiteSpace($value)) { $packet.Add("- ${field}: $value") }
}
# R1: "done" must survive a context reset. Acceptance is a multi-line sub-list,
# which Get-SectionField cannot see, so a recovered agent used to get Goal
# without ever learning what closes the package. Emit the items verbatim.
$acceptanceItems = [System.Collections.Generic.List[string]]::new()
$insideAcceptancePkg = $false
foreach ($line in $contextLines) {
    if ($line -match '^##\s+Current Package\s*$') { $insideAcceptancePkg = $true; continue }
    if ($insideAcceptancePkg -and $line -match '^##\s') { break }
    if ($insideAcceptancePkg -and $line -match '^\s*-\s*A\d+:') {
        $acceptanceItems.Add($line.Trim())
    }
}
if ($acceptanceItems.Count -gt 0) {
    $packet.Add('- Acceptance:')
    foreach ($item in $acceptanceItems) { $packet.Add("  $item") }
}
$insideNext = $false
foreach ($line in $contextLines) {
    if ($line -match '^## Next Action\s*$') { $insideNext = $true; continue }
    if ($insideNext -and $line -match '^## ') { break }
    if ($insideNext -and -not [string]::IsNullOrWhiteSpace($line)) {
        $packet.Add("- Next action: $line")
        break
    }
}

if ($packetLevel -ne 'anchor') {
$packet.Add('')
$packet.Add('## Component Rows')
$components = Get-SectionField $contextLines 'Workset Manifest' 'Components'
if ($components -eq 'none') {
    $packet.Add('- none')
} else {
    foreach ($component in @($components.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $row = $mapLines | Where-Object {
            $cells = $_.Split('|')
            $cells.Count -ge 3 -and $cells[1].Trim() -eq $component
        } | Select-Object -First 1
        if ($null -ne $row) { $packet.Add($row) }
    }
}

$packet.Add('')
$packet.Add('## Active Authority Summaries')
$authorityIds = [System.Collections.Generic.List[string]]::new()
foreach ($field in @('Methods', 'Facts', 'Decisions')) {
    $raw = Get-SectionField $contextLines 'Workset Manifest' $field
    if ($raw -ne 'none') {
        @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | ForEach-Object { $authorityIds.Add($_) }
    }
}
if ($authorityIds.Count -eq 0) {
    $packet.Add('- none')
} else {
    foreach ($authorityId in $authorityIds) {
        foreach ($line in $decisionLines) {
            if ($line -match "^### $([regex]::Escape($authorityId))(\s|$)") {
                $packet.Add($line)
                break
            }
        }
    }
}

}

if ($packetLevel -eq 'full') {
$packet.Add('')
$packet.Add('## Asset Readiness')
$assetChecker = Join-Path $rootFull 'scripts/asset_check.ps1'
if (Test-Path -LiteralPath $assetChecker -PathType Leaf) {
    $assetOutput = @(
        & $engine.Source -NoProfile -ExecutionPolicy Bypass -File `
            $assetChecker -Root $rootFull -Quick 2>&1
    )
    $assetExit = $LASTEXITCODE
    foreach ($line in @($assetOutput | Select-Object -First 80)) {
        $packet.Add("$line")
    }
    if ($assetExit -ne 0) {
        $packet.Add('Materialization: incomplete; Git synchronization alone is not a complete project handoff.')
    }
} else {
    $packet.Add('Asset checker: unavailable')
}

}

$packet.Add('')
$packet.Add('## Handover')
# A single word "dirty" tells the next agent nothing about WHICH files carry
# the previous session's uncommitted work. Name them.
$handoverEntries = @()
$gitProbe = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $gitProbe -and (Test-GitRepository $gitProbe.Source $rootFull)) {
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $rawHandover = ((& $gitProbe.Source -C $rootFull status --porcelain -z --untracked-files=all 2>$null) |
            ForEach-Object { "$_" }) -join "`n"
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
    $skipNextHandover = $false
    foreach ($entry in $rawHandover.Split([char]0)) {
        if ($skipNextHandover) { $skipNextHandover = $false; continue }
        if ($entry.Length -le 3) { continue }
        $entryStatus = $entry.Substring(0, 2)
        $entryPath = $entry.Substring(3)
        if ($entryStatus -match '^[RC]') { $skipNextHandover = $true }
        $handoverEntries += [pscustomobject]@{ Status = $entryStatus; Path = $entryPath }
    }
}
if ($handoverEntries.Count -eq 0) {
    $packet.Add('- Uncommitted paths: none')
} else {
    $packet.Add("- Uncommitted paths: $($handoverEntries.Count)")
    $shownHandover = 0
    foreach ($entry in $handoverEntries) {
        if ($shownHandover -ge 20) { break }
        $packet.Add("- protected: $($entry.Path) ($($entry.Status))")
        $shownHandover++
    }
    if ($handoverEntries.Count -gt 20) {
        $packet.Add("- protected: ... $($handoverEntries.Count - 20) more")
    }
    $nextValue = Get-SectionField $stateLines 'Hot State' 'Next'
    $declared = @()
    foreach ($entry in $handoverEntries) {
        if ($nextValue -and $nextValue.Contains($entry.Path)) { $declared += $entry.Path }
    }
    if ($declared.Count -gt 0) {
        $packet.Add("- Declared in Next: $($declared -join ', ')")
    } else {
        $packet.Add('- Declared in Next: none')
        $packet.Add('- WARNING: dirty worktree without explicit handover; do not overwrite the paths above wholesale.')
    }
}
$snapshotForPacket = Join-Path $rootFull '.pps/session-snapshot'
if (Test-Path -LiteralPath $snapshotForPacket -PathType Leaf) {
    $snapStarted = 'unknown'
    foreach ($snapLine in [System.IO.File]::ReadAllLines($snapshotForPacket, [System.Text.Encoding]::UTF8)) {
        if ($snapLine -match '^started_at:\s*(.+)$') { $snapStarted = $Matches[1].Trim(); break }
    }
    $packet.Add("- Session snapshot: present ($snapStarted)")
} else {
    $packet.Add('- Relay: SNAPSHOT MISSING; run scripts/session_begin.* before writing.')
}

$packet.Add('')
$packet.Add('## Repository Risk')
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git -and (Test-GitRepository $git.Source $rootFull)) {
    $branch = ((& $git.Source -C $rootFull branch --show-current 2>$null) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'detached' }
    $firstChange = ((& $git.Source -C $rootFull status --porcelain --untracked-files=normal 2>$null | Select-Object -First 1) | Out-String).Trim()
    $dirty = if ([string]::IsNullOrWhiteSpace($firstChange)) { 'clean' } else { 'dirty' }
    $packet.Add("- Branch: $branch")
    $packet.Add("- Worktree: $dirty")
} else {
    $packet.Add('- Git: unavailable or not initialized')
}
$packet.Add('- Validation: pass')
# Machine-readable trailer: lets the gate observe whether a packet was pulled
# in this session, and tells a reader which subset it is holding.
$packet.Add("- packet_level: $packetLevel")
$packet.Add("- generated_at: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")

function Measure-PacketBytes([System.Collections.Generic.List[string]]$Lines) {
    return [System.Text.Encoding]::UTF8.GetByteCount(($Lines -join [Environment]::NewLine))
}
function Remove-PacketSection(
    [System.Collections.Generic.List[string]]$Lines, [string]$Heading) {
    $kept = [System.Collections.Generic.List[string]]::new()
    $skipping = $false
    foreach ($line in $Lines) {
        if ($line -eq "## $Heading") { $skipping = $true; continue }
        if ($skipping -and $line -match '^## ') { $skipping = $false }
        if ($skipping) { continue }
        $kept.Add($line)
    }
    return $kept
}

# A hard failure over budget hands a small-context model ZERO information and
# tells it to "narrow the workset" - which it cannot do mid-session. Degrade in
# a fixed order instead, and say out loud what was dropped. The goal, the red
# lines, the current package and the write boundary are never droppable: they
# are the anti-drift payload the packet exists to carry.
$packetBytes = Measure-PacketBytes $packet
if ($packet.Count -gt 240 -or $packetBytes -gt 32768) {
    $droppedSections = [System.Collections.Generic.List[string]]::new()
    foreach ($droppable in @('Asset Readiness', 'Component Rows',
            'Active Authority Summaries', 'Recent Events', 'Repository Risk')) {
        if ($packet.Count -le 240 -and $packetBytes -le 32768) { break }
        $packet = Remove-PacketSection $packet $droppable
        $droppedSections.Add($droppable)
        $packetBytes = Measure-PacketBytes $packet
    }
    if ($droppedSections.Count -gt 0) {
        $packet.Add("- packet_degraded: dropped $($droppedSections -join ', ') to fit the L0 budget; re-read the files for those sections.")
        $packetBytes = Measure-PacketBytes $packet
    }
}
if ($packet.Count -gt 240 -or $packetBytes -gt 32768) {
    # Even after degrading, the undroppable core does not fit: that is a real
    # workset problem, not a context-size problem.
    throw "Resume packet exceeds the L0 budget even after dropping optional sections ($($packet.Count) lines / $packetBytes bytes); narrow the workset."
}
$ppsDir = Join-Path $rootFull '.pps'
if (Test-Path -LiteralPath $ppsDir -PathType Container) {
    try {
        # The fingerprint lets a later write-time check verify that the packet
        # matches the DISK, not just a timestamp. See core_fingerprint.ps1 for
        # why the cost of faking it equals the benefit of compliance.
        $coreFpText = ''
        $coreFpPath = Join-Path $rootFull 'scripts/core_fingerprint.ps1'
        if (Test-Path -LiteralPath $coreFpPath -PathType Leaf) {
            $coreFpText = (& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $coreFpPath -Root $rootFull 2>$null | Out-String).Trim()
        }
        $fingerprintLine = if ([string]::IsNullOrWhiteSpace($coreFpText)) { '' } else { "core_sha256: $coreFpText`n" }
        [System.IO.File]::WriteAllText(
            (Join-Path $ppsDir 'last-packet'),
            "packet_level: $packetLevel`ngenerated_at: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`n$fingerprintLine",
            [System.Text.UTF8Encoding]::new($false))
    } catch { }
}
$packet
