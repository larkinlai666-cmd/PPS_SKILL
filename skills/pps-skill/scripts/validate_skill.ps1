[CmdletBinding()]
param(
    [string]$SkillRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError([string]$Message) {
    $script:errors.Add($Message)
}

function Add-ValidationWarning([string]$Message) {
    $script:warnings.Add($Message)
}

$rootFull = [System.IO.Path]::GetFullPath($SkillRoot)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    Write-Host "PPS skill validation: FAILED"
    Write-Host "ERROR: Skill root is not a directory: $rootFull"
    exit 1
}
$rootFull = (Resolve-Path -LiteralPath $rootFull).Path

$required = @(
    'SKILL.md',
    'agents/openai.yaml',
    'assets/templates/AGENTS.md',
    'assets/templates/ASSETS.md',
    'assets/templates/CONTEXT.md',
    'assets/templates/CURRENT_REVIEW_EVIDENCE.md',
    'assets/templates/DECISIONS.md',
    'assets/templates/MAIN.md',
    'assets/templates/ENVIRONMENT.md',
    'assets/templates/PROJECT_MAP.md',
    'assets/templates/PROJECT_README.md',
    'assets/templates/PROJECT_STATE.md',
    'assets/templates/SOURCE_INDEX.md',
    'assets/templates/gitattributes.template',
    'assets/templates/gitignore.template',
    'references/asset-management.md',
    'references/design-rationale.md',
    'references/environment-bootstrap.md',
    'references/git-sync.md',
    'references/migration.md',
    'references/protocol.md',
    'references/project-modes.md',
    'references/retrieval-and-gates.md',
    'scripts/audit_legacy_project.ps1',
    'scripts/audit_legacy_project.sh',
    'scripts/asset_check.ps1',
    'scripts/asset_check.sh',
    'scripts/init_project.ps1',
    'scripts/init_project.sh',
    'scripts/environment_doctor.ps1',
    'scripts/environment_doctor.sh',
    'scripts/pre-commit',
    'scripts/pre-commit.ps1',
    'scripts/readiness_check.ps1',
    'scripts/readiness_check.sh',
    'scripts/resume_packet.ps1',
    'scripts/resume_packet.sh',
    'scripts/status_check.ps1',
    'scripts/status_check.sh',
    'scripts/validate_project.ps1',
    'scripts/validate_project.sh',
    'scripts/validate_skill.ps1',
    'scripts/validate_skill.sh'
)

foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $rootFull $relative) -PathType Leaf)) {
        Add-ValidationError "Missing required skill file: $relative"
    }
}

$skillPath = Join-Path $rootFull 'SKILL.md'
if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
    $skillText = [System.IO.File]::ReadAllText($skillPath, [System.Text.Encoding]::UTF8)
    if ($skillText -notmatch '\A---\r?\n') {
        Add-ValidationError "SKILL.md must begin with YAML frontmatter."
    }
    if ([regex]::Matches($skillText, '(?m)^name:\s+pps-skill\s*$').Count -ne 1) {
        Add-ValidationError "SKILL.md must declare name: pps-skill exactly once."
    }
    if ([regex]::Matches($skillText, '(?m)^description:\s+.+$').Count -ne 1) {
        Add-ValidationError "SKILL.md must declare one non-empty description."
    }
}

$parseTargets = @(
    Get-ChildItem -LiteralPath (Join-Path $rootFull 'scripts') -Filter '*.ps1' -File
)
foreach ($target in $parseTargets) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $target.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        Add-ValidationError "PowerShell parser rejected scripts/$($target.Name): $($parseError.Message)"
    }
}

$templateRoot = Join-Path $rootFull 'assets/templates'
$templateText = [string]::Join(
    [Environment]::NewLine,
    @(
        Get-ChildItem -LiteralPath $templateRoot -File |
            ForEach-Object {
                [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
            }
    )
)
foreach ($token in @(
    '{{PROJECT_NAME}}',
    '{{PROFILE}}',
    '{{MODE}}',
    '{{TIMESTAMP}}',
    '{{DATE}}',
    '{{DEVICE}}',
    '{{MAIN_ARTIFACT}}',
    '{{COVERAGE_ARTIFACT}}',
    '{{READ_SET}}',
    '{{WRITE_SET}}',
    '{{OPTIONAL_TOOLS}}'
)) {
    if (-not $templateText.Contains($token)) {
        Add-ValidationError "Templates are missing required token: $token"
    }
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    Add-ValidationWarning "git is unavailable; project initialization cannot create synchronized history."
}
if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
    Add-ValidationWarning "gh is unavailable; GitHub setup must use HTTPS/SSH fallback."
}
if ($null -eq (Get-Command bash -ErrorAction SilentlyContinue)) {
    Add-ValidationWarning "Bash is unavailable; Bash parity cannot be checked on this device."
}

foreach ($message in $warnings) {
    Write-Host "WARNING: $message"
}
if ($errors.Count -gt 0) {
    Write-Host "PPS skill validation: FAILED ($($errors.Count) error(s))"
    foreach ($message in $errors) {
        Write-Host "ERROR: $message"
    }
    exit 1
}

Write-Host "PPS skill validation: OK"
Write-Host "Skill root: $rootFull"
