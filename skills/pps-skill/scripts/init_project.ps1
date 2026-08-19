[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    [ValidateSet('document', 'software', 'hybrid')]
    [string]$Mode = 'document',
    [ValidateSet('standard', 'evidence')]
    [string]$Profile = 'standard',
    [string]$ParentDir,
    [string]$GitName,
    [string]$GitEmail,
    [switch]$InstallHook,
    [switch]$NoGit
)

$ErrorActionPreference = "Stop"

function Invoke-NativeProbe([scriptblock]$Command) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& $Command)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{
        Code = $exitCode
        Text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    }
}

if ($ProjectName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "ProjectName may contain only letters, digits, dot, underscore, and hyphen."
}
if ($ProjectName -in @('.', '..')) {
    throw "ProjectName cannot be '.' or '..'."
}
if ($ProjectName.Length -gt 100) {
    throw "ProjectName cannot exceed 100 characters."
}
if ($ProjectName.EndsWith('.')) {
    throw "ProjectName cannot end with a dot."
}
$portableBase = $ProjectName.Split('.')[0]
if ($portableBase -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
    throw "ProjectName uses a Windows-reserved device name: $ProjectName"
}
if ([string]::IsNullOrWhiteSpace($GitName) -xor [string]::IsNullOrWhiteSpace($GitEmail)) {
    throw "Provide both GitName and GitEmail, or neither."
}
if ($NoGit -and $InstallHook) {
    throw "-InstallHook cannot be used with -NoGit."
}
if ($NoGit -and -not [string]::IsNullOrWhiteSpace($GitName)) {
    throw "-GitName/-GitEmail cannot be used with -NoGit."
}

if ([string]::IsNullOrWhiteSpace($ParentDir)) {
    if (-not [string]::IsNullOrWhiteSpace($env:PPS_PROJECT_HOME)) {
        $ParentDir = $env:PPS_PROJECT_HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($env:PLAN_PROJECT_HOME)) {
        $ParentDir = $env:PLAN_PROJECT_HOME
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
$assetsDir = Join-Path $target 'assets'
$prototypesDir = Join-Path $target 'prototypes'
$scriptsDir = Join-Path $target 'scripts'
New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
New-Item -ItemType Directory -Path $prototypesDir -Force | Out-Null
New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

$now = [DateTime]::UtcNow
$timestamp = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
$date = $now.ToString("yyyy-MM-dd")
$device = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($device)) { $device = 'unknown-device' }
switch ($Mode) {
    'document' {
        $mainArtifact = 'docs/MAIN.md'
        $readSet = 'PROJECT_STATE.md,CONTEXT.md,docs/MAIN.md'
        $writeSet = 'PROJECT_STATE.md,CONTEXT.md,docs/MAIN.md'
        $optionalTools = 'gh,pandoc,imagemagick'
    }
    'software' {
        $mainArtifact = '.'
        $readSet = 'PROJECT_STATE.md,CONTEXT.md,PROJECT_MAP.md'
        $writeSet = 'PROJECT_STATE.md,CONTEXT.md,PROJECT_MAP.md'
        $optionalTools = 'gh,rg,node,python'
    }
    'hybrid' {
        $mainArtifact = '.'
        $readSet = 'PROJECT_STATE.md,CONTEXT.md,PROJECT_MAP.md,docs/MAIN.md'
        $writeSet = 'PROJECT_STATE.md,CONTEXT.md,PROJECT_MAP.md,docs/MAIN.md'
        $optionalTools = 'gh,rg,node,python,pandoc,imagemagick'
    }
}
$coverageArtifact = if ($Profile -eq 'evidence') {
    'docs/CURRENT_REVIEW_EVIDENCE.md'
} else {
    'CONTEXT.md'
}

$replacements = @{
    '{{PROJECT_NAME}}' = $ProjectName
    '{{PROFILE}}' = $Profile
    '{{MODE}}' = $Mode
    '{{TIMESTAMP}}' = $timestamp
    '{{DATE}}' = $date
    '{{DEVICE}}' = $device
    '{{MAIN_ARTIFACT}}' = $mainArtifact
    '{{COVERAGE_ARTIFACT}}' = $coverageArtifact
    '{{READ_SET}}' = $readSet
    '{{WRITE_SET}}' = $writeSet
    '{{OPTIONAL_TOOLS}}' = $optionalTools
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
Render-Template 'PROJECT_MAP.md' (Join-Path $target 'PROJECT_MAP.md')
Render-Template 'ENVIRONMENT.md' (Join-Path $target 'ENVIRONMENT.md')
Render-Template 'EVENTS.md' (Join-Path $target 'EVENTS.md')
if ($Mode -ne 'software') {
    Render-Template 'MAIN.md' (Join-Path $docsDir 'MAIN.md')
}
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
    'validate_project.sh',
    'environment_doctor.ps1',
    'environment_doctor.sh',
    'resume_packet.ps1',
    'resume_packet.sh',
    'asset_check.ps1',
    'asset_check.sh',
    'readiness_check.ps1',
    'readiness_check.sh',
    'verify_gate.ps1',
    'verify_gate.sh',
    'append_event.ps1',
    'append_event.sh',
    'boundary_check.ps1',
    'boundary_check.sh',
    'pre-commit',
    'pre-commit.ps1'
)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $scriptName) -Destination (Join-Path $scriptsDir $scriptName)
}

