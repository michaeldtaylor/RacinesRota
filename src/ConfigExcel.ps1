# ConfigExcel.ps1 -- the roster criteria as a spreadsheet, readable and editable by hand.
#
# The engine's rules are not the programmer's to own: shift counts, days off, who is a
# responsable and who is only cover are the manager's decisions, and they change. Keeping
# them in a workbook means changing them needs no code, no JSON syntax and no deployment.
#
# The workbook is the input format, not a rendering of it: Import-RotaConfigExcel produces
# the same config object as Import-RotaConfig, so everything downstream is unchanged.
#
# Sheets:
#   Staff      one row per person: contract, mode, cycle, days off, responsable, cover
#   FixedGrid  the fixed rota, one column per day and service
#   Criteria   per person per week: doubles, shifts, weekend, lunch, dinner eligibility
#   Coverage   how many are needed per service, and any closed services
#   Rules      the house rules
#   Weights    what the engine trades off against what

Set-StrictMode -Version Latest

$script:RotaCriteriaColumns = @('Name', 'Week', 'Doubles', 'Shifts', 'MaxShifts', 'Weekend', 'Lunch', 'Dinner')
$script:RotaStaffColumns = @('Name', 'Contract', 'Mode', 'Responsable', 'Temporary', 'CycleWeeks',
    'ConsecutiveDaysOff', 'Colour', 'DinnerStart', 'OfficeLunchDays')

function ConvertTo-RotaBool {
    <#  Excel round-trips booleans as TRUE/FALSE/1/0/yes depending on how they were typed.  #>
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value -or "$Value".Trim() -eq '') { return $Default }
    switch -Regex ("$Value".Trim()) {
        '^(?i:true|yes|y|1|x)$' { $true; break }
        '^(?i:false|no|n|0)$' { $false; break }
        default { $Default }
    }
}

function Export-RotaConfigExcel {
    <#
    .SYNOPSIS
        Write a roster config out as an editable workbook.
    .DESCRIPTION
        Use this once to lift the criteria out of JSON, then edit the workbook from then on.
        Import-RotaConfigExcel reads it back, so the two are a matched pair.
    .PARAMETER Config
        A config loaded by Import-RotaConfig.
    .PARAMETER Path
        Destination .xlsx. Overwritten if it exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    Assert-RotaExcelModule

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $package = Open-ExcelPackage -Path $Path -Create
    try {
        Write-RotaSheetFromRows -Package $package -Name 'Staff' -Columns $script:RotaStaffColumns -Rows (Get-RotaStaffRows -Config $Config)
        Write-RotaFixedGridSheet -Package $package -Config $Config
        Write-RotaSheetFromRows -Package $package -Name 'Criteria' -Columns $script:RotaCriteriaColumns -Rows (Get-RotaCriteriaRows -Config $Config)
        Write-RotaSheetFromRows -Package $package -Name 'Coverage' -Columns @('Setting', 'Value') -Rows (Get-RotaCoverageRows -Config $Config)
        Write-RotaSheetFromRows -Package $package -Name 'Rules' -Columns @('Setting', 'Value') -Rows (Get-RotaSettingRows -Object $Config.rules)
        Write-RotaSheetFromRows -Package $package -Name 'Weights' -Columns @('Setting', 'Value') -Rows (Get-RotaSettingRows -Object $Config.weights)
        Write-RotaSheetFromRows -Package $package -Name 'Solver' -Columns @('Setting', 'Value') -Rows (Get-RotaSettingRows -Object $Config.solver)
        Close-ExcelPackage -ExcelPackage $package
    }
    catch {
        Close-ExcelPackage -ExcelPackage $package -NoSave
        throw
    }
    $Path
}

function Write-RotaSheetFromRows {
    <#  A plain header-plus-rows sheet. Written cell by cell because Export-Excel closes the
        package unless -PassThru, which would end the workbook mid-build.  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Columns,
        $Rows
    )
    $ws = Add-Worksheet -ExcelPackage $Package -WorksheetName $Name
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        $ws.Cells[1, ($c + 1)].Value = $Columns[$c]
        $ws.Cells[1, ($c + 1)].Style.Font.Bold = $true
    }
    $r = 2
    foreach ($row in @($Rows)) {
        for ($c = 0; $c -lt $Columns.Count; $c++) {
            $value = $row.($Columns[$c])
            if ($null -ne $value) { $ws.Cells[$r, ($c + 1)].Value = "$value" }
        }
        $r++
    }
    $ws.View.FreezePanes(2, 1)
    $ws.Cells.AutoFitColumns()
}

