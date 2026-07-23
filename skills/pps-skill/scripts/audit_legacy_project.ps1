[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$rootFull = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw "Audit root is not a directory: $rootFull"
}
$rootFull = (Resolve-Path -LiteralPath $rootFull).Path

function Test-RelativeFile([string]$RelativePath) {
    return Test-Path -LiteralPath (Join-Path $rootFull $RelativePath) -PathType Leaf
}

function Get-FileStatus([string]$RelativePath) {
    if (Test-RelativeFile $RelativePath) { return 'present' }
    return 'missing'
}

function Get-ProjectFiles {
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push((Get-Item -LiteralPath $rootFull -Force))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            if ($item.PSIsContainer) {
                if ($item.Name -eq '.git' -or
                    ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    continue
                }
                $pending.Push($item)
            } else {
                $files.Add($item)
            }
        }
    }
    return $files
}

$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
$stateText = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
} else {
    ''
}
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
    $pattern = '(?m)^-\s*' + [regex]::Escape($Name) + ':\s*(.*?)\s*$'
    $match = [regex]::Match($hotStateText, $pattern)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
}

$protocol = Get-StateField 'Protocol'
$profile = Get-StateField 'Profile'
$mainArtifact = Get-StateField 'Main'

$hasState = Test-RelativeFile 'PROJECT_STATE.md'
$hasDecisions = Test-RelativeFile 'DECISIONS.md'
$hasContext = Test-RelativeFile 'CONTEXT.md'
$hasAgents = Test-RelativeFile 'AGENTS.md'
$hasPlanControl = $hasState -and $hasDecisions -and $hasAgents
$hasPpsProtocol = $protocol -eq 'PPS/1.0' -and $hasPlanControl -and $hasContext

$projectFiles = @(Get-ProjectFiles)
$stateCandidateNames = @('STATE.md', 'CURRENT_STATE.md', 'WORKFLOW_STATE.md')
$otherStateCandidates = @(
    $projectFiles | Where-Object { $stateCandidateNames -contains $_.Name }
)
$hasOtherState = $otherStateCandidates.Count -gt 0

$detected = if ($hasPpsProtocol) {
    'pps'
} elseif ($hasPlanControl -and $hasOtherState) {
    'mixed'
} elseif ($hasPlanControl) {
    'plan-project-sync'
} elseif ($hasOtherState) {
    'other-state-system'
} else {
    'unstructured'
}

$recommendedProfile = if (
    (Test-RelativeFile 'SOURCE_INDEX.md') -or
    (Test-RelativeFile 'docs/CURRENT_REVIEW_EVIDENCE.md')
) {
    'evidence'
} else {
    'standard (provisional)'
}

$markdownFiles = @(
    $projectFiles | Where-Object { $_.Extension -eq '.md' }
)
$authorityIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
foreach ($file in $markdownFiles) {
    try {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    } catch {
        continue
    }
    foreach ($match in [regex]::Matches($text, '[MFD]-[A-Za-z0-9][A-Za-z0-9_-]*')) {
        $null = $authorityIds.Add($match.Value)
    }
}

$gitStatus = 'not detected'
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git) {
    & $git.Source -C $rootFull rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
        $gitStatus = 'present'
    }
}

$lines = [System.Collections.Generic.List[string]]::new()
function Add-ReportLine([string]$Line = '') {
    $lines.Add($Line)
}

Add-ReportLine '# PPS Legacy Project Audit'
Add-ReportLine
Add-ReportLine "- Target: ``$rootFull``"
Add-ReportLine "- Generated: ``$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))``"
Add-ReportLine '- Audit mode: read-only'
Add-ReportLine "- Detected system: ``$detected``"
Add-ReportLine "- Recommended profile: ``$recommendedProfile``"
Add-ReportLine
Add-ReportLine '## Inventory'
Add-ReportLine
Add-ReportLine '| Signal | Status |'
Add-ReportLine '|---|---|'
Add-ReportLine "| Git repository | $gitStatus |"
Add-ReportLine "| README.md | $(Get-FileStatus 'README.md') |"
Add-ReportLine "| AGENTS.md | $(Get-FileStatus 'AGENTS.md') |"
Add-ReportLine "| PROJECT_STATE.md | $(Get-FileStatus 'PROJECT_STATE.md') |"
Add-ReportLine "| DECISIONS.md | $(Get-FileStatus 'DECISIONS.md') |"
Add-ReportLine "| CONTEXT.md | $(Get-FileStatus 'CONTEXT.md') |"
Add-ReportLine "| SOURCE_INDEX.md | $(Get-FileStatus 'SOURCE_INDEX.md') |"
Add-ReportLine "| Other state candidates | $($otherStateCandidates.Count) |"
Add-ReportLine "| Markdown files | $($markdownFiles.Count) |"
Add-ReportLine "| Unique M/F/D-shaped IDs | $($authorityIds.Count) |"
Add-ReportLine
Add-ReportLine '## Existing declarations'
Add-ReportLine
Add-ReportLine "- Protocol: ``$(if ($protocol) { $protocol } else { 'not declared' })``"
Add-ReportLine "- Profile: ``$(if ($profile) { $profile } else { 'not declared' })``"
Add-ReportLine "- Main artifact: ``$(if ($mainArtifact) { $mainArtifact } else { 'not declared' })``"
Add-ReportLine
Add-ReportLine '## Proposed migration'
Add-ReportLine

