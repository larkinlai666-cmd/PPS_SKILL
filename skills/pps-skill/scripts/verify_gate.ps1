[CmdletBinding()]
param(
    [string]$Root
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

Write-Host "== PPS verify gate =="

# Any previous stamp is invalid the moment a new verification starts. A failed
# run must never leave behind a stamp that readiness could accept.
$stampPath = Join-Path $rootFull '.pps/verify-stamp'
if (Test-Path -LiteralPath $stampPath) {
    Remove-Item -LiteralPath $stampPath -Force
}

Write-Host "-- Step 1/4: structural validation"
$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) {
    $engine = Get-Command powershell -ErrorAction Stop
}
& $engine.Source -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $rootFull 'scripts/validate_project.ps1') -Root $rootFull -Quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "PPS verify gate: FAILED (structural validation)"
    exit 1
}
Write-Host "structural validation: pass"

Write-Host "-- Step 2/4: Verify declaration routing"
$contextText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'CONTEXT.md'), [System.Text.Encoding]::UTF8)
$worksetMatch = [regex]::Match(
    $contextText,
    '(?ms)^##\s+Workset Manifest\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$verifyDecl = ''
if ($worksetMatch.Success) {
    $verifyMatch = [regex]::Match(
        $worksetMatch.Groups['body'].Value, '(?m)^-\s+Verify:\s*(.*?)\s*$')
    if ($verifyMatch.Success) { $verifyDecl = $verifyMatch.Groups[1].Value }
}
if ($verifyDecl -notmatch 'scripts/(verify_gate|project_verify)') {
    Write-Host "ERROR: the Workset Verify declaration must route through scripts/verify_gate.* (which executes scripts/project_verify.*)."
    Write-Host "Found unrouted declaration: $verifyDecl"
    Write-Host "Put the actual commands into scripts/project_verify.*; the gate never passes free-form Markdown text to a shell."
    Write-Host "PPS verify gate: FAILED (unrouted Verify declaration)"
    exit 1
}
Write-Host "Verify routing: declaration routes through the gate entry"

# A mention is not a call, and a definition is not a call either. Same
# semantics as the Bash entry_live_lines (shared by validate_project.ps1):
# comments stripped, dead branches dropped, function bodies reachable only via
# closure. Output lines are "T <line>" or "F <fnname> <line>".
function Get-EntryLiveLines([string]$EntryPath) {
    $raw = [System.IO.File]::ReadAllLines($EntryPath, [System.Text.Encoding]::UTF8)
    $cleaned = New-Object string[] $raw.Count
    $isFn = New-Object bool[] $raw.Count
    $fnName = New-Object string[] $raw.Count
    $inFn = $false
    $curFn = ''
    for ($i = 0; $i -lt $raw.Count; $i++) {
        $line = $raw[$i].TrimStart()
        if ($line.StartsWith('#')) { $line = '' }
        else {
            $hash = $line.IndexOf('#')
            if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
        }
        $line = $line.TrimEnd()
        $cleaned[$i] = $line
        if ($inFn) {
            $isFn[$i] = $true
            $fnName[$i] = $curFn
            if ($line -match '^\}\s*$') { $inFn = $false; $isFn[$i] = $false }
            continue
        }
        if ($line -match '^function\s+[A-Za-z_][A-Za-z0-9_-]*\s*\{') {
            $m = [regex]::Match($line, '^function\s+([A-Za-z_][A-Za-z0-9_-]*)')
            $curFn = $m.Groups[1].Value
            $isFn[$i] = $true
            $fnName[$i] = $curFn
            if ($line -notmatch '\}\s*$') { $inFn = $true }
            continue
        }
    }
    $bodies = @{}
    $top = @()
    $inDead = $false
    for ($i = 0; $i -lt $raw.Count; $i++) {
        $line = $cleaned[$i]
        if ($line -eq '') { continue }
        if ($line -match '^if\s*\(\s*(\$false|\$null|0|!\s*\$true)\s*\)' -or
            $line -match '^while\s*\(\s*\$false\s*\)') {
            if ($line -notmatch '\}\s*$') { $inDead = $true }
            continue
        }
        if ($inDead) {
            if ($line -match '^\}\s*$') { $inDead = $false }
            continue
        }
        if ($isFn[$i]) {
            if (-not $bodies.ContainsKey($fnName[$i])) {
                $bodies[$fnName[$i]] = New-Object System.Collections.ArrayList
            }
            $null = $bodies[$fnName[$i]].Add($line)
        } else {
            $top += $line
        }
    }
    $queue = New-Object System.Collections.ArrayList
    foreach ($l in $top) {
        $helperMatch = [regex]::Match($l, '(?:Invoke-Check|check)\s+"[^"]*"\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$')
        if ($helperMatch.Success) { $null = $queue.Add($helperMatch.Groups[1].Value) }
        elseif ($l -match '^[A-Za-z_][A-Za-z0-9_-]*\s*$') { $null = $queue.Add($l) }
    }
    $result = New-Object System.Collections.ArrayList
    foreach ($l in $top) { $null = $result.Add("T $l") }
    $visited = @{}
    $qi = 0
    while ($qi -lt $queue.Count) {
        $f = $queue[$qi]; $qi++
        if ($visited.ContainsKey($f)) { continue }
        $visited[$f] = $true
        if (-not $bodies.ContainsKey($f)) { continue }
        foreach ($b in $bodies[$f]) {
            if ($b -match '^if\s*\(\s*(\$false|\$null|0|!\s*\$true)\s*\)' -or
                $b -match '^while\s*\(\s*\$false\s*\)') { continue }
            $null = $result.Add("F $f $b")
            $helperMatch = [regex]::Match($b, '(?:Invoke-Check|check)\s+"[^"]*"\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$')
            if ($helperMatch.Success) { $null = $queue.Add($helperMatch.Groups[1].Value) }
            elseif ($b -match '^[A-Za-z_][A-Za-z0-9_-]*\s*$') { $null = $queue.Add($b) }
        }
    }
    return $result.ToArray()
}

function Test-EntryInvokesPath([string]$EntryPath, [string]$Wanted) {
    foreach ($l in @(Get-EntryLiveLines $EntryPath)) {
        if (-not $l.Contains($Wanted)) { continue }
        # Strip the live-line prefix so a top-level "& x.ps1" still counts,
        # then require a CALL shape, not a mention: a string literal that
        # names the path proves nothing.
        $line = $l
        if ($line.StartsWith('T ')) { $line = $line.Substring(2) }
        elseif ($line -match '^F [A-Za-z_][A-Za-z0-9_-]* ') {
            $line = $line.Substring($line.IndexOf(' ') + 1)
        }
        if ($line -match '(^|[^A-Za-z0-9_])(Invoke-Check|check|bash|sh|pwsh|powershell|python3?|node|npm|npx)\s' -or
            $line -match '^&\s' -or
            $line -match '\)\s*\{' -or
            $line -match '^\$\w+\s*=\s*&') {
            return $true
        }
    }
    return $false
}

$canonicalBookkeeping = @(
    'PROJECT_STATE.md', 'EVENTS.md', 'DECISIONS.md', 'CONTEXT.md', 'PROJECT_MAP.md',
    'TASK_INDEX.md', 'MERGES.md', 'ASSETS.md', 'ENVIRONMENT.md', 'SOURCE_INDEX.md',
    'AGENTS.md'
)

function Get-RealArtifactRefs([string]$Text, [string]$RootFull) {
    $refs = @()
    foreach ($m in [regex]::Matches($Text, '[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9]+')) {
        $candidate = $m.Value -replace '^\./', ''
        $candidate = $candidate -replace '^(root|rootFull|PSScriptRoot|projectRoot|repo|repoRoot)/', ''
        if ($candidate -in $canonicalBookkeeping) { continue }
        if (Test-Path -LiteralPath (Join-Path $RootFull $candidate)) { $refs += $candidate }
    }
    return $refs
}

Write-Host "-- Step 2b/4: gate substance"
$verifyEntry = Join-Path $rootFull 'scripts/project_verify.ps1'
if (-not (Test-Path -LiteralPath $verifyEntry -PathType Leaf)) {
    Write-Host "ERROR: missing verification entry: scripts/project_verify.ps1"
    Write-Host "PPS verify gate: FAILED (missing verification entry)"
    exit 1
}
# A gate that executes an empty entry proves execution of nothing. Refuse the
# hollow entry outright: this is the "knowing is not doing" failure the stamp
# exists to prevent.
$entryLinesAll = [System.IO.File]::ReadAllLines($verifyEntry, [System.Text.Encoding]::UTF8)
$substantive = @($entryLinesAll | Where-Object {
    $trimmed = $_.Trim()
    $trimmed -ne '' -and -not $trimmed.StartsWith('#') -and
    $trimmed -notmatch '^(exit\s+0|return|Write-(Host|Output)\s)' 
})
$hasCheckCalls = ($entryLinesAll | Where-Object { $_ -match 'Invoke-Check\s|check\s+"' }).Count -gt 0
if (-not $hasCheckCalls -or $substantive.Count -lt 5) {
    Write-Host "ERROR: scripts/project_verify.ps1 has no real checks; an unconditional 'exit 0' or an echo-only entry defeats the gate."
    Write-Host "Declare at least one check that fails non-zero when the project is broken."
    Write-Host "PPS verify gate: FAILED (hollow verification entry)"
    exit 1
}
$entryText = [System.IO.File]::ReadAllText($verifyEntry, [System.Text.Encoding]::UTF8)
$stateText = [System.IO.File]::ReadAllText((Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$modeMatch = [regex]::Match($stateText, '(?m)^-\s+Mode:\s*(.*?)\s*$')
$modeValue = if ($modeMatch.Success) { $modeMatch.Groups[1].Value } else { '' }
if ($modeValue -in @('software', 'hybrid')) {
    # Unit tests can pass while the caller path is broken: a software package
    # needs at least one check that is not the structural validator itself.
    # The template ships structural self-checks (state files exist, chronicle
    # non-empty). Those are PPS bookkeeping, not evidence the product works.
    $cleanedCandidates = @($entryLinesAll | ForEach-Object {
        $candidate = $_.TrimStart()
        $hash = $candidate.IndexOf('#')
        if ($hash -ge 0) { $candidate = $candidate.Substring(0, $hash) }
        $candidate.TrimEnd()
    })
    $behavioral = @($cleanedCandidates | Where-Object {
        (-not $_.StartsWith('#')) -and
        ($_ -match 'Invoke-Check\s|check\s+"') -and
        ($_ -notmatch 'validate_project|validate_skill') -and
        ($_ -notmatch 'PROJECT_STATE|EVENTS\.md|DECISIONS|CONTEXT\.md|PROJECT_MAP|TASK_INDEX|MERGES|coverage') -and
        ($_ -notmatch 'main artifact exists')
    })
    if ($behavioral.Count -lt 1) {
        Write-Host "ERROR: software package needs a behavioral check: scripts/project_verify.ps1 declares only structural validation."
        Write-Host "Add at least one check that exercises the product the way a user reaches it."
        Write-Host "PPS verify gate: FAILED (no behavioral check)"
        exit 1
    }
    # An always-true script block satisfies a lexical rule while asserting
    # nothing. Require a real project artifact on the behavioral line, in its
    # live block body, or in the helper it reaches. A check declared inside a
    # dead branch proves nothing: only the live analysis output counts.
    $liveLines = @(Get-EntryLiveLines $verifyEntry)
    $liveTop = @($liveLines | Where-Object { $_ -like 'T *' } |
        ForEach-Object { $_.Substring(2) })
    $behavioralReal = $false
    foreach ($behavioralLine in $behavioral) {
        if ($liveTop -notcontains $behavioralLine) { continue }
        $execPart = [regex]::Replace(
            $behavioralLine, '^.*?(Invoke-Check|check)\s+"[^"]*"', '')
        $sources = New-Object System.Collections.ArrayList
        $null = $sources.Add($execPart)
        $idx = [Array]::IndexOf($liveTop, $behavioralLine)
        for ($i = $idx + 1; $i -lt $liveTop.Count; $i++) {
            $blockLine = $liveTop[$i]
            if ($blockLine.TrimStart().StartsWith('}')) { break }
            $null = $sources.Add($blockLine)
        }
        $helperMatch = [regex]::Match($execPart, '^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$')
        if ($helperMatch.Success) {
            $helperName = $helperMatch.Groups[1].Value
            $prefix = "F $helperName "
            foreach ($l in $liveLines) {
                if ($l -like "F $helperName *") {
                    $null = $sources.Add($l.Substring($prefix.Length))
                }
            }
        }
        foreach ($src in $sources) {
            if ((Get-RealArtifactRefs $src $rootFull).Count -gt 0) {
                $behavioralReal = $true
                break
            }
        }
        if ($behavioralReal) { break }
    }
    if (-not $behavioralReal) {
        Write-Host "ERROR: the behavioral check in scripts/project_verify.ps1 names no real project artifact; an always-true assertion checks nothing."
        Write-Host "Point the check at a test file, probe, or product entry point that exists in the project."
        Write-Host "PPS verify gate: FAILED (behavioral check asserts nothing)"
        exit 1
    }
}
Write-Host "gate substance: entry declares real checks"

Write-Host "-- Step 2d/4: relay handover lock"
# The lock must be on the completion path, not in an optional script nobody
# runs. Close is "gate + readiness"; if the gate never consults the handover
# snapshot, the predecessor's uncommitted work can vanish silently and the
# stamp will still claim the package was verified.
$snapshotPathGate = Join-Path $rootFull '.pps/session-snapshot'
if (-not (Test-Path -LiteralPath $snapshotPathGate -PathType Leaf)) {
    if ($modeValue -in @('software', 'hybrid')) {
        Write-Host 'Relay: SNAPSHOT MISSING; run scripts/session_begin.ps1 before writing.'
        Write-Host 'Without a session snapshot the gate cannot prove this session did not overwrite uncommitted handover work.'
        Write-Host 'PPS verify gate: FAILED (Relay: SNAPSHOT MISSING)'
        exit 1
    }
    Write-Host "Relay: SNAPSHOT MISSING; run scripts/session_begin.ps1 before writing (warning in $modeValue mode)."
}
$boundaryScript = Join-Path $rootFull 'scripts/boundary_check.ps1'
if (Test-Path -LiteralPath $boundaryScript -PathType Leaf) {
    $boundaryArgs = @('-Root', $rootFull)
    $writerMatch = [regex]::Match($stateText, '(?m)^-\s+Writer:\s*(.*?)\s*$')
    if ($writerMatch.Success -and
        -not [string]::IsNullOrWhiteSpace($writerMatch.Groups[1].Value) -and
        $writerMatch.Groups[1].Value -ne 'none') {
        $boundaryArgs += @('-Task', $writerMatch.Groups[1].Value)
    }
    if (Test-Path -LiteralPath (Join-Path $rootFull '.pps/boundary-baseline') -PathType Leaf) {
        $boundaryArgs += '-AllowPreexisting'
    }
    $boundaryOutput = (& $engine.Source -NoProfile -ExecutionPolicy Bypass `
        -File $boundaryScript @boundaryArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    if ($boundaryOutput -match 'protected_overwrite:') {
        foreach ($boundaryLine in ($boundaryOutput -split "`n")) {
            if ($boundaryLine -match 'protected_overwrite:') { Write-Host $boundaryLine }
        }
        Write-Host 'PPS verify gate: FAILED (protected_overwrite: handover work was overwritten)'
        exit 1
    }
    if ($boundaryOutput -match 'unclaimed_write:') {
        # Unclaimed writes are a boundary-discipline problem, not a handover
        # loss. Keep the gate's hard failure scoped to what Git cannot recover.
        Write-Host 'WARNING: the worktree contains changes no Write set claims; run scripts/boundary_check.ps1 and claim or revert them.'
    }
    Write-Host 'relay handover lock: no protected path was overwritten'
} else {
    if ($modeValue -in @('software', 'hybrid')) {
        # Deleting the checker must not restore the old "no lock at all" path.
        Write-Host 'Relay: BOUNDARY MISSING; scripts/boundary_check.ps1 is required on the completion path.'
        Write-Host 'Without it the gate cannot prove this session did not overwrite uncommitted handover work.'
        Write-Host 'PPS verify gate: FAILED (Relay: BOUNDARY MISSING)'
        exit 1
    }
    Write-Host "relay handover lock: boundary_check.ps1 unavailable; cannot verify handover safety (warning in $modeValue mode)."
}



Write-Host "-- Step 2e/4: structured check manifest execution"
# The check manifest is the executable truth: every row is a real command the
# gate runs on THIS platform, with the exit code compared to the expected one.
# Static text scanning of the entry is only a lint below; it never satisfies
# red-line or coverage wiring on its own.

# --- F-050-02: Python 3 interpreter discovery -------------------------------
# The evidence engine is a hard runtime for this gate. Windows frequently has
# python/py but not python3, and the Store python3.exe stub is not an
# interpreter. Discovery order: PPS_PYTHON -> python3 -> python -> py -3.
$script:PPSPython = $null
function Resolve-PPSPython {
    if ($null -ne $script:PPSPython) { return $script:PPSPython }
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($env:PPS_PYTHON)) {
        $null = $candidates.Add(@($env:PPS_PYTHON))
    }
    $null = $candidates.Add(@('python3'))
    $null = $candidates.Add(@('python'))
    $null = $candidates.Add(@('py', '-3'))
    foreach ($cand in $candidates) {
        if ($null -eq (Get-Command $cand[0] -ErrorAction SilentlyContinue)) { continue }
        $candTail = if ($cand.Count -gt 1) { @($cand[1..($cand.Count - 1)]) } else { @() }
        $null = & $cand[0] @($candTail) -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>$null
        if ($LASTEXITCODE -eq 0) {
            $script:PPSPython = $cand
            return $cand
        }
    }
    return $null
}
function Invoke-PPSEvidence([string[]]$EvidenceArgs) {
    # PowerShell unrolls single-element arrays across return; @() restores
    # the array shape so $py[0] is the interpreter, not its first character.
    $py = @(Resolve-PPSPython)
    if ($null -eq $py) {
        Write-Host 'ERROR: the PPS evidence engine requires Python 3. Tried: python3, python, py -3. Install Python 3 or set PPS_PYTHON to the interpreter path.'
        Write-Host 'PPS verify gate: FAILED (python 3 interpreter required)'
        exit 1
    }
    $evidenceScript = Join-Path $PSScriptRoot 'pps_evidence.py'
    $pyTail = if ($py.Count -gt 1) { @($py[1..($py.Count - 1)]) } else { @() }
    $fullArgs = @($py[0]) + @($pyTail) + @($evidenceScript) + $EvidenceArgs
    $out = & $fullArgs[0] @($fullArgs[1..($fullArgs.Count - 1)]) 2>&1 | ForEach-Object { "$_" }
    return ($out -join "`n")
}
# --- F-050-03: kill the whole process tree on timeout -----------------------
function Stop-PPSProcessTree([int]$TargetPid) {
    if ($env:OS -eq 'Windows_NT') {
        $null = & taskkill /PID $TargetPid /T /F 2>$null
    } else {
        $null = & pkill -TERM -P $TargetPid 2>$null
        Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
        $null = & pkill -KILL -P $TargetPid 2>$null
    }
}
$manifestPath = Join-Path $rootFull '.pps/verify-manifest.txt'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host "ERROR: missing .pps/verify-manifest.txt; the gate must run a declared check list, not trust prose."
    Write-Host "PPS verify gate: FAILED (missing check manifest)"
    exit 1
}
$runTsvPath = Join-Path $rootFull '.pps/.verify-run.tsv'
$runTsv = New-Object System.Collections.ArrayList
$runFailed = $false
$runRelevant = 0
foreach ($lineRaw in [System.IO.File]::ReadAllLines($manifestPath, [System.Text.Encoding]::UTF8)) {
    $line = $lineRaw.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -lt 6) {
        Write-Host "ERROR: manifest line has $($parts.Count) columns, need at least 6: $line"
        Write-Host "PPS verify gate: FAILED (malformed check manifest)"
        exit 1
    }
    $checkId = $parts[0].Trim()
    $checkPlatform = $parts[1].Trim()
    $checkCwd = $parts[2].Trim()
    $checkTimeout = $parts[3].Trim()
    $checkExpected = $parts[4].Trim()
    $checkCommand = $parts[5].Trim()
    $checkNote = if ($parts.Count -gt 6) { $parts[6].Trim() } else { '' }
    if ($checkPlatform -notin @('any', 'powershell')) { continue }
    if ($checkId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        Write-Host "ERROR: invalid check id '$checkId'."
        Write-Host "PPS verify gate: FAILED (malformed check manifest)"
        exit 1
    }
    $runRelevant++
    $itemStarted = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $itemCwd = $rootFull
    if (-not [string]::IsNullOrWhiteSpace($checkCwd) -and $checkCwd -ne '.') {
        # F-050-04: the working directory must live inside the project root.
        # Absolute paths and escapes (including via symlinks) fail the row.
        if ($checkCwd -match '^[A-Za-z]:' -or $checkCwd.StartsWith('/') -or $checkCwd.StartsWith('\')) {
            Write-Host "ERROR: manifest check $checkId cwd '$checkCwd' is absolute; a check working directory must live inside the project root."
            $runFailed = $true
            continue
        }
        $cwdFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull $checkCwd))
        $rootPrefix = $rootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ($cwdFull -ne $rootPrefix -and -not $cwdFull.StartsWith($rootPrefix + [System.IO.Path]::DirectorySeparatorChar)) {
            Write-Host "ERROR: manifest check $checkId cwd '$checkCwd' escapes the project root."
            $runFailed = $true
            continue
        }
        if (-not (Test-Path -LiteralPath $cwdFull -PathType Container)) {
            Write-Host "ERROR: manifest check $checkId cwd '$checkCwd' does not exist."
            $runFailed = $true
            continue
        }
        $itemCwd = $cwdFull
    }
    Write-Host "check $checkId : $checkCommand"
    $itemCode = -1
    $itemTimedOut = $false
    $itemExpected = 0
    if ($checkExpected -match '^\d+$') { $itemExpected = [int]$checkExpected }
    $itemTimeout = 0
    if ($checkTimeout -match '^\d+$') { $itemTimeout = [int]$checkTimeout }
    if ($itemTimeout -gt 0) {
        # F-050-03: the timeout column is a real deadline, not a note. The
        # command runs as its own process; on expiry the whole tree is killed
        # and the row fails. -EncodedCommand avoids all quoting mangling, and
        # the CHILD reports its own exit code into a file: Start-Process
        # Process objects gave empty ExitCode on Windows CI, so the parent
        # never trusts the handle for the number.
        $exitFile = Join-Path $rootFull ('.pps/.last-exit-' + $checkId + '.txt')
        if (Test-Path -LiteralPath $exitFile) { Remove-Item -LiteralPath $exitFile -Force }
        $wrapped = $checkCommand + "; `$c = `$LASTEXITCODE; if (`$null -eq `$c) { `$c = 0 }; [System.IO.File]::WriteAllText(`$env:PPS_EXIT_FILE, [string]`$c)"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
        $env:PPS_EXIT_FILE = $exitFile
        # .NET ProcessStartInfo with a closed stdin: a Start-Process child
        # inherits the parent's (often redirected) stdin and tries to parse it
        # as CLIXML — "Data at the root level is invalid" on CI. Closing our
        # write end hands the child a clean EOF instead.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $engine.Source
        $psi.Arguments = "-NoProfile -EncodedCommand $encoded"
        $psi.WorkingDirectory = $itemCwd
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $itemProc = [System.Diagnostics.Process]::Start($psi)
        $itemProc.StandardInput.Close()
        # Drain the pipes while the child runs: Windows anonymous pipes are
        # ~4KB and a blocked child can never exit, so a synchronous
        # ReadToEnd after WaitForExit deadlocks. ReadToEndAsync runs
        # concurrently on both engines.
        $itemOutTask = $itemProc.StandardOutput.ReadToEndAsync()
        $itemErrTask = $itemProc.StandardError.ReadToEndAsync()
        if ($itemProc.WaitForExit([int]($itemTimeout * 1000))) {
            $itemStdOut = $itemOutTask.Result
            $itemStdErr = $itemErrTask.Result
            if ($itemStdOut) { Write-Host $itemStdOut }
            if ($itemStdErr) { Write-Host "stderr: $itemStdErr" }
            $itemCode = -1
            if (Test-Path -LiteralPath $exitFile) {
                $reported = [System.IO.File]::ReadAllText($exitFile).Trim()
                if ($reported -match '^-?\d+$') { $itemCode = [int]$reported }
            }
        } else {
            $itemTimedOut = $true
            Stop-PPSProcessTree $itemProc.Id
            $itemCode = -1
        }
        $env:PPS_EXIT_FILE = $null
    } else {
        $prevPref = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            Push-Location $itemCwd
            try {
                & $engine.Source -NoProfile -Command $checkCommand 2>&1 | ForEach-Object { Write-Host $_ }
                $itemCode = $LASTEXITCODE
            } finally {
                Pop-Location
            }
        } finally {
            $ErrorActionPreference = $prevPref
        }
    }
    $itemOk = $false
    if ($itemTimedOut) {
        Write-Host "check $checkId : FAIL (timed out after ${itemTimeout}s)"
    } else {
        $itemOk = ($itemCode -eq $itemExpected)
        $itemVerb = if ($itemOk) { 'pass' } else { 'FAIL' }
        Write-Host "check $checkId : $itemVerb (exit $itemCode, expected $itemExpected)"
    }
    if (-not $itemOk) { $runFailed = $true }
    if (-not [string]::IsNullOrWhiteSpace($checkNote)) { Write-Host "  note: $checkNote" }
    $itemExitText = if ($itemTimedOut) { 'timeout' } else { "$itemCode" }
    $itemOkText = if ($itemOk) { 'true' } else { 'false' }
    $null = $runTsv.Add(
        "$checkId`t$checkPlatform`t$checkCwd`t$checkTimeout`t$checkExpected`t$checkCommand`t$itemExitText`t$itemOkText`t$itemStarted`t$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
}
if ($runRelevant -eq 0) {
    Write-Host "ERROR: the check manifest declares no check for the powershell platform."
    $runFailed = $true
}
[System.IO.File]::WriteAllLines(
    $runTsvPath, [string[]]$runTsv, (New-Object System.Text.UTF8Encoding($false)))