function Get-RotaStaffRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    foreach ($p in $Config.staff) {
        $office = Get-RotaProperty -Object $p -Name 'officeLunch'
        $overrides = Get-RotaProperty -Object $p -Name 'startTimeOverrides'
        [pscustomobject]@{
            Name               = $p.name
            Contract           = $p.contract
            Mode               = $p.mode
            Responsable        = $p.IsResponsable
            Temporary          = [bool](Get-RotaProperty -Object $p -Name 'temporary' -Default $false)
            CycleWeeks         = Get-RotaProperty -Object $p -Name 'cycleWeeks' -Default $Config.meta.cycleWeeks
            ConsecutiveDaysOff = Get-RotaProperty -Object $p -Name 'consecutiveDaysOff' -Default ''
            Colour             = Get-RotaProperty -Object $p -Name 'colour' -Default ''
            DinnerStart        = $(if ($null -ne $overrides) { Get-RotaProperty -Object $overrides -Name 'Dinner' -Default '' } else { '' })
            OfficeLunchDays    = $(if ($null -ne $office) { @($office.candidateDays) -join ', ' } else { '' })
        }
    }
}

function Get-RotaCriteriaRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    foreach ($p in $Config.staff) {
        if (-not $p.IsSolved) { continue }
        $weeks = Get-RotaProperty -Object $p -Name 'weeks'
        if ($null -eq $weeks) { continue }
        foreach ($prop in ($weeks.PSObject.Properties | Sort-Object Name)) {
            $spec = $prop.Value
            [pscustomobject]@{
                Name      = $p.name
                Week      = $prop.Name
                Doubles   = [bool]$spec.doubles
                Shifts    = $spec.shifts
                MaxShifts = Get-RotaProperty -Object $spec -Name 'maxShifts' -Default ''
                Weekend   = [bool]$spec.weekend
                Lunch     = $spec.lunch
                Dinner    = $spec.dinner
            }
        }
    }
}

function Get-RotaCoverageRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    [pscustomobject]@{ Setting = 'requiredPerService'; Value = $Config.coverage.requiredPerService }
    [pscustomobject]@{ Setting = 'cycleWeeks'; Value = $Config.meta.cycleWeeks }
    [pscustomobject]@{ Setting = 'rosterName'; Value = $Config.meta.name }
    [pscustomobject]@{ Setting = 'lunchStart'; Value = $Config.startTimes.Lunch }
    [pscustomobject]@{ Setting = 'dinnerStart'; Value = $Config.startTimes.Dinner }
    [pscustomobject]@{ Setting = 'weekendDays'; Value = (@($Config.weekendDays) -join ', ') }
    foreach ($c in @($Config.coverage.closed)) {
        if ($null -ne $c) { [pscustomobject]@{ Setting = 'closed'; Value = "$($c.day)|$($c.slot)" } }
    }
}

function Get-RotaSettingRows {
    <#  Flattens a settings object to key/value, skipping the _note keys used for comments.  #>
    [CmdletBinding()]
    param($Object)
    if ($null -eq $Object) { return }
    foreach ($prop in $Object.PSObject.Properties) {
        if ($prop.Name.StartsWith('_')) { continue }
        [pscustomobject]@{ Setting = $prop.Name; Value = $prop.Value }
    }
}

