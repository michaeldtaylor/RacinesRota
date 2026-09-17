# Report.ps1 -- turn a schedule into something a human can check.
#
# The engine is only useful if you can see what it decided and, just as importantly, what
# it could not do. Every report here is built from the schedule itself rather than from
# anything the solver remembers, so a report cannot flatter a schedule it did not produce.

Set-StrictMode -Version Latest

function Get-RotaCoverageReport {
    <#
    .SYNOPSIS
        Per-service staffing: who is on, how many, and the shortfall against requirement.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedule)

    foreach ($s in $Schedule.Services) {
        $onFloor = Get-RotaCoverage -Schedule $Schedule -Service $s
        $office = @($Schedule.Assignments[$s.Index] | Where-Object { $onFloor -notcontains $_ })
        $resp = @($onFloor | Where-Object { $Schedule.Config.Responsables -contains $_ })
        [pscustomobject]@{
            Week        = $s.Week
            Day         = $s.Day
            Slot        = $s.Slot
            Required    = $s.Required
            OnFloor     = $onFloor.Count
            Delta       = $onFloor.Count - $s.Required
            Responsable = $resp -join ', '
            Staff       = ($onFloor | Sort-Object) -join ', '
            InOffice    = $office -join ', '
        }
    }
}

function Get-RotaPersonReport {
    <#
    .SYNOPSIS
        Per-person totals against contract: shifts, doubles, weekends and days off.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedule)

    $config = $Schedule.Config
    foreach ($p in $config.staff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $mask = $Schedule.Masks["$($p.name)|$w"]
            $doubles = 0; $weekend = 0; $daysWorked = 0
            for ($d = 0; $d -lt $config.days.Count; $d++) {
                $load = Get-RotaDayLoad -Mask $mask -DayIndex $d
                if ($load -gt 0) { $daysWorked++ }
                if ($load -eq 2) { $doubles++ }
                if ($config.WeekendDayIndexes -contains $d) { $weekend += $load }
            }
            $target = if ($p.IsSolved) { [int]$p.WeekSpec[$w].shifts } else { $null }
            [pscustomobject]@{
                Person     = $p.name
                Week       = $w
                Mode       = $p.mode
                Shifts     = Get-RotaMaskPopCount -Mask $mask
                Target     = $target
                DaysWorked = $daysWorked
                Doubles    = $doubles
                Weekend    = $weekend
            }
        }
    }

    # Days off run across the cycle, so it is reported once per person rather than per week.
    foreach ($p in $config.staff) {
        $loads = Get-RotaCycleDayLoads -Schedule $Schedule -Person $p.name
        [pscustomobject]@{
            Person     = $p.name
            Week       = 0
            Mode       = $p.mode
            Shifts     = ($loads | Measure-Object -Sum).Sum
            Target     = $null
            DaysWorked = @($loads | Where-Object { $_ -gt 0 }).Count
            Doubles    = @($loads | Where-Object { $_ -eq 2 }).Count
            Weekend    = "longest days off run: $(Get-RotaLongestDaysOffRun -DayLoads $loads)"
        }
    }
}

function Format-RotaGrid {
    <#
    .SYNOPSIS
        The schedule as the text equivalent of the source spreadsheet.
    .DESCRIPTION
        One row per person per cycle week, one column pair per day, so it can be eyeballed
        against the original sheet without opening Excel.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedule)

    $config = $Schedule.Config
    $lines = [System.Collections.Generic.List[string]]::new()

    # Width the day columns to the widest cell any person actually produces, so a double
    # never runs into the next day.
    $width = 8
    foreach ($p in $config.staff) {
        foreach ($slot in @('Lunch', 'Dinner')) {
            $w = (Get-RotaStartTime -Config $config -Person $p -Slot $slot).Length
            if (($w * 2 + 1) -gt $width) { $width = $w * 2 + 1 }
        }
    }
    $width += 3   # room for the office marker and a gap

    $header = "{0,-12} {1,-3} " -f 'STAFF', 'WK'
    foreach ($day in $config.days) { $header += "{0,-$width}" -f $day.ToUpper() }
    $lines.Add($header)
    $lines.Add('-' * $header.Length)

    foreach ($p in $config.staff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $mask = $Schedule.Masks["$($p.name)|$w"]
            $row = "{0,-12} {1,-3} " -f $p.name, "W$w"
            for ($d = 0; $d -lt $config.days.Count; $d++) {
                $cell = @()
                foreach ($slot in @('Lunch', 'Dinner')) {
                    if ($mask -band (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot))) {
                        $cell += Get-RotaStartTime -Config $config -Person $p -Slot $slot
                    }
                }
                $text = if (@($cell).Count -eq 0) { '.' } else { $cell -join '+' }
                if ($Schedule.OfficeLunch["$($p.name)|$w"] -eq $config.days[$d]) { $text += '*' }
                $row += "{0,-$width}" -f $text
            }
            $lines.Add($row.TrimEnd())
        }
    }
    $lines.Add('')
    $lines.Add('* = office lunch. Still counts towards the three, as they can step onto the floor.')
    $lines -join "`n"
}