$writeRunText = (Invoke-PPSEvidence @('write-run', $rootFull, 'powershell', $runTsvPath)).Trim()
if ($writeRunText -ne 'ok' -and $writeRunText -ne 'fail') {
    Write-Host "ERROR: run record generation failed: $writeRunText"
    Write-Host "PPS verify gate: FAILED (run record generation)"
    exit 1
}
if ($runFailed -or $writeRunText -ne 'ok') {
    Write-Host 'PPS verify gate: FAILED (check manifest execution)'
    exit 1
}
Write-Host 'check manifest execution: all declared checks passed'
Write-Host "-- Step 2c/4: red line wiring"
# Red lines may name the check that enforces them: "(verify: path)". When a
# red line names one, the gate entry must actually reference that path, or the
# red line is a wish rather than a rule.
$redlineTargets = @()
$agentsPath = Join-Path $rootFull 'AGENTS.md'
if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    $agentsText = [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8)
    $redlineSection = [regex]::Match(
        $agentsText, '(?ms)^##\s+Red Lines\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if ($redlineSection.Success) {
        foreach ($m in [regex]::Matches($redlineSection.Groups['body'].Value, '\(verify:\s*([^)]+)\)')) {
            $candidate = $m.Groups[1].Value.Trim()
            if ($candidate -and ($candidate -notin $redlineTargets)) { $redlineTargets += $candidate }
        }
    }
}
if ($redlineTargets.Count -gt 0) {
    # Wiring now means EXECUTED: the path must appear in a check manifest row
    # that the gate ran successfully on this platform. Text shape in the entry
    # is only a lint here; it can never satisfy wiring on its own.
    $unwired = $false
    foreach ($target in $redlineTargets) {
        $runEvidence = (Invoke-PPSEvidence @('run-has-path', $rootFull, $target)).Trim()
        if ($runEvidence -eq 'ok') { continue }
        $shapeLint = if (Test-EntryInvokesPath $verifyEntry $target) {
            ' (the gate entry mentions it, but a mention is not an execution)'
        } else { '' }
        Write-Host "ERROR: red line names '(verify: $target)' but no manifest check ran it successfully on this platform$shapeLint."
        $unwired = $true
    }
    if ($unwired) {
        Write-Host "Add a check row for the named path to .pps/verify-manifest.txt and re-run the gate."
        Write-Host "PPS verify gate: FAILED (red line not wired to an executed check)"
        exit 1
    }
    Write-Host "red line wiring: all named checks are wired to executed manifest checks"
} else {
    Write-Host "red line wiring: no red line names a machine check (human-only red lines are allowed)"
}

