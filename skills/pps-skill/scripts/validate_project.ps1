[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$idPattern = '[MFD]-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?'
$sourcePattern = 'SRC-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?'

function Add-ValidationError([string]$Message) {
    $script:errors.Add($Message)
}

function Add-ValidationWarning([string]$Message) {
    $script:warnings.Add($Message)
}

function Get-MatchingLineNumbers([string]$Text, [string]$Pattern) {
    $numbers = [System.Collections.Generic.List[int]]::new()
    $lines = @($Text -split "`r?`n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $Pattern) {
            $numbers.Add($index + 1)
        }
    }
    if ($numbers.Count -eq 0) {
        return 'none'
    }
    return ($numbers -join ',')
}

function Read-Utf8File([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Resolve-ProjectFile([string]$ProjectRoot, [string]$RelativePath, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath -match '(^|/)\.\.(/|$)') {
        Add-ValidationError "$Label must be a project-relative path: $RelativePath"
        return $null
    }
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    if (-not $candidate.StartsWith($prefix, $comparison)) {
        Add-ValidationError "$Label escapes the project root: $RelativePath"
        return $null
    }
    $current = $rootFull
    foreach ($segment in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-ValidationError "$Label must not traverse a symbolic link: $RelativePath"
                return $null
            }
        }
    }
    return $candidate
}

function Get-ManifestIds([string]$Value, [string]$Prefix, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    $trimmed = $Value.Trim()
    $emptyTokens = @('none', 'n/a', 'na', 'empty')
    if ($emptyTokens -contains $trimmed.ToLowerInvariant()) {
        return @()
    }
    $tokenPattern = [regex]::Escape($Prefix) + '-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?'
    $listPattern = '^' + $tokenPattern + '\s*(?:,\s*' + $tokenPattern + '\s*)*$'
    if ($trimmed -notmatch $listPattern) {
        Add-ValidationError "$Label must be 'none' or a comma-separated list of only $Prefix IDs: $Value"
        return @()
    }
    $compact = [regex]::Replace($trimmed, '\s+', '')
    $ids = @($compact.Split(','))
    $duplicates = @($ids | Group-Object | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        Add-ValidationError "$Label contains duplicate IDs: $($duplicates.Name -join ' ')"
    }
    return $ids
}

function Get-Section([string]$Text, [string]$Title) {
    $pattern = '(?ms)^##\s+' + [regex]::Escape($Title) + '\s*\r?\n(?<body>.*?)(?=^##\s+|\z)'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) {
        $locations = Get-MatchingLineNumbers $Text ('^##\s+' + [regex]::Escape($Title) + '\s*$')
        Add-ValidationError "Expected exactly one '$Title' section, found $($matches.Count) (lines $locations)."
        return ''
    }
    return $matches[0].Groups['body'].Value
}

function Get-SectionField(
    [string]$Section,
    [string]$FullText,
    [string]$Title,
    [string]$Name
) {
    $pattern = '(?m)^-\s+' + [regex]::Escape($Name) + ':\s*(.*?)\s*$'
    $matches = [regex]::Matches($Section, $pattern)
    if ($matches.Count -ne 1) {
        $locations = Get-MatchingLineNumbers $FullText ('^-\s+' + [regex]::Escape($Name) + ':\s*')
        Add-ValidationError "Expected exactly one '$Name' field in '$Title', found $($matches.Count) (candidate lines $locations)."
        return $null
    }
    return $matches[0].Groups[1].Value.Trim()
}

$rootFull = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    Write-Host "PPS validation: FAILED"
    Write-Host "ERROR: Project root is not a directory: $rootFull"
    exit 1
}
$rootFull = (Resolve-Path -LiteralPath $rootFull).Path
$requiredFiles = @(
    'README.md',
    'AGENTS.md',
    'PROJECT_STATE.md',
    'DECISIONS.md',
    'CONTEXT.md',
    'scripts/status_check.ps1',
    'scripts/status_check.sh',
    'scripts/validate_project.ps1',
    'scripts/validate_project.sh'
)

foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $rootFull $relative) -PathType Leaf)) {
        Add-ValidationError "Missing required file: $relative"
    }
}

$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
$decisionPath = Join-Path $rootFull 'DECISIONS.md'
$contextPath = Join-Path $rootFull 'CONTEXT.md'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $decisionPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    Write-Host "PPS validation: FAILED"
    foreach ($message in $errors) { Write-Host "ERROR: $message" }
    exit 1
}

$stateText = Read-Utf8File $statePath
$decisionText = Read-Utf8File $decisionPath
$contextText = Read-Utf8File $contextPath

