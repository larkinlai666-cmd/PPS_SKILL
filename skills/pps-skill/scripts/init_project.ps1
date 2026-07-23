[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    [ValidateSet('standard', 'evidence')]
    [string]$Profile = 'standard',
    [string]$ParentDir,
    [string]$GitName,
    [string]$GitEmail,
    [switch]$NoGit
)

$ErrorActionPreference = "Stop"
if ($ProjectName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "ProjectName may contain only letters, digits, dot, underscore, and hyphen."
}
if ([string]::IsNullOrWhiteSpace($GitName) -xor [string]::IsNullOrWhiteSpace($GitEmail)) {
    throw "Provide both GitName and GitEmail, or neither."
}

if ([string]::IsNullOrWhiteSpace($ParentDir)) {
    if (-not [string]::IsNullOrWhiteSpace($env:PPS_PROJECT_HOME)) {
        $ParentDir = $env:PPS_PROJECT_HOME
    } else {
        $ParentDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Projects'
    }
}

$parentFull = [System.IO.Path]::GetFullPath($ParentDir)
$target = Join-Path $parentFull $ProjectName
if (Test-Path -LiteralPath $target) {
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Target exists and is not a directory: $target"
    }
    if (@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) {
        throw "Refusing to initialize a non-empty target: $target"
    }
} else {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
}

$skillRoot = Split-Path -Parent $PSScriptRoot
$templateRoot = Join-Path $skillRoot 'assets/templates'
$docsDir = Join-Path $target 'docs'
$scriptsDir = Join-Path $target 'scripts'
New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

$now = [DateTime]::UtcNow
$timestamp = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
$date = $now.ToString("yyyy-MM-dd")
$device = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($device)) { $device = 'unknown-device' }
$mainArtifact = 'docs/MAIN.md'
$coverageArtifact = if ($Profile -eq 'evidence') {
    'docs/CURRENT_REVIEW_EVIDENCE.md'
} else {
    'CONTEXT.md'
}

$replacements = @{
    '{{PROJECT_NAME}}' = $ProjectName
    '{{PROFILE}}' = $Profile
    '{{TIMESTAMP}}' = $timestamp
    '{{DATE}}' = $date
    '{{DEVICE}}' = $device
    '{{MAIN_ARTIFACT}}' = $mainArtifact
    '{{COVERAGE_ARTIFACT}}' = $coverageArtifact
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Render-Template([string]$TemplateName, [string]$Destination) {
    $templatePath = Join-Path $templateRoot $TemplateName
    $text = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
    foreach ($token in $replacements.Keys) {
        $text = $text.Replace($token, $replacements[$token])
    }
    [System.IO.File]::WriteAllText($Destination, $text, $utf8NoBom)
}

Render-Template 'PROJECT_README.md' (Join-Path $target 'README.md')
Render-Template 'AGENTS.md' (Join-Path $target 'AGENTS.md')
Render-Template 'PROJECT_STATE.md' (Join-Path $target 'PROJECT_STATE.md')
Render-Template 'DECISIONS.md' (Join-Path $target 'DECISIONS.md')
Render-Template 'CONTEXT.md' (Join-Path $target 'CONTEXT.md')
Render-Template 'MAIN.md' (Join-Path $docsDir 'MAIN.md')
Render-Template 'gitignore.template' (Join-Path $target '.gitignore')
Render-Template 'gitattributes.template' (Join-Path $target '.gitattributes')

if ($Profile -eq 'evidence') {
    Render-Template 'SOURCE_INDEX.md' (Join-Path $target 'SOURCE_INDEX.md')
    Render-Template 'CURRENT_REVIEW_EVIDENCE.md' (Join-Path $docsDir 'CURRENT_REVIEW_EVIDENCE.md')
}

foreach ($scriptName in @(
    'status_check.ps1',
    'status_check.sh',
    'validate_project.ps1',
    'validate_project.sh'
)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $scriptName) -Destination (Join-Path $scriptsDir $scriptName)
}

if (-not $NoGit) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Warning "Git was not found; project files were created without a repository."
    } else {
        & $git.Source -C $target init --quiet
        if ($LASTEXITCODE -ne 0) { throw "git init failed." }
        & $git.Source -C $target add --all
        if ($LASTEXITCODE -ne 0) { throw "git add failed." }
        if (-not [string]::IsNullOrWhiteSpace($GitName)) {
            & $git.Source -C $target config user.name $GitName
            if ($LASTEXITCODE -ne 0) { throw "Could not set repository-local Git user.name." }
            & $git.Source -C $target config user.email $GitEmail
            if ($LASTEXITCODE -ne 0) { throw "Could not set repository-local Git user.email." }
        }
        $effectiveName = ((& $git.Source -C $target config --get user.name 2>$null) | Out-String).Trim()
        $effectiveEmail = ((& $git.Source -C $target config --get user.email 2>$null) | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($effectiveName) -or [string]::IsNullOrWhiteSpace($effectiveEmail)) {
            Write-Warning "Initial files are staged but not committed because Git identity is missing. Pass -GitName and -GitEmail for repository-local identity, or configure Git yourself."
        } else {
            & $git.Source -C $target commit --quiet -m "chore: initialize PPS project"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Initial commit was not created. Inspect Git output and commit manually."
            }
        }
    }
}

$validator = Join-Path $scriptsDir 'validate_project.ps1'
$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) {
    $engine = Get-Command powershell -ErrorAction Stop
}
& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $validator -Root $target
if ($LASTEXITCODE -ne 0) {
    throw "PPS project validation failed."
}

Write-Host "PPS project initialized: $target"
Write-Host "Profile: $Profile"
Write-Host "Next: replace the bootstrap objective and prepare PKG-001."