function Get-RotaStartTime {
    <#
    .SYNOPSIS
        The start time shown in a cell, honouring any per-person override.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Person,
        [Parameter(Mandatory)][string]$Slot
    )
    $overrides = Get-RotaProperty -Object $Person -Name 'startTimeOverrides'
    if ($null -ne $overrides) {
        $o = Get-RotaProperty -Object $overrides -Name $Slot
        if ($null -ne $o) { return "$o-CLS" }
    }
    "$($Config.startTimes.$Slot)-CLS"
}

function Get-RotaSummary {
    <#
    .SYNOPSIS
        The headline: is this schedule clean, and if not, exactly how is it not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)]$Violations
    )
    $hard = @($Violations | Where-Object Severity -eq 'Hard')
    $soft = @($Violations | Where-Object Severity -eq 'Soft')
    $coverage = @(Get-RotaCoverageReport -Schedule $Schedule)

    [pscustomobject]@{
        Services          = $coverage.Count
        FullyStaffed      = @($coverage | Where-Object Delta -eq 0).Count
        Understaffed      = @($coverage | Where-Object Delta -lt 0).Count
        Overstaffed       = @($coverage | Where-Object Delta -gt 0).Count
        MissingResponsable = @($Violations | Where-Object Id -eq 'H2-Responsable').Count
        HardViolations    = $hard.Count
        SoftViolations    = $soft.Count
        Score             = ($Violations | Measure-Object -Property Cost -Sum).Sum
    }
}

function Get-RotaTempCoverReport {
    <#
    .SYNOPSIS
        Exactly where an extra body is needed, and how many.
    .DESCRIPTION
        When the contracted staff cannot fill every service, this is the list to hire against:
        one row per short service, with the shift times a temp would be asked to work.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedule)

    $config = $Schedule.Config
    foreach ($s in $Schedule.Services) {
        if (-not $s.Open) { continue }
        $have = (Get-RotaCoverage -Schedule $Schedule -Service $s).Count
        if ($have -ge $s.Required) { continue }
        [pscustomobject]@{
            Week        = $s.Week
            Day         = $s.Day
            Slot        = $s.Slot
            Starts      = "$($config.startTimes.($s.Slot))-CLS"
            PeopleShort = $s.Required - $have
            Rostered    = ($Schedule.Assignments[$s.Index] | Sort-Object) -join ', '
        }
    }
}

function Get-RotaTemporaryExposureReport {
    <#
    .SYNOPSIS
        Every service that currently depends on someone temporary.
    .DESCRIPTION
        Cover staff make a rota look healthier than it is. This lists exactly which services
        would fall short the day they leave, so the schedule is never read as more robust
        than it actually is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedule)

    $config = $Schedule.Config
    $temps = @($config.staff | Where-Object { Get-RotaProperty -Object $_ -Name 'temporary' -Default $false } | ForEach-Object name)
    if ($temps.Count -eq 0) { return }

    foreach ($s in $Schedule.Services) {
        if (-not $s.Open) { continue }
        $staff = @($Schedule.Assignments[$s.Index])
        $onTemp = @($staff | Where-Object { $temps -contains $_ })
        if ($onTemp.Count -eq 0) { continue }
        [pscustomobject]@{
            Week          = $s.Week
            Day           = $s.Day
            Slot          = $s.Slot
            Starts        = "$($config.startTimes.($s.Slot))-CLS"
            CoveredBy     = $onTemp -join ', '
            WithoutThem   = $staff.Count - $onTemp.Count
            Required      = $s.Required
            ShortIfTheyGo = $s.Required - ($staff.Count - $onTemp.Count)
        }
    }
}

