# Model.ps1 -- core domain structures and index arithmetic.
#
# A cycle is $CycleWeeks weeks of 7 days, each day holding 2 services (Lunch, Dinner).
# Within a week, a service is addressed by a slot index:
#
#     slotIndex = dayIndex * 2 + (Lunch ? 0 : 1)        0..13
#
# A person's week of work is therefore a 14-bit mask, which is what makes the solver
# fast: coverage arithmetic is bit operations rather than object comparison.
# Across the whole cycle, serviceIndex = (week - 1) * 14 + slotIndex.

Set-StrictMode -Version Latest

$script:SlotsPerDay = 2
$script:SlotsPerWeek = 14

function Get-RotaSlotIndex {
    <#
    .SYNOPSIS
        Week-local slot index (0..13) for a day index and slot name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DayIndex,
        [Parameter(Mandatory)][ValidateSet('Lunch', 'Dinner')][string]$Slot
    )
    $DayIndex * $script:SlotsPerDay + $(if ($Slot -eq 'Lunch') { 0 } else { 1 })
}

function Get-RotaServiceIndex {
    <#
    .SYNOPSIS
        Cycle-wide service index (0..27 for a 2-week cycle).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Week,
        [Parameter(Mandatory)][int]$DayIndex,
        [Parameter(Mandatory)][ValidateSet('Lunch', 'Dinner')][string]$Slot
    )
    ($Week - 1) * $script:SlotsPerWeek + (Get-RotaSlotIndex -DayIndex $DayIndex -Slot $Slot)
}

function ConvertFrom-RotaSlotIndex {
    <#
    .SYNOPSIS
        Inverse of Get-RotaSlotIndex: turns a week-local slot index back into day/slot.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$SlotIndex)
    [pscustomobject]@{
        DayIndex = [int][math]::Floor($SlotIndex / $script:SlotsPerDay)
        Slot     = $(if (($SlotIndex % $script:SlotsPerDay) -eq 0) { 'Lunch' } else { 'Dinner' })
    }
}

function Get-RotaServices {
    <#
    .SYNOPSIS
        Ordered list of every service in the cycle, with its coverage requirement.
    .DESCRIPTION
        Returns one object per (week, day, slot). Closed services carry Open = $false
        and Required = 0 so the rest of the engine can treat them uniformly.

        coverage.requiredPerService is the house default. coverage.overrides raises or lowers
        it for named services, because a Saturday dinner is not a Tuesday lunch and a single
        number for all 28 of them cannot say so. An override names a day and a slot, so it
        applies in every week of the cycle: how busy a service is belongs to the day of the
        week, not to which half of the fortnight you happen to be in.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $closed = @{}
    foreach ($c in @($Config.coverage.closed)) {
        if ($null -ne $c) { $closed["$($c.day)|$($c.slot)"] = $true }
    }

    $override = @{}
    foreach ($o in @(Get-RotaProperty -Object $Config.coverage -Name 'overrides')) {
        if ($null -ne $o) { $override["$($o.day)|$($o.slot)"] = [int]$o.required }
    }

    $services = [System.Collections.Generic.List[object]]::new()
    for ($week = 1; $week -le $Config.meta.cycleWeeks; $week++) {
        for ($d = 0; $d -lt $Config.days.Count; $d++) {
            foreach ($slot in $Config.slots) {
                $day = $Config.days[$d]
                $key = "$day|$slot"
                $isClosed = $closed.ContainsKey($key)
                $required = if ($override.ContainsKey($key)) { $override[$key] } else { [int]$Config.coverage.requiredPerService }
                $services.Add([pscustomobject]@{
                        Index     = Get-RotaServiceIndex -Week $week -DayIndex $d -Slot $slot
                        SlotIndex = Get-RotaSlotIndex -DayIndex $d -Slot $slot
                        Week      = $week
                        DayIndex  = $d
                        Day       = $day
                        Slot      = $slot
                        Open      = -not $isClosed
                        Required  = $(if ($isClosed) { 0 } else { $required })
                        Key       = "W$week|$day|$slot"
                    })
            }
        }
    }
    , $services.ToArray()
}

function New-RotaSchedule {
    <#
    .SYNOPSIS
        An empty schedule: one assignment list per service index, plus per-person masks.
    .DESCRIPTION
        The schedule carries two redundant views of the same data -- Assignments
        (service -> people, for coverage questions) and Masks (person/week -> bitmask,
        for per-person questions). Mutators keep both in step; nothing else writes them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $services = Get-RotaServices -Config $Config
    $assignments = @{}
    foreach ($s in $services) { $assignments[$s.Index] = [System.Collections.Generic.List[string]]::new() }

    $masks = @{}
    foreach ($p in $Config.staff) {
        for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) { $masks["$($p.name)|$w"] = 0 }
    }

    [pscustomobject]@{
        Config      = $Config
        Services    = $services
        Assignments = $assignments
        Masks       = $masks
        OfficeLunch = @{}   # "person|week" -> day name, for Suyeon's rule-17 lunch
    }
}