$hotStateText = Get-Section $stateText 'Hot State'
$protocol = Get-SectionField $hotStateText $stateText 'Hot State' 'Protocol'
$profile = Get-SectionField $hotStateText $stateText 'Hot State' 'Profile'
$stage = Get-SectionField $hotStateText $stateText 'Hot State' 'Stage'
$mainRelative = Get-SectionField $hotStateText $stateText 'Hot State' 'Main'
$package = Get-SectionField $hotStateText $stateText 'Hot State' 'Package'
$status = Get-SectionField $hotStateText $stateText 'Hot State' 'Status'
$capsuleRelative = Get-SectionField $hotStateText $stateText 'Hot State' 'Capsule'
$coverageRelative = Get-SectionField $hotStateText $stateText 'Hot State' 'Coverage'
$blockers = Get-SectionField $hotStateText $stateText 'Hot State' 'Blockers'
$next = Get-SectionField $hotStateText $stateText 'Hot State' 'Next'
$updated = Get-SectionField $hotStateText $stateText 'Hot State' 'Updated'
$deviceMatch = [regex]::Match($hotStateText, '(?m)^-\s+Device:\s*(.*?)\s*$')

if ($protocol -ne 'PPS/1.0') {
    Add-ValidationError "Protocol must be PPS/1.0, found '$protocol'."
}
if ($profile -notin @('standard', 'evidence')) {
    Add-ValidationError "Profile must be standard or evidence, found '$profile'."
}
if ($status -notin @('active', 'review_pending', 'blocked', 'complete')) {
    Add-ValidationError "Unsupported Status '$status'."
}
if ($package -notmatch '^PKG-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') {
    Add-ValidationError "Package must use a PKG-* ID, found '$package'."
}
$parsedUpdated = [datetime]::MinValue
$validUpdated = [datetime]::TryParseExact(
    $updated,
    'yyyy-MM-ddTHH:mm:ssZ',
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal,
    [ref]$parsedUpdated
)
if (-not $validUpdated) {
    Add-ValidationError "Updated must be a UTC timestamp like YYYY-MM-DDTHH:MM:SSZ, found '$updated'."
}
foreach ($pair in @(
    @{ Name = 'Stage'; Value = $stage },
    @{ Name = 'Package'; Value = $package },
    @{ Name = 'Blockers'; Value = $blockers },
    @{ Name = 'Next'; Value = $next },
    @{ Name = 'Updated'; Value = $updated }
)) {
    if ([string]::IsNullOrWhiteSpace($pair.Value)) {
        Add-ValidationError "$($pair.Name) cannot be empty."
    }
}
if (-not $deviceMatch.Success -or [string]::IsNullOrWhiteSpace($deviceMatch.Groups[1].Value)) {
    Add-ValidationWarning "Device is missing; add it on the next state update."
}

$mainPath = Resolve-ProjectFile $rootFull $mainRelative 'Main'
$capsulePath = Resolve-ProjectFile $rootFull $capsuleRelative 'Capsule'
$coveragePath = Resolve-ProjectFile $rootFull $coverageRelative 'Coverage'
foreach ($pair in @(
    @{ Name = 'Main'; Path = $mainPath },
    @{ Name = 'Capsule'; Path = $capsulePath },
    @{ Name = 'Coverage'; Path = $coveragePath }
)) {
    if ($null -ne $pair.Path -and -not (Test-Path -LiteralPath $pair.Path -PathType Leaf)) {
        Add-ValidationError "$($pair.Name) file does not exist: $($pair.Path)"
    }
}

if ($capsuleRelative -ne 'CONTEXT.md') {
    Add-ValidationError "PPS/1.0 requires Capsule: CONTEXT.md."
}
if ($profile -eq 'standard' -and $coverageRelative -ne 'CONTEXT.md') {
    Add-ValidationError "The standard profile requires Coverage: CONTEXT.md."
}
if ($profile -eq 'evidence') {
    if ($coverageRelative -ne 'docs/CURRENT_REVIEW_EVIDENCE.md') {
        Add-ValidationError "The evidence profile requires Coverage: docs/CURRENT_REVIEW_EVIDENCE.md."
    }
    foreach ($relative in @('SOURCE_INDEX.md', 'docs/CURRENT_REVIEW_EVIDENCE.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull $relative) -PathType Leaf)) {
            Add-ValidationError "Evidence profile is missing: $relative"
        }
    }
}

$stateLines = @($stateText -split "`r?`n").Count
$contextLines = @($contextText -split "`r?`n").Count
if ($stateLines -gt 120) {
    Add-ValidationError "PROJECT_STATE.md has $stateLines lines; hard limit is 120."
} elseif ($stateLines -gt 80) {
    Add-ValidationWarning "PROJECT_STATE.md has $stateLines lines; compact target is 80."
}
if ($contextLines -gt 80) {
    Add-ValidationError "CONTEXT.md has $contextLines lines; hard limit is 80."
} elseif ($contextLines -gt 60) {
    Add-ValidationWarning "CONTEXT.md has $contextLines lines; compact target is 60."
}