switch ($detected) {
    'pps' {
        Add-ReportLine 'This repository already declares PPS/1.0 and has the core control files.'
        Add-ReportLine
        Add-ReportLine '1. Run the project-local validator.'
        Add-ReportLine '2. Resolve every reported mismatch without weakening validation.'
        Add-ReportLine '3. Do not create a second state system.'
    }
    'plan-project-sync' {
        Add-ReportLine 'Reuse the existing project state and decision history; do not reinitialize the repository.'
        Add-ReportLine
        Add-ReportLine '1. Preserve existing IDs and historical records.'
        Add-ReportLine '2. Add PPS hot-state fields and one explicit workset manifest.'
        Add-ReportLine '3. Add an active authority block without promoting proposals or assumptions.'
        Add-ReportLine '4. Add coverage and project-local validation scripts on a branch.'
        Add-ReportLine '5. Switch AGENTS.md only after validation passes.'
    }
    'other-state-system' {
        Add-ReportLine 'Treat the existing state system as authoritative until an explicit cutover is approved.'
        Add-ReportLine
        Add-ReportLine '1. Inventory current project, requirements, state, roadmap, context, plan, and summary files.'
        Add-ReportLine '2. Map only binding M/F/D authority and resolve repeated stage-local IDs.'
        Add-ReportLine '3. Select the current deliverable and build one explicit workset.'
        Add-ReportLine '4. Validate the proposed PPS state before stopping the legacy state system.'
    }
    'mixed' {
        Add-ReportLine 'Multiple state systems are present. Do not write until one authority is selected.'
        Add-ReportLine
        Add-ReportLine '1. Identify which system currently controls workflow and decisions.'
        Add-ReportLine '2. Preserve the other system as migration history until user-approved cutover.'
        Add-ReportLine '3. Build and validate one proposed PPS authority index and workset.'
        Add-ReportLine '4. Stop running both state machines after cutover.'
    }
    default {
        Add-ReportLine 'No supported state system was detected. User review is required before authority is created.'
        Add-ReportLine
        Add-ReportLine '1. Identify the current deliverable and authoritative user facts.'
        Add-ReportLine '2. Separate binding constraints from historical AI suggestions.'
        Add-ReportLine '3. Mark uncertainty as proposals or assumptions, not decisions.'
        Add-ReportLine '4. Review the initial active index with the user before cutover.'
    }
}

Add-ReportLine
Add-ReportLine '## Safety result'
Add-ReportLine
Add-ReportLine 'The target was inspected without modification. This report is a proposal, not an active migration.'
$report = [string]::Join([Environment]::NewLine, $lines) + [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Write-Output $report
    exit 0
}

$outputInputFull = [System.IO.Path]::GetFullPath($OutputPath)
$outputParentInput = Split-Path -Parent $outputInputFull
if (-not (Test-Path -LiteralPath $outputParentInput -PathType Container)) {
    throw "Output parent does not exist: $outputParentInput"
}
$outputParent = (Resolve-Path -LiteralPath $outputParentInput).Path
$outputFull = Join-Path $outputParent (Split-Path -Leaf $outputInputFull)

$comparison = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$rootPrefix = $rootFull.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
if ($outputFull.Equals($rootFull, $comparison) -or $outputFull.StartsWith($rootPrefix, $comparison)) {
    throw "Refusing to write the audit report inside the target project: $outputFull"
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Refusing to overwrite an existing report: $outputFull"
}

[System.IO.File]::WriteAllText(
    $outputFull,
    $report,
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host "PPS legacy audit report written: $outputFull"