function Write-RotaFixedGridSheet {
    <#  The fixed rota as a grid: one row per fixed person, one column per day and service.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)]$Config)

    $ws = Add-Worksheet -ExcelPackage $Package -WorksheetName 'FixedGrid'
    $ws.Cells[1, 1].Value = 'Name'
    $ws.Cells[1, 1].Style.Font.Bold = $true

    $col = 2
    $headers = @{}
    foreach ($day in $Config.days) {
        foreach ($slot in $Config.slots) {
            $ws.Cells[1, $col].Value = "$day $slot"
            $ws.Cells[1, $col].Style.Font.Bold = $true
            $headers["$day|$slot"] = $col
            $col++
        }
    }

    $r = 2
    foreach ($p in $Config.staff) {
        if ($p.IsSolved) { continue }
        $ws.Cells[$r, 1].Value = $p.name
        foreach ($day in $p.FixedByDay.Keys) {
            foreach ($slot in $p.FixedByDay[$day]) {
                $ws.Cells[$r, $headers["$day|$slot"]].Value = 'X'
            }
        }
        $r++
    }
    $ws.View.FreezePanes(2, 2)
    $ws.Cells.AutoFitColumns()
}

function Import-RotaConfigExcel {
    <#
    .SYNOPSIS
        Build a rota config from a criteria workbook.
    .DESCRIPTION
        The workbook is authoritative: edit shift counts, days off, eligibility and the fixed
        grid there and re-run. Returns the same shape as Import-RotaConfig, validated the same
        way, so nothing downstream can tell the difference.
    .PARAMETER Path
        Path to a workbook produced by Export-RotaConfigExcel.
    .PARAMETER SkipValidation
        Load without validating. For tests that build deliberately broken workbooks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$SkipValidation
    )
    Assert-RotaExcelModule
    if (-not (Test-Path -LiteralPath $Path)) { throw "Rota criteria workbook not found: $Path" }

    $staffRows = @(Import-Excel -Path $Path -WorksheetName 'Staff')
    $criteria = @(Import-Excel -Path $Path -WorksheetName 'Criteria')
    $grid = @(Import-Excel -Path $Path -WorksheetName 'FixedGrid')
    $coverage = @(Import-Excel -Path $Path -WorksheetName 'Coverage')
    $rules = @(Import-Excel -Path $Path -WorksheetName 'Rules')
    $weights = @(Import-Excel -Path $Path -WorksheetName 'Weights')
    $solver = @(Import-Excel -Path $Path -WorksheetName 'Solver')

    $settings = @{}
    foreach ($row in $coverage) {
        if ($row.Setting -eq 'closed') { continue }
        $settings[$row.Setting] = $row.Value
    }
    $closed = foreach ($row in ($coverage | Where-Object Setting -eq 'closed')) {
        $parts = "$($row.Value)".Split('|')
        [pscustomobject]@{ day = $parts[0]; slot = $parts[1] }
    }

    $days = @('Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche')
    $cycleWeeks = [int](if ($settings.ContainsKey('cycleWeeks')) { $settings['cycleWeeks'] } else { 2 })

    # Criteria rows are keyed by person and week; group them before building each person.
    $byPerson = @{}
    foreach ($row in $criteria) {
        if ([string]::IsNullOrWhiteSpace($row.Name)) { continue }
        if (-not $byPerson.ContainsKey($row.Name)) { $byPerson[$row.Name] = @{} }
        $spec = [ordered]@{
            doubles = ConvertTo-RotaBool $row.Doubles
            shifts  = [int]$row.Shifts
            weekend = ConvertTo-RotaBool $row.Weekend
            lunch   = "$($row.Lunch)".Trim().ToUpper()
            dinner  = "$($row.Dinner)".Trim().ToUpper()
        }
        if (-not [string]::IsNullOrWhiteSpace($row.MaxShifts)) { $spec['maxShifts'] = [int]$row.MaxShifts }
        $byPerson[$row.Name]["$($row.Week)"] = [pscustomobject]$spec
    }

    # The fixed grid uses one column per "<Day> <Slot>"; an X means that shift is worked.
    $fixedByPerson = @{}
    foreach ($row in $grid) {
        if ([string]::IsNullOrWhiteSpace($row.Name)) { continue }
        $fixed = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Name -eq 'Name' -or [string]::IsNullOrWhiteSpace($prop.Value)) { continue }
            $parts = $prop.Name.Split(' ')
            if ($parts.Count -ne 2) { continue }
            $day = $parts[0]; $slot = $parts[1]
            if (-not $fixed.Contains($day)) { $fixed[$day] = @() }
            $fixed[$day] += $slot
        }
        $fixedByPerson[$row.Name] = [pscustomobject]$fixed
    }

    $staff = foreach ($row in $staffRows) {
        if ([string]::IsNullOrWhiteSpace($row.Name)) { continue }
        $person = [ordered]@{
            name        = "$($row.Name)".Trim()
            contract    = "$($row.Contract)"
            mode        = "$($row.Mode)".Trim().ToLower()
            responsable = ConvertTo-RotaBool $row.Responsable
        }
        if (ConvertTo-RotaBool $row.Temporary) { $person['temporary'] = $true }
        if (-not [string]::IsNullOrWhiteSpace($row.Colour)) { $person['colour'] = "$($row.Colour)" }
        if (-not [string]::IsNullOrWhiteSpace($row.CycleWeeks)) { $person['cycleWeeks'] = [int]$row.CycleWeeks }
        if (-not [string]::IsNullOrWhiteSpace($row.ConsecutiveDaysOff)) { $person['consecutiveDaysOff'] = [double]$row.ConsecutiveDaysOff }
        if (-not [string]::IsNullOrWhiteSpace($row.DinnerStart)) {
            $person['startTimeOverrides'] = [pscustomobject]@{ Dinner = "$($row.DinnerStart)" }
        }
        if (-not [string]::IsNullOrWhiteSpace($row.OfficeLunchDays)) {
            $person['officeLunch'] = [pscustomobject]@{
                count = 1; slot = 'Lunch'
                candidateDays = @("$($row.OfficeLunchDays)".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
        if ($fixedByPerson.ContainsKey($person.name)) { $person['fixed'] = $fixedByPerson[$person.name] }
        if ($byPerson.ContainsKey($person.name)) { $person['weeks'] = [pscustomobject]$byPerson[$person.name] }
        [pscustomobject]$person
    }

    $config = [pscustomobject]@{
        meta        = [pscustomobject]@{
            name       = $(if ($settings.ContainsKey('rosterName')) { $settings['rosterName'] } else { 'Roster' })
            cycleWeeks = $cycleWeeks
            source     = $Path
        }
        days        = $days
        weekendDays = @($(if ($settings.ContainsKey('weekendDays')) { "$($settings['weekendDays'])".Split(',') | ForEach-Object { $_.Trim() } } else { @('Samedi', 'Dimanche') }))
        slots       = @('Lunch', 'Dinner')
        startTimes  = [pscustomobject]@{
            Lunch  = $(if ($settings.ContainsKey('lunchStart')) { "$($settings['lunchStart'])" } else { '10H' })
            Dinner = $(if ($settings.ContainsKey('dinnerStart')) { "$($settings['dinnerStart'])" } else { '18H' })
        }
        coverage    = [pscustomobject]@{
            requiredPerService = [int](if ($settings.ContainsKey('requiredPerService')) { $settings['requiredPerService'] } else { 3 })
            closed             = @($closed)
        }
        solver      = ConvertTo-RotaSettingsObject -Rows $solver
        weights     = ConvertTo-RotaSettingsObject -Rows $weights
        rules       = ConvertTo-RotaSettingsObject -Rows $rules
        staff       = @($staff)
    }

    $config = ConvertTo-RotaNormalisedConfig -Config $config
    if (-not $SkipValidation) {
        $problems = @(Test-RotaConfig -Config $config)
        if ($problems.Count -gt 0) {
            throw ("Invalid rota criteria in '$Path':`n  - " + ($problems -join "`n  - "))
        }
    }
    $config
}

function ConvertTo-RotaSettingsObject {
    <#  Key/value rows back into an object, restoring numbers and booleans from their text.  #>
    [CmdletBinding()]
    param($Rows)
    $obj = [ordered]@{}
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or [string]::IsNullOrWhiteSpace($row.Setting)) { continue }
        $raw = "$($row.Value)".Trim()
        $value = switch -Regex ($raw) {
            '^(?i:true|false)$' { [bool]::Parse($raw); break }
            '^-?\d+$' { [int]$raw; break }
            '^-?\d*\.\d+$' { [double]$raw; break }
            default { $raw }
        }
        $obj[$row.Setting] = $value
    }
    [pscustomobject]$obj
}