Write-Host "-- Step 3/4: project verification entry"
$entryRel = 'scripts/project_verify.ps1'
$entryPath = Join-Path $rootFull $entryRel
if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
    Write-Host "ERROR: missing project verification entry: $entryRel"
    Write-Host "PPS verify gate: FAILED (missing project_verify)"
    exit 1
}
& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $entryPath -Root $rootFull
if ($LASTEXITCODE -ne 0) {
    Write-Host "project verification: FAILED (exit $LASTEXITCODE)"
    Write-Host "PPS verify gate: FAILED (project verification)"
    exit 1
}
Write-Host "project verification: pass"

Write-Host "-- Step 4/4: recording verify stamp"
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
    Write-Host "PPS verify gate: FAILED (cannot resolve current package)"
    exit 1
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-TextSha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$entrySha = Get-FileSha256 $entryPath
$capsuleSha = Get-FileSha256 (Join-Path $rootFull 'CONTEXT.md')

function Invoke-NativeProbe([scriptblock]$Command) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 promotes native stderr to error records; a
        # non-repository is a normal probe result, not a terminating error.
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& $Command 2>$null)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{
        Code = $exitCode
        Output = $output
        Text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    }
}

$git = Get-Command git -ErrorAction SilentlyContinue
$worktreeId = 'no-git'
if ($null -ne $git) {
    $repoProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse --is-inside-work-tree }
    if ($repoProbe.Code -eq 0 -and $repoProbe.Text -eq 'true') {
        $headProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse HEAD }
        $headSha = if ($headProbe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($headProbe.Text)) {
            $headProbe.Text
        } else {
            'no-commit'
        }
        # Content-level fingerprint: HEAD plus, for every changed path, its
        # status AND the SHA-256 of its current bytes. Porcelain text alone is
        # blind to an already-dirty file changing again; this is not.
        $statusProbe = Invoke-NativeProbe {
            $prevEnc = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                & $git.Source -C $rootFull status --porcelain -z --untracked-files=all
            } finally {
                [Console]::OutputEncoding = $prevEnc
            }
        }
        $entryLines = @()
        $rawStatus = ($statusProbe.Output | ForEach-Object { "$_" }) -join "`n"
        $skipNext = $false
        foreach ($statusEntry in $rawStatus.Split([char]0)) {
            if ($skipNext) { $skipNext = $false; continue }
            $line = "$statusEntry"
            if ($line.Length -le 3) { continue }
            $entryStatus = $line.Substring(0, 2)
            $entryPath = $line.Substring(3)
            if ($entryStatus -match '^[RC]') { $skipNext = $true }
            $entryFile = Join-Path $rootFull $entryPath
            $contentHash = if (Test-Path -LiteralPath $entryFile -PathType Leaf) {
                Get-FileSha256 $entryFile
            } else {
                'absent'
            }
            $entryLines += "$entryStatus`t$entryPath`t$contentHash"
        }
        $entryText = ''
        if ($entryLines.Count -gt 0) {
            [System.Array]::Sort($entryLines, [System.StringComparer]::Ordinal)
            $entryText = $entryLines -join "`n"
        }
        $worktreeId = $headSha + '+' + (Get-TextSha256 $entryText)
    }
}

