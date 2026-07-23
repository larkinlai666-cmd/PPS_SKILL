[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repoRoot "skills/pps-skill"
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
$tempRoot = Join-Path $tempBase ("pps-skill-smoke-" + [guid]::NewGuid().ToString("N"))
$engine = (Get-Process -Id $PID).Path
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Run-Validator([string]$ProjectRoot) {
    $validator = Join-Path $ProjectRoot "scripts/validate_project.ps1"
    $output = & $engine -NoProfile -ExecutionPolicy Bypass -File $validator -Root $ProjectRoot 2>&1
    return @{
        Code = $LASTEXITCODE
        Text = ($output | Out-String)
    }
}

function Get-TreeFingerprint([string]$ProjectRoot) {
    $entries = Get-ChildItem -LiteralPath $ProjectRoot -Force -Recurse |
        Sort-Object FullName
    return [string]::Join(
        "`n",
        @($entries | ForEach-Object {
            $relative = $_.FullName.Substring($ProjectRoot.Length)
            if ($_.PSIsContainer) {
                "D|$relative"
            } else {
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                "F|$relative|$hash"
            }
        })
    )
}

function Assert-InvalidProject(
    [string]$ProjectRoot,
    [string]$Expected,
    [string]$Label,
    [string]$LocationPattern = ''
) {
    $result = Run-Validator $ProjectRoot
    if ($result.Code -ne 1 -or $result.Text -notmatch [regex]::Escape($Expected)) {
        throw "$Label was not rejected with the expected diagnostic '$Expected'. Output: $($result.Text)"
    }
    if (-not [string]::IsNullOrWhiteSpace($LocationPattern) -and
        $result.Text -notmatch $LocationPattern) {
        throw "$Label did not report exact conflict locations matching '$LocationPattern'. Output: $($result.Text)"
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/validate_skill.ps1") `
        -SkillRoot $skill
    if ($LASTEXITCODE -ne 0) { throw "PowerShell skill health validation failed." }
    $brokenSkill = Join-Path $tempRoot "broken-skill"
    Copy-Item -LiteralPath $skill -Destination $brokenSkill -Recurse
    Remove-Item -LiteralPath (Join-Path $brokenSkill "references/protocol.md")
    $brokenSkillOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $brokenSkill "scripts/validate_skill.ps1") `
        -SkillRoot $brokenSkill 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($brokenSkillOutput | Out-String) -notmatch "Missing required skill file: references/protocol.md") {
        throw "PowerShell skill health validator accepted a missing required file."
    }

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName standard-case -Profile standard -ParentDir $tempRoot -NoGit
    if ($LASTEXITCODE -ne 0) { throw "Standard initialization failed." }

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName evidence-case -Profile evidence -ParentDir $tempRoot -NoGit
    if ($LASTEXITCODE -ne 0) { throw "Evidence initialization failed." }

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName software-case -Mode software -Profile standard `
        -ParentDir $tempRoot -NoGit
    if ($LASTEXITCODE -ne 0) { throw "Software initialization failed." }

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName hybrid-case -Mode hybrid -Profile standard `
        -ParentDir $tempRoot -NoGit
    if ($LASTEXITCODE -ne 0) { throw "Hybrid initialization failed." }

    $standard = Join-Path $tempRoot "standard-case"
    $evidence = Join-Path $tempRoot "evidence-case"
    $software = Join-Path $tempRoot "software-case"
    $hybrid = Join-Path $tempRoot "hybrid-case"
    $validStandard = Run-Validator $standard
    $validEvidence = Run-Validator $evidence
    if ($validStandard.Code -ne 0 -or $validEvidence.Code -ne 0) {
        throw "A valid generated project failed validation."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $evidence "SOURCE_INDEX.md") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $evidence "docs/CURRENT_REVIEW_EVIDENCE.md") -PathType Leaf)) {
        throw "Evidence profile files are missing."
    }
    foreach ($relative in @(
        'assets',
        'prototypes',
        'PROJECT_MAP.md',
        'ENVIRONMENT.md',
        'scripts/pre-commit',
        'scripts/pre-commit.ps1',
        'scripts/resume_packet.sh',
        'scripts/environment_doctor.ps1',
        'scripts/asset_check.sh',
        'scripts/readiness_check.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $standard $relative))) {
            throw "Generated project is missing restored compatibility path: $relative"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $software 'docs/MAIN.md') -PathType Leaf) {
        throw 'Software mode unexpectedly created a document main artifact.'
    }
    $softwareState = [System.IO.File]::ReadAllText(
        (Join-Path $software 'PROJECT_STATE.md'),
        [System.Text.Encoding]::UTF8
    )
    if ($softwareState -notmatch '(?m)^- Mode: software$' -or
        $softwareState -notmatch '(?m)^- Main: \.$') {
        throw 'Software mode did not use a directory Main path.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hybrid 'docs/MAIN.md') -PathType Leaf)) {
        throw 'Hybrid mode did not create its maintained specification.'
    }

    $largeSourceDir = Join-Path $software 'src'
    New-Item -ItemType Directory -Path $largeSourceDir | Out-Null
    $largeSource = Join-Path $largeSourceDir 'large-source.js'
    $writer = [System.IO.StreamWriter]::new($largeSource, $false, $utf8NoBom)
    try {
        for ($index = 1; $index -le 200000; $index++) {
            $writer.WriteLine("const bounded_line_$index = $index;")
        }
        $writer.WriteLine('PPS_BULK_SOURCE_SENTINEL')
    } finally {
        $writer.Dispose()
    }
    $largeValidation = Run-Validator $software
    if ($largeValidation.Code -ne 0) {
        throw "Software project with a 200,001-line source failed validation: $($largeValidation.Text)"
    }
    $resumeOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $software 'scripts/resume_packet.ps1') -Root $software 2>&1)
    $resumeText = $resumeOutput | Out-String
    if ($LASTEXITCODE -ne 0 -or $resumeOutput.Count -gt 240 -or
        $resumeText -notmatch '(?m)^### M-001 \[active\]$' -or
        $resumeText -match 'PPS_BULK_SOURCE_SENTINEL') {
        throw 'PowerShell resume packet was unbounded, incomplete, or leaked source content.'
    }
    $environmentOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $software 'scripts/environment_doctor.ps1') -Root $software 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($environmentOutput | Out-String) -notmatch '(?m)^PASS required: git$') {
        throw 'PowerShell environment doctor failed a valid required-tool check.'
    }
    $coreEnvironmentOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill 'scripts/environment_doctor.ps1') -Core 2>&1)
    if ($LASTEXITCODE -notin @(0, 1) -or
        ($coreEnvironmentOutput | Out-String) -notmatch '(?m)^(PASS|MISSING) required: git$' -or
        ($coreEnvironmentOutput | Out-String) -notmatch '(?m)^(PASS|MISSING) required: gh$') {
        throw 'PowerShell core environment check did not provide bounded pre-clone diagnostics.'
    }

    $legacyPps10 = Join-Path $tempRoot 'legacy-pps10'
    Copy-Item -LiteralPath $standard -Destination $legacyPps10 -Recurse
    $legacyStatePath = Join-Path $legacyPps10 'PROJECT_STATE.md'
    $text = [System.IO.File]::ReadAllText($legacyStatePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Protocol: PPS/1.1', '- Protocol: PPS/1.0')
    $text = [regex]::Replace($text, '(?m)^- (Mode|Map|Environment):.*\r?\n', '')
    [System.IO.File]::WriteAllText($legacyStatePath, $text, $utf8NoBom)
    $legacyContextPath = Join-Path $legacyPps10 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($legacyContextPath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- (Components|Read|Write|Verify):.*\r?\n', '')
    [System.IO.File]::WriteAllText($legacyContextPath, $text, $utf8NoBom)
    $legacyPps10Result = Run-Validator $legacyPps10
    if ($legacyPps10Result.Code -ne 0) {
        throw "PPS/1.0 compatibility regressed: $($legacyPps10Result.Text)"
    }

    $missingMap = Join-Path $tempRoot 'missing-map'
    Copy-Item -LiteralPath $standard -Destination $missingMap -Recurse
    Remove-Item -LiteralPath (Join-Path $missingMap 'PROJECT_MAP.md')
    Assert-InvalidProject $missingMap `
        'Project map file does not exist: PROJECT_MAP.md' `
        'Missing PPS/1.1 project map'

    $missingEnvironment = Join-Path $tempRoot 'missing-environment'
    Copy-Item -LiteralPath $standard -Destination $missingEnvironment -Recurse
    Remove-Item -LiteralPath (Join-Path $missingEnvironment 'ENVIRONMENT.md')
    Assert-InvalidProject $missingEnvironment `
        'Environment manifest does not exist: ENVIRONMENT.md' `
        'Missing PPS/1.1 environment manifest'

    $missingResume = Join-Path $tempRoot 'missing-resume-script'
    Copy-Item -LiteralPath $standard -Destination $missingResume -Recurse
    Remove-Item -LiteralPath (Join-Path $missingResume 'scripts/resume_packet.ps1')
    Assert-InvalidProject $missingResume `
        'PPS/1.1 is missing required file: scripts/resume_packet.ps1' `
        'Missing PPS/1.1 resume script'

    $missingComponent = Join-Path $tempRoot 'missing-component'
    Copy-Item -LiteralPath $standard -Destination $missingComponent -Recurse
    $casePath = Join-Path $missingComponent 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Components: C-ROOT', '- Components: C-MISSING')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $missingComponent `
        'Component ID C-MISSING must have exactly one row' `
        'Missing component-map row'

    $duplicateComponent = Join-Path $tempRoot 'duplicate-component'
    Copy-Item -LiteralPath $standard -Destination $duplicateComponent -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $duplicateComponent 'PROJECT_MAP.md'),
        "| C-ROOT | docs/MAIN.md | duplicate | none | none |`n",
        $utf8NoBom
    )
    Assert-InvalidProject $duplicateComponent `
        'contains duplicate component rows for C-ROOT' `
        'Duplicate component-map row'

    $malformedComponent = Join-Path $tempRoot 'malformed-component'
    Copy-Item -LiteralPath $standard -Destination $malformedComponent -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $malformedComponent 'PROJECT_MAP.md'),
        "| C-BROKEN | docs/MAIN.md | missing columns |`n",
        $utf8NoBom
    )
    Assert-InvalidProject $malformedComponent `
        'Malformed component row in PROJECT_MAP.md' `
        'Malformed component-map row'

    $readEscape = Join-Path $tempRoot 'read-escape'
    Copy-Item -LiteralPath $standard -Destination $readEscape -Recurse
    $casePath = Join-Path $readEscape 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Read:.*$', '- Read: ../outside.md')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $readEscape `
        'Read path must be a project-relative path' `
        'Escaping Read path'

    $broadReadRoot = Join-Path $tempRoot 'broad-read-root'
    Copy-Item -LiteralPath $standard -Destination $broadReadRoot -Recurse
    $casePath = Join-Path $broadReadRoot 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Read:.*$', '- Read: .')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $broadReadRoot `
        'Read path must name an exact file or bounded subdirectory' `
        'Repository-root Read path'

    $oversizedWorkset = Join-Path $tempRoot 'oversized-workset'
    Copy-Item -LiteralPath $standard -Destination $oversizedWorkset -Recurse
    $casePath = Join-Path $oversizedWorkset 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $manyPaths = @(1..31 | ForEach-Object { "generated/path-$($_.ToString('00')).txt" }) -join ','
    $text = [regex]::Replace($text, '(?m)^- Write:.*$', "- Write: $manyPaths")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $oversizedWorkset `
        'Read and Write contain 34 paths; hard limit is 30' `
        'Oversized path workset'

    $oversizedContextBytes = Join-Path $tempRoot 'oversized-context-bytes'
    Copy-Item -LiteralPath $standard -Destination $oversizedContextBytes -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $oversizedContextBytes 'CONTEXT.md'),
        ('A' * 33000) + "`n",
        $utf8NoBom
    )
    Assert-InvalidProject $oversizedContextBytes `
        'hard limit is 32768' `
        'Oversized context byte budget'

    $oversizedAuthority = Join-Path $tempRoot 'oversized-authority-workset'
    Copy-Item -LiteralPath $standard -Destination $oversizedAuthority -Recurse
    $casePath = Join-Path $oversizedAuthority 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $manyAuthority = @(1..61 | ForEach-Object { "M-X$($_.ToString('00'))" }) -join ','
    $text = [regex]::Replace($text, '(?m)^- Methods:.*$', "- Methods: $manyAuthority")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $oversizedAuthority `
        'Methods, Facts, and Decisions contain 61 IDs; hard limit is 60' `
        'Oversized authority workset'

    $unknownTool = Join-Path $tempRoot 'unknown-tool'
    Copy-Item -LiteralPath $standard -Destination $unknownTool -Recurse
    $casePath = Join-Path $unknownTool 'ENVIRONMENT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Optional:.*$', '- Optional: madeup-tool')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $unknownTool `
        "Optional tools contains unsupported tool 'madeup-tool'" `
        'Unknown environment tool'
    $unknownDoctorOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $unknownTool 'scripts/environment_doctor.ps1') `
        -Root $unknownTool 2>&1)
    if ($LASTEXITCODE -eq 0 -or
        ($unknownDoctorOutput | Out-String) -notmatch 'Unsupported optional tool: madeup-tool') {
        throw 'PowerShell environment doctor accepted an unknown tool.'
    }

    $extendedTools = Join-Path $tempRoot 'extended-tools'
    Copy-Item -LiteralPath $standard -Destination $extendedTools -Recurse
    $casePath = Join-Path $extendedTools 'ENVIRONMENT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace(
        $text,
        '(?m)^- Optional:.*$',
        '- Optional: powershell,libreoffice,poppler,rclone'
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    $extendedToolsResult = Run-Validator $extendedTools
    if ($extendedToolsResult.Code -ne 0) {
        throw "Extended environment capabilities were rejected: $($extendedToolsResult.Text)"
    }

    $missingDependency = Join-Path $tempRoot 'missing-dependency-manifest'
    Copy-Item -LiteralPath $standard -Destination $missingDependency -Recurse
    $casePath = Join-Path $missingDependency 'ENVIRONMENT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace(
        '- Dependency manifests: none',
        '- Dependency manifests: requirements.txt'
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $missingDependency `
        'Dependency manifest path does not exist: requirements.txt' `
        'Missing declared dependency manifest'

    $missingRequiredGit = Join-Path $tempRoot 'missing-required-git'
    Copy-Item -LiteralPath $standard -Destination $missingRequiredGit -Recurse
    $casePath = Join-Path $missingRequiredGit 'ENVIRONMENT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Required: git', '- Required: python')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $missingRequiredGit `
        'Required tools must include git' `
        'Environment manifest without Git'

    $assetCase = Join-Path $tempRoot 'asset-case'
    Copy-Item -LiteralPath $standard -Destination $assetCase -Recurse
    $assetDir = Join-Path $assetCase 'local-assets/source'
    New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
    $coreAssetPath = Join-Path $assetDir 'core.bin'
    [System.IO.File]::WriteAllText($coreAssetPath, "canonical core bytes`n", $utf8NoBom)
    $coreItem = Get-Item -LiteralPath $coreAssetPath
    $coreSha = (Get-FileHash -LiteralPath $coreAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $assetManifest = @"
# Asset Registry

## Asset Manifest

| ID | Priority | Sync | Materialize | Locator | SHA-256 | Bytes | Purpose |
|---|---|---|---|---|---|---:|---|
| A-CORE-001 | core | cloud | local-assets/source/core.bin | rclone:drive:PPS/core.bin | $coreSha | $($coreItem.Length) | Canonical source material |
| A-REF-001 | reference | local-marker | local-assets/reference/missing.bin | local-only | $([string]::new('0', 64)) | 1 | Optional reference marker |
"@
    [System.IO.File]::WriteAllText(
        (Join-Path $assetCase 'ASSETS.md'),
        $assetManifest,
        $utf8NoBom
    )
    $casePath = Join-Path $assetCase 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Assets: none', '- Assets: A-CORE-001')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    $assetValidation = Run-Validator $assetCase
    if ($assetValidation.Code -ne 0) {
        throw "Valid tiered assets were rejected: $($assetValidation.Text)"
    }
    $assetQuick = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $assetCase 'scripts/asset_check.ps1') `
        -Root $assetCase -Quick 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($assetQuick | Out-String) -notmatch 'Integrity level: existence-and-size \(quick\)') {
        throw 'PowerShell quick asset check failed.'
    }
    $fakeRcloneBin = Join-Path $tempRoot 'fake-rclone-bin'
    New-Item -ItemType Directory -Path $fakeRcloneBin -Force | Out-Null
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $fakeRclonePath = Join-Path $fakeRcloneBin 'rclone.cmd'
        $fakeRcloneText = @"
@echo off
echo {"count":%PPS_FAKE_RCLONE_COUNT%,"bytes":%PPS_FAKE_RCLONE_BYTES%}
"@
    } else {
        $fakeRclonePath = Join-Path $fakeRcloneBin 'rclone'
        $fakeRcloneText = @'
#!/usr/bin/env sh
printf '{"count":%s,"bytes":%s}\n' "$PPS_FAKE_RCLONE_COUNT" "$PPS_FAKE_RCLONE_BYTES"
'@
    }
    [System.IO.File]::WriteAllText($fakeRclonePath, $fakeRcloneText, $utf8NoBom)
    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        & chmod '+x' $fakeRclonePath
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the fake rclone fixture.' }
    }
    $originalPath = $env:PATH
    $env:PATH = $fakeRcloneBin + [System.IO.Path]::PathSeparator + $originalPath
    $env:PPS_FAKE_RCLONE_COUNT = '1'
    $env:PPS_FAKE_RCLONE_BYTES = $coreItem.Length.ToString()
    $assetFull = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $assetCase 'scripts/asset_check.ps1') `
        -Root $assetCase -All -Handoff 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($assetFull | Out-String) -notmatch 'Reference asset A-REF-001 is not materialized' -or
        ($assetFull | Out-String) -notmatch 'PASS cloud copy: A-CORE-001') {
        throw 'PowerShell full asset check mishandled a marker-only reference.'
    }
    $readiness = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $assetCase 'scripts/readiness_check.ps1') `
        -Root $assetCase -Verified 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($readiness | Out-String) -notmatch '(?m)^PPS readiness: OK$') {
        throw 'PowerShell readiness gate rejected a verified valid package.'
    }
    $readinessPending = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $assetCase 'scripts/readiness_check.ps1') `
        -Root $assetCase 2>&1)
    if ($LASTEXITCODE -ne 3 -or
        ($readinessPending | Out-String) -notmatch '(?m)^PPS readiness: VERIFY PENDING$') {
        throw 'PowerShell readiness gate accepted work without explicit verification attestation.'
    }
    $env:PPS_FAKE_RCLONE_COUNT = '0'
    $env:PPS_FAKE_RCLONE_BYTES = '0'
    $missingCloudOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $assetCase 'scripts/asset_check.ps1') `
        -Root $assetCase -Handoff 2>&1)
    if ($LASTEXITCODE -eq 0 -or
        ($missingCloudOutput | Out-String) -notmatch 'Cloud asset A-CORE-001 durable copy mismatch') {
        throw 'PowerShell asset handoff accepted a missing durable cloud copy.'
    }
    $env:PATH = $originalPath
    Remove-Item Env:PPS_FAKE_RCLONE_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:PPS_FAKE_RCLONE_BYTES -ErrorAction SilentlyContinue

    $missingCore = Join-Path $tempRoot 'missing-core-asset'
    Copy-Item -LiteralPath $assetCase -Destination $missingCore -Recurse
    Remove-Item -LiteralPath (Join-Path $missingCore 'local-assets/source/core.bin')
    $missingCoreOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $missingCore 'scripts/asset_check.ps1') `
        -Root $missingCore -Handoff 2>&1)
    if ($LASTEXITCODE -eq 0 -or
        ($missingCoreOutput | Out-String) -notmatch 'Required asset A-CORE-001 is not materialized') {
        throw 'PowerShell asset handoff accepted a missing core asset.'
    }

    $coreLocalMarker = Join-Path $tempRoot 'core-local-marker'
    Copy-Item -LiteralPath $assetCase -Destination $coreLocalMarker -Recurse
    $casePath = Join-Path $coreLocalMarker 'ASSETS.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace(
        '| A-CORE-001 | core | cloud |',
        '| A-CORE-001 | core | local-marker |'
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $coreLocalMarker `
        'Core asset A-CORE-001 cannot use local-marker' `
        'Core asset with marker-only sync'

    $referenceInWorkset = Join-Path $tempRoot 'reference-in-workset'
    Copy-Item -LiteralPath $assetCase -Destination $referenceInWorkset -Recurse
    $casePath = Join-Path $referenceInWorkset 'CONTEXT.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Assets: A-CORE-001', '- Assets: A-REF-001')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $referenceInWorkset `
        'Reference asset A-REF-001 cannot enter the current Workset' `
        'Reference asset in current Workset'

    $cloudSecretLocator = Join-Path $tempRoot 'cloud-secret-locator'
    Copy-Item -LiteralPath $assetCase -Destination $cloudSecretLocator -Recurse
    $casePath = Join-Path $cloudSecretLocator 'ASSETS.md'
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace(
        'rclone:drive:PPS/core.bin',
        'https://cloud.example/core.bin?token=secret'
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $cloudSecretLocator `
        'Locator must use restricted non-secret rclone:REMOTE:path syntax' `
        'Secret-bearing cloud locator'

    $riskCase = Join-Path $tempRoot 'asset-risk-case'
    New-Item -ItemType Directory -Path (Join-Path $riskCase 'assets') -Force | Out-Null
    & git init --quiet -b main $riskCase 2>$null
    if ($LASTEXITCODE -ne 0) {
        & git init --quiet $riskCase
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the asset-risk fixture.' }
    }
    $oversizedAsset = Join-Path $riskCase 'assets/oversized.mp4'
    $stream = [System.IO.File]::Open(
        $oversizedAsset,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $stream.SetLength(99614721)
    } finally {
        $stream.Dispose()
    }
    & git -C $riskCase add -N assets/oversized.mp4
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the asset-risk fixture.' }
    $riskOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill 'scripts/asset_check.ps1') `
        -Root $riskCase -Risk 2>&1)
    if ($LASTEXITCODE -eq 0 -or
        ($riskOutput | Out-String) -notmatch 'Tracked non-LFS file exceeds the 95 MiB safe push ceiling') {
        throw 'PowerShell asset risk audit accepted a tracked non-LFS file above 95 MiB.'
    }

    $lifecycleValid = Join-Path $tempRoot "lifecycle-valid"
    Copy-Item -LiteralPath $standard -Destination $lifecycleValid -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $lifecycleValid "DECISIONS.md"),
        "`n### D-700 [superseded]`n`n- Summary: retained history.`n" +
        "`n### F-700 [frozen]`n`n- Summary: frozen history.`n",
        $utf8NoBom
    )
    $lifecycleResult = Run-Validator $lifecycleValid
    if ($lifecycleResult.Code -ne 0) {
        throw "Valid superseded/frozen authority history was rejected: $($lifecycleResult.Text)"
    }

    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName git-case -Profile standard -ParentDir $tempRoot `
        -GitName "PPS Smoke" -GitEmail "pps-smoke@example.invalid" `
        -InstallHook
    if ($LASTEXITCODE -ne 0) { throw "Git initialization case failed." }
    $gitCase = Join-Path $tempRoot "git-case"
    $branch = ((& git -C $gitCase branch --show-current) | Out-String).Trim()
    if ($branch -ne 'main') { throw "Initializer did not create main; found '$branch'." }
    if (-not (Test-Path -LiteralPath (Join-Path $gitCase ".git/hooks/pre-commit") -PathType Leaf)) {
        throw "Initializer did not install the pre-commit hook."
    }

    $remoteCase = Join-Path $tempRoot "remote.git"
    & git init --quiet --bare -b main $remoteCase 2>$null
    if ($LASTEXITCODE -ne 0) {
        & git init --quiet --bare $remoteCase
        if ($LASTEXITCODE -ne 0) { throw "Could not create the smoke-test remote." }
    }
    & git -C $gitCase remote add origin $remoteCase
    & git -C $gitCase push --quiet -u origin main
    if ($LASTEXITCODE -ne 0) { throw "Could not push the initialized PPS project." }
    $gitStatusOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gitCase "scripts/status_check.ps1") `
        -Root $gitCase -Fetch 2>&1
    $gitStatusText = $gitStatusOutput | Out-String
    foreach ($expected in @(
        'Git-Remotes: origin',
        'Git-Upstream: origin/main',
        'Git-Ahead: 0',
        'Git-Behind: 0'
    )) {
        if ($gitStatusText -notmatch [regex]::Escape($expected)) {
            throw "Git status output is missing '$expected'."
        }
    }

    & git -C $gitCase remote add broken (Join-Path $tempRoot "does-not-exist.git")
    $failedFetchOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gitCase "scripts/status_check.ps1") `
        -Root $gitCase -Fetch 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($failedFetchOutput | Out-String) -notmatch "Git-Fetch: FAILED") {
        throw "PowerShell status returned success after a requested fetch failed."
    }
    & git -C $gitCase remote remove broken

    $peer = Join-Path $tempRoot "peer"
    & git clone --quiet $remoteCase $peer
    & git -C $peer config user.name "PPS Peer"
    & git -C $peer config user.email "pps-peer@example.invalid"
    [System.IO.File]::WriteAllText(
        (Join-Path $peer "peer.txt"),
        "remote checkpoint`n",
        $utf8NoBom
    )
    & git -C $peer add peer.txt
    & git -C $peer commit --quiet -m "test: remote checkpoint"
    & git -C $peer push --quiet
    if ($LASTEXITCODE -ne 0) { throw "Could not create the remote checkpoint." }
    $gitBehindOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gitCase "scripts/status_check.ps1") `
        -Root $gitCase -Fetch 2>&1
    if (($gitBehindOutput | Out-String) -notmatch 'Git-Behind: 1') {
        throw "Git status did not report the remote commit as behind."
    }
    & git -C $gitCase pull --quiet --ff-only
    if ($LASTEXITCODE -ne 0) { throw "Could not fast-forward the smoke-test project." }

    [System.IO.File]::WriteAllText(
        (Join-Path $gitCase "notes.txt"),
        "local checkpoint`n",
        $utf8NoBom
    )
    & git -C $gitCase add notes.txt
    & git -C $gitCase commit --quiet -m "test: local checkpoint"
    if ($LASTEXITCODE -ne 0) { throw "Valid commit was blocked by the installed hook." }
    $gitAheadOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gitCase "scripts/status_check.ps1") `
        -Root $gitCase 2>&1
    if (($gitAheadOutput | Out-String) -notmatch 'Git-Ahead: 1') {
        throw "Git status did not report the local commit as ahead."
    }

    $hookAssetManifest = @"
# Asset Registry

## Asset Manifest

| ID | Priority | Sync | Materialize | Locator | SHA-256 | Bytes | Purpose |
|---|---|---|---|---|---|---:|---|
| A-HOOK-REF | reference | local-marker | local-assets/hook/missing.bin | local-only | $([string]::new('0', 64)) | 1 | Hook snapshot marker |
"@
    [System.IO.File]::WriteAllText(
        (Join-Path $gitCase 'ASSETS.md'),
        $hookAssetManifest,
        $utf8NoBom
    )
    & git -C $gitCase add ASSETS.md
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the hook asset registry.' }
    $validAssetHook = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gitCase 'scripts/pre-commit.ps1') `
        -Root $gitCase 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "PowerShell pre-commit rejected a valid staged asset registry: $($validAssetHook | Out-String)"
    }
    & git -C $gitCase restore --staged ASSETS.md
    if ($LASTEXITCODE -ne 0) { throw 'Could not restore the hook asset fixture.' }

    $invalidContext = Join-Path $gitCase "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($invalidContext, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Excluded:.*\r?\n', '')
    [System.IO.File]::WriteAllText($invalidContext, $text, $utf8NoBom)
    & git -C $gitCase add CONTEXT.md
    & git -C $gitCase restore --worktree -- CONTEXT.md
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare the staged-snapshot hook test." }
    $psHookOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gitCase "scripts/pre-commit.ps1") `
        -Root $gitCase 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($psHookOutput | Out-String) -notmatch "staged project validation failed") {
        throw "PowerShell pre-commit accepted invalid staged PPS state."
    }
    $hookOutput = & git -C $gitCase commit -m "test: invalid state" 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($hookOutput | Out-String) -notmatch "PPS pre-commit: staged project validation failed") {
        throw "Installed pre-commit hook accepted invalid staged PPS state."
    }

    $nonempty = Join-Path $tempRoot "nonempty"
    New-Item -ItemType Directory -Path $nonempty | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $nonempty "user.txt"),
        "keep`n",
        $utf8NoBom
    )
    $nonemptyOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName nonempty -ParentDir $tempRoot -NoGit 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($nonemptyOutput | Out-String) -notmatch "Refusing to initialize a non-empty target" -or
        -not (Test-Path -LiteralPath (Join-Path $nonempty "user.txt") -PathType Leaf)) {
        throw "Initializer did not safely refuse a non-empty target."
    }

    $invalidNameOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName "invalid/name" -ParentDir $tempRoot -NoGit 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($invalidNameOutput | Out-String) -notmatch "may contain only") {
        throw "Initializer accepted an invalid project name."
    }
    $dotDotNameOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName ".." -ParentDir $tempRoot -NoGit 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($dotDotNameOutput | Out-String) -notmatch "cannot be '.' or '..'") {
        throw "Initializer accepted '..' as a project name."
    }
    $reservedNameOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName "CON" -ParentDir $tempRoot -NoGit 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($reservedNameOutput | Out-String) -notmatch "Windows-reserved device name") {
        throw "Initializer accepted a non-portable reserved project name."
    }
    $contradictoryOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName "contradictory" -ParentDir $tempRoot -NoGit -InstallHook 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($contradictoryOutput | Out-String) -notmatch "cannot be used with -NoGit") {
        throw "Initializer accepted contradictory Git options."
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
        $missingResult.Text -notmatch "Manifest ID M-002 must have exactly one row") {
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

    $duplicateActiveBlock = Join-Path $tempRoot "duplicate-active-block"
    Copy-Item -LiteralPath $standard -Destination $duplicateActiveBlock -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $duplicateActiveBlock "DECISIONS.md"),
        "`n<!-- PPS:ACTIVE:BEGIN -->`n<!-- PPS:ACTIVE:END -->`n",
        $utf8NoBom
    )
    Assert-InvalidProject $duplicateActiveBlock `
        "must contain exactly one active authority block" `
        "Duplicate active block"

    $orphanActive = Join-Path $tempRoot "orphan-active-record"
    Copy-Item -LiteralPath $standard -Destination $orphanActive -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $orphanActive "DECISIONS.md"),
        "`n### D-999 [active]`n`n- Summary: orphan.`n",
        $utf8NoBom
    )
    Assert-InvalidProject $orphanActive `
        "Active record D-999 must appear exactly once in the active block" `
        "Orphan active record"

    $duplicateGlobalId = Join-Path $tempRoot "duplicate-global-id"
    Copy-Item -LiteralPath $standard -Destination $duplicateGlobalId -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $duplicateGlobalId "DECISIONS.md"),
        "`n### M-001 [superseded]`n`n- Summary: duplicate.`n",
        $utf8NoBom
    )
    Assert-InvalidProject $duplicateGlobalId `
        "Authority ID has more than one canonical record: M-001" `
        "Duplicate canonical authority ID" `
        'DECISIONS\.md lines \d+,\d+'

    $missingExcluded = Join-Path $tempRoot "missing-excluded"
    Copy-Item -LiteralPath $standard -Destination $missingExcluded -Recurse
    $casePath = Join-Path $missingExcluded "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Excluded:.*\r?\n', '')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $missingExcluded `
        "Expected exactly one 'Excluded' field in 'Workset Manifest', found 0" `
        "Missing Excluded field"

    $packageMismatch = Join-Path $tempRoot "package-mismatch"
    Copy-Item -LiteralPath $standard -Destination $packageMismatch -Recurse
    $casePath = Join-Path $packageMismatch "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("- ID: PKG-001", "- ID: PKG-999")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $packageMismatch `
        "does not match PROJECT_STATE Package" `
        "Package mismatch"

    $wrongTypeManifest = Join-Path $tempRoot "wrong-type-manifest"
    Copy-Item -LiteralPath $standard -Destination $wrongTypeManifest -Recurse
    $casePath = Join-Path $wrongTypeManifest "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace(
        "- Methods: M-001, M-002",
        "- Methods: M-001, M-002, D-999"
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $wrongTypeManifest `
        "comma-separated list of only M IDs" `
        "Wrong authority class in manifest"

    $duplicateManifestId = Join-Path $tempRoot "duplicate-manifest-id"
    Copy-Item -LiteralPath $standard -Destination $duplicateManifestId -Recurse
    $casePath = Join-Path $duplicateManifestId "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace(
        "- Methods: M-001, M-002",
        "- Methods: M-001, M-001, M-002"
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $duplicateManifestId `
        "Methods contains duplicate IDs: M-001" `
        "Duplicate manifest ID"

    $manifestWhitespaceMerge = Join-Path $tempRoot "manifest-whitespace-merge"
    Copy-Item -LiteralPath $standard -Destination $manifestWhitespaceMerge -Recurse
    $casePath = Join-Path $manifestWhitespaceMerge "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace(
        "- Methods: M-001, M-002",
        "- Methods: M-001 M-002"
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $manifestWhitespaceMerge `
        "comma-separated list of only M IDs" `
        "Manifest IDs merged by whitespace"

    $duplicateCoverage = Join-Path $tempRoot "duplicate-coverage"
    Copy-Item -LiteralPath $standard -Destination $duplicateCoverage -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $duplicateCoverage "CONTEXT.md"),
        "| M-001 | Duplicate | docs/MAIN.md | Conflicting |`n",
        $utf8NoBom
    )
    Assert-InvalidProject $duplicateCoverage `
        "Manifest ID M-001 must have exactly one row" `
        "Duplicate coverage row" `
        'found 2 \(lines \d+,\d+\)'

    $evidencePackageMismatch = Join-Path $tempRoot "evidence-package-mismatch"
    Copy-Item -LiteralPath $evidence -Destination $evidencePackageMismatch -Recurse
    $casePath = Join-Path $evidencePackageMismatch "docs/CURRENT_REVIEW_EVIDENCE.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("- ID: PKG-001", "- ID: PKG-999")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $evidencePackageMismatch `
        "Evidence package 'PKG-999' does not match PROJECT_STATE Package" `
        "Evidence package mismatch"

    $duplicateSourceRow = Join-Path $tempRoot "duplicate-source-row"
    Copy-Item -LiteralPath $evidence -Destination $duplicateSourceRow -Recurse
    $casePath = Join-Path $duplicateSourceRow "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("- Sources: none", "- Sources: SRC-001")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    [System.IO.File]::AppendAllText(
        (Join-Path $duplicateSourceRow "SOURCE_INDEX.md"),
        "| SRC-001 | source-a | v1 | F-001 | none | review |`n" +
        "| SRC-001 | source-b | v2 | F-001 | conflict | reject |`n",
        $utf8NoBom
    )
    Assert-InvalidProject $duplicateSourceRow `
        "Source ID SRC-001 must have exactly one row" `
        "Duplicate source row" `
        'found 2 \(lines \d+,\d+\)'

    $misplacedHotField = Join-Path $tempRoot "misplaced-hot-field"
    Copy-Item -LiteralPath $standard -Destination $misplacedHotField -Recurse
    $casePath = Join-Path $misplacedHotField "PROJECT_STATE.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Protocol: PPS/1\.1\r?\n', '')
    $text += "`n## Misplaced`n`n- Protocol: PPS/1.1`n"
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $misplacedHotField `
        "Expected exactly one 'Protocol' field in 'Hot State', found 0" `
        "Hot-state field outside canonical section"

    $misplacedWorksetField = Join-Path $tempRoot "misplaced-workset-field"
    Copy-Item -LiteralPath $standard -Destination $misplacedWorksetField -Recurse
    $casePath = Join-Path $misplacedWorksetField "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Facts: none\r?\n', '')
    $text += "`n## Misplaced`n`n- Facts: none`n"
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $misplacedWorksetField `
        "Expected exactly one 'Facts' field in 'Workset Manifest', found 0" `
        "Workset field outside canonical section"

    $duplicateHotSection = Join-Path $tempRoot "duplicate-hot-section"
    Copy-Item -LiteralPath $standard -Destination $duplicateHotSection -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $duplicateHotSection "PROJECT_STATE.md"),
        "`n## Hot State`n`n- Protocol: PPS/1.1`n",
        $utf8NoBom
    )
    Assert-InvalidProject $duplicateHotSection `
        "Expected exactly one 'Hot State' section, found 2" `
        "Duplicate hot-state section"

    $reversedActiveMarkers = Join-Path $tempRoot "reversed-active-markers"
    Copy-Item -LiteralPath $standard -Destination $reversedActiveMarkers -Recurse
    $casePath = Join-Path $reversedActiveMarkers "DECISIONS.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("PPS:ACTIVE:BEGIN", "PPS:ACTIVE:TEMP")
    $text = $text.Replace("PPS:ACTIVE:END", "PPS:ACTIVE:BEGIN")
    $text = $text.Replace("PPS:ACTIVE:TEMP", "PPS:ACTIVE:END")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $reversedActiveMarkers `
        "active authority markers are out of order" `
        "Reversed active markers"

    $invalidPackageId = Join-Path $tempRoot "invalid-package-id"
    Copy-Item -LiteralPath $standard -Destination $invalidPackageId -Recurse
    $casePath = Join-Path $invalidPackageId "PROJECT_STATE.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("- Package: PKG-001", "- Package: package one")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $invalidPackageId `
        "Package must use a PKG-* ID" `
        "Invalid package ID"

    $invalidUpdatedTime = Join-Path $tempRoot "invalid-updated-time"
    Copy-Item -LiteralPath $standard -Destination $invalidUpdatedTime -Recurse
    $casePath = Join-Path $invalidUpdatedTime "PROJECT_STATE.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace(
        $text,
        '(?m)^- Updated:.*Z$',
        '- Updated: 2026-02-30T12:00:00Z'
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $invalidUpdatedTime `
        "Updated must be a UTC timestamp" `
        "Invalid Updated timestamp"

    $frozenInActiveBlock = Join-Path $tempRoot "frozen-in-active-block"
    Copy-Item -LiteralPath $standard -Destination $frozenInActiveBlock -Recurse
    $casePath = Join-Path $frozenInActiveBlock "DECISIONS.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace(
        "<!-- PPS:ACTIVE:END -->",
        "- ``D-777```n<!-- PPS:ACTIVE:END -->"
    )
    $text += "`n### D-777 [frozen]`n`n- Summary: frozen item.`n"
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $frozenInActiveBlock `
        "Active ID D-777 must have exactly one [active] record, found 0" `
        "Frozen authority in active block"

    $outsideDir = Join-Path $tempRoot "outside"
    New-Item -ItemType Directory -Path $outsideDir | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $outsideDir "MAIN.md"),
        "# Outside project`n",
        $utf8NoBom
    )
    $symlinkEscape = Join-Path $tempRoot "symlink-escape"
    Copy-Item -LiteralPath $standard -Destination $symlinkEscape -Recurse
    $linkedDir = Join-Path $symlinkEscape "linked"
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        New-Item -ItemType Junction -Path $linkedDir -Target $outsideDir | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $linkedDir -Target $outsideDir | Out-Null
    }
    $casePath = Join-Path $symlinkEscape "PROJECT_STATE.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("- Main: docs/MAIN.md", "- Main: linked/MAIN.md")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $symlinkEscape `
        "Main must not traverse a symbolic link" `
        "Symbolic-link path escape"

    $legacy = Join-Path $tempRoot "legacy-case"
    $legacyDocs = Join-Path $legacy "docs"
    New-Item -ItemType Directory -Path $legacyDocs -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $legacy "README.md"), "# Legacy project`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $legacy "AGENTS.md"), "# Agent handoff`n", $utf8NoBom)
    [System.IO.File]::WriteAllText(
        (Join-Path $legacy "PROJECT_STATE.md"),
        "# Project state`n- Main: docs/PLAN.md`n",
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $legacy "DECISIONS.md"),
        "# Decisions`nUTF-8 must not become an authority ID.`n",
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText((Join-Path $legacyDocs "PLAN.md"), "# Plan`n", $utf8NoBom)
    [System.IO.File]::WriteAllText(
        (Join-Path $legacy "ROADMAP.md"),
        "# Ordinary roadmap`n",
        $utf8NoBom
    )

    $legacyBefore = Get-TreeFingerprint $legacy
    $legacyReport = Join-Path $tempRoot "legacy-report.md"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
        -Root $legacy -OutputPath $legacyReport
    if ($LASTEXITCODE -ne 0) { throw "Legacy project audit failed." }
    $legacyAfter = Get-TreeFingerprint $legacy
    if ($legacyBefore -ne $legacyAfter) {
        throw "Legacy project audit modified the target."
    }
    $legacyReportText = [System.IO.File]::ReadAllText(
        $legacyReport,
        [System.Text.Encoding]::UTF8
    )
    if ($legacyReportText -notmatch 'Detected system: `plan-project-sync`' -or
        $legacyReportText -notmatch 'Audit mode: read-only' -or
        $legacyReportText -notmatch '\| Strict M/F/D IDs \| 0 \|' -or
        $legacyReportText -notmatch 'Recommended mode: `document`') {
        throw "Legacy project audit report is missing expected classification."
    }

    $lightweightCode = Join-Path $tempRoot 'lightweight-code-audit'
    New-Item -ItemType Directory -Path (Join-Path $lightweightCode 'docs') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $lightweightCode 'docs/SPEC.md'),
        "# Product specification`n",
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $lightweightCode 'index.html'),
        "<!doctype html><title>Game</title>`n",
        $utf8NoBom
    )
    $lightweightOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill 'scripts/audit_legacy_project.ps1') `
        -Root $lightweightCode 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($lightweightOutput | Out-String) -notmatch 'Recommended mode: `hybrid`' -or
        ($lightweightOutput | Out-String) -notmatch '\| Implementation/prototype code files \| 1 \|') {
        throw 'Legacy audit did not recognize a lightweight document/code project.'
    }

    $generatedNoise = Join-Path $tempRoot 'generated-noise-audit'
    New-Item -ItemType Directory `
        -Path (Join-Path $generatedNoise 'docs'), (Join-Path $generatedNoise 'node_modules/vendor') `
        -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $generatedNoise 'docs/PLAN.md'),
        "# Text project`n",
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $generatedNoise 'node_modules/vendor/package.json'),
        "{`"name`":`"generated-dependency`"}`n",
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $generatedNoise 'node_modules/vendor/index.js'),
        "export default true;`n",
        $utf8NoBom
    )
    $noiseOutput = @(& $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill 'scripts/audit_legacy_project.ps1') `
        -Root $generatedNoise 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($noiseOutput | Out-String) -notmatch 'Recommended mode: `document`' -or
        ($noiseOutput | Out-String) -notmatch '\| Implementation/prototype code files \| 0 \|') {
        throw 'Legacy audit treated generated dependency code as project architecture.'
    }

    $insideReport = Join-Path $legacy "MIGRATION_REPORT.md"
    $insideOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
        -Root $legacy -OutputPath $insideReport 2>&1
    if ($LASTEXITCODE -eq 0 -or
        ($insideOutput | Out-String) -notmatch "Refusing to write the audit report inside the target project" -or
        (Test-Path -LiteralPath $insideReport)) {
        throw "Audit report was incorrectly allowed inside the target."
    }

    $mixed = Join-Path $tempRoot "mixed-case"
    $mixedPlanning = Join-Path $mixed "legacy-state"
    New-Item -ItemType Directory -Path $mixedPlanning -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $legacy "AGENTS.md") -Destination $mixed
    Copy-Item -LiteralPath (Join-Path $legacy "PROJECT_STATE.md") -Destination $mixed
    Copy-Item -LiteralPath (Join-Path $legacy "DECISIONS.md") -Destination $mixed
    [System.IO.File]::WriteAllText(
        (Join-Path $mixedPlanning "STATE.md"),
        "# Legacy state`n",
        $utf8NoBom
    )
    $mixedOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
        -Root $mixed 2>&1
    if ($LASTEXITCODE -ne 0 -or
        ($mixedOutput | Out-String) -notmatch 'Detected system: `mixed`' -or
        ($mixedOutput | Out-String) -notmatch "Do not write until one authority is selected") {
        throw "Mixed state systems were not classified correctly."
    }

    $ppsWithHistory = Join-Path $tempRoot "pps-with-history"
    Copy-Item -LiteralPath $standard -Destination $ppsWithHistory -Recurse
    $ppsPlanning = Join-Path $ppsWithHistory "legacy-state"
    New-Item -ItemType Directory -Path $ppsPlanning -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $ppsPlanning "STATE.md"),
        "# Archived state`n",
        $utf8NoBom
    )
    $ppsHistoryOutput = & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
        -Root $ppsWithHistory 2>&1
    if ($LASTEXITCODE -ne 0 -or
        ($ppsHistoryOutput | Out-String) -notmatch 'Detected system: `pps`') {
        throw "A valid PPS project with retained planning history was misclassified."
    }

    Write-Host "PPS PowerShell smoke tests: OK"
} finally {
    $resolved = [System.IO.Path]::GetFullPath($tempRoot)
    $comparison = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $tempPrefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempPrefix, $comparison) -and
        (Split-Path -Leaf $resolved).StartsWith("pps-skill-smoke-")) {
        if (Test-Path -LiteralPath $resolved) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } else {
        Write-Warning "Refusing unexpected cleanup target: $resolved"
    }
}
