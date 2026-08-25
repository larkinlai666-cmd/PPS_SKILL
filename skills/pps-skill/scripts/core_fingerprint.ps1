[CmdletBinding()]
param([string]$Root)

# Prints a 16-character sha256 fingerprint of the state a resume packet's
# anchor level must reflect: the objective, the red lines, the current package
# (with its Acceptance items), and the write boundary. Anything that changes
# the goal, the done-condition, or what may be written changes this fingerprint.
#
# Why this exists: .pps/last-packet records the fingerprint of the packet that
# was actually pulled. boundary_check -RequireFreshPacket compares it with the
# disk. A forged timestamp is not enough to satisfy that check: faking the
# fingerprint requires reading these sections off the disk and hashing them,
# and reading them IS the re-anchoring the check exists to force. The cost of
# a fake equals the benefit of compliance.

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)

function Get-SectionBody([string]$File, [string]$Section) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($File, [System.Text.Encoding]::UTF8)
    $result = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in $lines) {
        if ($line -eq "## $Section") { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside) { $result.Add($line) }
    }
    return $result
}

$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
$agentsPath = Join-Path $rootFull 'AGENTS.md'
$contextPath = Join-Path $rootFull 'CONTEXT.md'

# Assembly rule (byte-level parity with the Bash edition, pinned by fixture
# 055): a non-empty section contributes its lines joined by newlines plus a
# trailing newline, then one extra newline closes the section. A section that
# is missing or empty still contributes exactly one closing newline.
function Get-WorksetBoundaryLines([string]$File) {
    $lines = [System.IO.File]::ReadAllLines($File, [System.Text.Encoding]::UTF8)
    $result = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in $lines) {
        if ($line -eq '## Workset Manifest') { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside -and $line -match '^- (Read|Write|Verify|Excluded):') { $result.Add($line) }
    }
    return $result
}

function Append-Section([System.Text.StringBuilder]$Sb, [string[]]$Lines) {
    if ($Lines.Count -gt 0) {
        [void]$Sb.Append($Lines -join [Environment]::NewLine)
        [void]$Sb.Append([Environment]::NewLine)
    }
    [void]$Sb.Append([Environment]::NewLine)
}

# Objective and current package come first: they are the goal and the
# done-condition, the two things drift replaces. Red lines and the write
# boundary are the guardrails rot erases. Order is part of the input.
$sb = [System.Text.StringBuilder]::new()
Append-Section $sb (Get-SectionBody $statePath 'Objective')
Append-Section $sb (Get-SectionBody $agentsPath 'Red Lines')
Append-Section $sb (Get-SectionBody $contextPath 'Current Package')
Append-Section $sb (Get-WorksetBoundaryLines $contextPath)
$coreText = $sb.ToString()

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($coreText)
    $hash = $sha.ComputeHash($bytes)
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    $hex.Substring(0, 16)
} finally {
    $sha.Dispose()
}
