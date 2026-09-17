# Export.ps1 -- write the rota to Excel in the shape of the original sheet.
#
# The layout deliberately mirrors the source spreadsheet: merged day headers, two columns
# per day (lunch and dinner), one row per person, per-person fill colours, and the
# FIXED/CHANGEABLE marker on the right. Anyone who reads the current rota should be able to
# read this one without being told how.

Set-StrictMode -Version Latest

function Assert-RotaExcelModule {
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw "The ImportExcel module is required for Excel output. Install it with: Install-Module ImportExcel -Scope CurrentUser"
    }
    Import-Module ImportExcel -ErrorAction Stop
}

function Export-RotaExcel {
    <#
    .SYNOPSIS
        Write a solved rota to an .xlsx workbook.
    .DESCRIPTION
        Sheet 1 "Rota" reproduces the source grid. Sheet 2 "Coverage" lists every service
        with its staffing and shortfall. Sheet 3 "Report" carries per-person totals and the
        full violation list, so the caveats travel with the schedule rather than being lost
        in a terminal somewhere.
    .PARAMETER Path
        Destination .xlsx. Overwritten if it exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)]$Violations,
        [Parameter(Mandatory)][string]$Path
    )
    Assert-RotaExcelModule
    $config = $Schedule.Config

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $package = Open-ExcelPackage -Path $Path -Create
    try {
        Write-RotaGridSheet -Package $package -Schedule $Schedule
        Write-RotaCoverageSheet -Package $package -Schedule $Schedule
        Write-RotaReportSheet -Package $package -Schedule $Schedule -Violations $Violations
        Close-ExcelPackage -ExcelPackage $package
    }
    catch {
        Close-ExcelPackage -ExcelPackage $package -NoSave
        throw
    }
    $Path
}

function Write-RotaGridSheet {
    <#  The main grid: two columns per day, one block per cycle week.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)]$Schedule)

    $config = $Schedule.Config
    $ws = Add-Worksheet -ExcelPackage $Package -WorksheetName 'Rota'
    $dayCount = $config.days.Count
    $row = 1

    for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
        # Day headers, each merged across its lunch and dinner columns.
        $ws.Cells[$row, 1].Value = "WEEK $w"
        $ws.Cells[$row, 1].Style.Font.Bold = $true
        # Day header over each lunch/dinner column pair. Deliberately not a merged cell:
        # EPPlus merging does not bind reliably through PowerShell, and a merged header buys
        # nothing but looks -- the pair is already obvious from the LUNCH/DINNER subheading.
        for ($d = 0; $d -lt $dayCount; $d++) {
            $c1 = 3 + $d * 2
            $cell = $ws.Cells[$row, $c1]
            $cell.Value = $config.days[$d].ToUpper()
            $cell.Style.Font.Bold = $true
            $cell.Style.HorizontalAlignment = 'Center'
        }
        # Note the parentheses on every computed index: inside [ ], PowerShell binds the
        # comma tighter than arithmetic, so Cells[$sub, $c1 + 1] would become ($sub, $c1) + 1
        # -- a three-element array, and a null cell.
        $sub = $row + 1
        $typeCol = 3 + $dayCount * 2
        for ($d = 0; $d -lt $dayCount; $d++) {
            $c1 = 3 + $d * 2
            $ws.Cells[$sub, $c1].Value = 'LUNCH'
            $ws.Cells[$sub, ($c1 + 1)].Value = 'DINNER'
            $ws.Cells[$sub, $c1].Style.Font.Italic = $true
            $ws.Cells[$sub, ($c1 + 1)].Style.Font.Italic = $true
        }
        $ws.Cells[$row, $typeCol].Value = 'TYPE'
        $ws.Cells[$row, $typeCol].Style.Font.Bold = $true
        $row += 2

        foreach ($p in $config.staff) {
            $mask = $Schedule.Masks["$($p.name)|$w"]
            $ws.Cells[$row, 1].Value = $p.name.ToUpper()
            $ws.Cells[$row, 2].Value = $p.contract
            $ws.Cells[$row, 1].Style.Font.Bold = $true

            $colour = Get-RotaProperty -Object $p -Name 'colour'
            foreach ($col in @(1, 2)) { Set-RotaCellFill -Cell $ws.Cells[$row, $col] -Colour $colour }

            for ($d = 0; $d -lt $dayCount; $d++) {
                foreach ($slot in @('Lunch', 'Dinner')) {
                    $col = 3 + $d * 2 + $(if ($slot -eq 'Lunch') { 0 } else { 1 })
                    $cell = $ws.Cells[$row, $col]
                    $cell.Style.Border.BorderAround('Thin')
                    $cell.Style.HorizontalAlignment = 'Center'
                    if ($mask -band (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot))) {
                        $text = Get-RotaStartTime -Config $config -Person $p -Slot $slot
                        # Mark the office lunch so the extra head on that service is obvious.
                        if ($slot -eq 'Lunch' -and $Schedule.OfficeLunch["$($p.name)|$w"] -eq $config.days[$d]) {
                            $text = "$text (OFFICE)"
                        }
                        $cell.Value = $text
                        Set-RotaCellFill -Cell $cell -Colour $colour
                    }
                }
            }
            $ws.Cells[$row, $typeCol].Value = $(if ($p.IsSolved) { 'CHANGEABLE' } else { 'FIXED' })
            $row++
        }
        $row++
    }

    $ws.Cells[$row, 1].Value = 'Generated by RacinesRota. Cells show the start time; CLS = until close. A person with both columns filled on one day is working a double.'
    $ws.Cells.AutoFitColumns()
}