function Add-RotaAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][string]$Person,
        [Parameter(Mandatory)][int]$Week,
        [Parameter(Mandatory)][int]$DayIndex,
        [Parameter(Mandatory)][ValidateSet('Lunch', 'Dinner')][string]$Slot
    )
    $idx = Get-RotaServiceIndex -Week $Week -DayIndex $DayIndex -Slot $Slot
    if (-not $Schedule.Assignments[$idx].Contains($Person)) {
        $Schedule.Assignments[$idx].Add($Person)
    }
    $bit = 1 -shl (Get-RotaSlotIndex -DayIndex $DayIndex -Slot $Slot)
    $Schedule.Masks["$Person|$Week"] = $Schedule.Masks["$Person|$Week"] -bor $bit
}

function Set-RotaWeekMask {
    <#
    .SYNOPSIS
        Apply a whole week of work for one person from a 14-bit mask.
    .DESCRIPTION
        The solver works in masks, so this is how a chosen week pattern is written back
        into a schedule. Replaces, rather than merges, that person's week.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][string]$Person,
        [Parameter(Mandatory)][int]$Week,
        [Parameter(Mandatory)][int]$Mask
    )
    $old = $Schedule.Masks["$Person|$Week"]
    for ($i = 0; $i -lt $script:SlotsPerWeek; $i++) {
        $idx = ($Week - 1) * $script:SlotsPerWeek + $i
        $wasSet = ($old -band (1 -shl $i)) -ne 0
        $isSet = ($Mask -band (1 -shl $i)) -ne 0
        if ($wasSet -and -not $isSet) { [void]$Schedule.Assignments[$idx].Remove($Person) }
        if ($isSet -and -not $Schedule.Assignments[$idx].Contains($Person)) { $Schedule.Assignments[$idx].Add($Person) }
    }
    $Schedule.Masks["$Person|$Week"] = $Mask
}

function Get-RotaWeekMask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][string]$Person,
        [Parameter(Mandatory)][int]$Week
    )
    $Schedule.Masks["$Person|$Week"]
}

function Get-RotaMaskPopCount {
    <#
    .SYNOPSIS
        Number of set bits -- i.e. shifts worked in a week mask.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Mask)
    $n = 0
    while ($Mask) { $Mask = $Mask -band ($Mask - 1); $n++ }
    $n
}

function Get-RotaDayLoad {
    <#
    .SYNOPSIS
        Shifts worked on one day of a week mask: 0, 1 or 2.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Mask,
        [Parameter(Mandatory)][int]$DayIndex
    )
    $n = 0
    if ($Mask -band (1 -shl ($DayIndex * 2))) { $n++ }
    if ($Mask -band (1 -shl ($DayIndex * 2 + 1))) { $n++ }
    $n
}

function Get-RotaCycleDayLoads {
    <#
    .SYNOPSIS
        Per-day shift counts across the whole cycle, as an array of length 7 * weeks.
    .DESCRIPTION
        This is the input to the consecutive-days-off test, which treats the cycle as a
        ring: the last day wraps round to the first because the template repeats.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][string]$Person
    )
    $weeks = $Schedule.Config.meta.cycleWeeks
    $dayCount = $Schedule.Config.days.Count
    $loads = New-Object int[] ($weeks * $dayCount)
    for ($w = 1; $w -le $weeks; $w++) {
        $mask = $Schedule.Masks["$Person|$w"]
        for ($d = 0; $d -lt $dayCount; $d++) {
            $loads[($w - 1) * $dayCount + $d] = Get-RotaDayLoad -Mask $mask -DayIndex $d
        }
    }
    , $loads
}

function Get-RotaLongestDaysOffRun {
    <#
    .SYNOPSIS
        Longest run of days off on the cycle ring, counting a one-service day as a half.
    .DESCRIPTION
        A fully free day is worth 1.0. A day with exactly one service worked is worth
        0.5, but only when it sits at one end of a run of full days off -- that is how
        Barbara's "3.5 CONSEC" is modelled. Days are a ring because the template repeats,
        so week 2 Dimanche is adjacent to week 1 Lundi.

        Returns 0 when the person never works (a run cannot be bounded on a ring of all
        free days), signalled by returning the ring length.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int[]]$DayLoads)

    $n = $DayLoads.Count
    if (@($DayLoads | Where-Object { $_ -eq 0 }).Count -eq $n) { return [double]$n }

    $best = 0.0
    for ($start = 0; $start -lt $n; $start++) {
        # Only consider runs that actually begin here, so each run is measured once.
        if ($DayLoads[$start] -ne 0) { continue }
        $prev = ($start - 1 + $n) % $n
        if ($DayLoads[$prev] -eq 0) { continue }

        $full = 0
        $i = $start
        while ($full -lt $n -and $DayLoads[$i] -eq 0) {
            $full++
            $i = ($i + 1) % $n
        }

        $value = [double]$full
        # A half day may extend the run at either end.
        if ($DayLoads[$prev] -eq 1) { $value += 0.5 }
        $next = $i
        if ($DayLoads[$next] -eq 1) { $value += 0.5 }

        if ($value -gt $best) { $best = $value }
    }
    $best
}