$worksetText = Get-Section $contextText 'Workset Manifest'
$methodsValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Methods'
$factsValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Facts'
$decisionsValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Decisions'
$sourcesValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Sources'
$excludedValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Excluded'
$manifestCoverage = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Coverage'
$currentPackageText = Get-Section $contextText 'Current Package'
$contextPackage = Get-SectionField $currentPackageText $contextText 'Current Package' 'ID'

$requiredIds = @()
$requiredIds += Get-ManifestIds $methodsValue 'M' 'Methods'
$requiredIds += Get-ManifestIds $factsValue 'F' 'Facts'
$requiredIds += Get-ManifestIds $decisionsValue 'D' 'Decisions'
$requiredIds = @($requiredIds | Select-Object -Unique)
$sourceIds = @(Get-ManifestIds $sourcesValue 'SRC' 'Sources')

if ($manifestCoverage -ne $coverageRelative) {
    Add-ValidationError "CONTEXT Coverage '$manifestCoverage' does not match PROJECT_STATE Coverage '$coverageRelative'."
}
if ($contextPackage -ne $package) {
    Add-ValidationError "CONTEXT package '$contextPackage' does not match PROJECT_STATE Package '$package'."
}
if ([string]::IsNullOrWhiteSpace($excludedValue)) {
    Add-ValidationError "Excluded cannot be empty; use 'none' when nothing is excluded."
}

if ($profile -eq 'evidence') {
    $evidencePath = Join-Path $rootFull 'docs/CURRENT_REVIEW_EVIDENCE.md'
    if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
        $evidenceText = Read-Utf8File $evidencePath
        $evidencePackageText = Get-Section $evidenceText 'Package'
        $evidencePackage = Get-SectionField $evidencePackageText $evidenceText 'Package' 'ID'
        if ($evidencePackage -ne $package) {
            Add-ValidationError "Evidence package '$evidencePackage' does not match PROJECT_STATE Package '$package'."
        }
    }
}

$beginPattern = '(?m)^<!-- PPS:ACTIVE:BEGIN -->\s*$'
$endPattern = '(?m)^<!-- PPS:ACTIVE:END -->\s*$'
$beginCount = [regex]::Matches($decisionText, $beginPattern).Count
$endCount = [regex]::Matches($decisionText, $endPattern).Count
$activeIds = @()
if ($beginCount -ne 1 -or $endCount -ne 1) {
    Add-ValidationError "DECISIONS.md must contain exactly one active authority block; found $beginCount begin marker(s) and $endCount end marker(s)."
} else {
    $activeMatch = [regex]::Match(
        $decisionText,
        '(?ms)^<!-- PPS:ACTIVE:BEGIN -->\s*$\r?\n?(.*?)^<!-- PPS:ACTIVE:END -->\s*$'
    )
    if (-not $activeMatch.Success) {
        Add-ValidationError "DECISIONS.md active authority markers are out of order or malformed."
    }
    $activeLines = @($activeMatch.Groups[1].Value -split "`r?`n")
    foreach ($line in $activeLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lineMatch = [regex]::Match($line, '^\s*-\s+`(?<id>[MFD]-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)`\s*$')
        if (-not $lineMatch.Success) {
            Add-ValidationError "Malformed active-block line: $line"
            continue
        }
        $activeIds += $lineMatch.Groups['id'].Value
    }
}

foreach ($duplicate in @($activeIds | Group-Object | Where-Object Count -gt 1)) {
    Add-ValidationError "Active ID appears more than once: $($duplicate.Name)"
}

foreach ($id in @($activeIds | Select-Object -Unique)) {
    $recordPattern = '(?m)^###\s+' + [regex]::Escape($id) + '\s+\[active\]\s*$'
    $recordCount = [regex]::Matches($decisionText, $recordPattern).Count
    if ($recordCount -ne 1) {
        Add-ValidationError "Active ID $id must have exactly one [active] record, found $recordCount."
    }
}

$recordHeadings = [regex]::Matches($decisionText, '(?m)^###\s+(?<id>[MFD]-\S+)(?<tail>.*)$')
$records = @()
foreach ($heading in $recordHeadings) {
    $line = $heading.Value
    if ($line -notmatch ('^###\s+' + $idPattern + '\s+\[(active|superseded|rejected|frozen)\]\s*$')) {
        Add-ValidationError "Malformed authority record heading: $line"
    } else {
        $parsed = [regex]::Match(
            $line,
            '^###\s+(?<id>' + $idPattern + ')\s+\[(?<status>active|superseded|rejected|frozen)\]\s*$'
        )
        $records += [pscustomobject]@{
            Id = $parsed.Groups['id'].Value
            Status = $parsed.Groups['status'].Value
        }
    }
}

