# Constraints.ps1 -- one evaluator per rule, registered in a table.
#
# Every evaluator has the same shape: (Schedule) -> violation objects. Hard violations
# mean the schedule breaks a stated rule; soft ones are preferences that were traded
# away. Both carry a Cost, and the solver minimises the weighted total, so the same
# table drives both validation and search. Adding a rule means adding one function and
# one registry entry -- nothing else changes.

Set-StrictMode -Version Latest

function New-RotaViolation {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Hard', 'Soft')][string]$Severity,
        [Parameter(Mandatory)][string]$Message,
        [string]$Person = '',
        [int]$Week = 0,
        [string]$Day = '',
        [string]$Slot = '',
        [double]$Cost = 0
    )
    [pscustomobject]@{
        Id = $Id; Severity = $Severity; Message = $Message
        Person = $Person; Week = $Week; Day = $Day; Slot = $Slot; Cost = $Cost
    }
}

function Get-RotaWeight {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name, [double]$Default = 1)
    $w = Get-RotaProperty -Object $Config.weights -Name $Name -Default $Default
    [double]$w
}

# ---------------------------------------------------------------- hard constraints

function Test-RotaCoverage {
    <#  H1: every open service carries exactly the required number of people on the floor.  #>
    param([Parameter(Mandatory)]$Schedule)
    $weight = Get-RotaWeight -Config $Schedule.Config -Name 'coverageShortfall' -Default 1000
    foreach ($s in $Schedule.Services) {
        if (-not $s.Open) { continue }
        $n = (Get-RotaCoverage -Schedule $Schedule -Service $s).Count
        if ($n -ne $s.Required) {
            $word = if ($n -lt $s.Required) { 'short' } else { 'over' }
            New-RotaViolation -Id 'H1-Coverage' -Severity 'Hard' -Week $s.Week -Day $s.Day -Slot $s.Slot `
                -Message "$($s.Key): $n on the floor, needs $($s.Required) ($word by $([math]::Abs($n - $s.Required)))." `
                -Cost ($weight * [math]::Abs($n - $s.Required))
        }
    }
}

function Test-RotaResponsable {
    <#  H2: at least one responsable on the floor for every open service.  #>
    param([Parameter(Mandatory)]$Schedule)
    if (-not $Schedule.Config.rules.requireResponsablePerService) { return }
    $resp = $Schedule.Config.Responsables
    foreach ($s in $Schedule.Services) {
        if (-not $s.Open) { continue }
        $onFloor = Get-RotaCoverage -Schedule $Schedule -Service $s
        if (-not ($onFloor | Where-Object { $resp -contains $_ })) {
            New-RotaViolation -Id 'H2-Responsable' -Severity 'Hard' -Week $s.Week -Day $s.Day -Slot $s.Slot `
                -Message "$($s.Key): no responsable on the floor." -Cost 100000
        }
    }
}

function Test-RotaFixedAssignments {
    <#  H3: fixed rows are input, not output -- they must appear exactly as configured.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    foreach ($p in $config.FixedStaff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $expected = 0
            foreach ($day in $p.FixedByDay.Keys) {
                foreach ($slot in $p.FixedByDay[$day]) {
                    $expected = $expected -bor (1 -shl (Get-RotaSlotIndex -DayIndex $config.DayIndexOf[$day] -Slot $slot))
                }
            }
            $actual = $Schedule.Masks["$($p.name)|$w"]
            if ($actual -ne $expected) {
                New-RotaViolation -Id 'H3-Fixed' -Severity 'Hard' -Person $p.name -Week $w `
                    -Message "$($p.name) week ${w}: fixed pattern was modified (expected mask $expected, got $actual)." -Cost 100000
            }
        }
    }
}