function ConvertTo-RotaExcelColumn {
    <#
    .SYNOPSIS
        Column number to spreadsheet letters: 1 -> A, 27 -> AA.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Index)
    $name = ''
    while ($Index -gt 0) {
        $rem = ($Index - 1) % 26
        $name = [char](65 + $rem) + $name
        $Index = [int][math]::Floor(($Index - 1) / 26)
    }
    $name
}

function Set-RotaCellFill {
    <#  Solid fill from a #RRGGBB string; silently does nothing when no colour is set.  #>
    [CmdletBinding()]
    param($Cell, $Colour)
    if ([string]::IsNullOrWhiteSpace($Colour)) { return }
    $Cell.Style.Fill.PatternType = 'Solid'
    $Cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($Colour))
}

function Write-RotaCoverageSheet {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)]$Schedule)

    # Written cell by cell rather than via Export-Excel, which closes the package unless
    # -PassThru is used and would end the workbook before the report sheet is added.
    $rows = @(Get-RotaCoverageReport -Schedule $Schedule)
    $ws = Add-Worksheet -ExcelPackage $Package -WorksheetName 'Coverage'
    $headers = @($rows[0].PSObject.Properties.Name)

    for ($c = 0; $c -lt $headers.Count; $c++) {
        $ws.Cells[1, ($c + 1)].Value = $headers[$c]
        $ws.Cells[1, ($c + 1)].Style.Font.Bold = $true
    }

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $i + 2
        for ($c = 0; $c -lt $headers.Count; $c++) {
            $ws.Cells[$r, ($c + 1)].Value = $rows[$i].($headers[$c])
        }
        # Flag anything not exactly staffed, so a short service cannot be missed at a glance.
        if ($rows[$i].Delta -ne 0) {
            $colour = if ($rows[$i].Delta -lt 0) { '#F8CBAD' } else { '#FFE699' }
            for ($c = 1; $c -le $headers.Count; $c++) { Set-RotaCellFill -Cell $ws.Cells[$r, $c] -Colour $colour }
        }
    }
    $ws.View.FreezePanes(2, 1)
    $ws.Cells.AutoFitColumns()
}

function Write-RotaReportSheet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)]$Violations
    )
    $ws = Add-Worksheet -ExcelPackage $Package -WorksheetName 'Report'
    $row = 1

    $ws.Cells[$row, 1].Value = 'SUMMARY'; $ws.Cells[$row, 1].Style.Font.Bold = $true; $row++
    $summary = Get-RotaSummary -Schedule $Schedule -Violations $Violations
    foreach ($prop in $summary.PSObject.Properties) {
        $ws.Cells[$row, 1].Value = $prop.Name
        $ws.Cells[$row, 2].Value = $prop.Value
        $row++
    }
    $row++

    $ws.Cells[$row, 1].Value = 'PEOPLE'; $ws.Cells[$row, 1].Style.Font.Bold = $true; $row++
    $headers = @('Person', 'Week', 'Mode', 'Shifts', 'Target', 'DaysWorked', 'Doubles', 'Weekend')
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $ws.Cells[$row, ($i + 1)].Value = $headers[$i]
        $ws.Cells[$row, ($i + 1)].Style.Font.Bold = $true
    }
    $row++
    foreach ($p in (Get-RotaPersonReport -Schedule $Schedule)) {
        $ws.Cells[$row, 1].Value = $p.Person
        $ws.Cells[$row, 2].Value = $(if ($p.Week -eq 0) { 'cycle' } else { "W$($p.Week)" })
        $ws.Cells[$row, 3].Value = $p.Mode
        $ws.Cells[$row, 4].Value = $p.Shifts
        $ws.Cells[$row, 5].Value = $p.Target
        $ws.Cells[$row, 6].Value = $p.DaysWorked
        $ws.Cells[$row, 7].Value = $p.Doubles
        $ws.Cells[$row, 8].Value = "$($p.Weekend)"
        $row++
    }
    $row++

    foreach ($severity in @('Hard', 'Soft')) {
        $list = @($Violations | Where-Object Severity -eq $severity | Sort-Object Id, Week, Day)
        $title = if ($severity -eq 'Hard') { 'HARD VIOLATIONS' } else { 'PREFERENCES NOT MET' }
        $ws.Cells[$row, 1].Value = "$title ($($list.Count))"
        $ws.Cells[$row, 1].Style.Font.Bold = $true
        $row++
        if ($list.Count -eq 0) {
            $ws.Cells[$row, 1].Value = 'none'
            $row++
        }
        else {
            foreach ($v in $list) {
                $ws.Cells[$row, 1].Value = $v.Id
                $ws.Cells[$row, 2].Value = $v.Message
                $ws.Cells[$row, 3].Value = $v.Cost
                $row++
            }
        }
        $row++
    }
    $ws.Cells.AutoFitColumns()
}