function Get-RotaDaysOffRunByWeek {
    <#
    .SYNOPSIS
        The best run of days off available to each week, measured on the cycle ring.
    .DESCRIPTION
        "Two days off in a row" is a promise made to someone every week, not once a
        fortnight. A single long block in week 2 must not excuse week 1 having none.

        For each week, this returns the value of the longest run of days off that touches
        that week. Runs are still measured on the ring, so a Saturday-Sunday-Monday block
        straddling the week boundary counts for both weeks it falls in -- which is the whole
        point of a rota that repeats.

        Each week reports two numbers, and BOTH matter:

          FullDays - consecutive days with neither service worked.
          Value    - FullDays plus 0.5 when a day at either end of the run has exactly one
                     service worked.

        A half day may only ever supply the ".5" in a requirement like Barbara's 3.5. It can
        never stand in for a whole day off, which is why callers must check FullDays against
        the whole number of the requirement as well as Value against the requirement itself.
        Without that, "lunch Monday, Tuesday off, lunch Wednesday" would score 2.0 and pass a
        two-days-off-in-a-row rule while giving nobody two days off in a row.
    .OUTPUTS
        One object per week with FullDays (int) and Value (double).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int[]]$DayLoads,
        [Parameter(Mandatory)][int]$DaysPerWeek
    )
    # Written with flat arrays and integer division rather than pipelines and hashtables:
    # the solver calls this on every candidate schedule, and the allocation showed up as
    # most of the solve time.
    $n = $DayLoads.Count
    $weeks = [int][math]::Floor($n / $DaysPerWeek)
    $bestFull = New-Object int[] $weeks
    $bestValue = New-Object double[] $weeks
    $touched = New-Object bool[] $weeks

    $anyWorked = $false
    for ($i = 0; $i -lt $n; $i++) { if ($DayLoads[$i] -ne 0) { $anyWorked = $true; break } }
    if (-not $anyWorked) {
        for ($w = 0; $w -lt $weeks; $w++) { $bestFull[$w] = $n; $bestValue[$w] = [double]$n }
    }
    else {
        for ($start = 0; $start -lt $n; $start++) {
            if ($DayLoads[$start] -ne 0) { continue }
            $prev = ($start - 1 + $n) % $n
            if ($DayLoads[$prev] -eq 0) { continue }   # measure each run once, from its start

            for ($w = 0; $w -lt $weeks; $w++) { $touched[$w] = $false }
            $full = 0
            $i = $start
            while ($full -lt $n -and $DayLoads[$i] -eq 0) {
                $touched[[int][math]::Floor($i / $DaysPerWeek)] = $true
                $full++
                $i = ($i + 1) % $n
            }

            # At most one half day counts, and only as the fraction of a requirement. It adds
            # value but deliberately does NOT make the run belong to its week: a run of whole
            # days off sitting entirely in week 2 must not satisfy week 1 merely because the
            # part-worked day on the boundary happens to fall on a Sunday.
            $value = [double]$full
            if ($DayLoads[$prev] -eq 1 -or $DayLoads[$i] -eq 1) { $value += 0.5 }

            for ($w = 0; $w -lt $weeks; $w++) {
                if (-not $touched[$w]) { continue }
                # Rank by whole days first: a longer genuine break always wins.
                if ($full -gt $bestFull[$w] -or ($full -eq $bestFull[$w] -and $value -gt $bestValue[$w])) {
                    $bestFull[$w] = $full
                    $bestValue[$w] = $value
                }
            }
        }
    }

    $out = foreach ($w in 0..($weeks - 1)) {
        [pscustomobject]@{ Week = $w + 1; FullDays = $bestFull[$w]; Value = $bestValue[$w] }
    }
    , @($out)
}

function Test-RotaDaysOffRequirement {
    <#
    .SYNOPSIS
        Does a measured run satisfy a required number of consecutive days off?
    .DESCRIPTION
        The whole-number part must be met by whole days off. Only the fractional ".5" may be
        supplied by an adjacent day with a single service worked. This is the single place
        that decision is made, so the solver and the constraint engine cannot disagree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][double]$Required
    )
    if ($Required -le 0) { return $true }
    ($Run.FullDays -ge [math]::Floor($Required)) -and ($Run.Value -ge $Required)
}

function Get-RotaCoverage {
    <#
    .SYNOPSIS
        People counting towards a service's staffing requirement.
    .DESCRIPTION
        Someone on their office lunch is still in the building and can step onto the floor,
        so by default they count towards the three. Set rules.officeLunchCountsOnFloor to
        false to treat that lunch as genuinely off-service, which makes it need a fourth
        person rostered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)]$Service
    )
    $people = @($Schedule.Assignments[$Service.Index])
    $counts = $true
    if (Test-RotaHasProperty -Object $Schedule.Config.rules -Name 'officeLunchCountsOnFloor') {
        $counts = [bool]$Schedule.Config.rules.officeLunchCountsOnFloor
    }
    if ($counts) { return , @($people) }

    $onFloor = foreach ($p in $people) {
        if ($Schedule.OfficeLunch["$p|$($Service.Week)"] -eq $Service.Day -and $Service.Slot -eq 'Lunch') { continue }
        $p
    }
    , @($onFloor)
}

