[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repoRoot "skills/pps-skill"
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot = Join-Path $tempBase ("pps-skill-smoke-" + [guid]::NewGuid().ToString("N"))
$engine = (Get-Process -Id $PID).Path

function Run-Validator([string]$ProjectRoot) {
    $validator = Join-Path $ProjectRoot "scripts/validate_project.ps1"
    $output = & $engine -NoProfile -ExecutionPolicy Bypass -File $validator -Root $ProjectRoot 2>&1
    return @{
        Code = $LASTEXITCODE
        Text = ($output | Out-String)
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName standard-case -Profile standard -ParentDir $tempRoot -NoGit
    if ($LASTEXITCODE -ne 0) { throw "Standard initialization failed." }

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName evidence-case -Profile evidence -ParentDir $tempRoot -NoGit
    if ($LASTEXITCODE -ne 0) { throw "Evidence initialization failed." }

    $standard = Join-Path $tempRoot "standard-case"
    $evidence = Join-Path $tempRoot "evidence-case"
    $validStandard = Run-Validator $standard
    $validEvidence = Run-Validator $evidence
    if ($validStandard.Code -ne 0 -or $validEvidence.Code -ne 0) {
        throw "A valid generated project failed validation."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $evidence "SOURCE_INDEX.md") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $evidence "docs/CURRENT_REVIEW_EVIDENCE.md") -PathType Leaf)) {
        throw "Evidence profile files are missing."
    }

    $missing = Join-Path $tempRoot "missing-coverage"
    Copy-Item -LiteralPath $standard -Destination $missing -Recurse
    $missingContext = Join-Path $missing "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($missingContext, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^\| M-002 \|.*\r?\n', '')
    [System.IO.File]::WriteAllText(
        $missingContext,
        $text,
        [System.Text.UTF8Encoding]::new($false)
    )
    $missingResult = Run-Validator $missing
    if ($missingResult.Code -ne 1 -or
        $missingResult.Text -notmatch "Manifest ID M-002 has no row") {
        throw "Missing coverage was not rejected correctly."
    }

    $inactive = Join-Path $tempRoot "inactive-decision"
    Copy-Item -LiteralPath $standard -Destination $inactive -Recurse
    $inactiveContext = Join-Path $inactive "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($inactiveContext, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("- Decisions: none", "- Decisions: D-404")
    [System.IO.File]::WriteAllText(
        $inactiveContext,
        $text,
        [System.Text.UTF8Encoding]::new($false)
    )
    $inactiveResult = Run-Validator $inactive
    if ($inactiveResult.Code -ne 1 -or
        $inactiveResult.Text -notmatch "Manifest ID D-404 must appear exactly once") {
        throw "Inactive manifest decision was not rejected correctly."
    }

    Write-Host "PPS PowerShell smoke tests: OK"
} finally {
    $resolved = [System.IO.Path]::GetFullPath($tempRoot)
    if ($resolved.StartsWith($tempBase + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved).StartsWith("pps-skill-smoke-")) {
        if (Test-Path -LiteralPath $resolved) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } else {
        Write-Warning "Refusing unexpected cleanup target: $resolved"
    }
}
