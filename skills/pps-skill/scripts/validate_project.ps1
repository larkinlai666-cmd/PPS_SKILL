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
    if (-not $candidate.Equals($rootFull, $comparison) -and
        -not $candidate.StartsWith($prefix, $comparison)) {
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

function Get-PathManifest(
    [string]$Value,
    [string]$Label,
    [bool]$MustExist,
    [string]$ProjectRoot
) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Trim().ToLowerInvariant() -eq 'none') {
        return @()
    }
    $raw = $Value.Trim()
    if ($raw.StartsWith(',') -or $raw.EndsWith(',') -or $raw.Contains(',,')) {
        Add-ValidationError "$Label must be 'none' or a comma-separated list of project-relative paths: $Value"
        return @()
    }
    $paths = @($raw.Split(',') | ForEach-Object { $_.Trim() })
    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            Add-ValidationError "$Label contains an empty path entry."
            continue
        }
        if ($path -eq '.' -or $path -match '[\*\?\[\]\{\}]') {
            Add-ValidationError "$Label path must name an exact file or bounded subdirectory, not '.' or a glob: $path"
            continue
        }
        if ($path.Length -gt 240) {
            Add-ValidationError "$Label path exceeds the 240-character limit: $path"
            continue
        }
        $resolved = Resolve-ProjectFile $ProjectRoot $path "$Label path"
        if ($MustExist -and $null -ne $resolved -and -not (Test-Path -LiteralPath $resolved)) {
            Add-ValidationError "$Label path does not exist: $path"
        }
    }
    foreach ($duplicate in @($paths | Group-Object | Where-Object Count -gt 1)) {
        Add-ValidationError "$Label contains duplicate paths: $($duplicate.Name)"
    }
    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ToolManifest([string]$Value, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Trim().ToLowerInvariant() -eq 'none') {
        return @()
    }
    $allowed = @(
        'git', 'gh', 'rg', 'node', 'python', 'powershell',
        'imagemagick', 'ffmpeg', 'pandoc', 'libreoffice', 'poppler', 'rclone'
    )
    $tools = @($Value.Split(',') | ForEach-Object { $_.Trim() })
    foreach ($tool in $tools) {
        if ($tool -notin $allowed) {
            Add-ValidationError "$Label contains unsupported tool '$tool'."
        }
    }
    foreach ($duplicate in @($tools | Group-Object | Where-Object Count -gt 1)) {
        Add-ValidationError "$Label contains duplicate tools: $($duplicate.Name)"
    }
    return @($tools | Where-Object { $_ -in $allowed })
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

$stateBytes = (Get-Item -LiteralPath $statePath).Length
$contextBytes = (Get-Item -LiteralPath $contextPath).Length
if ($stateBytes -gt 32768) {
    Add-ValidationError "PROJECT_STATE.md has $stateBytes bytes; hard limit is 32768."
}
if ($contextBytes -gt 32768) {
    Add-ValidationError "CONTEXT.md has $contextBytes bytes; hard limit is 32768."
}
if ($stateBytes -gt 32768 -or $contextBytes -gt 32768) {
    Write-Host "PPS validation: FAILED ($($errors.Count) error(s))"
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

if ($protocol -notin @('PPS/1.0', 'PPS/1.1', 'PPS/1.2')) {
    Add-ValidationError "Protocol must be PPS/1.0, PPS/1.1, or PPS/1.2, found '$protocol'."
}
if ($profile -notin @('standard', 'evidence')) {
    Add-ValidationError "Profile must be standard or evidence, found '$profile'."
}
$isPps11Plus = $protocol -in @('PPS/1.1', 'PPS/1.2')
$isPps12 = $protocol -eq 'PPS/1.2'
$mode = $null
$mapRelative = $null
$environmentRelative = $null
if ($isPps11Plus) {
    $mode = Get-SectionField $hotStateText $stateText 'Hot State' 'Mode'
    $mapRelative = Get-SectionField $hotStateText $stateText 'Hot State' 'Map'
    $environmentRelative = Get-SectionField $hotStateText $stateText 'Hot State' 'Environment'
    if ($mode -notin @('document', 'software', 'hybrid')) {
        Add-ValidationError "Mode must be document, software, or hybrid, found '$mode'."
    }
    foreach ($relative in @(
        'scripts/environment_doctor.ps1',
        'scripts/environment_doctor.sh',
        'scripts/resume_packet.ps1',
        'scripts/resume_packet.sh'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull $relative) -PathType Leaf)) {
            Add-ValidationError "$protocol is missing required file: $relative"
        }
    }
}
if ($isPps12) {
    foreach ($relative in @(
        'EVENTS.md',
        'scripts/verify_gate.ps1',
        'scripts/verify_gate.sh',
        'scripts/project_verify.ps1',
        'scripts/project_verify.sh',
        'scripts/append_event.ps1',
        'scripts/append_event.sh'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull $relative) -PathType Leaf)) {
            Add-ValidationError "PPS/1.2 is missing required file: $relative"
        }
    }
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
if ($null -ne $mainPath) {
    $mainExists = if ($isPps11Plus -and $mode -ne 'document') {
        Test-Path -LiteralPath $mainPath
    } else {
        Test-Path -LiteralPath $mainPath -PathType Leaf
    }
    if (-not $mainExists) { Add-ValidationError "Main path does not exist: $mainRelative" }
}
foreach ($pair in @(
    @{ Name = 'Capsule'; Path = $capsulePath; Relative = $capsuleRelative },
    @{ Name = 'Coverage'; Path = $coveragePath; Relative = $coverageRelative }
)) {
    if ($null -ne $pair.Path -and -not (Test-Path -LiteralPath $pair.Path -PathType Leaf)) {
        Add-ValidationError "$($pair.Name) file does not exist: $($pair.Relative)"
    }
}