function Test-RotaShiftCount {
    <#  H4: a solved person never works more than their contracted shifts (hard ceiling).
        Working fewer is allowed but penalised, because the sheet's numbers are targets
        as well as caps and the week-2 surplus has to land somewhere.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    $underWeight = Get-RotaWeight -Config $config -Name 'shiftUnderrun' -Default 200
    $tolerance = [int](Get-RotaProperty -Object $config.solver -Name 'shiftCountTolerance' -Default 0)
    foreach ($p in $config.SolvedStaff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $target = [int]$p.WeekSpec[$w].shifts
            # Cover staff have a target of zero but a ceiling above it: they are there to
            # fill gaps, so working fewer than the ceiling is the desired outcome, not a miss.
            $ceiling = [int](Get-RotaProperty -Object $p.WeekSpec[$w] -Name 'maxShifts' -Default $target)
            $actual = Get-RotaMaskPopCount -Mask $Schedule.Masks["$($p.name)|$w"]
            if ($actual -gt ($ceiling + $tolerance)) {
                New-RotaViolation -Id 'H4-ShiftCeiling' -Severity 'Hard' -Person $p.name -Week $w `
                    -Message "$($p.name) week ${w}: $actual shifts exceeds the ceiling of $ceiling." -Cost 100000
            }
            elseif ($actual -lt $target) {
                # Cost grows with the square of the deficit, so when shifts cannot all be
                # placed the engine spreads the loss (one each) rather than taking the whole
                # shortfall out of a single person's week.
                $deficit = $target - $actual
                New-RotaViolation -Id 'S3-ShiftUnderrun' -Severity 'Soft' -Person $p.name -Week $w `
                    -Message "$($p.name) week ${w}: $actual shifts against a target of $target ($deficit unassigned)." `
                    -Cost ($underWeight * $deficit * $deficit)
            }
        }
    }
}

function Test-RotaDoubles {
    <#  H5: nobody works both services in a day unless their week allows doubles.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    foreach ($p in $config.SolvedStaff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            if ($p.WeekSpec[$w].doubles) { continue }
            $mask = $Schedule.Masks["$($p.name)|$w"]
            for ($d = 0; $d -lt $config.days.Count; $d++) {
                if ((Get-RotaDayLoad -Mask $mask -DayIndex $d) -eq 2) {
                    New-RotaViolation -Id 'H5-Doubles' -Severity 'Hard' -Person $p.name -Week $w -Day $config.days[$d] `
                        -Message "$($p.name) week ${w}: double on $($config.days[$d]) but doubles are not allowed." -Cost 100000
                }
            }
        }
    }
}

function Test-RotaSlotEligibility {
    <#  H6: NO means never that service; OBLIG means every shift is that service.
        PREF is soft and handled by Test-RotaSlotPreference.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    foreach ($p in $config.SolvedStaff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $spec = $p.WeekSpec[$w]
            $mask = $Schedule.Masks["$($p.name)|$w"]
            for ($i = 0; $i -lt 14; $i++) {
                if (-not ($mask -band (1 -shl $i))) { continue }
                $at = ConvertFrom-RotaSlotIndex -SlotIndex $i
                $rule = if ($at.Slot -eq 'Lunch') { $spec.lunch } else { $spec.dinner }
                $other = if ($at.Slot -eq 'Lunch') { $spec.dinner } else { $spec.lunch }
                if ($rule -eq 'NO') {
                    New-RotaViolation -Id 'H6-Eligibility' -Severity 'Hard' -Person $p.name -Week $w `
                        -Day $config.days[$at.DayIndex] -Slot $at.Slot `
                        -Message "$($p.name) week ${w}: assigned $($at.Slot) on $($config.days[$at.DayIndex]) but $($at.Slot) is NO." -Cost 100000
                }
                if ($other -eq 'OBLIG') {
                    New-RotaViolation -Id 'H6-Eligibility' -Severity 'Hard' -Person $p.name -Week $w `
                        -Day $config.days[$at.DayIndex] -Slot $at.Slot `
                        -Message "$($p.name) week ${w}: assigned $($at.Slot) on $($config.days[$at.DayIndex]) but every shift must be the other service." -Cost 100000
                }
            }
        }
    }
}

