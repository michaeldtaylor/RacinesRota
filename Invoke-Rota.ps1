#Requires -Version 7.0
<#
.SYNOPSIS
    Generate the restaurant rota from a roster config.

.DESCRIPTION
    Solves the schedule, prints a readable report, and writes JSON and (optionally) Excel.
    Exits non-zero when the schedule breaks a hard rule, so it can be wired into a check.

.PARAMETER Config
    Path to the roster JSON. Defaults to config\roster.json beside this script.

.PARAMETER Out
    Output directory. Defaults to .\out.

.PARAMETER NoExcel
    Skip the .xlsx and write JSON only.

.PARAMETER Quiet
    Suppress the report on stdout; still writes the files.

.EXAMPLE
    .\Invoke-Rota.ps1
    Solve the shipped roster and write out\schedule.json and out\rota.xlsx.

.EXAMPLE
    .\Invoke-Rota.ps1 -Config .\config\roster.json -Out .\out -NoExcel
    JSON only, useful while iterating on the rules.
#>
[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot 'config\roster.json'),
    [string]$Out = (Join-Path $PSScriptRoot 'out'),
    [switch]$NoExcel,
    [switch]$Quiet,
    # How many candidates get the full constraint engine. The shortlist is what decides
    # quality once the search is fast: at 100 this roster settled for a schedule costing
    # 1330 when one costing 924 was three seconds away.
    [int]$ShortlistSize = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\RacinesRota.psd1') -Force

$cfg = Import-RotaConfig -Path $Config
if (-not $Quiet) {
    Write-Host "Roster: $($cfg.meta.name)  |  $($cfg.staff.Count) staff, $($cfg.SolvedStaff.Count) to place, $($cfg.meta.cycleWeeks)-week cycle"
    Write-Host 'Solving...'
}

$result = Invoke-RotaSolver -Config $cfg -ShortlistSize $ShortlistSize

if (-not $Quiet) {
    Write-Host ''
    Write-Host (Format-RotaReport -Schedule $result.Schedule -Violations $result.Violations)
    Write-Host ''
    Write-Host "Search: $($result.Stats.Nodes) nodes, $($result.Stats.CandidatesFound) candidates, $($result.Stats.ExactlyScored) scored exactly, $([math]::Round($result.Elapsed.TotalSeconds,1))s"
    if ($result.Stats.TimedOut) {
        Write-Warning 'The search hit its time budget, so a better schedule may exist. Raise solver.timeBudgetSeconds to look harder.'
    }
}

$jsonPath = Join-Path $Out 'schedule.json'
Export-RotaJson -Schedule $result.Schedule -Violations $result.Violations -Stats $result.Stats -Path $jsonPath | Out-Null
if (-not $Quiet) { Write-Host "Wrote $jsonPath" }

if (-not $NoExcel) {
    $xlsxPath = Join-Path $Out 'rota.xlsx'
    Export-RotaExcel -Schedule $result.Schedule -Violations $result.Violations -Path $xlsxPath | Out-Null
    if (-not $Quiet) { Write-Host "Wrote $xlsxPath" }
}

# Non-zero exit when a hard rule is broken, so this can gate a build or a scheduled run.
$hard = @($result.Violations | Where-Object Severity -eq 'Hard')
if ($hard.Count -gt 0) {
    if (-not $Quiet) { Write-Warning "$($hard.Count) hard violation(s) -- see the report above." }
    exit 1
}
exit 0
