[CmdletBinding()]
param(
    [string]$Root = '.',
    [string]$Type,
    [string]$Script,
    [string]$Message
)

# Append one self-observation line to $ROOT/.pps/fault-log.md.
# The PPS self-observation channel: when a PPS script notices an anomaly in
# itself or its environment, it records one structured line here. The log is
# append-only, project-local, and read by the PPS author between real-world
# runs to turn field faults into review vectors and fixtures.
#
# The channel is strictly side-effect-free: it never changes any PPS check,
# never fails a gate, and every caller swallows its failure so a logging
# problem can never change the behaviour of the script that logged it.
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Type) -or
    [string]::IsNullOrWhiteSpace($Script) -or
    [string]::IsNullOrWhiteSpace($Message)) {
    Write-Output 'Usage: fault_log.ps1 [Root] -Type F-ENV -Script NAME -Message TEXT'
    exit 2
}

$logDir = Join-Path $Root '.pps'
$logFile = Join-Path $logDir 'fault-log.md'
$timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Best-effort only: a logging problem must never propagate to the caller.
try {
    [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
    if (-not (Test-Path -LiteralPath $logFile -PathType Leaf)) {
        $header = "# PPS Fault Log`n`nSelf-observation records: anomalies PPS noticed in itself or its environment.`nAppend-only; see references/self-observation.md.`n`n"
        [System.IO.File]::WriteAllText($logFile, $header, (New-Object System.Text.UTF8Encoding($false)))
    }
    $line = "- $timestamp | $Type | script: $Script | engine: pwsh | $Message`n"
    [System.IO.File]::AppendAllText($logFile, $line, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    exit 1
}