function Test-RotaWeekendAvailability {
    <#  H7: weekend = false means no Saturday or Sunday work that week.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    foreach ($p in $config.SolvedStaff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            if ($p.WeekSpec[$w].weekend) { continue }
            $mask = $Schedule.Masks["$($p.name)|$w"]
            foreach ($d in $config.WeekendDayIndexes) {
                if ((Get-RotaDayLoad -Mask $mask -DayIndex $d) -gt 0) {
                    New-RotaViolation -Id 'H7-Weekend' -Severity 'Hard' -Person $p.name -Week $w -Day $config.days[$d] `
                        -Message "$($p.name) week ${w}: works $($config.days[$d]) but is unavailable at weekends that week." -Cost 100000
                }
            }
        }
    }
}

function Test-RotaConsecutiveDaysOff {
    <#  H8/H9: each person gets their required run of consecutive days off in EVERY week.
        Runs are measured on the cycle ring, so a block straddling the week boundary counts
        for both weeks it touches -- but one long block in week 2 no longer excuses week 1
        having none. Set rules.daysOffScope to 'cycle' for the looser once-per-fortnight
        reading. The floor in rules.minConsecutiveDaysOffForEveryone covers fixed staff too.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    $floor = [double](Get-RotaProperty -Object $config.rules -Name 'minConsecutiveDaysOffForEveryone' -Default 0)
    $scope = [string](Get-RotaProperty -Object $config.rules -Name 'daysOffScope' -Default 'week')

    foreach ($p in $config.staff) {
        $required = [double](Get-RotaProperty -Object $p -Name 'consecutiveDaysOff' -Default 0)
        $required = [math]::Max($required, $floor)
        if ($required -le 0) { continue }
        $loads = Get-RotaCycleDayLoads -Schedule $Schedule -Person $p.name
        $id = if ($p.IsSolved) { 'H8-DaysOff' } else { 'H9-DaysOffFloor' }

        if ($scope -eq 'cycle') {
            $run = Get-RotaLongestDaysOffRun -DayLoads $loads
            if ($run -lt $required) {
                New-RotaViolation -Id $id -Severity 'Hard' -Person $p.name `
                    -Message "$($p.name): longest run of days off across the cycle is $run, needs $required." -Cost 100000
            }
            continue
        }

        foreach ($run in (Get-RotaDaysOffRunByWeek -DayLoads $loads -DaysPerWeek $config.days.Count)) {
            if (-not (Test-RotaDaysOffRequirement -Run $run -Required $required)) {
                New-RotaViolation -Id $id -Severity 'Hard' -Person $p.name -Week $run.Week `
                    -Message "$($p.name) week $($run.Week): longest run of days off is $($run.FullDays) full day(s) (counts as $($run.Value)), needs $required." -Cost 100000
            }
        }
    }
}

# ---------------------------------------------------------------- soft constraints

function Test-RotaSlotPreference {
    <#  S1: PREF is honoured where it can be.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    $weight = Get-RotaWeight -Config $config -Name 'slotPreference' -Default 10
    foreach ($p in $config.SolvedStaff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $spec = $p.WeekSpec[$w]
            $mask = $Schedule.Masks["$($p.name)|$w"]
            foreach ($slot in @('Lunch', 'Dinner')) {
                $rule = if ($slot -eq 'Lunch') { $spec.dinner } else { $spec.lunch }
                if ($rule -ne 'PREF') { continue }
                # The other service is preferred, so every shift in THIS slot costs.
                $n = 0
                for ($d = 0; $d -lt $config.days.Count; $d++) {
                    $bit = 1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot)
                    if ($mask -band $bit) { $n++ }
                }
                if ($n -gt 0) {
                    $preferred = if ($slot -eq 'Lunch') { 'Dinner' } else { 'Lunch' }
                    New-RotaViolation -Id 'S1-SlotPreference' -Severity 'Soft' -Person $p.name -Week $w -Slot $slot `
                        -Message "$($p.name) week ${w}: $n $slot shift(s) against a preference for $preferred." -Cost ($weight * $n)
                }
            }
        }
    }
}

