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

function ConvertTo-NormalizedOutputText([object[]]$Items) {
    return (@($Items | ForEach-Object { "$_" }) -join "`n")
}

function Invoke-NativeCapture([scriptblock]$Command) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 promotes native stderr to error records. Negative
        # smoke cases must capture those records and assert the exit code instead
        # of terminating the whole test harness before the assertion runs.
        $ErrorActionPreference = 'Continue'
        $output = @(& $Command)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{
        Code = $exitCode
        Output = $output
        Text = ConvertTo-NormalizedOutputText $output
    }
}

function Run-Validator([string]$ProjectRoot) {
    $validator = Join-Path $ProjectRoot "scripts/validate_project.ps1"
    $result = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File $validator -Root $ProjectRoot 2>&1
    }
    return @{
        Code = $result.Code
        Text = $result.Text
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
    $brokenSkillResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $brokenSkill "scripts/validate_skill.ps1") `
            -SkillRoot $brokenSkill 2>&1
    }
    if ($brokenSkillResult.Code -eq 0 -or
        $brokenSkillResult.Text -notmatch "Missing required skill file: references/protocol.md") {
        throw "PowerShell skill health validator accepted a missing required file."
    }

    # F-048-02: the live-line parser must stay ONE implementation. The gate
    # and the validator each carry a copy; a drift fixture makes divergence
    # loud. (The gate names its entry check Test-EntryInvokesPath, the
    # validator Test-EntryCallsPath; bodies must be identical modulo the name.)
    function Get-FunctionBody([string]$Path, [string]$Name) {
        # Brace counting is unreliable here: the bodies contain regex literals
        # like '\)\s*\{'. The closing brace of a top-level function sits in
        # column zero, so grab from the definition line to the first bare '}'.
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
        $out = New-Object System.Collections.ArrayList
        $grabbing = $false
        foreach ($l in $lines) {
            if (-not $grabbing -and
                $l -match ('^function\s+' + [regex]::Escape($Name) + '\s*\(')) {
                $grabbing = $true
            }
            if ($grabbing) {
                $null = $out.Add($l)
                if ($out.Count -gt 1 -and $l -match '^\}\s*$') { break }
            }
        }
        return ($out -join "`n")
    }
    $gatePsFile = Join-Path $skill "scripts/verify_gate.ps1"
    $validatorPsFile = Join-Path $skill "scripts/validate_project.ps1"
    $gateLiveBody = Get-FunctionBody $gatePsFile 'Get-EntryLiveLines'
    $validatorLiveBody = Get-FunctionBody $validatorPsFile 'Get-EntryLiveLines'
    if ($gateLiveBody -ne $validatorLiveBody) {
        throw 'Get-EntryLiveLines drifted between the gate and the validator.'
    }
    $gateInvBody = Get-FunctionBody $gatePsFile 'Test-EntryInvokesPath'
    $validatorInvBody = Get-FunctionBody $validatorPsFile 'Test-EntryCallsPath'
    if ($gateInvBody -ne $validatorInvBody.Replace('Test-EntryCallsPath', 'Test-EntryInvokesPath')) {
        throw 'The wiring call-shape check drifted between the gate and the validator.'
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
    $resumeResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $software 'scripts/resume_packet.ps1') -Root $software 2>&1
    }
    if ($resumeResult.Code -ne 0) {
        throw "PowerShell resume packet exited with code $($resumeResult.Code): $($resumeResult.Text)"
    }
    if ($resumeResult.Output.Count -gt 240) {
        throw "PowerShell resume packet exceeded 240 lines: $($resumeResult.Output.Count)"
    }
    if ($resumeResult.Text -notmatch '(?m)^### M-001 \[active\]$') {
        throw 'PowerShell resume packet omitted the active M-001 authority summary.'
    }
    if ($resumeResult.Text -match 'PPS_BULK_SOURCE_SENTINEL') {
        throw 'PowerShell resume packet leaked bulk source content.'
    }
    $environmentResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $software 'scripts/environment_doctor.ps1') -Root $software 2>&1
    }
    if ($environmentResult.Code -ne 0 -or
        $environmentResult.Text -notmatch '(?m)^PASS required: git$') {
        throw 'PowerShell environment doctor failed a valid required-tool check.'
    }
    $coreEnvironmentResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill 'scripts/environment_doctor.ps1') -Core 2>&1
    }
    if ($coreEnvironmentResult.Code -notin @(0, 1) -or
        $coreEnvironmentResult.Text -notmatch '(?m)^(PASS|MISSING) required: git$' -or
        $coreEnvironmentResult.Text -notmatch '(?m)^(PASS|MISSING) required: gh$') {
        throw 'PowerShell core environment check did not provide bounded pre-clone diagnostics.'
    }

    $legacyPps10 = Join-Path $tempRoot 'legacy-pps10'
    Copy-Item -LiteralPath $standard -Destination $legacyPps10 -Recurse
    $legacyStatePath = Join-Path $legacyPps10 'PROJECT_STATE.md'
    $text = [System.IO.File]::ReadAllText($legacyStatePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Protocol: PPS/1.2', '- Protocol: PPS/1.0')
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
        'PPS/1.2 is missing required file: scripts/resume_packet.ps1' `
        'Missing PPS/1.2 resume script'

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
    $unknownDoctorResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $unknownTool 'scripts/environment_doctor.ps1') `
            -Root $unknownTool 2>&1
    }
    if ($unknownDoctorResult.Code -eq 0 -or
        $unknownDoctorResult.Text -notmatch 'Unsupported optional tool: madeup-tool') {
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
    $text = [regex]::Replace($text, '(?m)^- Required: .*$', '- Required: python')
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
    $assetQuickResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $assetCase 'scripts/asset_check.ps1') `
            -Root $assetCase -Quick 2>&1
    }
    if ($assetQuickResult.Code -ne 0 -or
        $assetQuickResult.Text -notmatch 'Integrity level: existence-and-size \(quick\)') {
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
    $assetFullResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $assetCase 'scripts/asset_check.ps1') `
            -Root $assetCase -All -Handoff 2>&1
    }
    if ($assetFullResult.Code -ne 0 -or
        $assetFullResult.Text -notmatch 'Reference asset A-REF-001 is not materialized' -or
        $assetFullResult.Text -notmatch 'PASS cloud copy: A-CORE-001') {
        throw 'PowerShell full asset check mishandled a marker-only reference.'
    }
    $gateResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $assetCase 'scripts/verify_gate.ps1') `
            -Root $assetCase 2>&1
    }
    if ($gateResult.Code -ne 0) {
        throw "PowerShell verify gate failed on a valid project: $($gateResult.Text)"
    }
    $readinessResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $assetCase 'scripts/readiness_check.ps1') `
            -Root $assetCase -Verified 2>&1
    }
    if ($readinessResult.Code -ne 0 -or
        $readinessResult.Text -notmatch '(?m)^PPS readiness: OK$') {
        throw 'PowerShell readiness gate rejected a verified valid package.'
    }
    $readinessPendingResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $assetCase 'scripts/readiness_check.ps1') `
            -Root $assetCase 2>&1
    }
    if ($readinessPendingResult.Code -ne 3 -or
        $readinessPendingResult.Text -notmatch '(?m)^PPS readiness: VERIFY PENDING$') {
        throw 'PowerShell readiness gate accepted work without explicit verification attestation.'
    }
    $env:PPS_FAKE_RCLONE_COUNT = '0'
    $env:PPS_FAKE_RCLONE_BYTES = '0'
    $missingCloudResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $assetCase 'scripts/asset_check.ps1') `
            -Root $assetCase -Handoff 2>&1
    }
    if ($missingCloudResult.Code -eq 0 -or
        $missingCloudResult.Text -notmatch 'Cloud asset A-CORE-001 durable copy mismatch') {
        throw 'PowerShell asset handoff accepted a missing durable cloud copy.'
    }
    $env:PATH = $originalPath
    Remove-Item Env:PPS_FAKE_RCLONE_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:PPS_FAKE_RCLONE_BYTES -ErrorAction SilentlyContinue

    $missingCore = Join-Path $tempRoot 'missing-core-asset'
    Copy-Item -LiteralPath $assetCase -Destination $missingCore -Recurse
    Remove-Item -LiteralPath (Join-Path $missingCore 'local-assets/source/core.bin')
    $missingCoreResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $missingCore 'scripts/asset_check.ps1') `
            -Root $missingCore -Handoff 2>&1
    }
    if ($missingCoreResult.Code -eq 0 -or
        $missingCoreResult.Text -notmatch 'Required asset A-CORE-001 is not materialized') {
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
    $riskResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill 'scripts/asset_check.ps1') `
            -Root $riskCase -Risk 2>&1
    }
    if ($riskResult.Code -eq 0 -or
        $riskResult.Text -notmatch 'Tracked non-LFS file exceeds the 95 MiB safe push ceiling') {
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
    $gitStatusResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitCase "scripts/status_check.ps1") `
            -Root $gitCase -Fetch 2>&1
    }
    if ($gitStatusResult.Code -ne 0) {
        throw "PowerShell status failed for a synchronized repository: $($gitStatusResult.Text)"
    }
    foreach ($expected in @(
        'Git-Remotes: origin',
        'Git-Upstream: origin/main',
        'Git-Ahead: 0',
        'Git-Behind: 0'
    )) {
        if ($gitStatusResult.Text -notmatch [regex]::Escape($expected)) {
            throw "Git status output is missing '$expected'."
        }
    }

    & git -C $gitCase remote add broken (Join-Path $tempRoot "does-not-exist.git")
    $failedFetchResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitCase "scripts/status_check.ps1") `
            -Root $gitCase -Fetch 2>&1
    }
    if ($failedFetchResult.Code -eq 0 -or
        $failedFetchResult.Text -notmatch "Git-Fetch: FAILED") {
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
    $gitBehindResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitCase "scripts/status_check.ps1") `
            -Root $gitCase -Fetch 2>&1
    }
    if ($gitBehindResult.Code -ne 0 -or
        $gitBehindResult.Text -notmatch 'Git-Behind: 1') {
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
    $gitAheadResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitCase "scripts/status_check.ps1") `
            -Root $gitCase 2>&1
    }
    if ($gitAheadResult.Code -ne 0 -or
        $gitAheadResult.Text -notmatch 'Git-Ahead: 1') {
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
    $validAssetHookResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitCase 'scripts/pre-commit.ps1') `
            -Root $gitCase 2>&1
    }
    if ($validAssetHookResult.Code -ne 0) {
        throw "PowerShell pre-commit rejected a valid staged asset registry: $($validAssetHookResult.Text)"
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
    $psHookResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitCase "scripts/pre-commit.ps1") `
            -Root $gitCase 2>&1
    }
    if ($psHookResult.Code -eq 0 -or
        $psHookResult.Text -notmatch "staged project validation failed") {
        throw "PowerShell pre-commit accepted invalid staged PPS state."
    }
    $hookResult = Invoke-NativeCapture {
        & git -C $gitCase commit -m "test: invalid state" 2>&1
    }
    if ($hookResult.Code -eq 0 -or
        $hookResult.Text -notmatch "PPS pre-commit: staged project validation failed") {
        throw "Installed pre-commit hook accepted invalid staged PPS state."
    }

    $nonempty = Join-Path $tempRoot "nonempty"
    New-Item -ItemType Directory -Path $nonempty | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $nonempty "user.txt"),
        "keep`n",
        $utf8NoBom
    )
    $nonemptyResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/init_project.ps1") `
            -ProjectName nonempty -ParentDir $tempRoot -NoGit 2>&1
    }
    if ($nonemptyResult.Code -eq 0 -or
        $nonemptyResult.Text -notmatch "Refusing to initialize a non-empty target" -or
        -not (Test-Path -LiteralPath (Join-Path $nonempty "user.txt") -PathType Leaf)) {
        throw "Initializer did not safely refuse a non-empty target."
    }

    $invalidNameResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/init_project.ps1") `
            -ProjectName "invalid/name" -ParentDir $tempRoot -NoGit 2>&1
    }
    if ($invalidNameResult.Code -eq 0 -or
        $invalidNameResult.Text -notmatch "may contain only") {
        throw "Initializer accepted an invalid project name."
    }
    $dotDotNameResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/init_project.ps1") `
            -ProjectName ".." -ParentDir $tempRoot -NoGit 2>&1
    }
    if ($dotDotNameResult.Code -eq 0 -or
        $dotDotNameResult.Text -notmatch "cannot be '.' or '..'") {
        throw "Initializer accepted '..' as a project name."
    }
    $reservedNameResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/init_project.ps1") `
            -ProjectName "CON" -ParentDir $tempRoot -NoGit 2>&1
    }
    if ($reservedNameResult.Code -eq 0 -or
        $reservedNameResult.Text -notmatch "Windows-reserved device name") {
        throw "Initializer accepted a non-portable reserved project name."
    }
    $contradictoryResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/init_project.ps1") `
            -ProjectName "contradictory" -ParentDir $tempRoot -NoGit -InstallHook 2>&1
    }
    if ($contradictoryResult.Code -eq 0 -or
        $contradictoryResult.Text -notmatch "cannot be used with -NoGit") {
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
    $text = [regex]::Replace($text, '(?m)^- Protocol: PPS/1\.2\r?\n', '')
    $text += "`n## Misplaced`n`n- Protocol: PPS/1.2`n"
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
        "`n## Hot State`n`n- Protocol: PPS/1.2`n",
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
    $lightweightResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill 'scripts/audit_legacy_project.ps1') `
            -Root $lightweightCode 2>&1
    }
    if ($lightweightResult.Code -ne 0 -or
        $lightweightResult.Text -notmatch 'Recommended mode: `hybrid`' -or
        $lightweightResult.Text -notmatch '\| Implementation/prototype code files \| 1 \|') {
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
    $noiseResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill 'scripts/audit_legacy_project.ps1') `
            -Root $generatedNoise 2>&1
    }
    if ($noiseResult.Code -ne 0 -or
        $noiseResult.Text -notmatch 'Recommended mode: `document`' -or
        $noiseResult.Text -notmatch '\| Implementation/prototype code files \| 0 \|') {
        throw 'Legacy audit treated generated dependency code as project architecture.'
    }

    $insideReport = Join-Path $legacy "MIGRATION_REPORT.md"
    $insideResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
            -Root $legacy -OutputPath $insideReport 2>&1
    }
    if ($insideResult.Code -eq 0 -or
        $insideResult.Text -notmatch "Refusing to write the audit report inside the target project" -or
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
    $mixedResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
            -Root $mixed 2>&1
    }
    if ($mixedResult.Code -ne 0 -or
        $mixedResult.Text -notmatch 'Detected system: `mixed`' -or
        $mixedResult.Text -notmatch "Do not write until one authority is selected") {
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
    $ppsHistoryResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
            -Root $ppsWithHistory 2>&1
    }
    if ($ppsHistoryResult.Code -ne 0 -or
        $ppsHistoryResult.Text -notmatch 'Detected system: `pps`') {
        throw "A valid PPS project with retained planning history was misclassified."
    }
    if ($ppsHistoryResult.Text -notmatch 'Confidence: `high`') {
        throw "The PPS detection did not report high confidence."
    }

    # P1-01: custom-named structure is a structured candidate with evidence,
    # never "unstructured".
    $customStructure = Join-Path $tempRoot "custom-structure-audit"
    foreach ($customDir in @('rules', 'decisions', 'risks', 'notes')) {
        New-Item -ItemType Directory -Path (Join-Path $customStructure $customDir) -Force | Out-Null
    }
    [System.IO.File]::WriteAllText((Join-Path $customStructure 'rules/RULES.md'), "# Rules`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $customStructure 'decisions/DECISION_LOG.md'), "# Decisions`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $customStructure 'risks/RISKS.md'), "# Risks`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $customStructure 'notes/SPEC.md'), "# Product spec`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $customStructure 'app.py'), "print(1)`n", $utf8NoBom)
    $customStructureResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
            -Root $customStructure 2>&1
    }
    if ($customStructureResult.Code -ne 0 -or
        $customStructureResult.Text -notmatch 'Confidence:' -or
        $customStructureResult.Text -match 'Detected system: `unstructured`' -or
        $customStructureResult.Text -notmatch 'rules \(CLAUDE / RULES / rules\)' -or
        $customStructureResult.Text -notmatch 'Recommended mode: `hybrid`') {
        throw "A custom-structured project was not reported as a structured candidate. Output: $($customStructureResult.Text)"
    }

    # An empty directory is unknown, with the uncertainty said out loud.
    $emptyDir = Join-Path $tempRoot "empty-dir-audit"
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    $emptyDirResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill "scripts/audit_legacy_project.ps1") `
            -Root $emptyDir 2>&1
    }
    if ($emptyDirResult.Code -ne 0 -or
        $emptyDirResult.Text -notmatch 'Detected system: `unknown`' -or
        $emptyDirResult.Text -notmatch 'Confidence: `low`') {
        throw "An empty directory was not reported as unknown. Output: $($emptyDirResult.Text)"
    }

    $missingEvents = Join-Path $tempRoot "missing-events"
    Copy-Item -LiteralPath $standard -Destination $missingEvents -Recurse
    Remove-Item -LiteralPath (Join-Path $missingEvents "EVENTS.md")
    Assert-InvalidProject $missingEvents `
        "PPS/1.2 is missing required file: EVENTS.md" `
        "Missing PPS/1.2 events file"

    $malformedEvent = Join-Path $tempRoot "malformed-event"
    Copy-Item -LiteralPath $standard -Destination $malformedEvent -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $malformedEvent "EVENTS.md"),
        "- 2026-08-19: broken event without package or segments`n",
        $utf8NoBom
    )
    Assert-InvalidProject $malformedEvent `
        "Malformed event line in EVENTS.md" `
        "Malformed event line"

    $missingRedLines = Join-Path $tempRoot "missing-red-lines"
    Copy-Item -LiteralPath $standard -Destination $missingRedLines -Recurse
    $casePath = Join-Path $missingRedLines "AGENTS.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('## Red Lines', '## Old Section')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $missingRedLines `
        "requires a '## Red Lines' section in AGENTS.md" `
        "Missing Red Lines section"

    $barePresent = Join-Path $tempRoot "bare-present-coverage"
    Copy-Item -LiteralPath $standard -Destination $barePresent -Recurse
    $casePath = Join-Path $barePresent "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace(
        $text,
        '(?m)^\| M-001 \| (.*) \| (.*) \| .* \|$',
        '| M-001 | $1 | $2 | Present |'
    )
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $barePresent `
        "needs an evidence cell naming the command, test, or inspection" `
        "Bare Present coverage row"

    $multitaskCase = Join-Path $tempRoot "multitask-case"
    Copy-Item -LiteralPath $standard -Destination $multitaskCase -Recurse
    New-Item -ItemType Directory -Path (Join-Path $multitaskCase "task-contexts") -Force | Out-Null
    $taskCapsuleText = @(
        '# T-002 Capsule', '', '## Workset Manifest', '',
        '- Methods: none', '- Facts: none', '- Decisions: none',
        '- Sources: none', '- Assets: none', '- Components: C-ROOT',
        '- Read: PROJECT_MAP.md', '- Write: local-task-output/T-002/out.md',
        '- Verify: scripts/verify_gate.ps1', '- Excluded: none', '- Coverage: CONTEXT.md'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $multitaskCase "task-contexts/T-002.md"),
        $taskCapsuleText + "`n",
        $utf8NoBom
    )
    $taskIndexText = @(
        '# Task Index', '', '## Task Index', '',
        '### T-001', '- Title: Integration', '- Role: integrator', '- Status: active',
        '- Active Package: PKG-001', '- Capsule: CONTEXT.md', '- Output Root: none', '',
        '### T-002', '- Title: Worker', '- Role: worker', '- Status: active',
        '- Active Package: PKG-001', '- Capsule: task-contexts/T-002.md',
        '- Output Root: local-task-output/T-002'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $multitaskCase "TASK_INDEX.md"),
        $taskIndexText + "`n",
        $utf8NoBom
    )
    Assert-InvalidProject $multitaskCase `
        "Multitask projects require a 'Writer:' field in Hot State" `
        "Multitask without Writer lease"
    $casePath = Join-Path $multitaskCase "PROJECT_STATE.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Device: ', "- Writer: T-001`n- Device: ")
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    $multitaskValid = Run-Validator $multitaskCase
    if ($multitaskValid.Code -ne 0) {
        throw "Valid multitask project was rejected: $($multitaskValid.Text)"
    }

    $twoIntegrators = Join-Path $tempRoot "two-integrators"
    Copy-Item -LiteralPath $multitaskCase -Destination $twoIntegrators -Recurse
    $casePath = Join-Path $twoIntegrators "TASK_INDEX.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Role: worker', '- Role: integrator')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $twoIntegrators `
        "must have exactly one active integrator, found 2" `
        "Two active integrators"

    $workerCanonical = Join-Path $tempRoot "worker-writes-canonical"
    Copy-Item -LiteralPath $multitaskCase -Destination $workerCanonical -Recurse
    $casePath = Join-Path $workerCanonical "task-contexts/T-002.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Write: local-task-output/T-002/out.md', '- Write: DECISIONS.md')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $workerCanonical `
        "declares canonical file 'DECISIONS.md' in its Write set" `
        "Worker claiming canonical write"

    $uncheckedMerge = Join-Path $tempRoot "unchecked-merge"
    Copy-Item -LiteralPath $multitaskCase -Destination $uncheckedMerge -Recurse
    $mergesText = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: absorbs', '- Accepted: docs/MAIN.md', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: none',
        '- Result Checkpoint: none', '- Approval: none',
        '- Verification: none', '- Status: integrated'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $uncheckedMerge "MERGES.md"),
        $mergesText + "`n",
        $utf8NoBom
    )
    Assert-InvalidProject $uncheckedMerge `
        "not a resolvable Git object or the explicit lineage_incomplete marker" `
        "Integrated merge without checkpoints"

    $terminalNoReceipt = Join-Path $tempRoot "terminal-no-receipt"
    Copy-Item -LiteralPath $multitaskCase -Destination $terminalNoReceipt -Recurse
    $casePath = Join-Path $terminalNoReceipt "TASK_INDEX.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace(
        $text,
        '(?s)(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active',
        '${1}integrated')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $terminalNoReceipt `
        "no merge receipt with matching status names it" `
        "Integrated task without receipt"

    $receiptUnknownTask = Join-Path $tempRoot "receipt-unknown-task"
    Copy-Item -LiteralPath $multitaskCase -Destination $receiptUnknownTask -Recurse
    $mergesText = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-404',
        '- Relation: absorbs', '- Accepted: docs/MAIN.md', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: lineage_incomplete',
        '- Result Checkpoint: lineage_incomplete', '- Approval: none',
        '- Verification: manual', '- Status: pending'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptUnknownTask "MERGES.md"),
        $mergesText + "`n",
        $utf8NoBom
    )
    Assert-InvalidProject $receiptUnknownTask `
        "references unknown Source Task 'T-404'" `
        "Receipt referencing unknown task"

    $capsuleWriteDot = Join-Path $tempRoot "capsule-write-dot"
    Copy-Item -LiteralPath $multitaskCase -Destination $capsuleWriteDot -Recurse
    $casePath = Join-Path $capsuleWriteDot "task-contexts/T-002.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Write: local-task-output/T-002/out.md', '- Write: .')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $capsuleWriteDot `
        "Write path must name an exact file or bounded subdirectory" `
        "Task capsule repository-root Write"

    $capsuleMissingFields = Join-Path $tempRoot "capsule-missing-fields"
    Copy-Item -LiteralPath $multitaskCase -Destination $capsuleMissingFields -Recurse
    [System.IO.File]::WriteAllText(
        (Join-Path $capsuleMissingFields "task-contexts/T-003.md"),
        "# T-003 Capsule`n`n## Workset Manifest`n`n- Write: local-task-output/T-003/out.md`n",
        $utf8NoBom
    )
    [System.IO.File]::AppendAllText(
        (Join-Path $capsuleMissingFields "TASK_INDEX.md"),
        "`n### T-003`n- Title: Bare`n- Role: worker`n- Status: active`n- Active Package: PKG-001`n- Capsule: task-contexts/T-003.md`n- Output Root: local-task-output/T-003`n",
        $utf8NoBom
    )
    Assert-InvalidProject $capsuleMissingFields `
        "must declare exactly one 'Methods' field" `
        "Task capsule missing required fields"

    $outputRootEscape = Join-Path $tempRoot "output-root-escape"
    Copy-Item -LiteralPath $multitaskCase -Destination $outputRootEscape -Recurse
    $casePath = Join-Path $outputRootEscape "TASK_INDEX.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('- Output Root: local-task-output/T-002', '- Output Root: ../outside')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    Assert-InvalidProject $outputRootEscape `
        "Output Root" `
        "Task Output Root escape"

    $outputRootOverlap = Join-Path $tempRoot "output-root-overlap"
    Copy-Item -LiteralPath $multitaskCase -Destination $outputRootOverlap -Recurse
    $overlapCapsule = @(
        '# T-003 Capsule', '', '## Workset Manifest', '',
        '- Methods: none', '- Facts: none', '- Decisions: none',
        '- Sources: none', '- Assets: none', '- Components: C-ROOT',
        '- Read: PROJECT_MAP.md', '- Write: local-task-output/T-002/nested/out.md',
        '- Verify: scripts/verify_gate.ps1', '- Excluded: none', '- Coverage: CONTEXT.md'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $outputRootOverlap "task-contexts/T-003.md"),
        $overlapCapsule + "`n",
        $utf8NoBom
    )
    [System.IO.File]::AppendAllText(
        (Join-Path $outputRootOverlap "TASK_INDEX.md"),
        "`n### T-003`n- Title: Overlap`n- Role: worker`n- Status: active`n- Active Package: PKG-001`n- Capsule: task-contexts/T-003.md`n- Output Root: local-task-output/T-002/nested`n",
        $utf8NoBom
    )
    Assert-InvalidProject $outputRootOverlap `
        "overlaps Task T-002 Output Root" `
        "Overlapping task output roots"

    $rogueIntegrator = Join-Path $tempRoot "rogue-integrator"
    Copy-Item -LiteralPath $multitaskCase -Destination $rogueIntegrator -Recurse
    [System.IO.File]::WriteAllText(
        (Join-Path $rogueIntegrator "task-contexts/T-001.md"),
        "# Rogue integrator capsule`n`n## Workset Manifest`n`n- Write: docs/MAIN.md`n",
        $utf8NoBom
    )
    $casePath = Join-Path $rogueIntegrator "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = [regex]::Replace(
        $text2,
        '(?s)(### T-001\n- Title: [^\n]+\n- Role: integrator\n- Status: active\n- Active Package: PKG-001\n- Capsule: )CONTEXT\.md',
        '${1}task-contexts/T-001.md')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    Assert-InvalidProject $rogueIntegrator `
        "capsule must be CONTEXT.md itself" `
        "Integrator with a separate capsule"

    $receiptEscapePath = Join-Path $tempRoot "receipt-escape-path"
    Copy-Item -LiteralPath $multitaskCase -Destination $receiptEscapePath -Recurse
    $casePath = Join-Path $receiptEscapePath "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = [regex]::Replace(
        $text2,
        '(?s)(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active',
        '${1}integrated')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    $escapeReceipt = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: absorbs', '- Accepted: ../outside/thing.md', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: lineage_incomplete',
        '- Result Checkpoint: lineage_incomplete', '- Lineage Note: fixture migration marker',
        '- Approval: D-001', '- Verification: manual review', '- Status: integrated'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptEscapePath "MERGES.md"),
        $escapeReceipt + "`n",
        $utf8NoBom
    )
    Assert-InvalidProject $receiptEscapePath `
        "Accepted path must be a" `
        "Receipt disposition path escape"

    $receiptStatusMismatch = Join-Path $tempRoot "receipt-status-mismatch"
    Copy-Item -LiteralPath $multitaskCase -Destination $receiptStatusMismatch -Recurse
    $casePath = Join-Path $receiptStatusMismatch "DECISIONS.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('<!-- PPS:ACTIVE:END -->', "- ``D-001``" + "`n" + "<!-- PPS:ACTIVE:END -->")
    $text2 = $text2.Replace('## Status Events', (@("### D-001 [active]", "", "- Summary: Fixture approval.", "- Source: fixture.", "- Scope: MERGE-001.", "- Supersedes: none.", "- Affects: merges.", "", "## Status Events") -join "`n"))
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    $mismatchReceipt = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: absorbs', '- Accepted: docs/MAIN.md', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: lineage_incomplete',
        '- Result Checkpoint: lineage_incomplete', '- Lineage Note: fixture migration marker',
        '- Approval: D-001', '- Verification: manual review', '- Status: integrated'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptStatusMismatch "MERGES.md"),
        $mismatchReceipt + "`n", $utf8NoBom)
    Assert-InvalidProject $receiptStatusMismatch `
        "the registry and the receipt must agree" `
        "Receipt terminal status vs active registry"

    $ambiguousStampCase = Join-Path $tempRoot "ambiguous-stamp-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName ambiguous-stamp-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Ambiguous-stamp initialization failed." }
    $ambGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $ambiguousStampCase 'scripts/verify_gate.ps1') `
            -Root $ambiguousStampCase 2>&1
    }
    if ($ambGate.Code -ne 0) { throw "Verify gate failed: $($ambGate.Text)" }
    $ambStampPath = Join-Path $ambiguousStampCase '.pps/verify-stamp'
    $ambText = [System.IO.File]::ReadAllText($ambStampPath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText(
        $ambStampPath,
        "result: pass`npackage: PKG-001`n" + $ambText.Replace('result: pass', 'result: fail'),
        $utf8NoBom)
    $ambReadiness = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $ambiguousStampCase 'scripts/readiness_check.ps1') `
            -Root $ambiguousStampCase -Verified 2>&1
    }
    if ($ambReadiness.Code -ne 4 -or
        $ambReadiness.Text -notmatch 'ambiguous stamp is not evidence') {
        throw 'Readiness accepted a stamp with duplicated fields.'
    }

    $newlineEventCase = Join-Path $tempRoot "newline-event-case"
    Copy-Item -LiteralPath $standard -Destination $newlineEventCase -Recurse
    $newlineResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $newlineEventCase 'scripts/append_event.ps1') `
            -Root $newlineEventCase -Title "clean`n## Forged Section" 2>&1
    }
    if ($newlineResult.Code -eq 0 -or
        $newlineResult.Text -notmatch 'single-line') {
        throw 'Event appender accepted a multi-line segment.'
    }

    $workerWritesMain = Join-Path $tempRoot "worker-writes-main"
    Copy-Item -LiteralPath $multitaskCase -Destination $workerWritesMain -Recurse
    $casePath = Join-Path $workerWritesMain "task-contexts/T-002.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('- Write: local-task-output/T-002/out.md', '- Write: docs/MAIN.md')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    Assert-InvalidProject $workerWritesMain `
        "outside its Output Root" `
        "Worker Write outside its Output Root"

    $hollowReceipt = Join-Path $tempRoot "hollow-receipt"
    Copy-Item -LiteralPath $multitaskCase -Destination $hollowReceipt -Recurse
    $casePath = Join-Path $hollowReceipt "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = [regex]::Replace(
        $text2,
        '(?s)(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active',
        '${1}integrated')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    $hollowText = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-999', '- Source Tasks: T-002',
        '- Relation: absorbs', '- Accepted: none', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: lineage_incomplete',
        '- Result Checkpoint: lineage_incomplete', '- Approval: none',
        '- Verification: none', '- Status: integrated'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $hollowReceipt "MERGES.md"),
        $hollowText + "`n",
        $utf8NoBom
    )
    Assert-InvalidProject $hollowReceipt `
        "an integration that accepted nothing is not an integration" `
        "Hollow integrated receipt"
    Assert-InvalidProject $hollowReceipt `
        "without an Approval decision" `
        "Receipt without approval"
    Assert-InvalidProject $hollowReceipt `
        "without Verification evidence" `
        "Receipt without verification"
    Assert-InvalidProject $hollowReceipt `
        "is neither the current package" `
        "Receipt targeting phantom package"
    Assert-InvalidProject $hollowReceipt `
        "uses lineage_incomplete without a 'Lineage Note'" `
        "lineage_incomplete without note"

    $receiptBase = Join-Path $tempRoot "receipt-evidence-base"
    Copy-Item -LiteralPath $multitaskCase -Destination $receiptBase -Recurse
    $casePath = Join-Path $receiptBase "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = [regex]::Replace(
        $text2,
        '(?s)(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active',
        '${1}integrated')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    $casePath = Join-Path $receiptBase "DECISIONS.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('<!-- PPS:ACTIVE:END -->', "- ``D-001``" + "`n" + '<!-- PPS:ACTIVE:END -->')
    $decisionBlocks = @(
        '### D-001 [active]', '', '- Summary: Merge authorized.', '- Source: fixture.',
        '- Scope: MERGE-001.', '- Supersedes: none.', '- Affects: merges.', '',
        '### D-002 [rejected]', '', '- Summary: Merge NOT authorized.', '- Source: fixture.',
        '- Scope: MERGE-001.', '- Supersedes: none.', '- Affects: merges.', '',
        '## Status Events'
    ) -join "`n"
    $text2 = $text2.Replace('## Status Events', $decisionBlocks)
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    New-Item -ItemType Directory -Path (Join-Path $receiptBase "local-task-output/T-002") -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptBase "local-task-output/T-002/real.md"),
        "real artifact`n", $utf8NoBom)
    function Write-FixtureReceipt([string]$Dir, [string]$Approval, [string]$Verification, [string]$Accepted, [string]$Target) {
        $receiptText = @(
            '# Merges', '', '## Merge Receipts', '',
            '### MERGE-001', "- Target Package: $Target", '- Source Tasks: T-002',
            '- Relation: absorbs', "- Accepted: $Accepted", '- Rejected: none',
            '- Deferred: none', '- Base Checkpoint: lineage_incomplete',
            '- Result Checkpoint: lineage_incomplete', '- Lineage Note: migration per D-001',
            "- Approval: $Approval", "- Verification: $Verification", '- Status: integrated'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $Dir "MERGES.md"), $receiptText + "`n", $utf8NoBom)
    }

    $receiptPhantomPackage = Join-Path $tempRoot "receipt-phantom-package"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptPhantomPackage -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $receiptPhantomPackage "EVENTS.md"), "<!-- [PKG-999] -->`n", $utf8NoBom)
    Write-FixtureReceipt $receiptPhantomPackage 'D-001' 'validate_project pass' 'local-task-output/T-002/real.md' 'PKG-999'
    Assert-InvalidProject $receiptPhantomPackage `
        "nor recorded as a positive event line" `
        "Receipt targeting package only mentioned in a comment"

    $receiptRejectedApproval = Join-Path $tempRoot "receipt-rejected-approval"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptRejectedApproval -Recurse
    Write-FixtureReceipt $receiptRejectedApproval 'D-002' 'validate_project pass' 'local-task-output/T-002/real.md' 'PKG-001'
    Assert-InvalidProject $receiptRejectedApproval `
        "a decision that never authorized the merge cannot approve it" `
        "Receipt citing a rejected decision as approval"

    $receiptProseVerification = Join-Path $tempRoot "receipt-prose-verification"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptProseVerification -Recurse
    Write-FixtureReceipt $receiptProseVerification 'D-001' 'looked fine to me' 'local-task-output/T-002/real.md' 'PKG-001'
    Assert-InvalidProject $receiptProseVerification `
        "is not evidence the merge succeeded" `
        "Receipt with prose-only verification"

    $receiptGhostAccepted = Join-Path $tempRoot "receipt-ghost-accepted"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptGhostAccepted -Recurse
    Write-FixtureReceipt $receiptGhostAccepted 'D-001' 'validate_project pass' 'local-task-output/T-002/ghost.md' 'PKG-001'
    Assert-InvalidProject $receiptGhostAccepted `
        "an integration must point at artifacts inside the result commit" `
        "Receipt accepting a nonexistent artifact"

    $receiptMissingDoc = Join-Path $tempRoot "receipt-missing-evidence-doc"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptMissingDoc -Recurse
    Write-FixtureReceipt $receiptMissingDoc 'D-001' 'docs/nonexistent-evidence.md' 'local-task-output/T-002/real.md' 'PKG-001'
    Assert-InvalidProject $receiptMissingDoc `
        "not evidence the merge succeeded" `
        "Receipt citing a nonexistent evidence document"

    $receiptBareGate = Join-Path $tempRoot "receipt-bare-gate-name"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptBareGate -Recurse
    Write-FixtureReceipt $receiptBareGate 'D-001' 'verify_gate' 'local-task-output/T-002/real.md' 'PKG-001'
    Assert-InvalidProject $receiptBareGate `
        "not evidence the merge succeeded" `
        "Receipt naming a gate without an outcome"

    $receiptUnowned = Join-Path $tempRoot "receipt-unowned-accepted"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptUnowned -Recurse
    Write-FixtureReceipt $receiptUnowned 'D-001' 'validate_project pass' 'PROJECT_MAP.md' 'PKG-001'
    Assert-InvalidProject $receiptUnowned `
        "not inside any Source Task Output Root" `
        "Receipt accepting an artifact outside every source task root"

    $receiptSameCheckpoints = Join-Path $tempRoot "receipt-same-checkpoints"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptSameCheckpoints -Recurse
    $gitTool = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $gitTool) {
        & $gitTool.Source -C $receiptSameCheckpoints init -q 2>$null | Out-Null
        & $gitTool.Source -C $receiptSameCheckpoints -c user.name="PPS Smoke" -c user.email="pps-smoke@example.invalid" add -A 2>$null | Out-Null
        & $gitTool.Source -C $receiptSameCheckpoints -c user.name="PPS Smoke" -c user.email="pps-smoke@example.invalid" commit -qm fixture 2>$null | Out-Null
        $sameHead = (& $gitTool.Source -C $receiptSameCheckpoints rev-parse HEAD 2>$null | Select-Object -First 1)
        $sameReceipt = @(
            '# Merges', '', '## Merge Receipts', '',
            '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
            '- Relation: absorbs', '- Accepted: local-task-output/T-002/real.md',
            '- Rejected: none', '- Deferred: none', "- Base Checkpoint: $sameHead",
            "- Result Checkpoint: $sameHead", '- Approval: D-001',
            '- Verification: validate_project pass', '- Status: integrated'
        ) -join "`n"
        [System.IO.File]::WriteAllText(
            (Join-Path $receiptSameCheckpoints "MERGES.md"), $sameReceipt + "`n", $utf8NoBom)
        Assert-InvalidProject $receiptSameCheckpoints `
            "integration that changed nothing integrated nothing" `
            "Receipt with identical base and result checkpoints"

        $receiptNonMigration = Join-Path $tempRoot "receipt-nonmigration-decision"
        Copy-Item -LiteralPath $receiptBase -Destination $receiptNonMigration -Recurse
        & $gitTool.Source -C $receiptNonMigration init -q 2>$null | Out-Null
        & $gitTool.Source -C $receiptNonMigration -c user.name="PPS Smoke" -c user.email="pps-smoke@example.invalid" add -A 2>$null | Out-Null
        & $gitTool.Source -C $receiptNonMigration -c user.name="PPS Smoke" -c user.email="pps-smoke@example.invalid" commit -qm fixture 2>$null | Out-Null
        Write-FixtureReceipt $receiptNonMigration 'D-001' 'validate_project pass' 'local-task-output/T-002/real.md' 'PKG-001'
        Assert-InvalidProject $receiptNonMigration `
            "does not authorize migrating or adopting pre-layer history" `
            "lineage_incomplete citing a non-migration decision"
    }

    $taskBogusPackage = Join-Path $tempRoot "task-bogus-package"
    Copy-Item -LiteralPath $multitaskCase -Destination $taskBogusPackage -Recurse
    $casePath = Join-Path $taskBogusPackage "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('- Active Package: PKG-001', '- Active Package: NOT-A-PACKAGE-ID')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    Assert-InvalidProject $taskBogusPackage `
        "Active Package must be a PKG" `
        "Task with a malformed Active Package"

    $taskDuplicateStatus = Join-Path $tempRoot "task-duplicate-status"
    Copy-Item -LiteralPath $multitaskCase -Destination $taskDuplicateStatus -Recurse
    $casePath = Join-Path $taskDuplicateStatus "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = [regex]::Replace(
        $text2,
        '(?s)(### T-002\n- Title: Worker\n- Role: worker\n- Status: active)',
        "`${1}`n- Status: integrated")
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    Assert-InvalidProject $taskDuplicateStatus `
        "declares 'Status' 2 times" `
        "Task declaring Status twice"

    $receiptDuplicateStatus = Join-Path $tempRoot "receipt-duplicate-status"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptDuplicateStatus -Recurse
    Write-FixtureReceipt $receiptDuplicateStatus 'D-001' 'validate_project pass' 'local-task-output/T-002/real.md' 'PKG-001'
    $casePath = Join-Path $receiptDuplicateStatus "MERGES.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('- Status: integrated', "- Status: integrated`n- Status: rejected")
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    Assert-InvalidProject $receiptDuplicateStatus `
        "declares 'Status' 2 times" `
        "Receipt declaring Status twice"

    $archivedContradiction = Join-Path $tempRoot "archived-contradiction"
    Copy-Item -LiteralPath $receiptBase -Destination $archivedContradiction -Recurse
    $casePath = Join-Path $archivedContradiction "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('- Status: integrated', '- Status: archived')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    $contradictionReceipts = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: absorbs', '- Accepted: local-task-output/T-002/real.md', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: lineage_incomplete',
        '- Result Checkpoint: lineage_incomplete', '- Lineage Note: migration per D-001',
        '- Approval: D-001', '- Verification: validate_project pass', '- Status: integrated', '',
        '### MERGE-002', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: rejected', '- Accepted: none', '- Rejected: local-task-output/T-002/real.md',
        '- Deferred: none', '- Base Checkpoint: none', '- Result Checkpoint: none',
        '- Approval: D-001', '- Verification: validate_project pass',
        '- Reason: contradiction fixture', '- Status: rejected'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $archivedContradiction "MERGES.md"), $contradictionReceipts + "`n", $utf8NoBom)
    Assert-InvalidProject $archivedContradiction `
        "contradictory terminal receipts" `
        "Archived task with contradictory receipts"

    # ==== 049 adversarial matrix (PowerShell edition): evidence must prove the
    # merge actually happened. Mirrors the Bash matrix; verdicts must match.
    $matrixBase = Join-Path $tempRoot "matrix-base"
    Copy-Item -LiteralPath $receiptBase -Destination $matrixBase -Recurse
    function Write-MatrixReceipt([string]$Dir, [string]$Verification, [string]$Accepted,
        [string]$Relation, [string]$Base, [string]$Result, [string]$Approval,
        [string]$Status, [string]$Target) {
        $lines = @(
            '# Merges', '', '## Merge Receipts', '',
            '### MERGE-001',
            "- Target Package: $Target", '- Source Tasks: T-002',
            "- Relation: $Relation", "- Accepted: $Accepted",
            '- Rejected: none', '- Deferred: none',
            "- Base Checkpoint: $Base", "- Result Checkpoint: $Result",
            '- Lineage Note: migration per D-001',
            "- Approval: $Approval", "- Verification: $Verification",
            "- Status: $Status"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $Dir 'MERGES.md'), ($lines -join "`n") + "`n", $utf8NoBom)
    }

    $mxVerificationFailed = Join-Path $tempRoot "mx-verification-failed"
    Copy-Item -LiteralPath $matrixBase -Destination $mxVerificationFailed -Recurse
    Write-MatrixReceipt $mxVerificationFailed "validate_project failed" 'local-task-output/T-002/real.md' absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
    Assert-InvalidProject $mxVerificationFailed `
        "not evidence the merge succeeded" `
        "Verification that says failed must be rejected"

    $mxVerificationDirectory = Join-Path $tempRoot "mx-verification-directory"
    Copy-Item -LiteralPath $matrixBase -Destination $mxVerificationDirectory -Recurse
    Write-MatrixReceipt $mxVerificationDirectory "file_evidence: docs" 'local-task-output/T-002/real.md' absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
    Assert-InvalidProject $mxVerificationDirectory `
        "not evidence the merge succeeded" `
        "Verification naming a directory must be rejected"

    $mxDeferredGhost = Join-Path $tempRoot "mx-deferred-ghost"
    Copy-Item -LiteralPath $matrixBase -Destination $mxDeferredGhost -Recurse
    $mxCasePath = Join-Path $mxDeferredGhost 'TASK_INDEX.md'
    $mxText = [System.IO.File]::ReadAllText($mxCasePath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($mxCasePath, $mxText.Replace('- Status: integrated', '- Status: deferred'), $utf8NoBom)
    $mxDeferredReceipt = @(
        '# Merges', '', '## Merge Receipts', '', '### MERGE-001',
        '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: deferred', '- Accepted: none', '- Rejected: none',
        '- Deferred: local-task-output/T-002/ghost.md',
        '- Base Checkpoint: lineage_incomplete', '- Result Checkpoint: none',
        '- Reactivate When: when upstream lands',
        '- Approval: D-001', '- Verification: validate_project pass',
        '- Status: deferred'
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $mxDeferredGhost 'MERGES.md'), ($mxDeferredReceipt -join "`n") + "`n", $utf8NoBom)
    Assert-InvalidProject $mxDeferredGhost `
        "must keep recoverable evidence" `
        "A deferred path that does not exist must be rejected"

    $mxConsumerAbsorbs = Join-Path $tempRoot "mx-consumer-absorbs"
    Copy-Item -LiteralPath $matrixBase -Destination $mxConsumerAbsorbs -Recurse
    $mxCasePath = Join-Path $mxConsumerAbsorbs 'TASK_INDEX.md'
    $mxText = [System.IO.File]::ReadAllText($mxCasePath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText(
        $mxCasePath, $mxText.Replace('- Role: worker', '- Role: consumer'), $utf8NoBom)
    Write-MatrixReceipt $mxConsumerAbsorbs "validate_project pass" 'local-task-output/T-002/real.md' absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
    Assert-InvalidProject $mxConsumerAbsorbs `
        "is not allowed for Source Task T-002 whose Role is 'consumer'" `
        "A consumer claiming absorbs must be rejected"

    $mxConsumesOnlyNone = Join-Path $tempRoot "mx-consumes-only-none"
    Copy-Item -LiteralPath $matrixBase -Destination $mxConsumesOnlyNone -Recurse
    $mxCasePath = Join-Path $mxConsumesOnlyNone 'TASK_INDEX.md'
    $mxText = [System.IO.File]::ReadAllText($mxCasePath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText(
        $mxCasePath, $mxText.Replace('- Role: worker', '- Role: consumer'), $utf8NoBom)
    Write-MatrixReceipt $mxConsumesOnlyNone "validate_project pass" none consumes_only lineage_incomplete none D-001 integrated PKG-001
    $mxNoneResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxConsumesOnlyNone 'scripts/validate_project.ps1') `
            -Root $mxConsumesOnlyNone -Quiet 2>&1
    }
    if ($mxNoneResult.Code -ne 0) {
        throw 'consumes_only with Accepted: none was incorrectly rejected.'
    }

    $mxPackageNegative = Join-Path $tempRoot "mx-package-negative-event"
    Copy-Item -LiteralPath $matrixBase -Destination $mxPackageNegative -Recurse
    Add-Content -LiteralPath (Join-Path $mxPackageNegative 'EVENTS.md') `
        -Value '- 2026-08-22: Do not create [PKG-999] here. | files: none | verify: none | pending: none' -Encoding UTF8
    Write-MatrixReceipt $mxPackageNegative "validate_project pass" 'local-task-output/T-002/real.md' absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-999
    Assert-InvalidProject $mxPackageNegative `
        "nor recorded as a positive event line" `
        "A negated event line must not create a package identity"

    $mxTaskCapsuleOutside = Join-Path $tempRoot "mx-task-capsule-outside"
    Copy-Item -LiteralPath $matrixBase -Destination $mxTaskCapsuleOutside -Recurse
    $mxCasePath = Join-Path $mxTaskCapsuleOutside 'TASK_INDEX.md'
    $mxText = [System.IO.File]::ReadAllText($mxCasePath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText(
        $mxCasePath,
        $mxText.Replace('- Capsule: task-contexts/T-002.md', '- Capsule: docs/MAIN.md'),
        $utf8NoBom)
    Assert-InvalidProject $mxTaskCapsuleOutside `
        "must live under task-contexts/" `
        "A worker capsule outside task-contexts/ must be rejected"

    $mxTaskMissingTitle = Join-Path $tempRoot "mx-task-missing-title"
    Copy-Item -LiteralPath $matrixBase -Destination $mxTaskMissingTitle -Recurse
    $mxCasePath = Join-Path $mxTaskMissingTitle 'TASK_INDEX.md'
    $mxText = [System.IO.File]::ReadAllText($mxCasePath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText(
        $mxCasePath, ($mxText -replace '(?m)^- Title: Worker\r?\n', ''), $utf8NoBom)
    Assert-InvalidProject $mxTaskMissingTitle `
        "has no Title" `
        "A task without a Title must be rejected"

    # The gate must actually EXECUTE the manifest on this platform too.
    $mxGateExit9 = Join-Path $tempRoot "mx-gate-exit9"
    Copy-Item -LiteralPath $software -Destination $mxGateExit9 -Recurse
    New-Item -ItemType Directory -Path (Join-Path $mxGateExit9 'tests') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mxGateExit9 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mxGateExit9 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $mxStateFile = Join-Path $mxGateExit9 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $mxStateFile,
        [System.IO.File]::ReadAllText($mxStateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    [System.IO.File]::WriteAllText(
        (Join-Path $mxGateExit9 'tests/real-check.ps1'), "exit 9`n", $utf8NoBom)
    $mxManifest = Join-Path $mxGateExit9 '.pps/verify-manifest.txt'
    $mxManifestBody = [System.IO.File]::ReadAllText($mxManifest, [System.Text.Encoding]::UTF8)
    if (-not $mxManifestBody.EndsWith("`n")) { $mxManifestBody += "`n" }
    [System.IO.File]::WriteAllText(
        $mxManifest,
        $mxManifestBody + "M-002`tpowershell`t.`t60`t0`tpwsh -NoProfile -ExecutionPolicy Bypass -File tests/real-check.ps1`tfailing test`n",
        $utf8NoBom)
    $mxStamp = Join-Path $mxGateExit9 '.pps/verify-stamp'
    if (Test-Path -LiteralPath $mxStamp) { Remove-Item -LiteralPath $mxStamp }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $mxGateExit9 'scripts/session_begin.ps1') `
        -Root $mxGateExit9 2>&1 | Out-Null
    $mxGateExit9Result = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxGateExit9 'scripts/verify_gate.ps1') `
            -Root $mxGateExit9 2>&1
    }
    if ($mxGateExit9Result.Code -eq 0 -or $mxGateExit9Result.Text -notmatch 'check manifest execution') {
        throw ("The PowerShell gate stamped a project whose declared check exits 9. gate output: " + $mxGateExit9Result.Text)
    }
    if (Test-Path -LiteralPath $mxStamp) {
        throw 'The PowerShell gate left a stamp behind after a failing declared check.'
    }

    # ==== 050 field-consistency fixtures (PowerShell edition) ====

    # 050-01: the default manifest must not hardcode an interpreter; the
    # powershell row runs under the gate's own engine (pwsh or powershell).
    $defaultManifest = Join-Path $software '.pps/verify-manifest.txt'
    $defaultManifestText = [System.IO.File]::ReadAllText($defaultManifest, [System.Text.Encoding]::UTF8)
    if (-not $defaultManifestText.Contains("M-001`tpowershell`t.`t60`t0`t& ./scripts/project_verify.ps1 -Root .")) {
        throw 'The generated default manifest still hardcodes an interpreter.'
    }

    # 050-03: the timeout column is a real deadline on this platform too.
    $mxTimeout = Join-Path $tempRoot "mx-timeout"
    Copy-Item -LiteralPath $software -Destination $mxTimeout -Recurse
    New-Item -ItemType Directory -Path (Join-Path $mxTimeout 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mxTimeout 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $mxTimeoutStateFile = Join-Path $mxTimeout 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $mxTimeoutStateFile,
        [System.IO.File]::ReadAllText($mxTimeoutStateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    $mxManifestPath = Join-Path $mxTimeout '.pps/verify-manifest.txt'
    [System.IO.File]::WriteAllText(
        $mxManifestPath,
        [System.IO.File]::ReadAllText($mxManifestPath, [System.Text.Encoding]::UTF8) +
        "M-050`tpowershell`t.`t1`t0`tStart-Sleep -Seconds 30`tslow test`n",
        $utf8NoBom)
    $mxStampPath = Join-Path $mxTimeout '.pps/verify-stamp'
    if (Test-Path -LiteralPath $mxStampPath) { Remove-Item -LiteralPath $mxStampPath }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $mxTimeout 'scripts/session_begin.ps1') `
        -Root $mxTimeout 2>&1 | Out-Null
    $mxTimeoutResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxTimeout 'scripts/verify_gate.ps1') `
            -Root $mxTimeout 2>&1
    }
    if ($mxTimeoutResult.Code -eq 0 -or $mxTimeoutResult.Text -notmatch 'timed out after 1s') {
        throw ("The PowerShell gate did not enforce the timeout column. gate output: " + $mxTimeoutResult.Text)
    }
    if (Test-Path -LiteralPath $mxStampPath) {
        throw 'The PowerShell gate left a stamp behind after a timed-out check.'
    }
    $mxRunRecord = [System.IO.File]::ReadAllText(
        (Join-Path $mxTimeout '.pps/verify-run.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $mxTimedItem = $mxRunRecord.items | Where-Object { $_.id -eq 'M-050' } | Select-Object -First 1
    if ($null -eq $mxTimedItem -or $mxTimedItem.ok -or $mxTimedItem.exit_code -ne 'timeout') {
        throw 'The timed-out row was not recorded as a timeout in the run record.'
    }

    # 050-04: a working directory escaping the project root fails the row.
    $mxCwd = Join-Path $tempRoot "mx-cwd-escape"
    Copy-Item -LiteralPath $software -Destination $mxCwd -Recurse
    New-Item -ItemType Directory -Path (Join-Path $mxCwd 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mxCwd 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $mxCwdStateFile = Join-Path $mxCwd 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $mxCwdStateFile,
        [System.IO.File]::ReadAllText($mxCwdStateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    $mxManifestPath = Join-Path $mxCwd '.pps/verify-manifest.txt'
    [System.IO.File]::WriteAllText(
        $mxManifestPath,
        [System.IO.File]::ReadAllText($mxManifestPath, [System.Text.Encoding]::UTF8) +
        "M-050`tpowershell`t../`t60`t0`tGet-Location`tescape attempt`n",
        $utf8NoBom)
    $mxStampPath = Join-Path $mxCwd '.pps/verify-stamp'
    if (Test-Path -LiteralPath $mxStampPath) { Remove-Item -LiteralPath $mxStampPath }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $mxCwd 'scripts/session_begin.ps1') `
        -Root $mxCwd 2>&1 | Out-Null
    $mxCwdResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxCwd 'scripts/verify_gate.ps1') `
            -Root $mxCwd 2>&1
    }
    if ($mxCwdResult.Code -eq 0 -or $mxCwdResult.Text -notmatch "cwd '../' escapes the project root") {
        throw ("The PowerShell gate did not contain the working directory. gate output: " + $mxCwdResult.Text)
    }

    # 050-05: an unquoted Write-Host of the path must not wire the red line.
    $mxEcho = Join-Path $tempRoot "mx-echo-mention"
    Copy-Item -LiteralPath $software -Destination $mxEcho -Recurse
    New-Item -ItemType Directory -Path (Join-Path $mxEcho 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mxEcho 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $mxEchoStateFile = Join-Path $mxEcho 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $mxEchoStateFile,
        [System.IO.File]::ReadAllText($mxEchoStateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    New-Item -ItemType Directory -Path (Join-Path $mxEcho 'tests') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mxEcho 'tests/parity-harness.ps1'), "exit 0`n", $utf8NoBom)
    $mxAgents = Join-Path $mxEcho 'AGENTS.md'
    $mxAgentsText = [System.IO.File]::ReadAllText($mxAgents, [System.Text.Encoding]::UTF8)
    $mxRedStart = $mxAgentsText.IndexOf('## Red Lines')
    $mxRedEnd = $mxAgentsText.IndexOf("`n## ", $mxRedStart + 5)
    [System.IO.File]::WriteAllText(
        $mxAgents,
        $mxAgentsText.Substring(0, $mxRedEnd) + "`n- Never ship without parity. (verify: tests/parity-harness.ps1)`n" + $mxAgentsText.Substring($mxRedEnd),
        $utf8NoBom)
    $mxManifestPath = Join-Path $mxEcho '.pps/verify-manifest.txt'
    [System.IO.File]::WriteAllText(
        $mxManifestPath,
        [System.IO.File]::ReadAllText($mxManifestPath, [System.Text.Encoding]::UTF8) +
        "M-002`tpowershell`t.`t60`t0`tWrite-Host tests/parity-harness.ps1`tprint only, unquoted`n",
        $utf8NoBom)
    $mxStampPath = Join-Path $mxEcho '.pps/verify-stamp'
    if (Test-Path -LiteralPath $mxStampPath) { Remove-Item -LiteralPath $mxStampPath }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $mxEcho 'scripts/session_begin.ps1') `
        -Root $mxEcho 2>&1 | Out-Null
    $mxEchoResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxEcho 'scripts/verify_gate.ps1') `
            -Root $mxEcho 2>&1
    }
    if ($mxEchoResult.Code -eq 0 -or $mxEchoResult.Text -notmatch 'red line not wired to an executed check') {
        throw ("A Write-Host mention wired the red line. gate output: " + $mxEchoResult.Text)
    }

    # 050-05b: a real executed row satisfies the same red line.
    $mxWired = Join-Path $tempRoot "mx-wired-ps"
    Copy-Item -LiteralPath $mxEcho -Destination $mxWired -Recurse
    $mxManifestPath = Join-Path $mxWired '.pps/verify-manifest.txt'
    [System.IO.File]::WriteAllText(
        $mxManifestPath,
        [System.IO.File]::ReadAllText($mxManifestPath, [System.Text.Encoding]::UTF8).Replace(
            "M-002`tpowershell`t.`t60`t0`tWrite-Host tests/parity-harness.ps1`tprint only, unquoted",
            "M-002`tpowershell`t.`t60`t0`t& ./tests/parity-harness.ps1`treal check"),
        $utf8NoBom)
    $mxStampPath = Join-Path $mxWired '.pps/verify-stamp'
    if (Test-Path -LiteralPath $mxStampPath) { Remove-Item -LiteralPath $mxStampPath }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $mxWired 'scripts/session_begin.ps1') `
        -Root $mxWired 2>&1 | Out-Null
    $mxWiredResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxWired 'scripts/verify_gate.ps1') `
            -Root $mxWired 2>&1
    }
    if ($mxWiredResult.Code -ne 0 -or $mxWiredResult.Text -notmatch 'red line wiring: all named checks are wired to executed manifest checks') {
        throw ("An executed row did not wire the red line. gate output: " + $mxWiredResult.Text)
    }

    # P0-01 / P1-02: the real 1.1 migration matrix. Every fixture was
    # initialized by the actual PPS/1.1 skill release (v0.3.0), so the
    # migrator faces the files a real old project has. The assertion is the
    # FINAL 1.2 state (valid + gated + ready), not "files were created".
    foreach ($migFixture in @(
        'pps-1.1-document-standard',
        'pps-1.1-software-standard',
        'pps-1.1-hybrid-standard',
        'pps-1.1-document-evidence'
    )) {
        $mxMig = Join-Path $tempRoot ("mig-" + $migFixture)
        Copy-Item -LiteralPath (Join-Path $repoRoot ("tests/fixtures/" + $migFixture)) `
            -Destination $mxMig -Recurse
        $null = Invoke-NativeCapture { & git -C $mxMig init -q 2>&1 }
        $null = Invoke-NativeCapture { & git -C $mxMig add -A 2>&1 }
        $null = Invoke-NativeCapture { & git -C $mxMig -c user.name=Smoke -c user.email=smoke@example.invalid commit -qm base 2>&1 }
        $mxPreapply = @{}
        foreach ($pf in @(Get-ChildItem -LiteralPath $mxMig -File -Recurse | Where-Object { -not $_.FullName -like '*/.git/*' })) {
            $rel = $pf.FullName.Substring($mxMig.Length).TrimStart('/').TrimStart('\')
            $mxPreapply[$rel] = (Get-FileHash -LiteralPath $pf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill 'scripts/migrate_project.ps1') `
            -Root $mxMig -Mode apply -Confirm 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw ("Migration of $migFixture failed on PowerShell. See the migrator output above.")
        }
        # Core upgrade must NOT force the multitask layer onto a single-task
        # project.
        if ((Test-Path -LiteralPath (Join-Path $mxMig 'TASK_INDEX.md')) -or
            (Test-Path -LiteralPath (Join-Path $mxMig 'MERGES.md'))) {
            throw ("${migFixture}: the core migration forced the multitask layer.")
        }
        $mxStateText = [System.IO.File]::ReadAllText(
            (Join-Path $mxMig 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
        if ($mxStateText -notmatch '(?m)^- Protocol: PPS/1\.2\s*$') {
            throw "${migFixture}: the protocol was not flipped to PPS/1.2."
        }
        $mxAgentsText = [System.IO.File]::ReadAllText(
            (Join-Path $mxMig 'AGENTS.md'), [System.Text.Encoding]::UTF8)
        if ($mxAgentsText -notmatch '(?m)^##\s+Red Lines\s*$') {
            throw "${migFixture}: AGENTS.md did not gain a Red Lines section."
        }
        $mxDecisionsText = [System.IO.File]::ReadAllText(
            (Join-Path $mxMig 'DECISIONS.md'), [System.Text.Encoding]::UTF8)
        if ($mxDecisionsText -notmatch '### D-MIGRATE-001 \[active\]' -or
            $mxDecisionsText -notmatch '`D-MIGRATE-001`') {
            throw "${migFixture}: the migration decision did not enter the active block."
        }
        $mxContextText = [System.IO.File]::ReadAllText(
            (Join-Path $mxMig 'CONTEXT.md'), [System.Text.Encoding]::UTF8)
        if ($mxContextText -notmatch 'Decisions: D-MIGRATE-001' -or
            $mxContextText -notmatch '\(opened 20\d\d-\d\d-\d\d\)') {
            throw "${migFixture}: workset decisions or proposal dates were not upgraded."
        }
        $mxEventsText = [System.IO.File]::ReadAllText(
            (Join-Path $mxMig 'EVENTS.md'), [System.Text.Encoding]::UTF8)
        if ($mxEventsText -notmatch 'migration_authorized D-MIGRATE-001') {
            throw "${migFixture}: the migration event was not recorded."
        }
        foreach ($requiredScript in @('verify_gate', 'project_verify', 'append_event')) {
            foreach ($suffix in @('.ps1', '.sh')) {
                if (-not (Test-Path -LiteralPath (Join-Path $mxMig ("scripts/" + $requiredScript + $suffix)))) {
                    throw "${migFixture}: scripts/$requiredScript$suffix was not installed."
                }
            }
        }
        # The final 1.2 state must validate, gate, and reach readiness.
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxMig 'scripts/validate_project.ps1') `
            -Root $mxMig -Quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "${migFixture}: migrated project fails validation." }
        if (-not (Test-Path -LiteralPath (Join-Path $mxMig '.pps/verify-stamp'))) {
            throw "${migFixture}: the gate did not stamp the migrated project."
        }
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxMig 'scripts/readiness_check.ps1') `
            -Root $mxMig -Verified 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "${migFixture}: migrated project fails readiness." }
        # Rollback restores the pre-apply file set AND byte identity.
        $mxMigBackups = Get-ChildItem -LiteralPath (Join-Path $mxMig '.pps') -Directory -Filter 'migration-backup-*'
        $mxMigBackup = $mxMigBackups | Select-Object -First 1
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill 'scripts/migrate_project.ps1') `
            -Root $mxMig -Mode rollback -RollbackDir $mxMigBackup.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "${migFixture}: rollback failed." }
        $mxPostFiles = @(Get-ChildItem -LiteralPath $mxMig -File -Recurse | Where-Object {
            -not $_.FullName -like '*/.git/*' -and -not $_.FullName -like '*/.pps/*'
        })
        if ($mxPostFiles.Count -ne $mxPreapply.Count) {
            throw "${migFixture}: rollback file set differs ($($mxPostFiles.Count) vs $($mxPreapply.Count))."
        }
        foreach ($pf in $mxPostFiles) {
            $rel = $pf.FullName.Substring($mxMig.Length).TrimStart('/').TrimStart('\')
            if (-not $mxPreapply.ContainsKey($rel)) {
                throw "${migFixture}: rollback left new file $rel."
            }
            if ((Get-FileHash -LiteralPath $pf.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $mxPreapply[$rel]) {
                throw "${migFixture}: rollback changed bytes of $rel."
            }
        }
        $mxStateAfter = [System.IO.File]::ReadAllText(
            (Join-Path $mxMig 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
        if ($mxStateAfter -notmatch '(?m)^- Protocol: PPS/1\.1\s*$') {
            throw "${migFixture}: rollback did not restore the 1.1 protocol."
        }
    }

    # The multitask layer stays an explicit opt-in.
    $mxMt = Join-Path $tempRoot "mig-multitask"
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/fixtures/pps-1.1-document-standard') `
        -Destination $mxMt -Recurse
    $null = Invoke-NativeCapture { & git -C $mxMt init -q 2>&1 }
    $null = Invoke-NativeCapture { & git -C $mxMt add -A 2>&1 }
    $null = Invoke-NativeCapture { & git -C $mxMt -c user.name=Smoke -c user.email=smoke@example.invalid commit -qm base 2>&1 }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill 'scripts/migrate_project.ps1') `
        -Root $mxMt -Mode apply -Confirm -WithMultitask 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The -WithMultitask migration failed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $mxMt 'TASK_INDEX.md')) -or
        -not (Test-Path -LiteralPath (Join-Path $mxMt 'MERGES.md'))) {
        throw '-WithMultitask did not create the multitask registry.'
    }
    $mxMtState = [System.IO.File]::ReadAllText(
        (Join-Path $mxMt 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
    if ($mxMtState -notmatch '(?m)^- Writer: T-001\s*$') {
        throw '-WithMultitask did not write the Writer lease.'
    }

    # A migration that would not validate rolls back automatically.
    $mxFail = Join-Path $tempRoot "mig-fails"
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/fixtures/pps-1.1-document-standard') `
        -Destination $mxFail -Recurse
    $null = Invoke-NativeCapture { & git -C $mxFail init -q 2>&1 }
    $null = Invoke-NativeCapture { & git -C $mxFail add -A 2>&1 }
    $null = Invoke-NativeCapture { & git -C $mxFail -c user.name=Smoke -c user.email=smoke@example.invalid commit -qm base 2>&1 }
    $mxFailStatePath = Join-Path $mxFail 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $mxFailStatePath,
        [regex]::Replace(
            [System.IO.File]::ReadAllText($mxFailStatePath, [System.Text.Encoding]::UTF8),
            '(?m)^- Coverage:.*
?
', ''),
        $utf8NoBom)
    $mxFailResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $skill 'scripts/migrate_project.ps1') `
            -Root $mxFail -Mode apply -Confirm 2>&1
    }
    if ($mxFailResult.Code -eq 0) {
        throw 'Migration of an unrecoverable 1.1 state incorrectly succeeded.'
    }
    $mxFailState = [System.IO.File]::ReadAllText(
        (Join-Path $mxFail 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
    if ($mxFailState -notmatch '(?m)^- Protocol: PPS/1\.1\s*$') {
        throw 'A failed migration did not roll back the protocol.'
    }
    if (Test-Path -LiteralPath (Join-Path $mxFail 'EVENTS.md')) {
        throw 'A failed migration left EVENTS.md behind.'
    }

    # 050-02: a broken python3 on PATH must not kill the gate; PPS_PYTHON and
    # the python fallback both work.
    $mxPy = Join-Path $tempRoot "mx-py-fallback"
    Copy-Item -LiteralPath $software -Destination $mxPy -Recurse
    New-Item -ItemType Directory -Path (Join-Path $mxPy 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mxPy 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $mxPyStateFile = Join-Path $mxPy 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $mxPyStateFile,
        [System.IO.File]::ReadAllText($mxPyStateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    $realPy = (Get-Command python3 -ErrorAction SilentlyContinue).Source
    if ($null -eq $realPy) { $realPy = (Get-Command python -ErrorAction SilentlyContinue).Source }
    if ($null -ne $realPy) {
        $mxPrevPath = $env:PATH
        $shimDir = Join-Path $tempRoot "ps-py-shim"
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        if ($null -ne (Get-Command chmod -ErrorAction SilentlyContinue)) {
            [System.IO.File]::WriteAllText(
                (Join-Path $shimDir 'python3'), "#!/bin/sh`necho store stub`nexit 127`n",
                (New-Object System.Text.UTF8Encoding($false)))
            & chmod +x (Join-Path $shimDir 'python3') 2>$null | Out-Null
            # A wrapper, not a copy: macOS CLT python3 shims dispatch on argv[0],
            # so a python-named binary copy triggers xcode-select instead.
            [System.IO.File]::WriteAllText(
                (Join-Path $shimDir 'python'), "#!/bin/sh`nexec '$realPy' `"$@`"`n",
                (New-Object System.Text.UTF8Encoding($false)))
            & chmod +x (Join-Path $shimDir 'python') 2>$null | Out-Null
            $env:PATH = $shimDir + [System.IO.Path]::PathSeparator + $env:PATH
        }
    }
    $mxStampPath = Join-Path $mxPy '.pps/verify-stamp'
    if (Test-Path -LiteralPath $mxStampPath) { Remove-Item -LiteralPath $mxStampPath }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $mxPy 'scripts/session_begin.ps1') `
        -Root $mxPy 2>&1 | Out-Null
    $mxPyResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mxPy 'scripts/verify_gate.ps1') `
            -Root $mxPy 2>&1
    }
    if ($mxPyResult.Code -ne 0 -or -not (Test-Path -LiteralPath $mxStampPath)) {
        throw ("The PowerShell gate failed without a working python3. gate output: " + $mxPyResult.Text)
    }
    if ($null -ne $realPy) {
        $env:PATH = $mxPrevPath
    }

    $emptyDeferred = Join-Path $tempRoot "empty-deferred"
    Copy-Item -LiteralPath $receiptBase -Destination $emptyDeferred -Recurse
    $casePath = Join-Path $emptyDeferred "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('- Status: integrated', '- Status: deferred')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    $emptyDeferredReceipt = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: deferred', '- Accepted: none', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: none', '- Result Checkpoint: none',
        '- Approval: none', '- Verification: none', '- Status: deferred'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyDeferred "MERGES.md"), $emptyDeferredReceipt + "`n", $utf8NoBom)
    Assert-InvalidProject $emptyDeferred `
        "a deferral that defers nothing records nothing" `
        "Deferred receipt with no deferred set"
    Assert-InvalidProject $emptyDeferred `
        "without a 'Reactivate When' field" `
        "Deferred receipt without reactivation condition"

    $emptyRejected = Join-Path $tempRoot "empty-rejected"
    Copy-Item -LiteralPath $receiptBase -Destination $emptyRejected -Recurse
    $casePath = Join-Path $emptyRejected "TASK_INDEX.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('- Status: integrated', '- Status: rejected')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    $emptyRejectedReceipt = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: rejected', '- Accepted: none', '- Rejected: none',
        '- Deferred: none', '- Base Checkpoint: none', '- Result Checkpoint: none',
        '- Approval: none', '- Verification: none', '- Status: rejected'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyRejected "MERGES.md"), $emptyRejectedReceipt + "`n", $utf8NoBom)
    Assert-InvalidProject $emptyRejected `
        "a rejection that rejects nothing records nothing" `
        "Rejected receipt with no rejected set"
    Assert-InvalidProject $emptyRejected `
        "without a 'Reason' field" `
        "Rejected receipt without reason"

    # P1-03: an 'integrated' receipt must not mask open dispositions, and
    # every non-empty Rejected/Deferred set carries its own evidence.
    $receiptMixed = Join-Path $tempRoot "receipt-mixed-masked"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptMixed -Recurse
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptMixed 'local-task-output/T-002/drop.md'), "real drop`n", $utf8NoBom)
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptMixed 'local-task-output/T-002/later.md'), "real later`n", $utf8NoBom)
    $receiptMixedText = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: absorbs', '- Accepted: local-task-output/T-002/real.md',
        '- Rejected: local-task-output/T-002/drop.md',
        '- Deferred: local-task-output/T-002/later.md',
        '- Base Checkpoint: lineage_incomplete', '- Result Checkpoint: lineage_incomplete',
        '- Lineage Note: migration per D-001', '- Approval: D-001',
        '- Verification: validate_project pass', '- Status: integrated'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptMixed "MERGES.md"), $receiptMixedText + "`n", $utf8NoBom)
    Assert-InvalidProject $receiptMixed `
        "still lists Rejected or Deferred paths" `
        "Integrated receipt masking mixed dispositions"
    Assert-InvalidProject $receiptMixed `
        "non-empty Rejected set without a 'Reason' field" `
        "Mixed receipt missing rejection reason"
    Assert-InvalidProject $receiptMixed `
        "non-empty Deferred set without a 'Reactivate When' field" `
        "Mixed receipt missing reactivation condition"

    # The explicit partial state passes with full per-set evidence and a task
    # that stays active until the remainder is resolved.
    $receiptPartial = Join-Path $tempRoot "receipt-partial-full"
    Copy-Item -LiteralPath $receiptBase -Destination $receiptPartial -Recurse
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptPartial 'local-task-output/T-002/drop.md'), "real drop`n", $utf8NoBom)
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptPartial 'local-task-output/T-002/later.md'), "real later`n", $utf8NoBom)
    $partialTaskIndex = Join-Path $receiptPartial "TASK_INDEX.md"
    [System.IO.File]::WriteAllText(
        $partialTaskIndex,
        [System.IO.File]::ReadAllText($partialTaskIndex, [System.Text.Encoding]::UTF8).Replace(
            '- Status: integrated', '- Status: active'),
        $utf8NoBom)
    $receiptPartialText = @(
        '# Merges', '', '## Merge Receipts', '',
        '### MERGE-001', '- Target Package: PKG-001', '- Source Tasks: T-002',
        '- Relation: absorbs', '- Accepted: local-task-output/T-002/real.md',
        '- Rejected: local-task-output/T-002/drop.md',
        '- Deferred: local-task-output/T-002/later.md',
        '- Base Checkpoint: lineage_incomplete', '- Result Checkpoint: lineage_incomplete',
        '- Lineage Note: migration per D-001', '- Approval: D-001',
        '- Verification: validate_project pass',
        '- Reason: duplicates the accepted artifact.',
        '- Reactivate When: after the next package closes.',
        '- Status: partially_integrated'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $receiptPartial "MERGES.md"), $receiptPartialText + "`n", $utf8NoBom)
    $partialValid = Run-Validator $receiptPartial
    if ($partialValid.Code -ne 0) {
        throw ("A fully evidenced partially_integrated receipt was rejected. Output: " + $partialValid.Text)
    }

    # A partially integrated receipt cannot sit under a task the registry
    # calls integrated.
    $receiptPartialDone = Join-Path $tempRoot "receipt-partial-task-done"
    Copy-Item -LiteralPath $receiptPartial -Destination $receiptPartialDone -Recurse
    $partialDoneTaskIndex = Join-Path $receiptPartialDone "TASK_INDEX.md"
    [System.IO.File]::WriteAllText(
        $partialDoneTaskIndex,
        [System.IO.File]::ReadAllText($partialDoneTaskIndex, [System.Text.Encoding]::UTF8).Replace(
            '- Status: active', '- Status: integrated'),
        $utf8NoBom)
    Assert-InvalidProject $receiptPartialDone `
        "stays active until the remainder is resolved" `
        "Partially integrated task marked integrated in the registry"

    $phantomRefs = Join-Path $tempRoot "phantom-refs"
    Copy-Item -LiteralPath $multitaskCase -Destination $phantomRefs -Recurse
    $casePath = Join-Path $phantomRefs "task-contexts/T-002.md"
    $text2 = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text2 = $text2.Replace('- Methods: none', '- Methods: M-404')
    $text2 = $text2.Replace('- Components: C-ROOT', '- Components: C-404')
    [System.IO.File]::WriteAllText($casePath, $text2, $utf8NoBom)
    Assert-InvalidProject $phantomRefs `
        "references authority M-404 which is not in the DECISIONS.md active block" `
        "Task referencing phantom authority"
    Assert-InvalidProject $phantomRefs `
        "references component C-404 which does not exist" `
        "Task referencing phantom component"

    $stampCase = Join-Path $tempRoot "stamp-case"
    Copy-Item -LiteralPath $standard -Destination $stampCase -Recurse
    $stampMissingResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $stampCase 'scripts/readiness_check.ps1') `
            -Root $stampCase -Verified 2>&1
    }
    if ($stampMissingResult.Code -ne 4 -or
        $stampMissingResult.Text -notmatch 'VERIFY EVIDENCE MISSING') {
        throw 'Readiness accepted attestation without a verify stamp.'
    }
    $gateStampResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $stampCase 'scripts/verify_gate.ps1') `
            -Root $stampCase 2>&1
    }
    if ($gateStampResult.Code -ne 0) {
        throw "Verify gate failed on a valid project: $($gateStampResult.Text)"
    }
    $stampOkResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $stampCase 'scripts/readiness_check.ps1') `
            -Root $stampCase -Verified 2>&1
    }
    if ($stampOkResult.Code -ne 0 -or
        $stampOkResult.Text -notmatch '(?m)^PPS readiness: OK$') {
        throw 'Readiness rejected a stamped, attested package.'
    }
    $stampPath = Join-Path $stampCase '.pps/verify-stamp'
    $stampText = [System.IO.File]::ReadAllText($stampPath, [System.Text.Encoding]::UTF8)
    $stampText = $stampText.Replace('package: PKG-001', 'package: PKG-999')
    [System.IO.File]::WriteAllText($stampPath, $stampText, $utf8NoBom)
    $stampStaleResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $stampCase 'scripts/readiness_check.ps1') `
            -Root $stampCase -Verified 2>&1
    }
    if ($stampStaleResult.Code -ne 4 -or
        $stampStaleResult.Text -notmatch 'VERIFY EVIDENCE STALE') {
        throw 'Readiness accepted a stale verify stamp for another package.'
    }

    $eventAppendCase = Join-Path $tempRoot "event-append-case"
    Copy-Item -LiteralPath $standard -Destination $eventAppendCase -Recurse
    $appendResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $eventAppendCase 'scripts/append_event.ps1') `
            -Root $eventAppendCase -Title 'Smoke event' -Files 'docs/MAIN.md' -Verify 'gate pass' 2>&1
    }
    if ($appendResult.Code -ne 0) {
        throw "Event appender failed: $($appendResult.Text)"
    }
    $eventsText = [System.IO.File]::ReadAllText(
        (Join-Path $eventAppendCase 'EVENTS.md'), [System.Text.Encoding]::UTF8)
    if ($eventsText -notmatch '\[PKG-001\] Smoke event \| files: docs/MAIN\.md \| verify: gate pass \| pending: none') {
        throw 'Appended event line has the wrong format.'
    }
    $eventAppendValid = Run-Validator $eventAppendCase
    if ($eventAppendValid.Code -ne 0) {
        throw "Project with appended event failed validation: $($eventAppendValid.Text)"
    }
    $pipeResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $eventAppendCase 'scripts/append_event.ps1') `
            -Root $eventAppendCase -Title 'bad | title' 2>&1
    }
    if ($pipeResult.Code -eq 0 -or
        $pipeResult.Text -notmatch "must not contain the '\|' separator") {
        throw 'Event appender accepted a title containing the separator.'
    }

    $boundaryCase = Join-Path $tempRoot "boundary-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName boundary-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Boundary-case initialization failed." }
    [System.IO.File]::WriteAllText(
        (Join-Path $boundaryCase "rogue.txt"), "rogue content`n", $utf8NoBom)
    $boundaryFail = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCase 'scripts/boundary_check.ps1') `
            -Root $boundaryCase 2>&1
    }
    if ($boundaryFail.Code -eq 0 -or
        $boundaryFail.Text -notmatch 'unclaimed_write: rogue.txt') {
        throw 'Boundary check accepted an unclaimed write.'
    }
    $boundaryNoBaseline = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCase 'scripts/boundary_check.ps1') `
            -Root $boundaryCase -AllowPreexisting 2>&1
    }
    if ($boundaryNoBaseline.Code -eq 0 -or
        $boundaryNoBaseline.Text -notmatch 'requires a recorded baseline') {
        throw 'Boundary check downgraded changes without a recorded baseline.'
    }
    $null = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCase 'scripts/boundary_check.ps1') `
            -Root $boundaryCase -RecordBaseline 2>&1
    }
    $boundaryPre = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCase 'scripts/boundary_check.ps1') `
            -Root $boundaryCase -AllowPreexisting 2>&1
    }
    if ($boundaryPre.Code -ne 0 -or
        $boundaryPre.Text -notmatch 'preexisting \(baseline\): rogue.txt') {
        throw 'Boundary check did not classify a baselined preexisting change.'
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $boundaryCase "rogue2.txt"), "new rogue`n", $utf8NoBom)
    $boundaryNewRogue = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCase 'scripts/boundary_check.ps1') `
            -Root $boundaryCase -AllowPreexisting 2>&1
    }
    if ($boundaryNewRogue.Code -eq 0 -or
        $boundaryNewRogue.Text -notmatch 'unclaimed_write: rogue2.txt') {
        throw 'Boundary check treated a post-baseline change as preexisting.'
    }
    Remove-Item -LiteralPath (Join-Path $boundaryCase "rogue2.txt")
    [System.IO.File]::WriteAllText(
        (Join-Path $boundaryCase "rogue.txt"), "rogue content rewritten after baseline`n", $utf8NoBom)
    $boundaryRewritten = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCase 'scripts/boundary_check.ps1') `
            -Root $boundaryCase -AllowPreexisting 2>&1
    }
    if ($boundaryRewritten.Code -eq 0 -or
        $boundaryRewritten.Text -notmatch 'baselined path changed again after the baseline') {
        throw 'Boundary check exempted a baselined path whose content changed.'
    }
    Remove-Item -LiteralPath (Join-Path $boundaryCase "rogue.txt")
    Remove-Item -LiteralPath (Join-Path $boundaryCase ".pps/boundary-baseline")
    [System.IO.File]::AppendAllText(
        (Join-Path $boundaryCase "docs/MAIN.md"), "update`n", $utf8NoBom)
    $boundaryOk = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCase 'scripts/boundary_check.ps1') `
            -Root $boundaryCase 2>&1
    }
    if ($boundaryOk.Code -ne 0 -or
        $boundaryOk.Text -notmatch 'claimed: docs/MAIN.md' -or
        $boundaryOk.Text -notmatch '(?m)^PPS boundary check: OK$') {
        throw 'Boundary check rejected a claimed write.'
    }

    $terminalSubject = Join-Path $tempRoot "boundary-terminal-subject"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName boundary-terminal-subject -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Boundary-terminal initialization failed." }
    New-Item -ItemType Directory -Path (Join-Path $terminalSubject "task-contexts") -Force | Out-Null
    $terminalCapsule = @(
        '# T-002 Capsule', '', '## Workset Manifest', '',
        '- Methods: none', '- Facts: none', '- Decisions: none',
        '- Sources: none', '- Assets: none', '- Components: C-ROOT',
        '- Read: PROJECT_MAP.md', '- Write: local-task-output/T-002/out.md',
        '- Verify: scripts/verify_gate.ps1', '- Excluded: none', '- Coverage: CONTEXT.md'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $terminalSubject "task-contexts/T-002.md"),
        $terminalCapsule + "`n", $utf8NoBom)
    $terminalIndex = @(
        '# Task Index', '', '## Task Index', '',
        '### T-001', '- Title: I', '- Role: integrator', '- Status: active',
        '- Active Package: PKG-001', '- Capsule: CONTEXT.md', '- Output Root: none', '',
        '### T-002', '- Title: W', '- Role: worker', '- Status: rejected',
        '- Active Package: PKG-001', '- Capsule: task-contexts/T-002.md',
        '- Output Root: local-task-output/T-002'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $terminalSubject "TASK_INDEX.md"),
        $terminalIndex + "`n", $utf8NoBom)
    $terminalResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $terminalSubject 'scripts/boundary_check.ps1') `
            -Root $terminalSubject -Task T-002 2>&1
    }
    if ($terminalResult.Code -eq 0 -or
        $terminalResult.Text -notmatch 'only an active task holds write authority') {
        throw 'Boundary check granted write authority to a terminal-status task.'
    }

    $boundaryCanonical = Join-Path $tempRoot "boundary-canonical"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName boundary-canonical -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Boundary-canonical initialization failed." }
    $casePath = Join-Path $boundaryCanonical "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Write:.*$', '- Write: docs/MAIN.md')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    & git -C $boundaryCanonical add CONTEXT.md 2>$null
    & git -C $boundaryCanonical commit -qm 'narrow write set' 2>$null
    [System.IO.File]::AppendAllText(
        (Join-Path $boundaryCanonical "DECISIONS.md"), "drift`n", $utf8NoBom)
    $boundaryCanonicalResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $boundaryCanonical 'scripts/boundary_check.ps1') `
            -Root $boundaryCanonical 2>&1
    }
    if ($boundaryCanonicalResult.Code -eq 0 -or
        $boundaryCanonicalResult.Text -notmatch 'unclaimed_write: DECISIONS.md') {
        throw 'Boundary check auto-claimed an undeclared canonical file.'
    }

    # --- Necessary-path fixtures (D-CORE-012..020) -------------------------
    $gateNoSnapshot = Join-Path $tempRoot "gate-no-snapshot-case"
    Copy-Item -LiteralPath $software -Destination $gateNoSnapshot -Recurse
    # The objective anchor comes from the same session_begin run; deleting
    # only the snapshot isolates the relay check from the anchor check.
    $noSnapshotSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gateNoSnapshot 'scripts/session_begin.ps1') `
            -Root $gateNoSnapshot 2>&1
    }
    foreach ($leftover in @('.pps/session-snapshot', '.pps/verify-stamp')) {
        $leftoverPath = Join-Path $gateNoSnapshot $leftover
        if (Test-Path -LiteralPath $leftoverPath) { Remove-Item -LiteralPath $leftoverPath }
    }
    $noSnapshotResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gateNoSnapshot 'scripts/verify_gate.ps1') `
            -Root $gateNoSnapshot 2>&1
    }
    if ($noSnapshotResult.Code -eq 0 -or $noSnapshotResult.Text -notmatch 'Relay: SNAPSHOT MISSING') {
        throw 'Verify gate stamped a software package with no session snapshot.'
    }
    if (Test-Path -LiteralPath (Join-Path $gateNoSnapshot '.pps/verify-stamp')) {
        throw 'Verify gate wrote a stamp without a session snapshot.'
    }

    $gateOnlyOverwrite = Join-Path $tempRoot "gate-only-overwrite-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName gate-only-overwrite-case -Mode software -Profile standard `
        -ParentDir $tempRoot -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Gate-only overwrite fixture initialization failed.' }
    [System.IO.File]::WriteAllText(
        (Join-Path $gateOnlyOverwrite 'docs/MAIN.md'),
        "session A hardening not committed`n", $utf8NoBom)
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gateOnlyOverwrite 'scripts/session_begin.ps1') `
        -Root $gateOnlyOverwrite | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $gateOnlyOverwrite 'docs/MAIN.md'),
        "session B wholesale overwrite`n", $utf8NoBom)
    $stampToClear = Join-Path $gateOnlyOverwrite '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    $gateOnlyResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gateOnlyOverwrite 'scripts/verify_gate.ps1') `
            -Root $gateOnlyOverwrite 2>&1
    }
    if ($gateOnlyResult.Code -eq 0 -or $gateOnlyResult.Text -notmatch 'protected_overwrite: docs/MAIN\.md') {
        throw 'Running only the verify gate allowed a handover overwrite to be stamped.'
    }
    if (Test-Path -LiteralPath $stampToClear) {
        throw 'Verify gate stamped over overwritten handover work.'
    }

    $staleSnapshot = Join-Path $tempRoot "stale-snapshot-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName stale-snapshot-case -Mode software -Profile standard `
        -ParentDir $tempRoot -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Stale snapshot fixture initialization failed.' }
    [System.IO.File]::WriteAllText(
        (Join-Path $staleSnapshot 'docs/MAIN.md'), "session A work`n", $utf8NoBom)
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $staleSnapshot 'scripts/session_begin.ps1') `
        -Root $staleSnapshot | Out-Null
    $snapshotFilePath = Join-Path $staleSnapshot '.pps/session-snapshot'
    $snapshotBody = [System.IO.File]::ReadAllText($snapshotFilePath, [System.Text.Encoding]::UTF8)
    $epochMatch = [regex]::Match($snapshotBody, '(?m)^started_epoch: (\d+)')
    $agedEpoch = [long]$epochMatch.Groups[1].Value - (30 * 86400)
    $snapshotBody = [regex]::Replace(
        $snapshotBody, '(?m)^started_epoch: \d+', "started_epoch: $agedEpoch")
    [System.IO.File]::WriteAllText($snapshotFilePath, $snapshotBody, $utf8NoBom)
    $staleResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $staleSnapshot 'scripts/session_begin.ps1') `
            -Root $staleSnapshot 2>&1
    }
    if ($staleResult.Code -ne 3 -or $staleResult.Text -notmatch 'stale session snapshot') {
        throw 'An aged snapshot released its claim without a takeover.'
    }
    if ($staleResult.Text -notmatch 'Age does not release the claim') {
        throw 'The stale-snapshot refusal did not explain that age never releases the claim.'
    }
    $takeoverResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $staleSnapshot 'scripts/session_begin.ps1') `
            -Root $staleSnapshot -Takeover 2>&1
    }
    if ($takeoverResult.Text -notmatch 'Relay event recorded') {
        throw 'Takeover did not record a relay event.'
    }
    $staleEvents = [System.IO.File]::ReadAllText(
        (Join-Path $staleSnapshot 'EVENTS.md'), [System.Text.Encoding]::UTF8)
    if ($staleEvents -notmatch 'relay takeover') {
        throw 'The relay takeover is absent from the chronicle.'
    }

    $commentWiring = Join-Path $tempRoot "comment-wiring-case"
    Copy-Item -LiteralPath $software -Destination $commentWiring -Recurse
    New-Item -ItemType Directory -Path (Join-Path $commentWiring 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $commentWiring 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $commentWiring 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    New-Item -ItemType Directory -Path (Join-Path $commentWiring 'tests') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $commentWiring 'tests/parity-harness.ps1'), "exit 0`n", $utf8NoBom)
    $agentsFile = Join-Path $commentWiring 'AGENTS.md'
    $agentsBody = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
    $redIndex = $agentsBody.IndexOf('## Red Lines')
    $nextIndex = $agentsBody.IndexOf("`n## ", $redIndex + 5)
    $agentsBody = $agentsBody.Substring(0, $nextIndex) +
        "`n- Never ship without parity. (verify: tests/parity-harness.ps1)`n" +
        $agentsBody.Substring($nextIndex)
    [System.IO.File]::WriteAllText($agentsFile, $agentsBody, $utf8NoBom)
    $entryFile = Join-Path $commentWiring 'scripts/project_verify.ps1'
    $entryBody = [System.IO.File]::ReadAllText($entryFile, [System.Text.Encoding]::UTF8)
    $entryBody = $entryBody.Replace(
        '# Add project-specific checks here, for example:',
        "# also see tests/parity-harness.ps1 someday`n# Add project-specific checks here, for example:")
    [System.IO.File]::WriteAllText($entryFile, $entryBody, $utf8NoBom)
    $stampToClear = Join-Path $commentWiring '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $commentWiring 'scripts/session_begin.ps1') `
        -Root $commentWiring 2>&1 | Out-Null
    $commentResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $commentWiring 'scripts/verify_gate.ps1') `
            -Root $commentWiring 2>&1
    }
    if ($commentResult.Code -eq 0 -or $commentResult.Text -notmatch 'no manifest check ran it successfully') {
        throw 'A red line path mentioned only in a comment satisfied the wiring gate.'
    }

    $alwaysTrue = Join-Path $tempRoot "always-true-case"
    Copy-Item -LiteralPath $software -Destination $alwaysTrue -Recurse
    New-Item -ItemType Directory -Path (Join-Path $alwaysTrue 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $alwaysTrue 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $alwaysTrue 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    $entryFile = Join-Path $alwaysTrue 'scripts/project_verify.ps1'
    $entryBody = [System.IO.File]::ReadAllText($entryFile, [System.Text.Encoding]::UTF8)
    $entryBody = [regex]::Replace(
        $entryBody,
        '(?s)Invoke-Check "behavioral probe \(scripts/e2e_probe\.ps1\)" \{.*?\n\}',
        "Invoke-Check `"behavioral probe`" {`n    `$true`n}")
    [System.IO.File]::WriteAllText($entryFile, $entryBody, $utf8NoBom)
    $stampToClear = Join-Path $alwaysTrue '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $alwaysTrue 'scripts/session_begin.ps1') `
        -Root $alwaysTrue 2>&1 | Out-Null
    $alwaysTrueResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $alwaysTrue 'scripts/verify_gate.ps1') `
            -Root $alwaysTrue 2>&1
    }
    if ($alwaysTrueResult.Code -eq 0 -or $alwaysTrueResult.Text -notmatch 'behavioral check asserts nothing') {
        throw 'An always-true behavioral check satisfied the gate.'
    }

    $coverageUnwired = Join-Path $tempRoot "coverage-unwired-case"
    Copy-Item -LiteralPath $standard -Destination $coverageUnwired -Recurse
    New-Item -ItemType Directory -Path (Join-Path $coverageUnwired 'prototypes') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $coverageUnwired 'prototypes/hardening-smoke.ps1'), "exit 0`n", $utf8NoBom)
    $covFile = Join-Path $coverageUnwired 'CONTEXT.md'
    $covBody = [System.IO.File]::ReadAllText($covFile, [System.Text.Encoding]::UTF8)
    $covBody = [regex]::Replace(
        $covBody, '(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', '${1} prototypes/hardening-smoke.ps1 |', 1)
    [System.IO.File]::WriteAllText($covFile, $covBody, $utf8NoBom)
    Assert-InvalidProject $coverageUnwired `
        "no manifest check ran it successfully" `
        "Coverage evidence that the gate never runs"

    $noteLaundry = Join-Path $tempRoot "note-laundry-case"
    Copy-Item -LiteralPath $standard -Destination $noteLaundry -Recurse
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $noteLaundry 'scripts/append_event.ps1') `
        -Root $noteLaundry -Title 'note shipped installer hardening' `
        -Files 'none' -Verify 'none' -Pending 'none' | Out-Null
    Assert-InvalidProject $noteLaundry `
        "informational prefix but claims a closing action" `
        "Informational prefix laundering a real closure"

    $installerRuntime = Join-Path $tempRoot "installer-runtime-case"
    Copy-Item -LiteralPath $software -Destination $installerRuntime -Recurse
    [System.IO.File]::WriteAllText(
        (Join-Path $installerRuntime 'Install-Product.ps1'), "param()`n", $utf8NoBom)
    $installerResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $installerRuntime 'scripts/validate_project.ps1') `
            -Root $installerRuntime 2>&1
    }
    if ($installerResult.Text -notmatch "declares no '## Runtime Surfaces' row") {
        throw 'An installer-shaped project with no runtime surface produced no warning.'
    }

    # --- 047 necessary-path round two (F-047-01..04) -----------------------
    $gateBoundaryMissing = Join-Path $tempRoot "gate-boundary-missing-case"
    Copy-Item -LiteralPath $software -Destination $gateBoundaryMissing -Recurse
    foreach ($leftover in @('scripts/boundary_check.ps1', '.pps/verify-stamp')) {
        $leftoverPath = Join-Path $gateBoundaryMissing $leftover
        if (Test-Path -LiteralPath $leftoverPath) { Remove-Item -LiteralPath $leftoverPath }
    }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $gateBoundaryMissing 'scripts/session_begin.ps1') `
        -Root $gateBoundaryMissing 2>&1 | Out-Null
    $gateBoundaryResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gateBoundaryMissing 'scripts/verify_gate.ps1') `
            -Root $gateBoundaryMissing 2>&1
    }
    if ($gateBoundaryResult.Code -eq 0 -or $gateBoundaryResult.Text -notmatch 'Relay: BOUNDARY MISSING') {
        throw 'Deleting boundary_check.ps1 restored the no-lock gate path.'
    }
    if (Test-Path -LiteralPath (Join-Path $gateBoundaryMissing '.pps/verify-stamp')) {
        throw 'The gate stamped without the handover checker.'
    }

    $deadFnWiring = Join-Path $tempRoot "dead-fn-wiring-case"
    Copy-Item -LiteralPath $software -Destination $deadFnWiring -Recurse
    New-Item -ItemType Directory -Path (Join-Path $deadFnWiring 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $deadFnWiring 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $deadFnWiring 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    New-Item -ItemType Directory -Path (Join-Path $deadFnWiring 'tests') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $deadFnWiring 'tests/parity-harness.ps1'), "exit 0`n", $utf8NoBom)
    $agentsFile = Join-Path $deadFnWiring 'AGENTS.md'
    $agentsBody = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
    $redIndex = $agentsBody.IndexOf('## Red Lines')
    $nextIndex = $agentsBody.IndexOf("`n## ", $redIndex + 5)
    $agentsBody = $agentsBody.Substring(0, $nextIndex) +
        "`n- Never ship without parity. (verify: tests/parity-harness.ps1)`n" +
        $agentsBody.Substring($nextIndex)
    [System.IO.File]::WriteAllText($agentsFile, $agentsBody, $utf8NoBom)
    $entryFile = Join-Path $deadFnWiring 'scripts/project_verify.ps1'
    $entryBody = [System.IO.File]::ReadAllText($entryFile, [System.Text.Encoding]::UTF8)
    $entryBody += "`nfunction Never-Called { & tests/parity-harness.ps1 }`n"
    [System.IO.File]::WriteAllText($entryFile, $entryBody, $utf8NoBom)
    $stampToClear = Join-Path $deadFnWiring '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $deadFnWiring 'scripts/session_begin.ps1') `
        -Root $deadFnWiring 2>&1 | Out-Null
    $deadFnResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $deadFnWiring 'scripts/verify_gate.ps1') `
            -Root $deadFnWiring 2>&1
    }
    if ($deadFnResult.Code -eq 0 -or $deadFnResult.Text -notmatch 'no manifest check ran it successfully') {
        throw 'A red line path inside an unreached function satisfied the wiring gate.'
    }

    $deadBranchWiring = Join-Path $tempRoot "dead-branch-wiring-case"
    Copy-Item -LiteralPath $software -Destination $deadBranchWiring -Recurse
    New-Item -ItemType Directory -Path (Join-Path $deadBranchWiring 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $deadBranchWiring 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $deadBranchWiring 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    New-Item -ItemType Directory -Path (Join-Path $deadBranchWiring 'tests') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $deadBranchWiring 'tests/parity-harness.ps1'), "exit 0`n", $utf8NoBom)
    $agentsFile = Join-Path $deadBranchWiring 'AGENTS.md'
    $agentsBody = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
    $redIndex = $agentsBody.IndexOf('## Red Lines')
    $nextIndex = $agentsBody.IndexOf("`n## ", $redIndex + 5)
    $agentsBody = $agentsBody.Substring(0, $nextIndex) +
        "`n- Never ship without parity. (verify: tests/parity-harness.ps1)`n" +
        $agentsBody.Substring($nextIndex)
    [System.IO.File]::WriteAllText($agentsFile, $agentsBody, $utf8NoBom)
    $entryFile = Join-Path $deadBranchWiring 'scripts/project_verify.ps1'
    $entryBody = [System.IO.File]::ReadAllText($entryFile, [System.Text.Encoding]::UTF8)
    $entryBody += "`nif (`$false) { & tests/parity-harness.ps1 }`n"
    [System.IO.File]::WriteAllText($entryFile, $entryBody, $utf8NoBom)
    $stampToClear = Join-Path $deadBranchWiring '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $deadBranchWiring 'scripts/session_begin.ps1') `
        -Root $deadBranchWiring 2>&1 | Out-Null
    $deadBranchResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $deadBranchWiring 'scripts/verify_gate.ps1') `
            -Root $deadBranchWiring 2>&1
    }
    if ($deadBranchResult.Code -eq 0 -or $deadBranchResult.Text -notmatch 'no manifest check ran it successfully') {
        throw 'A red line path inside a dead branch satisfied the wiring gate.'
    }

    $mentionWiring = Join-Path $tempRoot "mention-wiring-case"
    Copy-Item -LiteralPath $software -Destination $mentionWiring -Recurse
    New-Item -ItemType Directory -Path (Join-Path $mentionWiring 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mentionWiring 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $mentionWiring 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    New-Item -ItemType Directory -Path (Join-Path $mentionWiring 'tests') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mentionWiring 'tests/parity-harness.ps1'), "exit 0`n", $utf8NoBom)
    $agentsFile = Join-Path $mentionWiring 'AGENTS.md'
    $agentsBody = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
    $redIndex = $agentsBody.IndexOf('## Red Lines')
    $nextIndex = $agentsBody.IndexOf("`n## ", $redIndex + 5)
    $agentsBody = $agentsBody.Substring(0, $nextIndex) +
        "`n- Never ship without parity. (verify: tests/parity-harness.ps1)`n" +
        $agentsBody.Substring($nextIndex)
    [System.IO.File]::WriteAllText($agentsFile, $agentsBody, $utf8NoBom)
    # F-048-03: a live line that only MENTIONS the path in a string literal
    # is not a call.
    $entryFile = Join-Path $mentionWiring 'scripts/project_verify.ps1'
    $entryBody = [System.IO.File]::ReadAllText($entryFile, [System.Text.Encoding]::UTF8)
    $entryBody += "`nWrite-Host 'see tests/parity-harness.ps1'`n"
    [System.IO.File]::WriteAllText($entryFile, $entryBody, $utf8NoBom)
    $stampToClear = Join-Path $mentionWiring '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $mentionWiring 'scripts/session_begin.ps1') `
        -Root $mentionWiring 2>&1 | Out-Null
    $mentionResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mentionWiring 'scripts/verify_gate.ps1') `
            -Root $mentionWiring 2>&1
    }
    if ($mentionResult.Code -eq 0 -or $mentionResult.Text -notmatch 'no manifest check ran it successfully') {
        throw 'A string-literal mention satisfied the wiring gate.'
    }
    if (Test-Path -LiteralPath $stampToClear) {
        throw 'The gate stamped on a string-literal mention.'
    }

    foreach ($deadShape in @(
        'if (0) { & tests/parity-harness.ps1 }',
        'while ($false) { & tests/parity-harness.ps1 }'
    )) {
        $deadShapeWiring = Join-Path $tempRoot "dead-shape-wiring-case"
        if (Test-Path -LiteralPath $deadShapeWiring) { Remove-Item -LiteralPath $deadShapeWiring -Recurse -Force }
        Copy-Item -LiteralPath $software -Destination $deadShapeWiring -Recurse
        New-Item -ItemType Directory -Path (Join-Path $deadShapeWiring 'src') -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $deadShapeWiring 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
        $stateFile = Join-Path $deadShapeWiring 'PROJECT_STATE.md'
        [System.IO.File]::WriteAllText(
            $stateFile,
            [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
            $utf8NoBom)
        New-Item -ItemType Directory -Path (Join-Path $deadShapeWiring 'tests') -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $deadShapeWiring 'tests/parity-harness.ps1'), "exit 0`n", $utf8NoBom)
        $agentsFile = Join-Path $deadShapeWiring 'AGENTS.md'
        $agentsBody = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
        $redIndex = $agentsBody.IndexOf('## Red Lines')
        $nextIndex = $agentsBody.IndexOf("`n## ", $redIndex + 5)
        $agentsBody = $agentsBody.Substring(0, $nextIndex) +
            "`n- Never ship without parity. (verify: tests/parity-harness.ps1)`n" +
            $agentsBody.Substring($nextIndex)
        [System.IO.File]::WriteAllText($agentsFile, $agentsBody, $utf8NoBom)
        # F-048-03: dead branches beyond the literal `$false` (`if (0)`,
        # `while ($false)`) must not satisfy wiring either.
        $entryFile = Join-Path $deadShapeWiring 'scripts/project_verify.ps1'
        $entryBody = [System.IO.File]::ReadAllText($entryFile, [System.Text.Encoding]::UTF8)
        $entryBody += "`n$deadShape`n"
        [System.IO.File]::WriteAllText($entryFile, $entryBody, $utf8NoBom)
        $stampToClear = Join-Path $deadShapeWiring '.pps/verify-stamp'
        if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $deadShapeWiring 'scripts/session_begin.ps1') `
            -Root $deadShapeWiring 2>&1 | Out-Null
        $deadShapeResult = Invoke-NativeCapture {
            & $engine -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $deadShapeWiring 'scripts/verify_gate.ps1') `
                -Root $deadShapeWiring 2>&1
        }
        if ($deadShapeResult.Code -eq 0 -or $deadShapeResult.Text -notmatch 'no manifest check ran it successfully') {
            throw "Dead shape [$deadShape] satisfied the wiring gate."
        }
    }

    $relayDiscard = Join-Path $tempRoot "relay-discard-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName relay-discard-case -Profile standard `
        -ParentDir $tempRoot -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Relay discard fixture initialization failed.' }
    [System.IO.File]::WriteAllText(
        (Join-Path $relayDiscard 'docs/MAIN.md'), "session A work`n", $utf8NoBom)
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $relayDiscard 'scripts/session_begin.ps1') `
        -Root $relayDiscard | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $relayDiscard 'docs/MAIN.md'), "session B overwrite`n", $utf8NoBom)
    # The discarded path remains dirty, so boundary still reports unclaimed
    # writes. The discard contract is the chronicle trace, not a clean exit.
    $discardResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $relayDiscard 'scripts/boundary_check.ps1') `
            -Root $relayDiscard -DiscardHandover docs/MAIN.md 2>&1
    }
    if ($discardResult.Text -notmatch 'Relay discard event recorded') {
        throw 'A discard left no relay event in the chronicle.'
    }
    $discardEvents = [System.IO.File]::ReadAllText(
        (Join-Path $relayDiscard 'EVENTS.md'), [System.Text.Encoding]::UTF8)
    if ($discardEvents -notmatch 'relay discard of protected paths') {
        throw 'The relay discard event is absent from EVENTS.md.'
    }
    # F-048-01: the chronicle written by the discard must itself pass
    # validation, so the automatic title must not trip the closing-verb rule.
    $discardValidate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $relayDiscard 'scripts/validate_project.ps1') `
            -Root $relayDiscard -Quiet 2>&1
    }
    if ($discardValidate.Code -ne 0) {
        throw 'The project fails validation right after a recorded discard.'
    }

    $floorProbeDir = Join-Path $tempRoot "floor-probe-dir-case"
    Copy-Item -LiteralPath $software -Destination $floorProbeDir -Recurse
    $stampToClear = Join-Path $floorProbeDir '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $floorProbeDir 'scripts/session_begin.ps1') `
        -Root $floorProbeDir 2>&1 | Out-Null
    $floorProbeDirResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $floorProbeDir 'scripts/verify_gate.ps1') `
            -Root $floorProbeDir 2>&1
    }
    if ($floorProbeDirResult.Code -eq 0 -or
        $floorProbeDirResult.Text -notmatch 'directory is not a product entry point') {
        throw 'The floor probe passed on a directory Main.'
    }
    if (Test-Path -LiteralPath $stampToClear) {
        throw 'The gate stamped a project whose only behavioral probe passed on a directory.'
    }

    $floorProbeFile = Join-Path $tempRoot "floor-probe-file-case"
    Copy-Item -LiteralPath $software -Destination $floorProbeFile -Recurse
    New-Item -ItemType Directory -Path (Join-Path $floorProbeFile 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $floorProbeFile 'src/main.ps1'), "param()`n", $utf8NoBom)
    $stateFile = Join-Path $floorProbeFile 'PROJECT_STATE.md'
    $stateBody = [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8)
    $stateBody = $stateBody.Replace('- Main: .', '- Main: src/main.ps1')
    [System.IO.File]::WriteAllText($stateFile, $stateBody, $utf8NoBom)
    $stampToClear = Join-Path $floorProbeFile '.pps/verify-stamp'
    if (Test-Path -LiteralPath $stampToClear) { Remove-Item -LiteralPath $stampToClear }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $floorProbeFile 'scripts/session_begin.ps1') `
        -Root $floorProbeFile 2>&1 | Out-Null
    $floorProbeFileResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $floorProbeFile 'scripts/verify_gate.ps1') `
            -Root $floorProbeFile 2>&1
    }
    if ($floorProbeFileResult.Code -ne 0 -or
        $floorProbeFileResult.Text -notmatch 'PPS verify gate: OK') {
        throw 'The floor probe failed on a real file Main.'
    }


    # --- Core duty fixtures (D-CORE series) --------------------------------
    $hollowGateCase = Join-Path $tempRoot "hollow-gate-case"
    Copy-Item -LiteralPath $software -Destination $hollowGateCase -Recurse
    New-Item -ItemType Directory -Path (Join-Path $hollowGateCase 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $hollowGateCase 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $hollowGateCase 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    [System.IO.File]::WriteAllText(
        (Join-Path $hollowGateCase "scripts/project_verify.ps1"), "exit 0`n", $utf8NoBom)
    $hollowStamp = Join-Path $hollowGateCase '.pps/verify-stamp'
    if (Test-Path -LiteralPath $hollowStamp) { Remove-Item -LiteralPath $hollowStamp }
    Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $hollowGateCase 'scripts/session_begin.ps1') `
            -Root $hollowGateCase 2>&1
    } | Out-Null
    $hollowResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $hollowGateCase 'scripts/verify_gate.ps1') `
            -Root $hollowGateCase 2>&1
    }
    if ($hollowResult.Code -eq 0 -or $hollowResult.Text -notmatch 'hollow verification entry') {
        throw 'Verify gate accepted a hollow project_verify entry.'
    }
    if (Test-Path -LiteralPath $hollowStamp) {
        throw 'Verify gate stamped despite a hollow verification entry.'
    }

    $structOnlyCase = Join-Path $tempRoot "struct-only-case"
    Copy-Item -LiteralPath $software -Destination $structOnlyCase -Recurse
    New-Item -ItemType Directory -Path (Join-Path $structOnlyCase 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $structOnlyCase 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $structOnlyCase 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    $structEntry = @(
        'function Invoke-Check([string]$Label, [scriptblock]$Body) {',
        '    if (& $Body) { Write-Output "PASS: $Label"; return $true }',
        '    Write-Output "FAIL: $Label"; return $false',
        '}',
        '$root = Split-Path -Parent $PSScriptRoot',
        '$ok = Invoke-Check "validate_project structural" {',
        '    $true',
        '}',
        'if (-not $ok) { exit 1 }',
        'Write-Output "ok"'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $structOnlyCase "scripts/project_verify.ps1"), $structEntry + "`n", $utf8NoBom)
    $structStamp = Join-Path $structOnlyCase '.pps/verify-stamp'
    if (Test-Path -LiteralPath $structStamp) { Remove-Item -LiteralPath $structStamp }
    Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $structOnlyCase 'scripts/session_begin.ps1') `
            -Root $structOnlyCase 2>&1
    } | Out-Null
    $structResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $structOnlyCase 'scripts/verify_gate.ps1') `
            -Root $structOnlyCase 2>&1
    }
    if ($structResult.Code -eq 0 -or $structResult.Text -notmatch 'software package needs a behavioral check') {
        throw 'Verify gate accepted a software package with only structural validation.'
    }

    $redlineUnwiredCase = Join-Path $tempRoot "redline-unwired-case"
    Copy-Item -LiteralPath $software -Destination $redlineUnwiredCase -Recurse
    New-Item -ItemType Directory -Path (Join-Path $redlineUnwiredCase 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $redlineUnwiredCase 'src/main.sh'), "#!/usr/bin/env bash`necho ok`n", $utf8NoBom)
    $stateFile = Join-Path $redlineUnwiredCase 'PROJECT_STATE.md'
    [System.IO.File]::WriteAllText(
        $stateFile,
        [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8).Replace('- Main: .', '- Main: src/main.sh'),
        $utf8NoBom)
    $agentsFile = Join-Path $redlineUnwiredCase 'AGENTS.md'
    $agentsBody = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
    $redIndex = $agentsBody.IndexOf('## Red Lines')
    $nextIndex = $agentsBody.IndexOf("`n## ", $redIndex + 5)
    $redTail = "`n- Never ship without the parity harness. (verify: tests/parity-harness.sh)`n"
    $agentsBody = $agentsBody.Substring(0, $nextIndex) + $redTail + $agentsBody.Substring($nextIndex)
    [System.IO.File]::WriteAllText($agentsFile, $agentsBody, $utf8NoBom)
    $redStamp = Join-Path $redlineUnwiredCase '.pps/verify-stamp'
    if (Test-Path -LiteralPath $redStamp) { Remove-Item -LiteralPath $redStamp }
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $redlineUnwiredCase 'scripts/session_begin.ps1') `
        -Root $redlineUnwiredCase 2>&1 | Out-Null
    $redResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $redlineUnwiredCase 'scripts/verify_gate.ps1') `
            -Root $redlineUnwiredCase 2>&1
    }
    if ($redResult.Code -eq 0 -or $redResult.Text -notmatch 'red line not wired to an executed check') {
        throw 'Verify gate stamped although a red line named an unwired check.'
    }
    if (Test-Path -LiteralPath $redStamp) {
        throw 'Verify gate stamped despite an unwired red line.'
    }

    $coverageProseCase = Join-Path $tempRoot "coverage-prose-case"
    Copy-Item -LiteralPath $standard -Destination $coverageProseCase -Recurse
    $covFile = Join-Path $coverageProseCase 'CONTEXT.md'
    $covBody = [System.IO.File]::ReadAllText($covFile, [System.Text.Encoding]::UTF8)
    $covBody = [regex]::Replace($covBody, '(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', '${1} looks fine to me |', 1)
    [System.IO.File]::WriteAllText($covFile, $covBody, $utf8NoBom)
    Assert-InvalidProject $coverageProseCase `
        "is not a resolvable evidence reference" `
        "Coverage evidence written as prose"

    $coverageGhostCase = Join-Path $tempRoot "coverage-ghost-case"
    Copy-Item -LiteralPath $standard -Destination $coverageGhostCase -Recurse
    $covFile = Join-Path $coverageGhostCase 'CONTEXT.md'
    $covBody = [System.IO.File]::ReadAllText($covFile, [System.Text.Encoding]::UTF8)
    $covBody = [regex]::Replace($covBody, '(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', '${1} tests/does-not-exist.sh |', 1)
    [System.IO.File]::WriteAllText($covFile, $covBody, $utf8NoBom)
    Assert-InvalidProject $coverageGhostCase `
        "which does not exist in the project" `
        "Coverage evidence naming a nonexistent check"

    $agedProposalCase = Join-Path $tempRoot "aged-proposal-case"
    Copy-Item -LiteralPath $standard -Destination $agedProposalCase -Recurse
    $propFile = Join-Path $agedProposalCase 'CONTEXT.md'
    $propBody = [System.IO.File]::ReadAllText($propFile, [System.Text.Encoding]::UTF8)
    $propBody = [regex]::Replace($propBody, '(?m)^- P-001.*$', '- P-001 (opened 2026-01-01): stale proposal never restated')
    [System.IO.File]::WriteAllText($propFile, $propBody, $utf8NoBom)
    Assert-InvalidProject $agedProposalCase `
        "not restated in Hot State Next by ID" `
        "Aged proposal without restatement"

    $abandonedProposalCase = Join-Path $tempRoot "abandoned-proposal-case"
    Copy-Item -LiteralPath $standard -Destination $abandonedProposalCase -Recurse
    $propFile = Join-Path $abandonedProposalCase 'CONTEXT.md'
    $propBody = [System.IO.File]::ReadAllText($propFile, [System.Text.Encoding]::UTF8)
    $propBody = [regex]::Replace($propBody, '(?m)^- P-001.*$', '- P-001 (opened 2026-01-01) [abandoned]: dropped deliberately')
    [System.IO.File]::WriteAllText($propFile, $propBody, $utf8NoBom)
    $abandonedResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $abandonedProposalCase 'scripts/validate_project.ps1') `
            -Root $abandonedProposalCase -Quiet 2>&1
    }
    if ($abandonedResult.Code -ne 0) {
        throw "An explicitly abandoned proposal was rejected: $($abandonedResult.Text)"
    }

    $zeroInfoEventCase = Join-Path $tempRoot "zero-info-event-case"
    Copy-Item -LiteralPath $standard -Destination $zeroInfoEventCase -Recurse
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $zeroInfoEventCase 'scripts/append_event.ps1') `
        -Root $zeroInfoEventCase -Title 'closed the package' `
        -Files 'none' -Verify 'none' -Pending 'none' | Out-Null
    Assert-InvalidProject $zeroInfoEventCase `
        "must name its verification or keep something pending" `
        "Zero-information closing event"

    $emptyRegistryCase = Join-Path $tempRoot "empty-registry-case"
    Copy-Item -LiteralPath $standard -Destination $emptyRegistryCase -Recurse
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyRegistryCase 'TASK_INDEX.md'),
        "# Task Index`n`n## Task Index`n", $utf8NoBom)
    Assert-InvalidProject $emptyRegistryCase `
        "empty registry not allowed" `
        "Half-activated multitask registry"

    $runtimeUnwiredCase = Join-Path $tempRoot "runtime-unwired-case"
    Copy-Item -LiteralPath $software -Destination $runtimeUnwiredCase -Recurse
    $runtimeSection = @(
        '', '## Runtime Surfaces', '',
        '| ID | Repo path | Runtime path env | Probe |',
        '| R-001 | docs/MAIN.md | WZ_RUNTIME_DIR | scripts/runtime_probe.ps1 |'
    ) -join "`n"
    [System.IO.File]::AppendAllText(
        (Join-Path $runtimeUnwiredCase 'CONTEXT.md'), $runtimeSection + "`n", $utf8NoBom)
    Assert-InvalidProject $runtimeUnwiredCase `
        "does not exist" `
        "Runtime surface probe that does not exist"

    $handoverCase = Join-Path $tempRoot "handover-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName handover-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Handover fixture initialization failed.' }
    [System.IO.File]::WriteAllText(
        (Join-Path $handoverCase 'docs/MAIN.md'),
        "session A hardening not committed`n", $utf8NoBom)
    $sessionBeginResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $handoverCase 'scripts/session_begin.ps1') `
            -Root $handoverCase 2>&1
    }
    if ($sessionBeginResult.Text -notmatch 'docs/MAIN\.md') {
        throw 'Session snapshot did not list the uncommitted path.'
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $handoverCase 'docs/MAIN.md'),
        "session B wholesale overwrite`n", $utf8NoBom)
    $overwriteResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $handoverCase 'scripts/boundary_check.ps1') `
            -Root $handoverCase 2>&1
    }
    if ($overwriteResult.Code -eq 0 -or $overwriteResult.Text -notmatch 'protected_overwrite: docs/MAIN\.md') {
        throw 'Boundary check allowed a wholesale overwrite of handover work.'
    }
    $discardResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $handoverCase 'scripts/boundary_check.ps1') `
            -Root $handoverCase -DiscardHandover 'docs/MAIN.md' 2>&1
    }
    if ($discardResult.Text -notmatch 'handover_discarded: docs/MAIN\.md') {
        throw 'Explicit handover discard was not honored.'
    }
    $secondSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $handoverCase 'scripts/session_begin.ps1') `
            -Root $handoverCase 2>&1
    }
    if ($secondSession.Code -ne 3 -or $secondSession.Text -notmatch 'unexpired session snapshot') {
        throw 'A second session started without an explicit takeover.'
    }
    $takeoverSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $handoverCase 'scripts/session_begin.ps1') `
            -Root $handoverCase -Takeover 2>&1
    }
    if ($takeoverSession.Text -notmatch 'Takeover: yes') {
        throw 'Takeover was not recorded in the session output.'
    }

    $packetRelayCase = Join-Path $tempRoot "packet-relay-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName packet-relay-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Packet relay fixture initialization failed.' }
    $agentsFile = Join-Path $packetRelayCase 'AGENTS.md'
    $agentsBody = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
    $redIndex = $agentsBody.IndexOf('## Red Lines')
    $nextIndex = $agentsBody.IndexOf("`n## ", $redIndex + 5)
    $numbered = @(
        '', '**R0 - Agent parity is non-negotiable.**', '',
        '1. Never swallow errors in an empty catch block.',
        '2. Never use array splatting for path arguments.', ''
    ) -join "`n"
    $agentsBody = $agentsBody.Substring(0, $nextIndex) + $numbered + $agentsBody.Substring($nextIndex)
    [System.IO.File]::WriteAllText($agentsFile, $agentsBody, $utf8NoBom)
    [System.IO.File]::WriteAllText(
        (Join-Path $packetRelayCase 'Install-WZ.ps1'), "uncommitted relay work`n", $utf8NoBom)
    $relayPacket = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $packetRelayCase 'scripts/resume_packet.ps1') `
            -Root $packetRelayCase 2>&1
    }
    foreach ($needle in @(
        'R0 - Agent parity is non-negotiable',
        '1. Never swallow errors in an empty catch block',
        'protected: Install-WZ.ps1',
        'dirty worktree without explicit handover',
        'SNAPSHOT MISSING'
    )) {
        if ($relayPacket.Text -notmatch [regex]::Escape($needle)) {
            throw "Resume packet is missing relay detail: $needle"
        }
    }

    $gateFailCase = Join-Path $tempRoot "gate-fail-case"
    Copy-Item -LiteralPath $standard -Destination $gateFailCase -Recurse
    $failingEntry = @(
        '$failures = 0',
        'function Invoke-Check([string]$Label, [scriptblock]$Body) {',
        '    if (& $Body) {',
        '        Write-Output "PASS project_verify: $Label"',
        '    } else {',
        '        Write-Output "FAIL project_verify: $Label"',
        '        $script:failures++',
        '    }',
        '}',
        '$probeRoot = Split-Path -Parent $PSScriptRoot',
        'Invoke-Check "behavioral end-to-end assertion" {',
        '    Test-Path -LiteralPath (Join-Path $probeRoot "this-artifact-cannot-exist")',
        '}',
        'if ($failures -gt 0) {',
        '    Write-Output "project_verify: FAILED"',
        '    exit 9',
        '}',
        'Write-Output "project_verify: OK"'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $gateFailCase "scripts/project_verify.ps1"),
        $failingEntry + "`n",
        $utf8NoBom
    )
    $gateFailStamp = Join-Path $gateFailCase '.pps/verify-stamp'
    if (Test-Path -LiteralPath $gateFailStamp) { Remove-Item -LiteralPath $gateFailStamp }
    $gateFailResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gateFailCase 'scripts/verify_gate.ps1') `
            -Root $gateFailCase 2>&1
    }
    if ($gateFailResult.Code -eq 0 -or
        $gateFailResult.Text -notmatch 'PPS verify gate: FAILED') {
        throw 'Verify gate wrote a green result for a failing project verification.'
    }
    if (Test-Path -LiteralPath $gateFailStamp) {
        throw 'Verify gate left a stamp behind after a failed verification.'
    }
    $gateFailReadiness = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gateFailCase 'scripts/readiness_check.ps1') `
            -Root $gateFailCase -Verified 2>&1
    }
    if ($gateFailReadiness.Code -ne 4 -or
        $gateFailReadiness.Text -notmatch 'VERIFY EVIDENCE MISSING') {
        throw 'Readiness accepted attestation after a failed gate.'
    }

    $unroutedCase = Join-Path $tempRoot "unrouted-verify-case"
    Copy-Item -LiteralPath $standard -Destination $unroutedCase -Recurse
    $casePath = Join-Path $unroutedCase "CONTEXT.md"
    $text = [System.IO.File]::ReadAllText($casePath, [System.Text.Encoding]::UTF8)
    $text = [regex]::Replace($text, '(?m)^- Verify:.*$', '- Verify: powershell -NoProfile -Command "exit 9"')
    [System.IO.File]::WriteAllText($casePath, $text, $utf8NoBom)
    $unroutedStamp = Join-Path $unroutedCase '.pps/verify-stamp'
    if (Test-Path -LiteralPath $unroutedStamp) { Remove-Item -LiteralPath $unroutedStamp }
    $unroutedResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $unroutedCase 'scripts/verify_gate.ps1') `
            -Root $unroutedCase 2>&1
    }
    if ($unroutedResult.Code -eq 0 -or
        $unroutedResult.Text -notmatch 'unrouted Verify declaration') {
        throw 'Verify gate accepted an unrouted free-form Verify declaration.'
    }
    if (Test-Path -LiteralPath $unroutedStamp) {
        throw 'Verify gate stamped an unrouted Verify declaration.'
    }

    $staleWorktreeCase = Join-Path $tempRoot "stale-worktree-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName stale-worktree-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Stale-worktree initialization failed." }
    $staleGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $staleWorktreeCase 'scripts/verify_gate.ps1') `
            -Root $staleWorktreeCase 2>&1
    }
    if ($staleGate.Code -ne 0) {
        throw "Verify gate failed on a valid Git project: $($staleGate.Text)"
    }
    [System.IO.File]::AppendAllText(
        (Join-Path $staleWorktreeCase "docs/MAIN.md"), "post-stamp drift`n", $utf8NoBom)
    $staleReadiness = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $staleWorktreeCase 'scripts/readiness_check.ps1') `
            -Root $staleWorktreeCase -Verified 2>&1
    }
    if ($staleReadiness.Code -ne 4 -or
        $staleReadiness.Text -notmatch 'worktree content changed after the stamp') {
        throw 'Readiness accepted a stamp whose worktree no longer matches.'
    }

    $dirtyContentCase = Join-Path $tempRoot "dirty-content-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName dirty-content-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Dirty-content initialization failed." }
    [System.IO.File]::AppendAllText(
        (Join-Path $dirtyContentCase "docs/MAIN.md"), "dirty before gate`n", $utf8NoBom)
    $dirtyGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $dirtyContentCase 'scripts/verify_gate.ps1') `
            -Root $dirtyContentCase 2>&1
    }
    if ($dirtyGate.Code -ne 0) {
        throw "Verify gate failed on a dirty-but-valid project: $($dirtyGate.Text)"
    }
    [System.IO.File]::AppendAllText(
        (Join-Path $dirtyContentCase "docs/MAIN.md"), "dirty again after gate`n", $utf8NoBom)
    $dirtyReadiness = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $dirtyContentCase 'scripts/readiness_check.ps1') `
            -Root $dirtyContentCase -Verified 2>&1
    }
    if ($dirtyReadiness.Code -ne 4 -or
        $dirtyReadiness.Text -notmatch 'worktree content changed after the stamp') {
        throw 'Readiness accepted a stamp although an already-dirty file changed again.'
    }

    $capsuleDriftCase = Join-Path $tempRoot "capsule-drift-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName capsule-drift-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Capsule-drift initialization failed." }
    $capsuleGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $capsuleDriftCase 'scripts/verify_gate.ps1') `
            -Root $capsuleDriftCase 2>&1
    }
    if ($capsuleGate.Code -ne 0) {
        throw "Verify gate failed on a valid project: $($capsuleGate.Text)"
    }
    [System.IO.File]::AppendAllText(
        (Join-Path $capsuleDriftCase "CONTEXT.md"), "`n<!-- capsule drift -->`n", $utf8NoBom)
    $capsuleReadiness = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $capsuleDriftCase 'scripts/readiness_check.ps1') `
            -Root $capsuleDriftCase -Verified 2>&1
    }
    if ($capsuleReadiness.Code -ne 4) {
        throw 'Readiness accepted a stamp although CONTEXT.md changed after it.'
    }

    $cjkDirtyCase = Join-Path $tempRoot "cjk-dirty-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName cjk-dirty-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CJK-dirty initialization failed." }
    $cjkFile = Join-Path $cjkDirtyCase ([string]::Join('', [char]0x4E2D, [char]0x6587, ' ', [char]0x810F, '.md'))
    [System.IO.File]::WriteAllText($cjkFile, "first version`n", $utf8NoBom)
    $cjkGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $cjkDirtyCase 'scripts/verify_gate.ps1') `
            -Root $cjkDirtyCase 2>&1
    }
    if ($cjkGate.Code -ne 0) {
        throw "Verify gate failed with a CJK dirty path: $($cjkGate.Text)"
    }
    [System.IO.File]::WriteAllText($cjkFile, "second version`n", $utf8NoBom)
    $cjkReadiness = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $cjkDirtyCase 'scripts/readiness_check.ps1') `
            -Root $cjkDirtyCase -Verified 2>&1
    }
    if ($cjkReadiness.Code -ne 4 -or
        $cjkReadiness.Text -notmatch 'worktree content changed after the stamp') {
        throw 'Readiness accepted a stamp although a CJK-named dirty file changed again.'
    }

    $gitlessCase = Join-Path $tempRoot "gitless-stamp-case"
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill "scripts/init_project.ps1") `
        -ProjectName gitless-stamp-case -Profile standard -ParentDir $tempRoot `
        -GitName 'PPS Smoke' -GitEmail 'pps-smoke@example.invalid' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Gitless-stamp initialization failed." }
    $gitlessGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitlessCase 'scripts/verify_gate.ps1') `
            -Root $gitlessCase 2>&1
    }
    if ($gitlessGate.Code -ne 0) {
        throw "Verify gate failed on a valid project: $($gitlessGate.Text)"
    }
    Move-Item -LiteralPath (Join-Path $gitlessCase '.git') `
        -Destination (Join-Path $tempRoot 'gitless-stamp-case-git')
    $gitlessReadiness = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $gitlessCase 'scripts/readiness_check.ps1') `
            -Root $gitlessCase -Verified 2>&1
    }
    Move-Item -LiteralPath (Join-Path $tempRoot 'gitless-stamp-case-git') `
        -Destination (Join-Path $gitlessCase '.git')
    if ($gitlessReadiness.Code -ne 4 -or
        $gitlessReadiness.Text -notmatch 'no longer one') {
        throw 'Readiness accepted a Git-bound stamp after .git was removed.'
    }

    $eventPlacementCase = Join-Path $tempRoot "event-placement-case"
    Copy-Item -LiteralPath $standard -Destination $eventPlacementCase -Recurse
    [System.IO.File]::AppendAllText(
        (Join-Path $eventPlacementCase "EVENTS.md"),
        "`n## Trailing Notes`n`n- unrelated trailing content`n",
        $utf8NoBom
    )
    $placementResult = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $eventPlacementCase 'scripts/append_event.ps1') `
            -Root $eventPlacementCase -Title 'chat Placement test' 2>&1
    }
    if ($placementResult.Code -ne 0) {
        throw "Event appender failed with a trailing section: $($placementResult.Text)"
    }
    $placementText = [System.IO.File]::ReadAllText(
        (Join-Path $eventPlacementCase 'EVENTS.md'), [System.Text.Encoding]::UTF8)
    $placementSection = [regex]::Match(
        $placementText,
        '(?ms)^##\s+Events\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if (-not $placementSection.Success -or
        $placementSection.Groups['body'].Value -notmatch 'Placement test') {
        throw 'Appended event landed outside the Events section.'
    }
    $placementValid = Run-Validator $eventPlacementCase
    if ($placementValid.Code -ne 0) {
        throw "Event placement project failed validation: $($placementValid.Text)"
    }

    # ==== 051 anti-drift fixtures: objective anchor + acceptance wiring ====
    # The objective anchor turns "the goal moved while nobody recorded it"
    # into a gate failure; acceptance items turn "done" into executed checks.

    # 051-01: session_begin anchors the objective; the gate stamps it.
    $anchorCase = Join-Path $tempRoot 'anchor-case'
    & $engine -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $skill 'scripts/init_project.ps1') `
        -ProjectName anchor-case -Profile standard -ParentDir $tempRoot -NoGit
    if ($LASTEXITCODE -ne 0) { throw 'anchor-case initialization failed.' }
    $anchorSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $anchorCase 'scripts/session_begin.ps1') -Root $anchorCase
    }
    if ($anchorSession.Code -ne 0) { throw "anchor-case session_begin failed: $($anchorSession.Text)" }
    $anchorFile = Join-Path $anchorCase '.pps/objective-anchor'
    if (-not (Test-Path -LiteralPath $anchorFile -PathType Leaf)) {
        throw 'session_begin did not write .pps/objective-anchor.'
    }
    $anchorFileText = [System.IO.File]::ReadAllText($anchorFile, [System.Text.Encoding]::UTF8)
    if ($anchorFileText -notmatch '(?m)^objective_sha256: [0-9a-f]{64}\s*$') {
        throw 'objective-anchor has no 64-hex sha256.'
    }
    $anchorGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $anchorCase 'scripts/verify_gate.ps1') -Root $anchorCase
    }
    if ($anchorGate.Code -ne 0) { throw "anchor-case gate failed: $($anchorGate.Text)" }
    $anchorStamp = [System.IO.File]::ReadAllText(
        (Join-Path $anchorCase '.pps/verify-stamp'), [System.Text.Encoding]::UTF8)
    if ($anchorStamp -notmatch '(?m)^objective_sha256: [0-9a-f]{64}\s*$') {
        throw 'verify stamp did not record objective_sha256.'
    }

    # 051-02: a silently rewritten objective fails the gate (no event recorded).
    $driftCase = Join-Path $tempRoot 'drift-case'
    Copy-Item -LiteralPath $standard -Destination $driftCase -Recurse
    $driftSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $driftCase 'scripts/session_begin.ps1') -Root $driftCase
    }
    if ($driftSession.Code -ne 0) { throw "drift-case session_begin failed: $($driftSession.Text)" }
    $driftState = [System.IO.File]::ReadAllText(
        (Join-Path $driftCase 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
    $driftState = [regex]::Replace(
        $driftState,
        '(?m)^(##\s+Objective\s*\r?\n)',
        '$1' + "DRIFT: quietly expanded scope beyond the anchor.`r`n`r`n",
        1)
    [System.IO.File]::WriteAllText(
        (Join-Path $driftCase 'PROJECT_STATE.md'), $driftState, $utf8NoBom)
    $driftGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $driftCase 'scripts/verify_gate.ps1') -Root $driftCase
    }
    if ($driftGate.Code -eq 0) {
        throw 'A silently rewritten objective passed the gate without an event.'
    }
    if ($driftGate.Text -notmatch 'objective anchor mismatch') {
        throw "Drift gate failed without the anchor diagnostic: $($driftGate.Text)"
    }

    # 051-03: a recorded objective-revised event legitimizes the change and
    # refreshes the anchor to the revised objective.
    $revisedCase = Join-Path $tempRoot 'revised-case'
    Copy-Item -LiteralPath $standard -Destination $revisedCase -Recurse
    $revisedSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $revisedCase 'scripts/session_begin.ps1') -Root $revisedCase
    }
    if ($revisedSession.Code -ne 0) { throw "revised-case session_begin failed: $($revisedSession.Text)" }
    $revisedState = [System.IO.File]::ReadAllText(
        (Join-Path $revisedCase 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
    $revisedState = [regex]::Replace(
        $revisedState,
        '(?m)^(##\s+Objective\s*\r?\n)',
        '$1' + "Revised objective, recorded in the chronicle.`r`n`r`n",
        1)
    [System.IO.File]::WriteAllText(
        (Join-Path $revisedCase 'PROJECT_STATE.md'), $revisedState, $utf8NoBom)
    $revisedEvent = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $revisedCase 'scripts/append_event.ps1') `
            -Root $revisedCase `
            -Title 'objective-revised: the scope was deliberately expanded' `
            -Files 'PROJECT_STATE.md' `
            -Verify 'manual' `
            -Pending 'review the revised objective'
    }
    if ($revisedEvent.Code -ne 0) { throw "revised-case append_event failed: $($revisedEvent.Text)" }
    $revisedGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $revisedCase 'scripts/verify_gate.ps1') -Root $revisedCase
    }
    if ($revisedGate.Code -ne 0) { throw "revised-case gate failed: $($revisedGate.Text)" }
    $revisedAnchor = [System.IO.File]::ReadAllText(
        (Join-Path $revisedCase '.pps/objective-anchor'), [System.Text.Encoding]::UTF8)
    $revisedStamp = [System.IO.File]::ReadAllText(
        (Join-Path $revisedCase '.pps/verify-stamp'), [System.Text.Encoding]::UTF8)
    $anchorHashMatch = [regex]::Match($revisedAnchor, '(?m)^objective_sha256:\s*(\S+)\s*$')
    $stampHashMatch = [regex]::Match($revisedStamp, '(?m)^objective_sha256:\s*(\S+)\s*$')
    if (-not $anchorHashMatch.Success -or -not $stampHashMatch.Success -or
        $anchorHashMatch.Groups[1].Value -ne $stampHashMatch.Groups[1].Value) {
        throw 'The refreshed anchor and the stamp disagree on the objective hash.'
    }

    # 051-04: a non-bootstrap package without Acceptance fails validation.
    $noAcceptanceCase = Join-Path $tempRoot 'no-acceptance-case'
    Copy-Item -LiteralPath $standard -Destination $noAcceptanceCase -Recurse
    $noAcceptanceState = [System.IO.File]::ReadAllText(
        (Join-Path $noAcceptanceCase 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
    $noAcceptanceState = [regex]::Replace(
        $noAcceptanceState,
        '(?m)^-\s+Stage: 0 / bootstrap\s*$',
        '- Stage: 1 / package',
        1)
    [System.IO.File]::WriteAllText(
        (Join-Path $noAcceptanceCase 'PROJECT_STATE.md'), $noAcceptanceState, $utf8NoBom)
    $noAcceptanceContext = [System.IO.File]::ReadAllText(
        (Join-Path $noAcceptanceCase 'CONTEXT.md'), [System.Text.Encoding]::UTF8)
    $noAcceptanceContext = [regex]::Replace(
        $noAcceptanceContext,
        '(?m)^- Acceptance:\s*\r?\n(\s+- A1:.*\r?\n)',
        '',
        1)
    [System.IO.File]::WriteAllText(
        (Join-Path $noAcceptanceCase 'CONTEXT.md'), $noAcceptanceContext, $utf8NoBom)
    $noAcceptanceValid = Run-Validator $noAcceptanceCase
    if ($noAcceptanceValid.Code -eq 0) {
        throw 'A non-bootstrap package without Acceptance passed validation.'
    }
    if ($noAcceptanceValid.Text -notmatch "requires an 'Acceptance' field") {
        throw "Acceptance absence failed without the diagnostic: $($noAcceptanceValid.Text)"
    }

    # 051-05: an acceptance item naming a check that never ran fails the gate.
    $unwiredCase = Join-Path $tempRoot 'unwired-case'
    Copy-Item -LiteralPath $standard -Destination $unwiredCase -Recurse
    $unwiredState = [System.IO.File]::ReadAllText(
        (Join-Path $unwiredCase 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
    $unwiredState = [regex]::Replace(
        $unwiredState,
        '(?m)^-\s+Stage: 0 / bootstrap\s*$',
        '- Stage: 1 / package',
        1)
    [System.IO.File]::WriteAllText(
        (Join-Path $unwiredCase 'PROJECT_STATE.md'), $unwiredState, $utf8NoBom)
    $unwiredContext = [System.IO.File]::ReadAllText(
        (Join-Path $unwiredCase 'CONTEXT.md'), [System.Text.Encoding]::UTF8)
    $unwiredContext = $unwiredContext.Replace('(verify: validate_project)', '(verify: ghost-check-404)')
    [System.IO.File]::WriteAllText(
        (Join-Path $unwiredCase 'CONTEXT.md'), $unwiredContext, $utf8NoBom)
    $unwiredSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $unwiredCase 'scripts/session_begin.ps1') -Root $unwiredCase
    }
    if ($unwiredSession.Code -ne 0) { throw "unwired-case session_begin failed: $($unwiredSession.Text)" }
    $unwiredGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $unwiredCase 'scripts/verify_gate.ps1') -Root $unwiredCase
    }
    if ($unwiredGate.Code -eq 0) {
        throw 'An acceptance item wired to a check that never ran passed the gate.'
    }
    if ($unwiredGate.Text -notmatch 'acceptance not wired to an executed check') {
        throw "Unwired acceptance failed without the diagnostic: $($unwiredGate.Text)"
    }

    # 051-06: an acceptance item wired to a real manifest check id passes.
    $wiredCase = Join-Path $tempRoot 'wired-case'
    Copy-Item -LiteralPath $standard -Destination $wiredCase -Recurse
    $wiredState = [System.IO.File]::ReadAllText(
        (Join-Path $wiredCase 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
    $wiredState = [regex]::Replace(
        $wiredState,
        '(?m)^-\s+Stage: 0 / bootstrap\s*$',
        '- Stage: 1 / package',
        1)
    [System.IO.File]::WriteAllText(
        (Join-Path $wiredCase 'PROJECT_STATE.md'), $wiredState, $utf8NoBom)
    $wiredContext = [System.IO.File]::ReadAllText(
        (Join-Path $wiredCase 'CONTEXT.md'), [System.Text.Encoding]::UTF8)
    $wiredContext = $wiredContext.Replace('(verify: validate_project)', '(verify: M-001)')
    [System.IO.File]::WriteAllText(
        (Join-Path $wiredCase 'CONTEXT.md'), $wiredContext, $utf8NoBom)
    $wiredSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $wiredCase 'scripts/session_begin.ps1') -Root $wiredCase
    }
    if ($wiredSession.Code -ne 0) { throw "wired-case session_begin failed: $($wiredSession.Text)" }
    $wiredGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $wiredCase 'scripts/verify_gate.ps1') -Root $wiredCase
    }
    if ($wiredGate.Code -ne 0) {
        throw "wired-case gate failed: $($wiredGate.Text)"
    }

    # ==== 052 self-distillation regressions (parity with the Bash suite) =====
    # The ISO-8601 chronicle migration silently broke three date-reading
    # consumers and the append-only compatibility promise. Each is fixtured.

    # 052-01: coverage evidence naming an EVENTS.md date must resolve against a
    # full ISO stamp (was: fail-forever).
    $covDateCase = Join-Path $tempRoot 'coverage-date-case'
    Copy-Item -LiteralPath $standard -Destination $covDateCase -Recurse
    $covAppend = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $covDateCase 'scripts/append_event.ps1') `
            -Root $covDateCase -Title 'coverage attestation refreshed' `
            -Files 'docs/MAIN.md' -Verify 'validate_project pass' -Pending 'none'
    }
    if ($covAppend.Code -ne 0) { throw "coverage-date-case append_event failed: $($covAppend.Text)" }
    $covDay = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
    $covContextPath = Join-Path $covDateCase 'CONTEXT.md'
    $covContext = [System.IO.File]::ReadAllText($covContextPath, [System.Text.Encoding]::UTF8)
    $covContext = [regex]::Replace(
        $covContext, '(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', ('${1} ' + $covDay + ' |'), 1)
    [System.IO.File]::WriteAllText($covContextPath, $covContext, $utf8NoBom)
    $covValidate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $covDateCase 'scripts/validate_project.ps1') -Root $covDateCase -Quiet
    }
    if ($covValidate.Code -ne 0) {
        throw "Coverage evidence naming a real ISO-stamped event date was rejected: $($covValidate.Text)"
    }

    # 052-02: `event: <stamp>:<mergeId>` must split on the LAST colon.
    $evidenceSplitCase = Join-Path $tempRoot 'evidence-split-case'
    Copy-Item -LiteralPath $standard -Destination $evidenceSplitCase -Recurse
    Add-Content -LiteralPath (Join-Path $evidenceSplitCase 'EVENTS.md') -Encoding utf8 `
        -Value '- 2026-08-24T10:00:00Z: [PKG-001] MERGE-001 integrated | files: docs/MAIN.md | verify: gate pass | pending: none'
    # F-050-02 discovery order: never hardcode python3, a field box may ship a
    # Store stub that exits 127.
    $splitPy = $null
    foreach ($pyCand in @($env:PPS_PYTHON, 'python3', 'python')) {
        if ([string]::IsNullOrWhiteSpace($pyCand)) { continue }
        $pyCmd = Get-Command $pyCand -ErrorAction SilentlyContinue
        if ($null -eq $pyCmd) { continue }
        $pyProbe = Invoke-NativeCapture { & $pyCmd.Source -c 'import sys; sys.exit(0)' }
        if ($pyProbe.Code -eq 0) { $splitPy = $pyCmd.Source; break }
    }
    if ($null -eq $splitPy) { throw '052-02 needs a working Python 3 interpreter.' }
    $splitProbe = Invoke-NativeCapture {
        & $splitPy (Join-Path $skill 'scripts/pps_evidence.py') verification-parse `
            $evidenceSplitCase 'event: 2026-08-24T10:00:00Z:MERGE-001' 'MERGE-001'
    }
    if ($splitProbe.Text.Trim() -ne 'ok') {
        throw "Typed event evidence with an ISO stamp did not resolve: $($splitProbe.Text)"
    }

    # 052-03: an objective revision recorded on a migrated calendar-day line
    # must still legitimize the change and refresh the anchor.
    $legacyRevisionCase = Join-Path $tempRoot 'legacy-revision-case'
    Copy-Item -LiteralPath $standard -Destination $legacyRevisionCase -Recurse
    $legacySession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $legacyRevisionCase 'scripts/session_begin.ps1') -Root $legacyRevisionCase
    }
    if ($legacySession.Code -ne 0) { throw "legacy-revision session_begin failed: $($legacySession.Text)" }
    $legacyStatePath = Join-Path $legacyRevisionCase 'PROJECT_STATE.md'
    $legacyState = [System.IO.File]::ReadAllText($legacyStatePath, [System.Text.Encoding]::UTF8)
    $legacyState = [regex]::Replace(
        $legacyState, '(?m)^(##\s+Objective\s*\r?\n)',
        '$1' + "Revised objective, recorded in a legacy-format chronicle line.`r`n`r`n", 1)
    [System.IO.File]::WriteAllText($legacyStatePath, $legacyState, $utf8NoBom)
    $legacyEventsPath = Join-Path $legacyRevisionCase 'EVENTS.md'
    $legacyEventLines = [System.Collections.Generic.List[string]]@(
        [System.IO.File]::ReadAllLines($legacyEventsPath, [System.Text.Encoding]::UTF8))
    $legacyLine = '- ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd') +
        ': [PKG-001] objective-revised: scope deliberately widened | files: PROJECT_STATE.md | verify: manual | pending: review the revision'
    $legacyInsertAt = -1
    for ($i = 0; $i -lt $legacyEventLines.Count; $i++) {
        if ($legacyEventLines[$i].StartsWith('- ') -and $legacyEventLines[$i].Contains(': [PKG-')) {
            $legacyInsertAt = $i
            break
        }
    }
    if ($legacyInsertAt -ge 0) { $legacyEventLines.Insert($legacyInsertAt, $legacyLine) }
    else { $legacyEventLines.Add($legacyLine) }
    [System.IO.File]::WriteAllText(
        $legacyEventsPath, (($legacyEventLines -join "`n") + "`n"), $utf8NoBom)
    $legacyGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $legacyRevisionCase 'scripts/verify_gate.ps1') -Root $legacyRevisionCase
    }
    if ($legacyGate.Code -ne 0) {
        throw "A calendar-day objective-revised line did not legitimize the change: $($legacyGate.Text)"
    }
    if ($legacyGate.Text -notmatch 'anchor refreshed') {
        throw 'The gate accepted the legacy revision without refreshing the anchor.'
    }

    # 052-04: the chronicle is append-only, so calendar-day lines written by an
    # older release must keep validating. Upgrading the skill must never
    # retroactively invalidate an existing project.
    $legacyChronicleCase = Join-Path $tempRoot 'legacy-chronicle-case'
    Copy-Item -LiteralPath $standard -Destination $legacyChronicleCase -Recurse
    $chronPath = Join-Path $legacyChronicleCase 'EVENTS.md'
    $chronLines = [System.Collections.Generic.List[string]]@(
        [System.IO.File]::ReadAllLines($chronPath, [System.Text.Encoding]::UTF8))
    $chronLegacy = '- 2026-08-20: [PKG-001] legacy calendar-day entry from an older release | files: docs/MAIN.md | verify: validate_project pass | pending: none'
    $chronAt = -1
    for ($i = 0; $i -lt $chronLines.Count; $i++) {
        if ($chronLines[$i].StartsWith('- ') -and $chronLines[$i].Contains(': [PKG-')) { $chronAt = $i; break }
    }
    if ($chronAt -ge 0) { $chronLines.Insert($chronAt, $chronLegacy) } else { $chronLines.Add($chronLegacy) }
    [System.IO.File]::WriteAllText($chronPath, (($chronLines -join "`n") + "`n"), $utf8NoBom)
    $chronValidate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $legacyChronicleCase 'scripts/validate_project.ps1') `
            -Root $legacyChronicleCase -Quiet
    }
    if ($chronValidate.Code -ne 0) {
        throw "A calendar-day chronicle line written by an older release was rejected: $($chronValidate.Text)"
    }
    $chronVerify = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $legacyChronicleCase 'scripts/project_verify.ps1') -Root $legacyChronicleCase
    }
    if ($chronVerify.Code -ne 0) {
        throw "project_verify no longer recognises a legacy calendar-day event line: $($chronVerify.Text)"
    }

    # 052-05: widening the grammar must not widen it into nonsense.
    $impossibleClockCase = Join-Path $tempRoot 'impossible-clock-case'
    Copy-Item -LiteralPath $standard -Destination $impossibleClockCase -Recurse
    Add-Content -LiteralPath (Join-Path $impossibleClockCase 'EVENTS.md') -Encoding utf8 `
        -Value '- 2026-08-24T99:99:99Z: [PKG-001] forged stamp | files: docs/MAIN.md | verify: gate pass | pending: none'
    $impossibleClock = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $impossibleClockCase 'scripts/validate_project.ps1') `
            -Root $impossibleClockCase
    }
    if ($impossibleClock.Code -eq 0) {
        throw 'An impossible clock (T99:99:99Z) was accepted as a valid event stamp.'
    }
    if ($impossibleClock.Text -notmatch 'Malformed event line') {
        throw "Impossible clock failed without the malformed-line diagnostic: $($impossibleClock.Text)"
    }

    # ==== 053 feature-review repairs (parity with the Bash suite) ============

    # 053-01 (R1): the packet must carry the objective body and Acceptance.
    $packetAuthorityCase = Join-Path $tempRoot 'packet-authority-case'
    Copy-Item -LiteralPath $standard -Destination $packetAuthorityCase -Recurse
    $packetAuthority = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $packetAuthorityCase 'scripts/resume_packet.ps1') -Root $packetAuthorityCase
    }
    if ($packetAuthority.Text -notmatch '(?m)^## Objective') {
        throw 'The resume packet does not carry the objective body.'
    }
    if ($packetAuthority.Text -notmatch '(?m)^- Acceptance:') {
        throw "The resume packet does not carry Acceptance; 'done' does not survive a context reset."
    }
    if ($packetAuthority.Text -notmatch '(?m)^\s+- A1:') {
        throw 'The resume packet lists Acceptance but drops the A-items themselves.'
    }
    $packetLineCount = @($packetAuthority.Text -split "`r?`n").Count
    if ($packetLineCount -gt 240) {
        throw "The enriched packet broke the L0 line budget: $packetLineCount lines."
    }

    # 053-02 (R2): the anchor must be readable, and the readable body must never
    # be able to forge the compared digest.
    $anchorReadableCase = Join-Path $tempRoot 'anchor-readable-case'
    Copy-Item -LiteralPath $standard -Destination $anchorReadableCase -Recurse
    $anchorReadableSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $anchorReadableCase 'scripts/session_begin.ps1') -Root $anchorReadableCase
    }
    if ($anchorReadableSession.Code -ne 0) {
        throw "anchor-readable session_begin failed: $($anchorReadableSession.Text)"
    }
    $anchorReadablePath = Join-Path $anchorReadableCase '.pps/objective-anchor'
    $anchorReadableText = [System.IO.File]::ReadAllText($anchorReadablePath, [System.Text.Encoding]::UTF8)
    if ($anchorReadableText -notmatch '(?m)^--\s*objective\s*--\s*$') {
        throw "The anchor carries no readable objective; an agent cannot 'read the anchor'."
    }
    Add-Content -LiteralPath $anchorReadablePath -Encoding utf8 `
        -Value 'objective_sha256: 0000000000000000000000000000000000000000000000000000000000000000'
    $anchorForged = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $anchorReadableCase 'scripts/verify_gate.ps1') -Root $anchorReadableCase
    }
    if ($anchorForged.Text -notmatch 'objective anchor: unchanged since session begin') {
        throw "A forged 'objective_sha256:' line inside the readable body changed the compared digest: $($anchorForged.Text)"
    }

    # 053-03 (§7-2): A1 structural + A2 real must clear the acceptance step.
    $mixedAcceptanceCase = Join-Path $tempRoot 'mixed-acceptance-case'
    Copy-Item -LiteralPath $hybrid -Destination $mixedAcceptanceCase -Recurse
    $mixedStatePath = Join-Path $mixedAcceptanceCase 'PROJECT_STATE.md'
    $mixedState = [System.IO.File]::ReadAllText($mixedStatePath, [System.Text.Encoding]::UTF8)
    $mixedState = $mixedState -replace '(?m)^- Stage: 0 / bootstrap$', '- Stage: 1 / package'
    $mixedState = $mixedState -replace '(?m)^- Main: .*$', '- Main: docs/MAIN.md'
    [System.IO.File]::WriteAllText($mixedStatePath, $mixedState, $utf8NoBom)
    $mixedContextPath = Join-Path $mixedAcceptanceCase 'CONTEXT.md'
    $mixedContext = [System.IO.File]::ReadAllText($mixedContextPath, [System.Text.Encoding]::UTF8)
    $mixedContext = [regex]::Replace(
        $mixedContext, '(?m)^(\s*)- A1:.*$',
        '${1}- A1: Structural validation passes (verify: validate_project).' + "`n" +
        '${1}- A2: Declared authority is wired to a manifest check (verify: M-001).', 1)
    [System.IO.File]::WriteAllText($mixedContextPath, $mixedContext, $utf8NoBom)
    $mixedSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mixedAcceptanceCase 'scripts/session_begin.ps1') -Root $mixedAcceptanceCase
    }
    if ($mixedSession.Code -ne 0) { throw "mixed-acceptance session_begin failed: $($mixedSession.Text)" }
    $mixedGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $mixedAcceptanceCase 'scripts/verify_gate.ps1') -Root $mixedAcceptanceCase
    }
    if ($mixedGate.Text -match 'structural-only floor') {
        throw "A1 structural + A2 real check was rejected; the floor is still 'any' instead of 'all'."
    }
    if ($mixedGate.Text -notmatch 'acceptance wiring: every acceptance item is backed by an executed check') {
        throw "A mixed acceptance declaration did not clear the acceptance wiring step: $($mixedGate.Text)"
    }

    # 053-04 (§7-2 negative): an all-structural non-bootstrap package must fail
    # at the floor, and the diagnostic must point at the migrated A1.
    $allStructuralCase = Join-Path $tempRoot 'all-structural-case'
    Copy-Item -LiteralPath $hybrid -Destination $allStructuralCase -Recurse
    $allStatePath = Join-Path $allStructuralCase 'PROJECT_STATE.md'
    $allState = [System.IO.File]::ReadAllText($allStatePath, [System.Text.Encoding]::UTF8)
    $allState = $allState -replace '(?m)^- Stage: 0 / bootstrap$', '- Stage: 1 / package'
    $allState = $allState -replace '(?m)^- Main: .*$', '- Main: docs/MAIN.md'
    [System.IO.File]::WriteAllText($allStatePath, $allState, $utf8NoBom)
    $allSession = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $allStructuralCase 'scripts/session_begin.ps1') -Root $allStructuralCase
    }
    if ($allSession.Code -ne 0) { throw "all-structural session_begin failed: $($allSession.Text)" }
    $allGate = Invoke-NativeCapture {
        & $engine -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $allStructuralCase 'scripts/verify_gate.ps1') -Root $allStructuralCase
    }
    if ($allGate.Code -eq 0) {
        throw 'An all-structural non-bootstrap package was stamped.'
    }
    if ($allGate.Text -notmatch 'structural-only floor') {
        throw "An all-structural declaration did not hit the structural floor: $($allGate.Text)"
    }
    if ($allGate.Text -notmatch 'migrated from PPS/1\.1') {
        throw 'The structural-floor failure does not tell the operator to replace the migrated A1.'
    }

    # 053-06 (§7-4): the over-claim must be gone from the shipped docs.
    foreach ($overclaimFile in @(
            (Join-Path $skill 'SKILL.md'),
            (Join-Path $repoRoot 'CHANGELOG.md'),
            (Join-Path $skill 'references/protocol.md'),
            (Join-Path $skill 'references/retrieval-and-gates.md'),
            (Join-Path $skill 'references/design-rationale.md'))) {
        $overclaimText = [System.IO.File]::ReadAllText($overclaimFile, [System.Text.Encoding]::UTF8)
        # Match the CLAIM, not any mention: the changelog legitimately quotes
        # the retired wording to record that it was withdrawn.
        if ($overclaimText -match '(?i)(^|[^"''])forced re-read') {
            throw "Stale over-claim 'forced re-read' still present in $overclaimFile."
        }
    }
    $skillDocText = [System.IO.File]::ReadAllText((Join-Path $skill 'SKILL.md'), [System.Text.Encoding]::UTF8)
    if ($skillDocText -notmatch 'Re-run the packet mid-session') {
        throw 'SKILL.md does not state the mid-session re-read invariant (R3).'
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