foreach ($duplicate in @($records | Group-Object Id | Where-Object Count -gt 1)) {
    $locations = Get-MatchingLineNumbers $decisionText (
        '^###\s+' + [regex]::Escape($duplicate.Name) + '\s+'
    )
    Add-ValidationError "Authority ID has more than one canonical record: $($duplicate.Name) (DECISIONS.md lines $locations)."
}

foreach ($record in @($records | Where-Object Status -eq 'active')) {
    $blockCount = @($activeIds | Where-Object { $_ -eq $record.Id }).Count
    if ($blockCount -ne 1) {
        Add-ValidationError "Active record $($record.Id) must appear exactly once in the active block, found $blockCount."
    }
}

foreach ($id in @($activeIds | Select-Object -Unique)) {
    $requiredCount = @($requiredIds | Where-Object { $_ -eq $id }).Count
    if ($requiredCount -ne 1) {
        Add-ValidationWarning "Active authority $id is not in the current workset."
    }
}

$coverageText = if ($null -ne $coveragePath -and (Test-Path -LiteralPath $coveragePath -PathType Leaf)) {
    Read-Utf8File $coveragePath
} else {
    ''
}

foreach ($id in $requiredIds) {
    $activeCount = @($activeIds | Where-Object { $_ -eq $id }).Count
    if ($activeCount -ne 1) {
        Add-ValidationError "Manifest ID $id must appear exactly once in the active block, found $activeCount."
    }
    $coveragePattern = '(?m)^\|\s*' + [regex]::Escape($id) + '\s*\|'
    $coverageCount = [regex]::Matches($coverageText, $coveragePattern).Count
    if ($coverageCount -ne 1) {
        $locations = Get-MatchingLineNumbers $coverageText (
            '^\|\s*' + [regex]::Escape($id) + '\s*\|'
        )
        Add-ValidationError "Manifest ID $id must have exactly one row in $coverageRelative, found $coverageCount (lines $locations)."
    }
}

if ($sourceIds.Count -gt 0) {
    $sourceIndexPath = Join-Path $rootFull 'SOURCE_INDEX.md'
    if (-not (Test-Path -LiteralPath $sourceIndexPath -PathType Leaf)) {
        Add-ValidationError "Source IDs are listed but SOURCE_INDEX.md is missing."
    } else {
        $sourceText = Read-Utf8File $sourceIndexPath
        foreach ($id in $sourceIds) {
            $sourceRowPattern = '(?m)^\|\s*' + [regex]::Escape($id) + '\s*\|'
            $sourceCount = [regex]::Matches($sourceText, $sourceRowPattern).Count
            if ($sourceCount -ne 1) {
                $locations = Get-MatchingLineNumbers $sourceText (
                    '^\|\s*' + [regex]::Escape($id) + '\s*\|'
                )
                Add-ValidationError "Source ID $id must have exactly one row in SOURCE_INDEX.md, found $sourceCount (lines $locations)."
            }
        }
    }
}

$sourceIndexPath = Join-Path $rootFull 'SOURCE_INDEX.md'
if (Test-Path -LiteralPath $sourceIndexPath -PathType Leaf) {
    $sourceText = Read-Utf8File $sourceIndexPath
    $allSourceRows = [regex]::Matches(
        $sourceText,
        '(?m)^\|\s*(?<id>SRC-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)\s*\|'
    )
    $allSourceIds = @($allSourceRows | ForEach-Object { $_.Groups['id'].Value })
    foreach ($duplicate in @($allSourceIds | Group-Object | Where-Object Count -gt 1)) {
        $locations = Get-MatchingLineNumbers $sourceText (
            '^\|\s*' + [regex]::Escape($duplicate.Name) + '\s*\|'
        )
        Add-ValidationError "SOURCE_INDEX.md contains duplicate source rows for $($duplicate.Name) (lines $locations)."
    }
}

if ($warnings.Count -gt 0 -and -not $Quiet) {
    foreach ($message in $warnings) { Write-Host "WARNING: $message" }
}

if ($errors.Count -gt 0) {
    Write-Host "PPS validation: FAILED ($($errors.Count) error(s))"
    foreach ($message in $errors) { Write-Host "ERROR: $message" }
    exit 1
}

if (-not $Quiet) {
    Write-Host "PPS validation: OK"
    Write-Host "Profile: $profile"
    Write-Host "Package: $package"
    Write-Host "Required authority IDs: $($requiredIds.Count)"
    Write-Host "Required source IDs: $($sourceIds.Count)"
}
exit 0
