[CmdletBinding()]
param(
    [string]$Root,
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [string]$Files = 'none',
    [string]$Verify = 'none',
    [string]$Pending = 'none'
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    Write-Host "ERROR: project root is not a directory: $Root"
    exit 1
}
$rootFull = (Resolve-Path -LiteralPath $rootFull).Path

foreach ($segment in @($Title, $Files, $Verify, $Pending)) {
    if ($segment.Contains('|')) {
        Write-Host "ERROR: event segments must not contain the '|' separator character."
        exit 1
    }
    if ($segment.Contains("`n") -or $segment.Contains("`r")) {
        Write-Host "ERROR: event segments must be single-line; newlines could forge extra chronicle lines or sections."
        exit 1
    }
}

$eventsPath = Join-Path $rootFull 'EVENTS.md'
if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
    Write-Host "ERROR: EVENTS.md not found; this project may predate PPS/1.2."
    exit 1
}
$eventsText = [System.IO.File]::ReadAllText($eventsPath, [System.Text.Encoding]::UTF8)
if ($eventsText -notmatch '(?m)^##\s+Events\s*$') {
    Write-Host "ERROR: EVENTS.md has no '## Events' section."
    exit 1
}

$stateText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$hotMatch = [regex]::Match(
    $stateText,
    '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$packageId = $null
if ($hotMatch.Success) {
    $packageMatch = [regex]::Match(
        $hotMatch.Groups['body'].Value, '(?m)^-\s+Package:\s*(.*?)\s*$')
    if ($packageMatch.Success) {
        $packageId = $packageMatch.Groups[1].Value
    }
}
if ([string]::IsNullOrWhiteSpace($packageId)) {
    Write-Host "ERROR: cannot resolve current package from PROJECT_STATE.md."
    exit 1
}

$dateValue = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
$line = "- ${dateValue}: [$packageId] $Title | files: $Files | verify: $Verify | pending: $Pending"
# Insert at the end of the '## Events' section, not the end of the file, so
# trailing sections can never silently absorb new events.
$eventsLines = [System.Collections.Generic.List[string]]@(
    [System.IO.File]::ReadAllLines($eventsPath, [System.Text.Encoding]::UTF8))
$insideEvents = $false
$insertIndex = -1
for ($i = 0; $i -lt $eventsLines.Count; $i++) {
    if ($eventsLines[$i] -match '^##\s+Events\s*$') { $insideEvents = $true; continue }
    if ($insideEvents -and $eventsLines[$i] -match '^##\s+') {
        $insertIndex = $i
        break
    }
}
if ($insertIndex -ge 0) {
    $eventsLines.Insert($insertIndex, $line)
} else {
    $eventsLines.Add($line)
}
[System.IO.File]::WriteAllText(
    $eventsPath,
    (($eventsLines -join "`n") + "`n"),
    [System.Text.UTF8Encoding]::new($false))

$lineCount = @([System.IO.File]::ReadAllLines($eventsPath)).Count
if ($lineCount -gt 200) {
    Write-Warning "EVENTS.md has $lineCount lines; archive older months to docs/events-archive/."
}
Write-Host "Event appended for $packageId."
exit 0