function Test-RotaIsolatedWorkDays {
    <#  S2: a single working day with days off either side is unpleasant to commute for.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    $weight = Get-RotaWeight -Config $config -Name 'isolatedWorkDay' -Default 5
    foreach ($p in $config.SolvedStaff) {
        $loads = Get-RotaCycleDayLoads -Schedule $Schedule -Person $p.name
        $n = $loads.Count
        for ($i = 0; $i -lt $n; $i++) {
            if ($loads[$i] -eq 0) { continue }
            $prev = $loads[($i - 1 + $n) % $n]
            $next = $loads[($i + 1) % $n]
            if ($prev -eq 0 -and $next -eq 0) {
                $week = [int][math]::Floor($i / $config.days.Count) + 1
                $day = $config.days[$i % $config.days.Count]
                New-RotaViolation -Id 'S2-IsolatedDay' -Severity 'Soft' -Person $p.name -Week $week -Day $day `
                    -Message "$($p.name): $day in week $week is an isolated working day." -Cost $weight
            }
        }
    }
}

function Test-RotaTemporaryStaff {
    <#  S7: every shift covered by temporary staff is a shift the permanent team cannot
        currently fill. It is charged a cost so the engine reaches for cover only where
        nothing else works, and reported so the exposure is visible: when that person
        leaves, these are the shifts that become gaps.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    $weight = Get-RotaWeight -Config $config -Name 'temporaryShift' -Default 300

    foreach ($p in $config.staff) {
        if (-not (Get-RotaProperty -Object $p -Name 'temporary' -Default $false)) { continue }
        $total = 0
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $total += Get-RotaMaskPopCount -Mask $Schedule.Masks["$($p.name)|$w"]
        }
        if ($total -gt 0) {
            New-RotaViolation -Id 'S7-TemporaryCover' -Severity 'Soft' -Person $p.name `
                -Message "$($p.name) is temporary and covers $total shift(s) across the cycle; these become gaps when they leave." `
                -Cost ($weight * $total)
        }
    }
}

function Test-RotaOfficeLunchProtected {
    <#  S6: an office lunch is meant to be admin time. The person can step onto the floor if
        the service is short, but if they are one of the three every single week then the
        admin time is notional -- they are load-bearing, not spare. This is soft: it never
        costs coverage, it just makes the situation visible instead of silently assumed.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    $weight = Get-RotaWeight -Config $config -Name 'adminLunchUnprotected' -Default 25

    foreach ($p in $config.staff) {
        $office = Get-RotaProperty -Object $p -Name 'officeLunch'
        if ($null -eq $office) { continue }
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $day = $Schedule.OfficeLunch["$($p.name)|$w"]
            if (-not $day) { continue }
            $service = $Schedule.Services | Where-Object { $_.Week -eq $w -and $_.Day -eq $day -and $_.Slot -eq $office.slot }
            if (-not $service) { continue }
            $others = @($Schedule.Assignments[$service.Index] | Where-Object { $_ -ne $p.name }).Count
            if ($others -lt $service.Required) {
                New-RotaViolation -Id 'S6-AdminLunchUnprotected' -Severity 'Soft' -Person $p.name -Week $w -Day $day -Slot $office.slot `
                    -Message "$($p.name) week ${w}: admin lunch on $day has only $others other staff against a requirement of $($service.Required), so they are counted as floor cover rather than free to do admin." `
                    -Cost $weight
            }
        }
    }
}

function Test-RotaDaysOffPreference {
    <#  S8: a longer run of days off that someone would like but is not owed.
        consecutiveDaysOff is a promise and breaking it makes a schedule wrong (H8/H9).
        preferredConsecutiveDaysOff is a wish: the engine reaches for it and reports when it
        could not, but never fails a schedule over it and never lets it crowd out a shift.
        Keeping the two apart matters -- writing a wish into the hard field means the solver
        rejects perfectly legal rotas, and the report cannot tell a broken promise from an
        unmet preference.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    $weight = Get-RotaWeight -Config $config -Name 'daysOffPreference' -Default 20
    $scope = [string](Get-RotaProperty -Object $config.rules -Name 'daysOffScope' -Default 'week')

    foreach ($p in $config.staff) {
        $wanted = [double](Get-RotaProperty -Object $p -Name 'preferredConsecutiveDaysOff' -Default 0)
        if ($wanted -le 0) { continue }
        # Only the part above what they are already owed is a preference.
        $required = [math]::Max(
            [double](Get-RotaProperty -Object $p -Name 'consecutiveDaysOff' -Default 0),
            [double](Get-RotaProperty -Object $config.rules -Name 'minConsecutiveDaysOffForEveryone' -Default 0))
        if ($wanted -le $required) { continue }

        $loads = Get-RotaCycleDayLoads -Schedule $Schedule -Person $p.name

        if ($scope -eq 'cycle') {
            $run = Get-RotaLongestDaysOffRun -DayLoads $loads
            if ($run -lt $wanted) {
                New-RotaViolation -Id 'S8-DaysOffPreference' -Severity 'Soft' -Person $p.name `
                    -Message "$($p.name) would prefer $wanted consecutive days off; the longest run across the cycle is $run." `
                    -Cost ($weight * ($wanted - $run))
            }
            continue
        }

        foreach ($run in (Get-RotaDaysOffRunByWeek -DayLoads $loads -DaysPerWeek $config.days.Count)) {
            if (Test-RotaDaysOffRequirement -Run $run -Required $wanted) { continue }
            # Cost the shortfall, so a near miss reads as a near miss.
            $shortfall = [math]::Max(0.5, $wanted - $run.Value)
            New-RotaViolation -Id 'S8-DaysOffPreference' -Severity 'Soft' -Person $p.name -Week $run.Week `
                -Message "$($p.name) week $($run.Week): would prefer $wanted consecutive days off, got $($run.Value) (they are owed $required)." `
                -Cost ($weight * $shortfall)
        }
    }
}

function Test-RotaFairness {
    <#  S5: spread weekend and dinner load evenly across the solved staff.
        Cost is the spread (max - min) rather than a variance, so it reads plainly in
        the report and stays comparable between runs.  #>
    param([Parameter(Mandatory)]$Schedule)
    $config = $Schedule.Config
    if ($config.SolvedStaff.Count -lt 2) { return }

    $weekendW = Get-RotaWeight -Config $config -Name 'weekendFairness' -Default 3
    $dinnerW = Get-RotaWeight -Config $config -Name 'dinnerFairness' -Default 3

    $weekendCount = @{}; $dinnerCount = @{}
    foreach ($p in $config.SolvedStaff) {
        $weekendCount[$p.name] = 0; $dinnerCount[$p.name] = 0
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            $mask = $Schedule.Masks["$($p.name)|$w"]
            for ($d = 0; $d -lt $config.days.Count; $d++) {
                $load = Get-RotaDayLoad -Mask $mask -DayIndex $d
                if ($config.WeekendDayIndexes -contains $d) { $weekendCount[$p.name] += $load }
                if ($mask -band (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot 'Dinner'))) { $dinnerCount[$p.name]++ }
            }
        }
    }

    foreach ($pair in @(
            @{ Name = 'weekend'; Counts = $weekendCount; Weight = $weekendW },
            @{ Name = 'dinner'; Counts = $dinnerCount; Weight = $dinnerW })) {
        $values = @($pair.Counts.Values)
        $spread = ($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum
        if ($spread -gt 0) {
            New-RotaViolation -Id "S5-Fairness-$($pair.Name)" -Severity 'Soft' `
                -Message "$($pair.Name) load spread across solved staff is $spread ($(($pair.Counts.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))." `
                -Cost ($pair.Weight * $spread)
        }
    }
}

# ---------------------------------------------------------------- registry

function Get-RotaConstraints {
    <#
    .SYNOPSIS
        The constraint registry. Order is report order.
    #>
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{ Id = 'H1-Coverage'; Severity = 'Hard'; Test = ${function:Test-RotaCoverage} }
        [pscustomobject]@{ Id = 'H2-Responsable'; Severity = 'Hard'; Test = ${function:Test-RotaResponsable} }
        [pscustomobject]@{ Id = 'H3-Fixed'; Severity = 'Hard'; Test = ${function:Test-RotaFixedAssignments} }
        [pscustomobject]@{ Id = 'H4-ShiftCount'; Severity = 'Hard'; Test = ${function:Test-RotaShiftCount} }
        [pscustomobject]@{ Id = 'H5-Doubles'; Severity = 'Hard'; Test = ${function:Test-RotaDoubles} }
        [pscustomobject]@{ Id = 'H6-Eligibility'; Severity = 'Hard'; Test = ${function:Test-RotaSlotEligibility} }
        [pscustomobject]@{ Id = 'H7-Weekend'; Severity = 'Hard'; Test = ${function:Test-RotaWeekendAvailability} }
        [pscustomobject]@{ Id = 'H8-DaysOff'; Severity = 'Hard'; Test = ${function:Test-RotaConsecutiveDaysOff} }
        [pscustomobject]@{ Id = 'S1-SlotPreference'; Severity = 'Soft'; Test = ${function:Test-RotaSlotPreference} }
        [pscustomobject]@{ Id = 'S2-IsolatedDay'; Severity = 'Soft'; Test = ${function:Test-RotaIsolatedWorkDays} }
        [pscustomobject]@{ Id = 'S5-Fairness'; Severity = 'Soft'; Test = ${function:Test-RotaFairness} }
        [pscustomobject]@{ Id = 'S6-AdminLunch'; Severity = 'Soft'; Test = ${function:Test-RotaOfficeLunchProtected} }
        [pscustomobject]@{ Id = 'S7-TemporaryCover'; Severity = 'Soft'; Test = ${function:Test-RotaTemporaryStaff} }
        [pscustomobject]@{ Id = 'S8-DaysOffPreference'; Severity = 'Soft'; Test = ${function:Test-RotaDaysOffPreference} }
    )
}

function Test-RotaSchedule {
    <#
    .SYNOPSIS
        Run every registered constraint and return all violations.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedule)
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($c in Get-RotaConstraints) {
        foreach ($v in (& $c.Test -Schedule $Schedule)) { if ($null -ne $v) { $all.Add($v) } }
    }
    , $all.ToArray()
}

function Get-RotaScore {
    <#
    .SYNOPSIS
        Total weighted cost of a schedule. Lower is better; 0 is perfect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedule, $Violations = $null)
    if ($null -eq $Violations) { $Violations = Test-RotaSchedule -Schedule $Schedule }
    ($Violations | Measure-Object -Property Cost -Sum).Sum
}