function Format-RotaReport {
    <#
    .SYNOPSIS
        The full human-readable report: grid, coverage, people, and what went wrong.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)]$Violations
    )
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('=== ROTA ===')
    $out.Add((Format-RotaGrid -Schedule $Schedule))
    $out.Add('')
    $out.Add('=== SUMMARY ===')
    $out.Add((Get-RotaSummary -Schedule $Schedule -Violations $Violations | Format-List | Out-String).Trim())
    $out.Add('')

    $temp = @(Get-RotaTempCoverReport -Schedule $Schedule)
    if ($temp.Count -gt 0) {
        $short = ($temp | Measure-Object -Property PeopleShort -Sum).Sum
        $out.Add("=== TEMP COVER NEEDED ($short shift(s) across $($temp.Count) service(s)) ===")
        foreach ($t in $temp) {
            $out.Add(("  Week {0}  {1,-10} {2,-7} {3}  need {4} more   (rostered: {5})" -f `
                        $t.Week, $t.Day, $t.Slot, $t.Starts, $t.PeopleShort, $t.Rostered))
        }
        $out.Add('')
    }

    $exposure = @(Get-RotaTemporaryExposureReport -Schedule $Schedule)
    if ($exposure.Count -gt 0) {
        $lost = ($exposure | Measure-Object -Property ShortIfTheyGo -Sum).Sum
        $out.Add("=== LEAVER EXPOSURE ($($exposure.Count) service(s), $lost shift(s) lost when they go) ===")
        $out.Add('  These are covered by temporary staff today and become gaps on their last day.')
        foreach ($e in $exposure) {
            $out.Add(("  Week {0}  {1,-10} {2,-7} {3}  covered by {4}  -> would drop to {5}/{6}" -f `
                        $e.Week, $e.Day, $e.Slot, $e.Starts, $e.CoveredBy, $e.WithoutThem, $e.Required))
        }
        $out.Add('')
    }

    $hard = @($Violations | Where-Object Severity -eq 'Hard')
    $out.Add("=== HARD VIOLATIONS ($($hard.Count)) ===")
    if ($hard.Count -eq 0) { $out.Add('  none -- every stated rule is satisfied.') }
    else { foreach ($v in ($hard | Sort-Object Id, Week, Day)) { $out.Add("  [$($v.Id)] $($v.Message)") } }
    $out.Add('')

    $soft = @($Violations | Where-Object Severity -eq 'Soft')
    $out.Add("=== PREFERENCES NOT MET ($($soft.Count)) ===")
    if ($soft.Count -eq 0) { $out.Add('  none -- every preference is honoured.') }
    else { foreach ($v in ($soft | Sort-Object Id, Person, Week)) { $out.Add("  [$($v.Id)] $($v.Message)") } }

    $out -join "`n"
}

function ConvertTo-RotaObject {
    <#
    .SYNOPSIS
        The canonical serialisable form of a solved rota.
    .DESCRIPTION
        This is what Export-RotaJson writes and what the round-trip test reads back, so it
        must carry everything needed to reconstruct the schedule -- not just a rendering.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)]$Violations,
        $Stats = $null
    )
    $config = $Schedule.Config

    $assignments = foreach ($s in $Schedule.Services) {
        $onFloor = Get-RotaCoverage -Schedule $Schedule -Service $s
        [pscustomobject]@{
            week = $s.Week; day = $s.Day; slot = $s.Slot
            required = $s.Required; onFloor = $onFloor.Count
            staff = @($Schedule.Assignments[$s.Index] | Sort-Object)
            inOffice = @($Schedule.Assignments[$s.Index] | Where-Object { $onFloor -notcontains $_ })
        }
    }

    $people = foreach ($p in $config.staff) {
        $weeks = foreach ($w in 1..$config.meta.cycleWeeks) {
            $mask = $Schedule.Masks["$($p.name)|$w"]
            $days = foreach ($d in 0..($config.days.Count - 1)) {
                $slots = foreach ($slot in @('Lunch', 'Dinner')) {
                    if ($mask -band (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot))) { $slot }
                }
                if (@($slots).Count -gt 0) {
                    [pscustomobject]@{ day = $config.days[$d]; slots = @($slots) }
                }
            }
            [pscustomobject]@{
                week = $w
                mask = $mask
                shifts = Get-RotaMaskPopCount -Mask $mask
                target = $(if ($p.IsSolved) { [int]$p.WeekSpec[$w].shifts } else { $null })
                officeLunch = $Schedule.OfficeLunch["$($p.name)|$w"]
                days = @($days)
            }
        }
        [pscustomobject]@{
            name = $p.name; contract = $p.contract; mode = $p.mode
            responsable = $p.IsResponsable
            longestDaysOffRun = Get-RotaLongestDaysOffRun -DayLoads (Get-RotaCycleDayLoads -Schedule $Schedule -Person $p.name)
            weeks = @($weeks)
        }
    }

    [pscustomobject]@{
        generated   = (Get-Date).ToString('o')
        roster      = $config.meta.name
        cycleWeeks  = $config.meta.cycleWeeks
        summary     = Get-RotaSummary -Schedule $Schedule -Violations $Violations
        stats       = $Stats
        people      = @($people)
        assignments = @($assignments)
        violations  = @($Violations)
    }
}

function Export-RotaJson {
    <#
    .SYNOPSIS
        Write the canonical JSON form of a solved rota.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)]$Violations,
        [Parameter(Mandatory)][string]$Path,
        $Stats = $null
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-RotaObject -Schedule $Schedule -Violations $Violations -Stats $Stats |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}