if ($capsuleRelative -ne 'CONTEXT.md') {
    Add-ValidationError "$protocol requires Capsule: CONTEXT.md."
}
if ($profile -eq 'standard') {
    if ($isPps12) {
        if ($coverageRelative -notin @('CONTEXT.md', 'docs/coverage.md')) {
            Add-ValidationError "The PPS/1.2 standard profile requires Coverage: CONTEXT.md or docs/coverage.md."
        }
    } elseif ($coverageRelative -ne 'CONTEXT.md') {
        Add-ValidationError "The standard profile requires Coverage: CONTEXT.md."
    }
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
$assetsFieldMatches = [regex]::Matches($worksetText, '(?m)^-\s*Assets:\s*(.*?)\s*$')
if ($assetsFieldMatches.Count -eq 0) {
    $assetsValue = 'none'
    if ($isPps12) {
        Add-ValidationError "PPS/1.2 requires an explicit Assets field in the Workset Manifest; use 'none' when empty."
    } elseif ($protocol -eq 'PPS/1.1') {
        Add-ValidationWarning "Workset Manifest has no Assets field; treating it as 'none' for PPS/1.1 compatibility."
    }
} elseif ($assetsFieldMatches.Count -eq 1) {
    $assetsValue = $assetsFieldMatches[0].Groups[1].Value.Trim()
} else {
    Add-ValidationError "Expected at most one 'Assets' field in 'Workset Manifest', found $($assetsFieldMatches.Count)."
    $assetsValue = 'none'
}
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
$assetIds = @(Get-ManifestIds $assetsValue 'A' 'Assets')

$components = @()
$readPaths = @()
$writePaths = @()
if ($isPps11Plus) {
    $componentsValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Components'
    $readValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Read'
    $writeValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Write'
    $verifyValue = Get-SectionField $worksetText $contextText 'Workset Manifest' 'Verify'
    $components = @(Get-ManifestIds $componentsValue 'C' 'Components')
    $readPaths = @(Get-PathManifest $readValue 'Read' $true $rootFull)
    $writePaths = @(Get-PathManifest $writeValue 'Write' $false $rootFull)
    if ($components.Count -eq 0) { Add-ValidationError 'Components cannot be empty; name at least one C-* boundary.' }
    if ($readPaths.Count -eq 0) { Add-ValidationError 'Read cannot be empty; declare the bounded input paths.' }
    if ($writePaths.Count -eq 0) { Add-ValidationError 'Write cannot be empty; declare the bounded output paths.' }
    if ([string]::IsNullOrWhiteSpace($verifyValue) -or $verifyValue -eq 'none') {
        Add-ValidationError "Verify cannot be empty or 'none'."
    }
    if ($components.Count -gt 30) {
        Add-ValidationError "Components contains $($components.Count) IDs; hard limit is 30."
    }
    if ($requiredIds.Count -gt 60) {
        Add-ValidationError "Methods, Facts, and Decisions contain $($requiredIds.Count) IDs; hard limit is 60."
    }
    if ($sourceIds.Count -gt 30) {
        Add-ValidationError "Sources contains $($sourceIds.Count) IDs; hard limit is 30."
    }
    if ($assetIds.Count -gt 30) {
        Add-ValidationError "Assets contains $($assetIds.Count) IDs; hard limit is 30."
    }
    $pathCount = $readPaths.Count + $writePaths.Count
    if ($pathCount -gt 30) {
        Add-ValidationError "Read and Write contain $pathCount paths; hard limit is 30."
    } elseif ($pathCount -gt 12) {
        Add-ValidationWarning "Read and Write contain $pathCount paths; compact target is 12."
    }
}

$assetManifestPath = Join-Path $rootFull 'ASSETS.md'
if ($assetIds.Count -gt 0 -or (Test-Path -LiteralPath $assetManifestPath -PathType Leaf)) {
    $assetScriptPs = Join-Path $rootFull 'scripts/asset_check.ps1'
    $assetScriptSh = Join-Path $rootFull 'scripts/asset_check.sh'
    if (-not (Test-Path -LiteralPath $assetManifestPath -PathType Leaf)) {
        Add-ValidationError 'Workset lists assets but ASSETS.md is missing.'
    }
    if (-not (Test-Path -LiteralPath $assetScriptPs -PathType Leaf)) {
        Add-ValidationError 'Asset registry requires scripts/asset_check.ps1.'
    }
    if (-not (Test-Path -LiteralPath $assetScriptSh -PathType Leaf)) {
        Add-ValidationError 'Asset registry requires scripts/asset_check.sh.'
    }
    if ((Test-Path -LiteralPath $assetManifestPath -PathType Leaf) -and
        (Test-Path -LiteralPath $assetScriptPs -PathType Leaf)) {
        $assetEngine = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -eq $assetEngine) {
            $assetEngine = Get-Command powershell -ErrorAction SilentlyContinue
        }
        if ($null -eq $assetEngine) {
            Add-ValidationError 'PowerShell asset registry validation is unavailable.'
        } else {
            $assetOutput = @(
                & $assetEngine.Source -NoProfile -ExecutionPolicy Bypass -File `
                    $assetScriptPs -Root $rootFull -Structure 2>&1
            )
            if ($LASTEXITCODE -ne 0) {
                $assetErrors = @($assetOutput | Where-Object { "$_" -like 'ERROR:*' })
                if ($assetErrors.Count -eq 0) {
                    Add-ValidationError 'Asset registry structural validation failed.'
                } else {
                    foreach ($assetError in $assetErrors) {
                        $assetErrorText = [string]$assetError
                        Add-ValidationError "Asset registry: $($assetErrorText.Substring(7))"
                    }
                }
            }
        }
    }
}

if ($manifestCoverage -ne $coverageRelative) {
    Add-ValidationError "CONTEXT Coverage '$manifestCoverage' does not match PROJECT_STATE Coverage '$coverageRelative'."
}
if ($contextPackage -ne $package) {
    Add-ValidationError "CONTEXT package '$contextPackage' does not match PROJECT_STATE Package '$package'."
}
if ([string]::IsNullOrWhiteSpace($excludedValue)) {
    Add-ValidationError "Excluded cannot be empty; use 'none' when nothing is excluded."
}

if ($isPps11Plus) {
    $mapPath = Resolve-ProjectFile $rootFull $mapRelative 'Map'
    $environmentPath = Resolve-ProjectFile $rootFull $environmentRelative 'Environment'
    if ($null -ne $mapPath -and -not (Test-Path -LiteralPath $mapPath -PathType Leaf)) {
        Add-ValidationError "Project map file does not exist: $mapRelative"
    }
    if ($null -ne $environmentPath -and -not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
        Add-ValidationError "Environment manifest does not exist: $environmentRelative"
    }

    if ($null -ne $mapPath -and (Test-Path -LiteralPath $mapPath -PathType Leaf)) {
        $mapBytes = (Get-Item -LiteralPath $mapPath).Length
        if ($mapBytes -gt 65536) {
            Add-ValidationError "$mapRelative has $mapBytes bytes; hard limit is 65536."
            $mapText = ''
        } else {
            $mapText = Read-Utf8File $mapPath
        }
        $mapLineCount = @($mapText -split "`r?`n").Count
        if ($mapLineCount -gt 240) {
            Add-ValidationError "$mapRelative has $mapLineCount lines; hard limit is 240."
        } elseif ($mapLineCount -gt 160) {
            Add-ValidationWarning "$mapRelative has $mapLineCount lines; compact target is 160."
        }
        $componentRowPattern = '(?m)^\|\s*(?<id>C-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)\s*\|\s*(?<root>[^|\r\n]+?)\s*\|\s*(?<responsibility>[^|\r\n]+?)\s*\|\s*(?<interfaces>[^|\r\n]+?)\s*\|\s*(?<verification>[^|\r\n]+?)\s*\|\s*$'
        $componentRows = [regex]::Matches($mapText, $componentRowPattern)
        $componentShapedLines = [regex]::Matches($mapText, '(?m)^\|\s*C-[^\r\n]*$')
        foreach ($shapedLine in $componentShapedLines) {
            $shapedMatch = [regex]::Match($shapedLine.Value, $componentRowPattern)
            $emptyCell = if ($shapedMatch.Success) {
                @(
                    @('root', 'responsibility', 'interfaces', 'verification') |
                        Where-Object {
                            [string]::IsNullOrWhiteSpace($shapedMatch.Groups[$_].Value)
                        }
                )
            } else {
                @()
            }
            if (-not $shapedMatch.Success -or $emptyCell.Count -gt 0) {
                $lineNumber = Get-MatchingLineNumbers $mapText (
                    '^' + [regex]::Escape($shapedLine.Value) + '$'
                )
                Add-ValidationError "Malformed component row in $mapRelative at line ${lineNumber}: $($shapedLine.Value)"
            }
        }
        $mapComponentIds = @($componentRows | ForEach-Object { $_.Groups['id'].Value })
        foreach ($duplicate in @($mapComponentIds | Group-Object | Where-Object Count -gt 1)) {
            $locations = Get-MatchingLineNumbers $mapText (
                '^\|\s*' + [regex]::Escape($duplicate.Name) + '\s*\|'
            )
            Add-ValidationError "$mapRelative contains duplicate component rows for $($duplicate.Name) (lines $locations)."
        }
        foreach ($row in $componentRows) {
            $componentId = $row.Groups['id'].Value
            $componentRoot = $row.Groups['root'].Value.Trim()
            $componentRootPath = Resolve-ProjectFile $rootFull $componentRoot "Component $componentId Root"
            if ($null -ne $componentRootPath -and -not (Test-Path -LiteralPath $componentRootPath)) {
                Add-ValidationError "Component $componentId Root does not exist: $componentRoot"
            }
        }
        foreach ($component in $components) {
            $rows = @($componentRows | Where-Object { $_.Groups['id'].Value -eq $component })
            if ($rows.Count -ne 1) {
                Add-ValidationError "Component ID $component must have exactly one row in $mapRelative, found $($rows.Count)."
            }
        }
    }

    if ($null -ne $environmentPath -and (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
        $environmentBytes = (Get-Item -LiteralPath $environmentPath).Length
        if ($environmentBytes -gt 16384) {
            Add-ValidationError "$environmentRelative has $environmentBytes bytes; hard limit is 16384."
            $environmentText = ''
        } else {
            $environmentText = Read-Utf8File $environmentPath
        }
        $toolchainText = Get-Section $environmentText 'Toolchain Manifest'
        $requiredToolsValue = Get-SectionField $toolchainText $environmentText 'Toolchain Manifest' 'Required'
        $optionalToolsValue = Get-SectionField $toolchainText $environmentText 'Toolchain Manifest' 'Optional'
        $dependencyMatches = [regex]::Matches(
            $toolchainText,
            '(?m)^-\s*Dependency manifests:\s*(.*?)\s*$'
        )
        if ($dependencyMatches.Count -eq 0) {
            $dependencyManifestsValue = 'none'
        } elseif ($dependencyMatches.Count -eq 1) {
            $dependencyManifestsValue = $dependencyMatches[0].Groups[1].Value.Trim()
        } else {
            Add-ValidationError "Expected at most one 'Dependency manifests' field in 'Toolchain Manifest', found $($dependencyMatches.Count)."
            $dependencyManifestsValue = 'none'
        }
        $managerValue = Get-SectionField $toolchainText $environmentText 'Toolchain Manifest' 'Package manager'
        $installPolicy = Get-SectionField $toolchainText $environmentText 'Toolchain Manifest' 'Install policy'
        $requiredTools = @(Get-ToolManifest $requiredToolsValue 'Required tools')
        $null = @(Get-ToolManifest $optionalToolsValue 'Optional tools')
        $null = @(Get-PathManifest $dependencyManifestsValue 'Dependency manifest' $true $rootFull)
        if ($requiredTools.Count -eq 0) { Add-ValidationError 'Required tools cannot be empty; include at least git.' }
        if ('git' -notin $requiredTools) { Add-ValidationError 'Required tools must include git.' }
        if ($managerValue -notin @('auto', 'brew', 'winget', 'apt', 'dnf', 'pacman', 'manual')) {
            Add-ValidationError "Unsupported package manager policy '$managerValue'."
        }
        if ($installPolicy -ne 'project-local-first') {
            Add-ValidationError 'Install policy must be project-local-first.'
        }
    }
}

function Test-TaskCapsule([string]$CapsulePath, [string]$TaskId, [string]$TaskRole) {
    $script:taskCapsuleWritePaths = @()
    $script:taskCapsuleReadPaths = @()
    $script:taskCapsuleAuthorityIds = @()
    $script:taskCapsuleSourceIds = @()
    $script:taskCapsuleAssetIds = @()
    $script:taskCapsuleComponentIds = @()
    $capsuleRel = $CapsulePath.Substring($rootFull.Length).TrimStart('\', '/')
    $capsuleBytes = (Get-Item -LiteralPath $CapsulePath).Length
    if ($capsuleBytes -gt 32768) {
        Add-ValidationError "Task $TaskId capsule $capsuleRel has $capsuleBytes bytes; hard limit is 32768."
    }
    $capsuleText = Read-Utf8File $CapsulePath
    $capsuleLines = @($capsuleText -split "`r?`n").Count
    if ($capsuleLines -gt 80) {
        Add-ValidationError "Task $TaskId capsule $capsuleRel has $capsuleLines lines; hard limit is 80."
    } elseif ($capsuleLines -gt 60) {
        Add-ValidationWarning "Task $TaskId capsule $capsuleRel has $capsuleLines lines; compact target is 60."
    }
    $sectionMatches = [regex]::Matches(
        $capsuleText, '(?m)^##\s+Workset Manifest\s*$')
    if ($sectionMatches.Count -ne 1) {
        Add-ValidationError "Task $TaskId capsule $capsuleRel must contain exactly one 'Workset Manifest' section, found $($sectionMatches.Count)."
        return
    }
    $sectionBody = [regex]::Match(
        $capsuleText,
        '(?ms)^##\s+Workset Manifest\s*\r?\n(?<body>.*?)(?=^##\s+|\z)'
    ).Groups['body'].Value
    foreach ($fieldName in @(
        'Methods', 'Facts', 'Decisions', 'Sources', 'Assets',
        'Components', 'Read', 'Write', 'Verify', 'Excluded', 'Coverage'
    )) {
        $fieldMatches = [regex]::Matches(
            $sectionBody,
            '(?m)^-\s*' + [regex]::Escape($fieldName) + ':\s*(.*?)\s*$')
        if ($fieldMatches.Count -ne 1) {
            Add-ValidationError "Task $TaskId capsule $capsuleRel must declare exactly one '$fieldName' field (use 'none' when empty), found $($fieldMatches.Count)."
            continue
        }
        $fieldValue = $fieldMatches[0].Groups[1].Value
        switch ($fieldName) {
            'Methods' { $script:taskCapsuleAuthorityIds += @(Get-ManifestIds $fieldValue 'M' "Task $TaskId Methods") }
            'Facts' { $script:taskCapsuleAuthorityIds += @(Get-ManifestIds $fieldValue 'F' "Task $TaskId Facts") }
            'Decisions' { $script:taskCapsuleAuthorityIds += @(Get-ManifestIds $fieldValue 'D' "Task $TaskId Decisions") }
            'Sources' { $script:taskCapsuleSourceIds += @(Get-ManifestIds $fieldValue 'SRC' "Task $TaskId Sources") }
            'Assets' { $script:taskCapsuleAssetIds += @(Get-ManifestIds $fieldValue 'A' "Task $TaskId Assets") }
            'Components' { $script:taskCapsuleComponentIds += @(Get-ManifestIds $fieldValue 'C' "Task $TaskId Components") }
            'Read' { $script:taskCapsuleReadPaths = @(Get-PathManifest $fieldValue "Task $TaskId Read" $true $rootFull) }
            'Write' {
                $script:taskCapsuleWritePaths = @(
                    Get-PathManifest $fieldValue "Task $TaskId Write" $false $rootFull)
                if ($script:taskCapsuleWritePaths.Count -eq 0) {
                    Add-ValidationError "Task $TaskId capsule Write cannot be empty or 'none'; declare the bounded output paths."
                }
            }
            'Verify' {
                if ([string]::IsNullOrWhiteSpace($fieldValue) -or $fieldValue -eq 'none') {
                    Add-ValidationError "Task $TaskId capsule Verify cannot be empty or 'none'."
                }
            }
            'Excluded' {
                if ([string]::IsNullOrWhiteSpace($fieldValue)) {
                    Add-ValidationError "Task $TaskId capsule Excluded cannot be empty; use 'none'."
                }
            }
            'Coverage' {
                if ([string]::IsNullOrWhiteSpace($fieldValue)) {
                    Add-ValidationError "Task $TaskId capsule Coverage cannot be empty."
                }
            }
        }
    }
    $capsulePathCount = $script:taskCapsuleReadPaths.Count + $script:taskCapsuleWritePaths.Count
    if ($capsulePathCount -gt 30) {
        Add-ValidationError "Task $TaskId Read and Write contain $capsulePathCount paths; hard limit is 30."
    }
    if ($script:taskCapsuleAuthorityIds.Count -gt 60) {
        Add-ValidationError "Task $TaskId Methods, Facts, and Decisions contain $($script:taskCapsuleAuthorityIds.Count) IDs; hard limit is 60."
    }
}

function Test-CheckpointResolvable([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'none') { return $false }
    if ($Value -eq 'lineage_incomplete') { return $true }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { return $false }
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 promotes native stderr to error records; a
        # missing object is a normal probe result, not a terminating error.
        $ErrorActionPreference = 'SilentlyContinue'
        $null = @(& $git.Source -C $rootFull rev-parse --is-inside-work-tree 2>$null)
        $insideCode = $LASTEXITCODE
        if ($insideCode -ne 0) { return $false }
        $null = @(& $git.Source -C $rootFull cat-file -e "$Value^{commit}" 2>$null)
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

if ($isPps12) {
    $agentsPath = Join-Path $rootFull 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
        $agentsText = Read-Utf8File $agentsPath
        $redLineMatches = [regex]::Matches($agentsText, '(?m)^##\s+Red Lines\s*$')
        $allH2 = [regex]::Matches($agentsText, '(?m)^##\s+(?<title>.+?)\s*$')
        $firstH2 = if ($allH2.Count -gt 0) { $allH2[0].Groups['title'].Value } else { '' }
        if ($redLineMatches.Count -eq 0) {
            Add-ValidationError "PPS/1.2 requires a '## Red Lines' section in AGENTS.md."
        } elseif ($redLineMatches.Count -ne 1) {
            Add-ValidationError "AGENTS.md must contain exactly one '## Red Lines' section, found $($redLineMatches.Count)."
        } elseif ($firstH2 -ne 'Red Lines') {
            Add-ValidationError "The '## Red Lines' section exists but is not the first H2 section of AGENTS.md (found '## $firstH2' first); L0 must meet red lines before any other rule."
        }
    }

    $eventsPath = Join-Path $rootFull 'EVENTS.md'
    if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
        $eventsText = Read-Utf8File $eventsPath
        if ($eventsText -notmatch '(?m)^##\s+Events\s*$') {
            Add-ValidationError "EVENTS.md must contain a '## Events' section."
        }
        $eventsSection = [regex]::Match(
            $eventsText,
            '(?ms)^##\s+Events\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
        if ($eventsSection.Success) {
            $eventPattern = '^- \d{4}-\d{2}-\d{2}: \[PKG-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?\] [^|]+\| files: [^|]+\| verify: [^|]+\| pending: [^|]+$'
            foreach ($line in @($eventsSection.Groups['body'].Value -split "`r?`n")) {
                if ($line -notmatch '^- ') { continue }
                if ($line -notmatch $eventPattern) {
                    Add-ValidationError "Malformed event line in EVENTS.md: $line"
                }
            }
        }
        $eventsLineCount = @($eventsText -split "`r?`n").Count
        if ($eventsLineCount -gt 200) {
            Add-ValidationWarning "EVENTS.md has $eventsLineCount lines; archive older months to docs/events-archive/."
        }
    }

    $proposalSection = [regex]::Match(
        $contextText,
        '(?ms)^##\s+Proposals\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if ($proposalSection.Success) {
        foreach ($line in @($proposalSection.Groups['body'].Value -split "`r?`n")) {
            if ($line -notmatch '^- P-') { continue }
            $proposalId = [regex]::Match($line, 'P-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?').Value
            $openedMatch = [regex]::Match($line, '\(opened (\d{4}-\d{2}-\d{2})\)')
            if (-not $openedMatch.Success) {
                Add-ValidationWarning "Proposal $proposalId has no '(opened YYYY-MM-DD)' date; aging cannot be tracked."
                continue
            }
            $openedDate = [datetime]::ParseExact(
                $openedMatch.Groups[1].Value, 'yyyy-MM-dd',
                [System.Globalization.CultureInfo]::InvariantCulture)
            if (([DateTime]::UtcNow.Date - $openedDate.Date).TotalDays -gt 7) {
                if ($next -notmatch [regex]::Escape($proposalId)) {
                    Add-ValidationWarning "Proposal $proposalId has been pending for more than 7 days and is not restated in Next; state kept, closed, or split."
                }
            }
        }
    }

    $writerMatch = [regex]::Match($hotStateText, '(?m)^-\s+Writer:\s*(.*?)\s*$')
    $writerValue = if ($writerMatch.Success) { $writerMatch.Groups[1].Value } else { '' }
    $taskIndexPath = Join-Path $rootFull 'TASK_INDEX.md'
    $canonicalFiles = @(
        'PROJECT_STATE.md', 'DECISIONS.md', 'CONTEXT.md', 'EVENTS.md',
        'TASK_INDEX.md', 'MERGES.md', 'PROJECT_MAP.md', 'ENVIRONMENT.md',
        'docs/coverage.md', 'docs/CURRENT_REVIEW_EVIDENCE.md'
    )
    # Canonical is a semantic role, not a fixed filename list: the Hot State
    # declarations decide where content truth actually lives.
    foreach ($hotCanonical in @($mainRelative, $coverageRelative, $mapRelative, $environmentRelative)) {
        if (-not [string]::IsNullOrWhiteSpace($hotCanonical) -and
            $hotCanonical -ne 'none' -and
            $hotCanonical -notin $canonicalFiles) {
            $canonicalFiles += $hotCanonical
        }
    }
    $allTaskAuthorityRefs = @()
    $allTaskComponentRefs = @()
    $allTaskSourceRefs = @()
    $allTaskAssetRefs = @()
    $taskIds = @()
    $terminalTasks = @()
    $outputRoots = @()
    if (Test-Path -LiteralPath $taskIndexPath -PathType Leaf) {
        $taskIndexText = Read-Utf8File $taskIndexPath
        $taskHeadings = [regex]::Matches(
            $taskIndexText,
            '(?m)^###\s+(?<id>T-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)\s*$')
        $taskIds = @($taskHeadings | ForEach-Object { $_.Groups['id'].Value })
        foreach ($duplicate in @($taskIds | Group-Object | Where-Object Count -gt 1)) {
            Add-ValidationError "TASK_INDEX.md contains duplicate task blocks for $($duplicate.Name)."
        }
        $activeIntegrators = @()
        foreach ($taskId in @($taskIds | Select-Object -Unique)) {
            $blockMatch = [regex]::Match(
                $taskIndexText,
                '(?ms)^###\s+' + [regex]::Escape($taskId) + '\s*\r?\n(?<body>.*?)(?=^###\s+|\z)')
            $body = if ($blockMatch.Success) { $blockMatch.Groups['body'].Value } else { '' }
            $taskRole = [regex]::Match($body, '(?m)^-\s+Role:\s*(.*?)\s*$').Groups[1].Value
            $taskStatus = [regex]::Match($body, '(?m)^-\s+Status:\s*(.*?)\s*$').Groups[1].Value
            $taskCapsule = [regex]::Match($body, '(?m)^-\s+Capsule:\s*(.*?)\s*$').Groups[1].Value
            $taskOutputRoot = [regex]::Match($body, '(?m)^-\s+Output Root:\s*(.*?)\s*$').Groups[1].Value
            if ($taskRole -notin @('integrator', 'worker', 'consumer')) {
                Add-ValidationError "Task $taskId has invalid Role '$taskRole'."
            }
            if ($taskStatus -notin @('active', 'handoff_ready', 'integrated', 'rejected', 'deferred', 'archived')) {
                Add-ValidationError "Task $taskId has invalid Status '$taskStatus'."
            }
            if ($taskStatus -in @('integrated', 'deferred', 'rejected')) {
                $terminalTasks += [pscustomobject]@{ Id = $taskId; Status = $taskStatus }
            }
            if ($taskRole -eq 'integrator' -and $taskStatus -eq 'active') {
                $activeIntegrators += $taskId
            }
            if ($taskStatus -ne 'archived') {
                if ([string]::IsNullOrWhiteSpace($taskCapsule)) {
                    Add-ValidationError "Task $taskId has no Capsule field."
                } else {
                    $taskCapsulePath = Resolve-ProjectFile $rootFull $taskCapsule "Task $taskId Capsule"
                    if ($null -eq $taskCapsulePath -or -not (Test-Path -LiteralPath $taskCapsulePath -PathType Leaf)) {
                        Add-ValidationError "Task $taskId capsule does not exist: $taskCapsule"
                    } elseif ($taskRole -eq 'integrator') {
                        # The integrator writes canonical truth, so its capsule
                        # IS the canonical capsule. A separate integrator
                        # capsule would be a second, unvalidated grant channel.
                        if ($taskCapsule -ne 'CONTEXT.md') {
                            Add-ValidationError "Task $taskId (integrator) capsule must be CONTEXT.md itself, found '$taskCapsule'; a separate integrator capsule would bypass Workset validation."
                        }
                    } elseif ($taskRole -ne 'integrator') {
                        Test-TaskCapsule $taskCapsulePath $taskId $taskRole
                        foreach ($refId in $script:taskCapsuleAuthorityIds) {
                            $allTaskAuthorityRefs += [pscustomobject]@{ Task = $taskId; Id = $refId }
                        }
                        foreach ($refId in $script:taskCapsuleComponentIds) {
                            $allTaskComponentRefs += [pscustomobject]@{ Task = $taskId; Id = $refId }
                        }
                        foreach ($refId in $script:taskCapsuleSourceIds) {
                            $allTaskSourceRefs += [pscustomobject]@{ Task = $taskId; Id = $refId }
                        }
                        foreach ($refId in $script:taskCapsuleAssetIds) {
                            $allTaskAssetRefs += [pscustomobject]@{ Task = $taskId; Id = $refId }
                        }
                        foreach ($writeRel in $script:taskCapsuleWritePaths) {
                            if ($writeRel -in $canonicalFiles) {
                                Add-ValidationError "Task $taskId ($taskRole) declares canonical file '$writeRel' in its Write set."
                            }
                            # worker/consumer writes land only inside the task's
                            # own Output Root; Write is not a second grant channel.
                            if (-not [string]::IsNullOrWhiteSpace($taskOutputRoot) -and $taskOutputRoot -ne 'none') {
                                if ($writeRel -ne $taskOutputRoot -and
                                    -not $writeRel.StartsWith("$taskOutputRoot/")) {
                                    Add-ValidationError "Task $taskId ($taskRole) Write path '$writeRel' is outside its Output Root '$taskOutputRoot'; worker and consumer tasks write only inside their own Output Root."
                                }
                            }
                        }
                    }
                }
                if ($taskRole -ne 'integrator') {
                    if ([string]::IsNullOrWhiteSpace($taskOutputRoot) -or $taskOutputRoot -eq 'none') {
                        Add-ValidationError "Task $taskId ($taskRole) requires a bounded Output Root."
                    } else {
                        $resolvedRoot = Resolve-ProjectFile $rootFull $taskOutputRoot "Task $taskId Output Root"
                        if ($null -ne $resolvedRoot) {
                            if ($taskOutputRoot -notmatch '^local-task-output/.+') {
                                Add-ValidationError "Task $taskId Output Root must live under local-task-output/, found '$taskOutputRoot'."
                            }
                            foreach ($existing in $outputRoots) {
                                if ($taskOutputRoot -eq $existing.Root -or
                                    $taskOutputRoot.StartsWith($existing.Root + '/') -or
                                    $existing.Root.StartsWith($taskOutputRoot + '/')) {
                                    Add-ValidationError "Task $taskId Output Root '$taskOutputRoot' overlaps Task $($existing.Id) Output Root '$($existing.Root)'."
                                }
                            }
                            $outputRoots += [pscustomobject]@{ Id = $taskId; Root = $taskOutputRoot }
                        }
                    }
                }
            }
        }
        if ($activeIntegrators.Count -ne 1) {
            Add-ValidationError "TASK_INDEX.md must have exactly one active integrator, found $($activeIntegrators.Count)."
        }
        if ([string]::IsNullOrWhiteSpace($writerValue)) {
            Add-ValidationError "Multitask projects require a 'Writer:' field in Hot State."
        } elseif ($activeIntegrators.Count -eq 1 -and $writerValue -ne $activeIntegrators[0]) {
            Add-ValidationError "Hot State Writer '$writerValue' does not match the active integrator '$($activeIntegrators[0])'."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($writerValue)) {
        Add-ValidationError "Hot State declares Writer '$writerValue' but TASK_INDEX.md does not exist."
    }

    $mergesPath = Join-Path $rootFull 'MERGES.md'
    $mergeRecords = @()
    if (Test-Path -LiteralPath $mergesPath -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $taskIndexPath -PathType Leaf)) {
            Add-ValidationError "MERGES.md exists but TASK_INDEX.md does not; merge receipts require the task registry."
        }
        $mergesText = Read-Utf8File $mergesPath
        $mergeHeadings = [regex]::Matches(
            $mergesText,
            '(?m)^###\s+(?<id>MERGE-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)\s*$')
        $mergeIds = @($mergeHeadings | ForEach-Object { $_.Groups['id'].Value })
        foreach ($duplicate in @($mergeIds | Group-Object | Where-Object Count -gt 1)) {
            Add-ValidationError "MERGES.md contains duplicate receipt blocks for $($duplicate.Name)."
        }
        foreach ($mergeId in @($mergeIds | Select-Object -Unique)) {
            $blockMatch = [regex]::Match(
                $mergesText,
                '(?ms)^###\s+' + [regex]::Escape($mergeId) + '\s*\r?\n(?<body>.*?)(?=^###\s+|\z)')
            $body = if ($blockMatch.Success) { $blockMatch.Groups['body'].Value } else { '' }
            $fields = @{}
            foreach ($fieldName in @(
                'Target Package', 'Source Tasks', 'Relation', 'Accepted',
                'Rejected', 'Deferred', 'Base Checkpoint', 'Result Checkpoint',
                'Approval', 'Verification', 'Status'
            )) {
                $fieldMatch = [regex]::Match(
                    $body, '(?m)^-\s+' + [regex]::Escape($fieldName) + ':\s*(.*?)\s*$')
                $fields[$fieldName] = if ($fieldMatch.Success) { $fieldMatch.Groups[1].Value } else { '' }
                if ([string]::IsNullOrWhiteSpace($fields[$fieldName])) {
                    Add-ValidationError "Merge receipt $mergeId is missing the '$fieldName' field."
                }
            }
            if ($fields['Relation'] -notin @('absorbs', 'layers_on', 'consumes_only', 'deferred', 'supersedes', 'rejected', 'rollback_to')) {
                Add-ValidationError "Merge receipt $mergeId has invalid Relation '$($fields['Relation'])'."
            }
            if ($fields['Status'] -notin @('pending', 'integrated', 'deferred', 'rejected')) {
                Add-ValidationError "Merge receipt $mergeId has invalid Status '$($fields['Status'])'."
            }
            # Status and Relation must tell the same story.
            switch ($fields['Status']) {
                'integrated' {
                    if ($fields['Relation'] -notin @('absorbs', 'layers_on', 'consumes_only', 'supersedes', 'rollback_to')) {
                        Add-ValidationError "Merge receipt $mergeId Status 'integrated' is incompatible with Relation '$($fields['Relation'])'."
                    }
                }
                'deferred' {
                    if ($fields['Relation'] -ne 'deferred') {
                        Add-ValidationError "Merge receipt $mergeId Status 'deferred' requires Relation 'deferred', found '$($fields['Relation'])'."
                    }
                }
                'rejected' {
                    if ($fields['Relation'] -ne 'rejected') {
                        Add-ValidationError "Merge receipt $mergeId Status 'rejected' requires Relation 'rejected', found '$($fields['Relation'])'."
                    }
                }
            }
            if ($fields['Target Package'] -notmatch '^PKG-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') {
                Add-ValidationError "Merge receipt $mergeId Target Package must be a PKG-* ID, found '$($fields['Target Package'])'."
            }
            # The Target Package must be a real package: the current one or
            # one recorded in the chronicle.
            if ($fields['Target Package'] -match '^PKG-' -and $fields['Target Package'] -ne $package) {
                $eventsFile = Join-Path $rootFull 'EVENTS.md'
                $targetKnown = $false
                if (Test-Path -LiteralPath $eventsFile -PathType Leaf) {
                    $eventsBody = Read-Utf8File $eventsFile
                    if ($eventsBody -match [regex]::Escape('[' + $fields['Target Package'] + ']')) {
                        $targetKnown = $true
                    }
                }
                if (-not $targetKnown) {
                    Add-ValidationError "Merge receipt $mergeId Target Package '$($fields['Target Package'])' is neither the current package '$package' nor recorded in EVENTS.md."
                }
            }
            if ($fields['Status'] -eq 'integrated') {
                # An integration without accepted content, approval, or
                # verification is a claim, not a receipt.
                if ([string]::IsNullOrWhiteSpace($fields['Accepted']) -or $fields['Accepted'] -eq 'none') {
                    Add-ValidationError "Merge receipt $mergeId is 'integrated' with an empty Accepted set; an integration that accepted nothing is not an integration."
                }
                if ([string]::IsNullOrWhiteSpace($fields['Approval']) -or $fields['Approval'] -eq 'none') {
                    Add-ValidationError "Merge receipt $mergeId is 'integrated' without an Approval decision; name the D-* record that authorized this merge."
                }
                if ([string]::IsNullOrWhiteSpace($fields['Verification']) -or $fields['Verification'] -eq 'none') {
                    Add-ValidationError "Merge receipt $mergeId is 'integrated' without Verification evidence; name the command, test, or inspection that checked the merged result."
                }
            }
            $sourceTasks = @()
            if (-not [string]::IsNullOrWhiteSpace($fields['Source Tasks']) -and $fields['Source Tasks'] -ne 'none') {
                foreach ($srcTask in @($fields['Source Tasks'].Split(',') | ForEach-Object { $_.Trim() })) {
                    if ([string]::IsNullOrWhiteSpace($srcTask)) { continue }
                    if ($srcTask -notmatch '^T-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') {
                        Add-ValidationError "Merge receipt $mergeId Source Tasks contains a non-T-* entry: '$srcTask'."
                    } elseif ($srcTask -notin $taskIds) {
                        Add-ValidationError "Merge receipt $mergeId references unknown Source Task '$srcTask'."
                    } else {
                        $sourceTasks += $srcTask
                        # Consistency must hold in both directions: a terminal
                        # receipt about a task the registry still lists as
                        # active means the two truth sources disagree.
                        if ($fields['Status'] -in @('integrated', 'deferred', 'rejected')) {
                            $srcBlock = [regex]::Match(
                                $taskIndexText,
                                '(?ms)^###\s+' + [regex]::Escape($srcTask) + '\s*\r?\n(?<body>.*?)(?=^###\s+|\z)')
                            $srcStatus = ''
                            if ($srcBlock.Success) {
                                $srcStatusMatch = [regex]::Match(
                                    $srcBlock.Groups['body'].Value, '(?m)^-\s+Status:\s*(.*?)\s*$')
                                if ($srcStatusMatch.Success) { $srcStatus = $srcStatusMatch.Groups[1].Value }
                            }
                            if ($srcStatus -ne $fields['Status'] -and $srcStatus -ne 'archived') {
                                Add-ValidationError "Merge receipt $mergeId says Task $srcTask is '$($fields['Status'])' but TASK_INDEX.md records status '$srcStatus'; the registry and the receipt must agree."
                            }
                        }
                    }
                }
            } else {
                Add-ValidationError "Merge receipt $mergeId must name at least one Source Task."
            }
            if (-not [string]::IsNullOrWhiteSpace($fields['Approval']) -and $fields['Approval'] -ne 'none') {
                foreach ($approvalId in @($fields['Approval'].Split(',') | ForEach-Object { $_.Trim() })) {
                    if ([string]::IsNullOrWhiteSpace($approvalId)) { continue }
                    if ($approvalId -notmatch '^D-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') {
                        Add-ValidationError "Merge receipt $mergeId Approval contains a non-D-* entry: '$approvalId'."
                    } elseif ($decisionText -notmatch ('(?m)^###\s+' + [regex]::Escape($approvalId) + '\s+\[')) {
                        Add-ValidationError "Merge receipt $mergeId Approval references unknown decision '$approvalId'."
                    }
                }
            }
            $dispositionPaths = @{}
            foreach ($setName in @('Accepted', 'Rejected', 'Deferred')) {
                $setValue = $fields[$setName]
                if ([string]::IsNullOrWhiteSpace($setValue) -or $setValue -eq 'none') { continue }
                foreach ($pathEntry in @($setValue.Split(',') | ForEach-Object { $_.Trim() })) {
                    if ([string]::IsNullOrWhiteSpace($pathEntry)) { continue }
                    if ($dispositionPaths.ContainsKey($pathEntry)) {
                        Add-ValidationError "Merge receipt $mergeId lists '$pathEntry' in more than one of Accepted/Rejected/Deferred."
                    } else {
                        $dispositionPaths[$pathEntry] = $setName
                    }
                    $null = Resolve-ProjectFile $rootFull $pathEntry "Merge receipt $mergeId $setName path"
                }
            }
            if ($fields['Status'] -eq 'integrated') {
                if (-not (Test-CheckpointResolvable $fields['Base Checkpoint'])) {
                    Add-ValidationError "Merge receipt $mergeId Base Checkpoint '$($fields['Base Checkpoint'])' is not a resolvable Git object or the explicit lineage_incomplete marker."
                }
                if (-not (Test-CheckpointResolvable $fields['Result Checkpoint'])) {
                    Add-ValidationError "Merge receipt $mergeId Result Checkpoint '$($fields['Result Checkpoint'])' is not a resolvable Git object or the explicit lineage_incomplete marker."
                }
                if ($fields['Base Checkpoint'] -eq 'lineage_incomplete' -or
                    $fields['Result Checkpoint'] -eq 'lineage_incomplete') {
                    # The migration escape hatch needs a reason on record.
                    $lineageNoteMatch = [regex]::Match(
                        $body, '(?m)^-\s+Lineage Note:\s*(.*?)\s*$')
                    $lineageNote = if ($lineageNoteMatch.Success) { $lineageNoteMatch.Groups[1].Value } else { '' }
                    if ([string]::IsNullOrWhiteSpace($lineageNote) -or $lineageNote -eq 'none') {
                        Add-ValidationError "Merge receipt $mergeId uses lineage_incomplete without a 'Lineage Note' field explaining why pre-layer history is unavailable; new projects must use real checkpoints."
                    }
                }
            }
            $mergeRecords += [pscustomobject]@{
                Id = $mergeId
                Status = $fields['Status']
                SourceTasks = $sourceTasks
            }
        }
    }

    foreach ($terminal in $terminalTasks) {
        $matching = @($mergeRecords | Where-Object {
            $_.Status -eq $terminal.Status -and $terminal.Id -in $_.SourceTasks
        })
        if ($matching.Count -eq 0) {
            Add-ValidationError "Task $($terminal.Id) is '$($terminal.Status)' but no merge receipt with matching status names it; only a receipt proves disposition."
        } elseif ($matching.Count -ne 1) {
            Add-ValidationError "Task $($terminal.Id) has $($matching.Count) '$($terminal.Status)' receipts; exactly one final disposition receipt is required."
        }
    }

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
    } elseif ($isPps12) {
        $rowMatch = [regex]::Match(
            $coverageText,
            '(?m)^\|\s*' + [regex]::Escape($id) + '\s*\|(?<rest>.*)$')
        $cells = @($rowMatch.Groups['rest'].Value -split '\|' | ForEach-Object { $_.Trim() })
        $evidenceCell = if ($cells.Count -ge 3) { $cells[2] } else { '' }
        if ([string]::IsNullOrWhiteSpace($evidenceCell) -or $evidenceCell -in @('Present', 'present')) {
            Add-ValidationError "Coverage row for $id needs an evidence cell naming the command, test, or inspection; bare 'Present' cannot distinguish checked from unchecked."
        }
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


if ($isPps12 -and (Test-Path -LiteralPath (Join-Path $rootFull 'TASK_INDEX.md') -PathType Leaf)) {
    # Task capsule IDs must resolve against the same authorities as the main
    # Workset: a structurally valid task that references phantom records
    # would still drift at resume time.
    foreach ($ref in @($allTaskAuthorityRefs | Sort-Object Task, Id -Unique)) {
        if ($ref.Id -notin $activeIds) {
            Add-ValidationError "Task $($ref.Task) references authority $($ref.Id) which is not in the DECISIONS.md active block."
        }
    }
    if ($null -ne $mapPath -and (Test-Path -LiteralPath $mapPath -PathType Leaf)) {
        $mapBody = Read-Utf8File $mapPath
        foreach ($ref in @($allTaskComponentRefs | Sort-Object Task, Id -Unique)) {
            $componentRows = [regex]::Matches(
                $mapBody, '(?m)^\|\s*' + [regex]::Escape($ref.Id) + '\s*\|')
            if ($componentRows.Count -ne 1) {
                Add-ValidationError "Task $($ref.Task) references component $($ref.Id) which does not exist in $mapRelative."
            }
        }
    }
    $sourceIndexFile = Join-Path $rootFull 'SOURCE_INDEX.md'
    foreach ($ref in @($allTaskSourceRefs | Sort-Object Task, Id -Unique)) {
        $sourceKnown = $false
        if (Test-Path -LiteralPath $sourceIndexFile -PathType Leaf) {
            $sourceBody = Read-Utf8File $sourceIndexFile
            if ($sourceBody -match ('(?m)^\|\s*' + [regex]::Escape($ref.Id) + '\s*\|')) {
                $sourceKnown = $true
            }
        }
        if (-not $sourceKnown) {
            Add-ValidationError "Task $($ref.Task) references source $($ref.Id) which does not exist in SOURCE_INDEX.md."
        }
    }
    $assetsFile = Join-Path $rootFull 'ASSETS.md'
    foreach ($ref in @($allTaskAssetRefs | Sort-Object Task, Id -Unique)) {
        $assetKnown = $false
        if (Test-Path -LiteralPath $assetsFile -PathType Leaf) {
            $assetsBody = Read-Utf8File $assetsFile
            if ($assetsBody -match ('(?m)^\|\s*' + [regex]::Escape($ref.Id) + '\s*\|')) {
                $assetKnown = $true
            }
        }
        if (-not $assetKnown) {
            Add-ValidationError "Task $($ref.Task) references asset $($ref.Id) which does not exist in ASSETS.md."
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
    Write-Host "Protocol: $protocol"
    if (-not [string]::IsNullOrWhiteSpace($mode)) { Write-Host "Mode: $mode" }
    Write-Host "Profile: $profile"
    Write-Host "Package: $package"
    Write-Host "Required authority IDs: $($requiredIds.Count)"
    Write-Host "Required source IDs: $($sourceIds.Count)"
    Write-Host "Required asset IDs: $($assetIds.Count)"
}
exit 0
