# RacinesRota -- restaurant rota engine.
#
# Load order matters: Model defines the index arithmetic everything else uses, Config adds
# the property helpers the later files depend on, and the solver needs both plus the
# constraint registry it scores against.

Set-StrictMode -Version Latest

$here = $PSScriptRoot
foreach ($file in @('Model.ps1', 'Config.ps1', 'Constraints.ps1', 'SearchKernel.ps1', 'Solver.ps1', 'Report.ps1', 'Export.ps1', 'ConfigExcel.ps1')) {
    $path = Join-Path $here $file
    if (-not (Test-Path -LiteralPath $path)) { throw "RacinesRota is missing a source file: $path" }
    . $path
}

Export-ModuleMember -Function @(
    # Config
    'Import-RotaConfig', 'Test-RotaConfig', 'ConvertTo-RotaNormalisedConfig', 'Add-RotaFixedStaff',
    'Get-RotaProperty', 'Test-RotaHasProperty', 'Get-RotaRepeatMode', 'Get-RotaNameValuePairs', 'ConvertTo-RotaDayMask'
    # Model
    'Get-RotaSlotIndex', 'Get-RotaServiceIndex', 'ConvertFrom-RotaSlotIndex', 'Get-RotaServices'
    'New-RotaSchedule', 'Add-RotaAssignment', 'Set-RotaWeekMask', 'Get-RotaWeekMask'
    'Get-RotaMaskPopCount', 'Get-RotaDayLoad', 'Get-RotaCycleDayLoads', 'Get-RotaLongestDaysOffRun'
    'Get-RotaDaysOffRunByWeek', 'Test-RotaDaysOffRequirement', 'Get-RotaVariableCosts'
    'Get-RotaCoverage'
    # Constraints
    'Get-RotaConstraints', 'Test-RotaSchedule', 'Get-RotaScore', 'New-RotaViolation', 'Get-RotaWeight'
    'Test-RotaCoverage', 'Test-RotaResponsable', 'Test-RotaFixedAssignments', 'Test-RotaShiftCount'
    'Test-RotaDoubles', 'Test-RotaSlotEligibility', 'Test-RotaWeekendAvailability'
    'Test-RotaConsecutiveDaysOff', 'Test-RotaDaysOffPreference', 'Test-RotaAvailability', 'Test-RotaSlotPreference', 'Test-RotaReleasedShifts', 'Test-RotaIsolatedWorkDays', 'Test-RotaFairness', 'Test-RotaOfficeLunchProtected', 'Test-RotaTemporaryStaff'
    # Solver
    'Invoke-RotaSolver', 'New-RotaSolverVariables', 'Get-RotaVariableComponents', 'Get-RotaWeekGaps'
    'Get-RotaWeekPatterns', 'Get-RotaAllowedMask', 'Get-RotaPopcountCombinations', 'Get-RotaOfficeCombinations', 'Add-RotaComboCost'
    'Get-RotaOfficeCapacityGroups', 'Select-RotaDaysOffFeasiblePatterns', 'Search-RotaComponent', 'Join-RotaComponents'
    'Test-RotaMasksDaysOff', 'Test-RotaMasksResponsable', 'Get-RotaPopCount'
    'Initialize-RotaSearchKernel'
    # Report and export
    'Get-RotaCoverageReport', 'Get-RotaTempCoverReport', 'Get-RotaTemporaryExposureReport', 'Get-RotaPersonReport', 'Get-RotaSummary', 'Format-RotaGrid', 'Format-RotaReport'
    'Get-RotaStartTime', 'ConvertTo-RotaObject', 'Export-RotaJson', 'Export-RotaExcel', 'Set-RotaColumnWidths'
    'Export-RotaConfigExcel', 'Import-RotaConfigExcel', 'ConvertTo-RotaBool', 'ConvertTo-RotaSettingsObject'
)





