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

function Read-Utf8File([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-Field([string]$Text, [string]$Name) {
    $pattern = '(?m)^-\s+' + [regex]::Escape($Name) + ':\s*(.*?)\s*$'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) {
        Add-ValidationError "Expected exactly one '$Name' field, found $($matches.Count)."
        return $null
    }
    return $matches[0].Groups[1].Value.Trim()
}

function Resolve-ProjectFile([string]$ProjectRoot, [string]$RelativePath, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        Add-ValidationError "$Label must be a project-relative path: $RelativePath"
        return $null
    }
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-ValidationError "$Label escapes the project root: $RelativePath"
        return $null
    }
    return $candidate
}

function Get-ManifestIds([string]$Value, [string]$Prefix, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    $emptyTokens = @('none', 'n/a', 'na', 'empty')
    if ($emptyTokens -contains $Value.Trim().ToLowerInvariant()) {
        return @()
    }
    $pattern = '\b' + [regex]::Escape($Prefix) + '-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?\b'
    $ids = @([regex]::Matches($Value, $pattern) | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($ids.Count -eq 0) {
        Add-ValidationError "$Label is non-empty but contains no parseable $Prefix IDs: $Value"
    }
    return $ids
}

$rootFull = [System.IO.Path]::GetFullPath($Root)
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

$protocol = Get-Field $stateText 'Protocol'
$profile = Get-Field $stateText 'Profile'
$stage = Get-Field $stateText 'Stage'
$mainRelative = Get-Field $stateText 'Main'
$package = Get-Field $stateText 'Package'
$status = Get-Field $stateText 'Status'
$capsuleRelative = Get-Field $stateText 'Capsule'
$coverageRelative = Get-Field $stateText 'Coverage'
$blockers = Get-Field $stateText 'Blockers'
$next = Get-Field $stateText 'Next'
$updated = Get-Field $stateText 'Updated'

if ($protocol -ne 'PPS/1.0') {
    Add-ValidationError "Protocol must be PPS/1.0, found '$protocol'."
}
if ($profile -notin @('standard', 'evidence')) {
    Add-ValidationError "Profile must be standard or evidence, found '$profile'."
}
if ($status -notin @('active', 'review_pending', 'blocked', 'complete')) {
    Add-ValidationError "Unsupported Status '$status'."
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

$methodsValue = Get-Field $contextText 'Methods'
$factsValue = Get-Field $contextText 'Facts'
$decisionsValue = Get-Field $contextText 'Decisions'
$sourcesValue = Get-Field $contextText 'Sources'
$manifestCoverage = Get-Field $contextText 'Coverage'

$requiredIds = @()
$requiredIds += Get-ManifestIds $methodsValue 'M' 'Methods'
$requiredIds += Get-ManifestIds $factsValue 'F' 'Facts'
$requiredIds += Get-ManifestIds $decisionsValue 'D' 'Decisions'
$requiredIds = @($requiredIds | Select-Object -Unique)
$sourceIds = @(Get-ManifestIds $sourcesValue 'SRC' 'Sources')

if ($manifestCoverage -ne $coverageRelative) {
    Add-ValidationError "CONTEXT Coverage '$manifestCoverage' does not match PROJECT_STATE Coverage '$coverageRelative'."
}

$activeMatch = [regex]::Match(
    $decisionText,
    '<!-- PPS:ACTIVE:BEGIN -->(.*?)<!-- PPS:ACTIVE:END -->',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$activeIds = @()
if (-not $activeMatch.Success) {
    Add-ValidationError "DECISIONS.md is missing the marked active authority block."
} else {
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
foreach ($heading in $recordHeadings) {
    $line = $heading.Value
    if ($line -notmatch ('^###\s+' + $idPattern + '\s+\[(active|superseded|rejected|frozen)\]\s*$')) {
        Add-ValidationError "Malformed authority record heading: $line"
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
    if (-not [regex]::IsMatch($coverageText, $coveragePattern)) {
        Add-ValidationError "Manifest ID $id has no row in $coverageRelative."
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
            if (-not [regex]::IsMatch($sourceText, $sourceRowPattern)) {
                Add-ValidationError "Source ID $id has no row in SOURCE_INDEX.md."
            }
        }
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