if (-not $NoGit) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Warning "Git was not found; project files were created without a repository."
    } else {
        $initializationProbe = Invoke-NativeProbe {
            & $git.Source -C $target init --quiet -b main 2>$null
        }
        if ($initializationProbe.Code -ne 0) {
            & $git.Source -C $target init --quiet
            if ($LASTEXITCODE -ne 0) { throw "git init failed." }
            $checkoutProbe = Invoke-NativeProbe {
                & $git.Source -C $target checkout -q -b main 2>$null
            }
            if ($checkoutProbe.Code -ne 0) {
                & $git.Source -C $target branch -M main
                if ($LASTEXITCODE -ne 0) { throw "Could not create the main branch." }
            }
        }
        & $git.Source -C $target add --all
        if ($LASTEXITCODE -ne 0) { throw "git add failed." }
        if (-not [string]::IsNullOrWhiteSpace($GitName)) {
            & $git.Source -C $target config user.name $GitName
            if ($LASTEXITCODE -ne 0) { throw "Could not set repository-local Git user.name." }
            & $git.Source -C $target config user.email $GitEmail
            if ($LASTEXITCODE -ne 0) { throw "Could not set repository-local Git user.email." }
        }
        $nameProbe = Invoke-NativeProbe {
            & $git.Source -C $target config --get user.name 2>$null
        }
        $emailProbe = Invoke-NativeProbe {
            & $git.Source -C $target config --get user.email 2>$null
        }
        $effectiveName = $nameProbe.Text
        $effectiveEmail = $emailProbe.Text
        if ([string]::IsNullOrWhiteSpace($effectiveName) -or [string]::IsNullOrWhiteSpace($effectiveEmail)) {
            Write-Warning "Initial files are staged but not committed because Git identity is missing. Pass -GitName and -GitEmail for repository-local identity, or configure Git yourself."
        } else {
            & $git.Source -C $target commit --quiet -m "chore: initialize PPS project"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Initial commit was not created. Inspect Git output and commit manually."
            }
        }
        if ($InstallHook) {
            $hookSource = Join-Path $PSScriptRoot 'pre-commit'
            $hookTarget = Join-Path $target '.git/hooks/pre-commit'
            Copy-Item -LiteralPath $hookSource -Destination $hookTarget -Force
            if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                $chmod = Get-Command chmod -ErrorAction SilentlyContinue
                if ($null -ne $chmod) {
                    & $chmod.Source '+x' $hookTarget
                    if ($LASTEXITCODE -ne 0) { throw "Could not make the pre-commit hook executable." }
                }
            }
            Write-Host "PPS pre-commit validation hook installed."
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
Write-Host "Mode: $Mode"
Write-Host "Profile: $Profile"
$branch = if ($NoGit -or $null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    'not initialized'
} else {
    ((& git -C $target branch --show-current 2>$null) | Out-String).Trim()
}
Write-Host "Branch: $branch"
Write-Host "Next: replace the bootstrap objective and prepare PKG-001."