$stampDir = Join-Path $rootFull '.pps'
if (-not (Test-Path -LiteralPath $stampDir)) {
    New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
}
$utcNow = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$manifestSha = 'absent'
$manifestStampPath = Join-Path $rootFull '.pps/verify-manifest.txt'
if (Test-Path -LiteralPath $manifestStampPath -PathType Leaf) {
    $manifestSha = Get-FileSha256 $manifestStampPath
}
$runSha = 'absent'
$runRecordPath = Join-Path $rootFull '.pps/verify-run.json'
if (Test-Path -LiteralPath $runRecordPath -PathType Leaf) {
    $runSha = Get-FileSha256 $runRecordPath
}
$stampLines = @(
    "package: $packageId",
    "entry: $entryRel",
    "entry_sha256: $entrySha",
    "capsule_sha256: $capsuleSha",
    "manifest_sha256: $manifestSha",
    "run_sha256: $runSha",
    "platform: powershell",
    "result: pass",
    "worktree: $worktreeId",
    "verified_at: $utcNow"
)
[System.IO.File]::WriteAllText(
    $stampPath,
    ($stampLines -join "`n") + "`n",
    [System.Text.UTF8Encoding]::new($false))
Write-Host "verify stamp: $packageId"
Write-Host "PPS verify gate: OK"
exit 0
