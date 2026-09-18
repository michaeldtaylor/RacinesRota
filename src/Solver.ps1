# Solver.ps1 -- fills the gaps the fixed staff leave behind.
#
# The search is over whole *week patterns* rather than individual shifts, because every
# per-person rule (shift count, doubles, lunch/dinner eligibility, weekend availability)
# is a property of a person's week. Enumerating legal weeks first means the search never
# visits a state that breaks one of them, and coverage becomes pure bitmask arithmetic.
#
# Coverage is tracked as three 14-bit masks per week -- services covered once, twice and
# three times -- so adding a person to a week is six bit operations regardless of how many
# shifts they work, and every capacity check is a single -band.
#
# Three prunes do nearly all the work:
#
#   1. Popcount pre-solve. How many shifts each variable contributes is decided before any
#      pattern is examined, by solving the small per-week sum problem first.
#   2. Zero-capacity masking. A pattern that touches a full service dies on one -band.
#   3. Last-variable determination. When a week must be filled exactly, the final variable's
#      pattern is whatever capacity remains -- one hash lookup instead of a domain scan.

Set-StrictMode -Version Latest

function Get-RotaPopCount {
    <#  Hot-path population count. Uses the intrinsic rather than a loop.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Value)
    [System.Numerics.BitOperations]::PopCount([uint32]$Value)
}

function Get-RotaWeekGaps {
    <#
    .SYNOPSIS
        Per-slot shortfall for one week of a schedule holding only fixed staff.
    .OUTPUTS
        int[14], indexed by week-local slot index.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][int]$Week
    )
    $gaps = New-Object int[] 14
    foreach ($s in $Schedule.Services) {
        if ($s.Week -ne $Week) { continue }
        $have = (Get-RotaCoverage -Schedule $Schedule -Service $s).Count
        $gaps[$s.SlotIndex] = [math]::Max(0, $s.Required - $have)
    }
    , $gaps
}

function Get-RotaAllowedMask {
    <#
    .SYNOPSIS
        The 14-bit mask of services a person may legally work in a given week.
    .DESCRIPTION
        Applies the hard per-week rules that do not depend on which other services the
        person takes: weekend availability, and NO / OBLIG slot eligibility. Doubles and
        shift count are applied during enumeration because they constrain combinations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Person,
        [Parameter(Mandatory)][int]$Week
    )
    $spec = $Person.WeekSpec[$Week]
    $mask = 0
    for ($d = 0; $d -lt $Config.days.Count; $d++) {
        $isWeekend = $Config.WeekendDayIndexes -contains $d
        if ($isWeekend -and -not $spec.weekend) { continue }
        foreach ($slot in @('Lunch', 'Dinner')) {
            $rule = if ($slot -eq 'Lunch') { $spec.lunch } else { $spec.dinner }
            $other = if ($slot -eq 'Lunch') { $spec.dinner } else { $spec.lunch }
            if ($rule -eq 'NO') { continue }
            if ($other -eq 'OBLIG') { continue }
            $mask = $mask -bor (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot))
        }
    }
    # Per-day availability, where it is given, is a further restriction on top of the week
    # rules -- it can say things they cannot, like dinner on Monday but not on Tuesday.
    if ($null -ne $Person.AvailableMask) { $mask = $mask -band $Person.AvailableMask }
    $mask
}

function Get-RotaWeekPatterns {
    <#
    .SYNOPSIS
        Every legal week pattern for a person, grouped by shift count.
    .DESCRIPTION
        Walks all 2^14 masks once. That is cheap, exhaustive and far easier to trust than
        a clever combinatorial generator -- and it runs once per person-week, not in the
        inner loop.
    .OUTPUTS
        Hashtable of shiftCount -> int[] of masks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Person,
        [Parameter(Mandatory)][int]$Week,
        [Parameter(Mandatory)][int]$MinShifts,
        [Parameter(Mandatory)][int]$MaxShifts
    )
    $allowed = Get-RotaAllowedMask -Config $Config -Person $Person -Week $Week
    $doubles = [bool]$Person.WeekSpec[$Week].doubles
    $dayCount = $Config.days.Count

    $byCount = @{}
    for ($c = $MinShifts; $c -le $MaxShifts; $c++) { $byCount[$c] = [System.Collections.Generic.List[int]]::new() }

    for ($mask = 0; $mask -lt 16384; $mask++) {
        if (($mask -band $allowed) -ne $mask) { continue }
        $n = Get-RotaPopCount -Value $mask
        if ($n -lt $MinShifts -or $n -gt $MaxShifts) { continue }
        if (-not $doubles) {
            $bad = $false
            for ($d = 0; $d -lt $dayCount; $d++) {
                if ((($mask -shr ($d * 2)) -band 3) -eq 3) { $bad = $true; break }
            }
            if ($bad) { continue }
        }
        $byCount[$n].Add($mask)
    }

    $out = @{}
    foreach ($k in $byCount.Keys) { $out[$k] = $byCount[$k].ToArray() }
    $out
}

function New-RotaSolverVariables {
    <#
    .SYNOPSIS
        Turn the solved staff into search variables.
    .DESCRIPTION
        A person whose repeat mode is 'weekly' makes one decision that applies to every week
        of the cycle, which is why their rota looks the same each week. 'cycle' (the contract
        differs between weeks) and 'none' (cover, placed week by week) both get one variable
        per week. Set rules.enforcePersonCycleRepeat to false to decouple a weekly person.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $cycleWeeks = [int]$Config.meta.cycleWeeks
    $enforce = [bool](Get-RotaProperty -Object $Config.rules -Name 'enforcePersonCycleRepeat' -Default $true)
    $vars = [System.Collections.Generic.List[object]]::new()

    foreach ($p in $Config.SolvedStaff) {
        # Only 'weekly' collapses to a single decision. 'cycle' and 'none' both get one
        # variable per week -- they differ in what the weeks mean, not in how they are placed.
        $repeats = $enforce -and $p.RepeatsWeekly -and $cycleWeeks -gt 1
        if ($repeats) {
            $vars.Add([pscustomobject]@{
                    Person = $p; Name = $p.name; Weeks = @(1..$cycleWeeks)
                    SpecWeek = 1; Target = [int]$p.WeekSpec[1].shifts
                })
        }
        else {
            for ($w = 1; $w -le $cycleWeeks; $w++) {
                $vars.Add([pscustomobject]@{
                        Person = $p; Name = $p.name; Weeks = @($w)
                        SpecWeek = $w; Target = [int]$p.WeekSpec[$w].shifts
                    })
            }
        }
    }
    , $vars.ToArray()
}

function Get-RotaPopcountCombinations {
    <#
    .SYNOPSIS
        Every way to distribute shift counts across variables without over-filling a week.
    .DESCRIPTION
        Solving this small integer problem before touching patterns is what makes the search
        tractable. Results carry their Total so the caller can try the fullest schedules
        first -- an extra shift assigned always beats any soft preference, so the first total
        that yields a solution is the right one.
    .OUTPUTS
        Objects with Counts (int[], one per variable) and Total.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Variables,
        [Parameter(Mandatory)][hashtable]$WeekTarget,
        [Parameter(Mandatory)][hashtable]$MinCount,
        [Parameter(Mandatory)][hashtable]$MaxCount
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $n = $Variables.Count
    $counts = New-Object int[] $n
    $weeks = @($WeekTarget.Keys)

    $recurse = {
        param([int]$i)
        if ($i -eq $n) {
            $total = 0
            for ($k = 0; $k -lt $n; $k++) { $total += $counts[$k] * $Variables[$k].Weeks.Count }
            $results.Add([pscustomobject]@{ Counts = $counts.Clone(); Total = $total })
            return
        }
        for ($c = $MinCount[$i]; $c -le $MaxCount[$i]; $c++) {
            $counts[$i] = $c
            $over = $false
            foreach ($w in $weeks) {
                $sum = 0
                for ($k = 0; $k -le $i; $k++) { if ($Variables[$k].Weeks -contains $w) { $sum += $counts[$k] } }
                if ($sum -gt $WeekTarget[$w]) { $over = $true; break }
            }
            if (-not $over) { & $recurse ($i + 1) }
        }
    }
    & $recurse 0
    , $results.ToArray()
}

function Add-RotaComboCost {
    <#
    .SYNOPSIS
        Score each shift-count distribution before any pattern search happens.
    .DESCRIPTION
        The search tries distributions cheapest-first, so this decides the order. Counting
        raw shifts assigned is not good enough once cover staff exist: more shifts is better
        when they come from the contracted team and worse when they come from a temp. The
        estimate covers exactly the terms fixed by the counts alone -- coverage shortfall,
        shift underrun and temporary cover -- which are also the terms that dominate.
    .OUTPUTS
        The combinations with an EstimatedCost property added.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Variables,
        [Parameter(Mandatory)]$Combinations,
        [Parameter(Mandatory)][hashtable]$WeekCapacityTotal
    )
    $shortW = Get-RotaWeight -Config $Config -Name 'coverageShortfall' -Default 1000
    $underW = Get-RotaWeight -Config $Config -Name 'shiftUnderrun' -Default 200
    $tempW = Get-RotaWeight -Config $Config -Name 'temporaryShift' -Default 300

    $isTemp = @{}
    for ($i = 0; $i -lt $Variables.Count; $i++) {
        $isTemp[$i] = [bool](Get-RotaProperty -Object $Variables[$i].Person -Name 'temporary' -Default $false)
    }

    foreach ($combo in $Combinations) {
        $cost = 0.0
        foreach ($w in $WeekCapacityTotal.Keys) {
            $sum = 0
            for ($i = 0; $i -lt $Variables.Count; $i++) {
                if ($Variables[$i].Weeks -contains $w) { $sum += $combo.Counts[$i] }
            }
            $cost += $shortW * [math]::Max(0, $WeekCapacityTotal[$w] - $sum)
        }
        for ($i = 0; $i -lt $Variables.Count; $i++) {
            $weeks = $Variables[$i].Weeks.Count
            if ($isTemp[$i]) { $cost += $tempW * $combo.Counts[$i] * $weeks; continue }
            $d = $Variables[$i].Target - $combo.Counts[$i]
            if ($d -gt 0) { $cost += $underW * $d * $d * $weeks }
        }
        Add-Member -InputObject $combo -NotePropertyName EstimatedCost -NotePropertyValue $cost -Force
        $combo
    }
}

function Test-RotaMasksDaysOff {
    <#
    .SYNOPSIS
        Cheap days-off check straight from masks, used inside the search.
    .DESCRIPTION
        Mirrors Test-RotaConsecutiveDaysOff but avoids materialising a schedule, because
        it runs on every complete candidate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][hashtable]$Masks,
        [Parameter(Mandatory)]$Person
    )
    $required = [double](Get-RotaProperty -Object $Person -Name 'consecutiveDaysOff' -Default 0)
    $floor = [double](Get-RotaProperty -Object $Config.rules -Name 'minConsecutiveDaysOffForEveryone' -Default 0)
    $required = [math]::Max($required, $floor)
    if ($required -le 0) { return $true }

    # The day loads are built inline rather than via Get-RotaDayLoad because this runs on
    # every candidate and cmdlet-call overhead dominated the solve. The run measurement
    # itself is shared with the constraint engine, so the two cannot drift apart.
    $dayCount = $Config.days.Count
    $n = $Config.meta.cycleWeeks * $dayCount
    $loads = New-Object int[] $n
    $anyOff = $false
    for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) {
        $m = $Masks["$($Person.name)|$w"]
        $base = ($w - 1) * $dayCount
        for ($d = 0; $d -lt $dayCount; $d++) {
            $load = 0
            if ($m -band (1 -shl ($d * 2))) { $load++ }
            if ($m -band (1 -shl ($d * 2 + 1))) { $load++ }
            $loads[$base + $d] = $load
            if ($load -eq 0) { $anyOff = $true }
        }
    }
    if (-not $anyOff) { return $false }

    $scope = [string](Get-RotaProperty -Object $Config.rules -Name 'daysOffScope' -Default 'week')
    if ($scope -eq 'cycle') {
        return (Get-RotaLongestDaysOffRun -DayLoads $loads) -ge $required
    }

    # Every week must be touched by a qualifying run, not just one week in the cycle.
    foreach ($run in (Get-RotaDaysOffRunByWeek -DayLoads $loads -DaysPerWeek $dayCount)) {
        if (-not (Test-RotaDaysOffRequirement -Run $run -Required $required)) { return $false }
    }
    $true
}

function Select-RotaDaysOffFeasiblePatterns {
    <#
    .SYNOPSIS
        Drop the patterns a cycle-spanning variable could never use, whatever anyone else does.
    .DESCRIPTION
        Days off is measured across the whole cycle ring, which is why the component search
        cannot check it: a variable owning a single week says nothing on its own, because the
        run that saves it may lie in a week some other variable controls.

        A variable owning EVERY week of the cycle is different. It carries the same mask in
        each of them -- that is what a one-week cycle means -- so its ring of day loads, and
        therefore its days-off verdict, is settled by that one pattern and nothing else. Those
        patterns can be discarded before the search starts rather than after it finishes,
        which is the difference between rejecting a dead branch at its root and walking the
        entire subtree beneath it first.

        This changes which schedules the search finds, but only by finding more of the legal
        ones: every pattern removed here is one Join-RotaComponents would have rejected
        anyway, so the surviving candidate set is unchanged while the shortlist it is drawn
        from is no longer crowded out by branches that were never going to qualify.

        Variables owning a subset of the weeks are returned untouched -- their verdict really
        does depend on the person's other weeks, and it stays where it was.
    .OUTPUTS
        Hashtable of shift count -> masks, in the shape Get-RotaWeekPatterns returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Variable,
        [Parameter(Mandatory)][hashtable]$PatternsByCount
    )
    # Anything less than the whole cycle couples to weeks this variable does not own.
    if ($Variable.Weeks.Count -ne [int]$Config.meta.cycleWeeks) { return $PatternsByCount }

    $filtered = @{}
    foreach ($count in $PatternsByCount.Keys) {
        $keep = [System.Collections.Generic.List[int]]::new()
        foreach ($mask in $PatternsByCount[$count]) {
            $masks = @{}
            foreach ($w in $Variable.Weeks) { $masks["$($Variable.Name)|$w"] = $mask }
            if (Test-RotaMasksDaysOff -Config $Config -Masks $masks -Person $Variable.Person) { $keep.Add($mask) }
        }
        $filtered[$count] = $keep
    }
    $filtered
}

function Get-RotaProxyScore {
    <#
    .SYNOPSIS
        Fast ranking score used to shortlist candidates before exact evaluation.
    .DESCRIPTION
        Covers the two soft terms that dominate and are cheap from masks alone: slot
        preference and shift underrun. The shortlist is then scored properly by the
        constraint engine, so this only decides *which* candidates get a full look.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][hashtable]$Masks
    )
    $defaultPrefW = Get-RotaWeight -Config $Config -Name 'slotPreference' -Default 10
    $underW = Get-RotaWeight -Config $Config -Name 'shiftUnderrun' -Default 200
    $score = 0.0
    foreach ($p in $Config.SolvedStaff) {
        for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) {
            $spec = $p.WeekSpec[$w]
            $mask = $Masks["$($p.name)|$w"]
            $n = Get-RotaPopCount -Value $mask
            if ($n -lt $spec.shifts) { $score += $underW * ($spec.shifts - $n) }
            foreach ($slot in @('Lunch', 'Dinner')) {
                $otherRule = if ($slot -eq 'Lunch') { $spec.dinner } else { $spec.lunch }
                if ($otherRule -ne 'PREF') { continue }
                $prefW = [double](Get-RotaProperty -Object $spec -Name 'preferenceWeight' -Default $defaultPrefW)
                for ($d = 0; $d -lt $Config.days.Count; $d++) {
                    if ($mask -band (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot))) { $score += $prefW }
                }
            }
        }
    }
    $score
}

function Get-RotaOfficeCombinations {
    <#
    .SYNOPSIS
        Every assignment of office-lunch days, one per person-with-a-rule per week.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $slots = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Config.staff) {
        $office = Get-RotaProperty -Object $p -Name 'officeLunch'
        if ($null -eq $office) { continue }
        for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) {
            $slots.Add([pscustomobject]@{ Key = "$($p.name)|$w"; Days = @($office.candidateDays) })
        }
    }
    if ($slots.Count -eq 0) { return , @(@{}) }

    $combos = [System.Collections.Generic.List[hashtable]]::new()
    $combos.Add(@{})
    foreach ($slot in $slots) {
        $next = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($partial in $combos) {
            foreach ($day in $slot.Days) {
                $copy = $partial.Clone()
                $copy[$slot.Key] = $day
                $next.Add($copy)
            }
        }
        $combos = $next
    }
    , $combos.ToArray()
}

function Get-RotaOfficeCapacityGroups {
    <#
    .SYNOPSIS
        Office-lunch arrangements grouped by the capacity problem they leave behind.
    .DESCRIPTION
        Where the admin lunch falls changes who is in the office, but not necessarily what
        the search has to solve. With rules.officeLunchCountsOnFloor set, the person counts
        towards the three whichever day they take, so every arrangement leaves exactly the
        same per-service gaps -- the same domains, the same pruning, the same answers. On the
        shipped roster that is four identical searches, three of them wasted.

        Grouping by the gap signature collapses them to one search per distinct capacity. The
        arrangements in a group are not interchangeable in the finished schedule -- they cost
        different amounts under the admin-lunch rule (S6) -- so the caller hands the masks it
        finds to every member of the group and lets exact scoring choose between them.

        Order is preserved: groups come out in the order their first arrangement was seen, and
        so do the arrangements within a group, so the search stays deterministic.
    .OUTPUTS
        One object per distinct capacity, with Representative (the arrangement to search) and
        Offices (every arrangement sharing it, including the representative).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$OfficeCombinations
    )
    $cycleWeeks = [int]$Config.meta.cycleWeeks
    $groups = [System.Collections.Generic.List[object]]::new()
    $bySignature = @{}

    foreach ($office in $OfficeCombinations) {
        $probe = New-RotaSchedule -Config $Config
        Add-RotaFixedStaff -Schedule $probe -OfficeLunchDays $office | Out-Null
        $parts = for ($w = 1; $w -le $cycleWeeks; $w++) { (Get-RotaWeekGaps -Schedule $probe -Week $w) -join ',' }
        $signature = $parts -join '|'

        if ($bySignature.ContainsKey($signature)) {
            $bySignature[$signature].Offices.Add($office)
            continue
        }
        $group = [pscustomobject]@{
            Representative = $office
            Offices        = [System.Collections.Generic.List[object]]::new()
        }
        $group.Offices.Add($office)
        $bySignature[$signature] = $group
        $groups.Add($group)
    }
    , $groups.ToArray()
}

function Get-RotaVariableComponents {
    <#
    .SYNOPSIS
        Split the variables into groups that cannot affect one another.
    .DESCRIPTION
        Two variables interact only if they compete for capacity in the same week. When
        nobody repeats across weeks, week 1 and week 2 are entirely separate problems and
        must be solved separately -- searching their cross-product multiplies the work by
        the size of the other week for no benefit. Every variable touching a week lands in
        the same component, so a component always owns whole weeks.
    .OUTPUTS
        Objects with VarIndexes (int[]) and Weeks (int[]).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Variables)

    $n = $Variables.Count
    $group = New-Object int[] $n
    for ($i = 0; $i -lt $n; $i++) { $group[$i] = $i }

    $allWeeks = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($v in $Variables) { foreach ($w in $v.Weeks) { [void]$allWeeks.Add($w) } }

    foreach ($w in $allWeeks) {
        $touching = @(for ($i = 0; $i -lt $n; $i++) { if ($Variables[$i].Weeks -contains $w) { $i } })
        if ($touching.Count -lt 2) { continue }
        $target = ($touching | ForEach-Object { $group[$_] } | Measure-Object -Minimum).Minimum
        $merge = @($touching | ForEach-Object { $group[$_] } | Sort-Object -Unique)
        for ($i = 0; $i -lt $n; $i++) { if ($merge -contains $group[$i]) { $group[$i] = $target } }
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($g in ($group | Sort-Object -Unique)) {
        $idx = @(for ($i = 0; $i -lt $n; $i++) { if ($group[$i] -eq $g) { $i } })
        $weeks = [System.Collections.Generic.SortedSet[int]]::new()
        foreach ($i in $idx) { foreach ($w in $Variables[$i].Weeks) { [void]$weeks.Add($w) } }
        $out.Add([pscustomobject]@{ VarIndexes = [int[]]$idx; Weeks = [int[]]@($weeks) })
    }
    , $out.ToArray()
}

function Get-RotaVariableProxy {
    <#
    .SYNOPSIS
        Soft cost attributable to one variable's chosen pattern.
    .DESCRIPTION
        Decomposable by design, so components can be ranked independently and their scores
        added when combined. Covers the two soft terms computable from a single variable:
        shift underrun and slot preference. The whole-schedule terms -- isolated days and
        fairness -- are left to the exact scoring pass.

        Get-RotaVariableCosts is the bulk form used by the solver; this one is the single-mask
        version kept for tests and for reading the rule without unpicking the loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Variable,
        [Parameter(Mandatory)][int]$Mask
    )
    (Get-RotaVariableCosts -Config $Config -Variable $Variable -Masks @($Mask))[0]
}

function Get-RotaVariableCosts {
    <#
    .SYNOPSIS
        Soft costs for a whole pattern domain at once.
    .DESCRIPTION
        The solver needs a cost for every pattern of every variable, which on this roster is
        tens of thousands of values per run. Calling a cmdlet per pattern dominated the whole
        solve, so the per-variable constants are hoisted out and the loop works on a
        precomputed preference mask.
    .OUTPUTS
        double[] parallel to $Masks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Variable,
        [Parameter(Mandatory)][int[]]$Masks
    )
    $spec = $Variable.Person.WeekSpec[$Variable.SpecWeek]
    # Honour the week's own preference weight, or the shortlist would rank by the house
    # default while the exact scorer used a different number -- and the schedules the
    # preference is meant to favour would never reach scoring.
    $prefW = [double](Get-RotaProperty -Object $spec -Name 'preferenceWeight' `
            -Default (Get-RotaWeight -Config $Config -Name 'slotPreference' -Default 10))
    $underW = Get-RotaWeight -Config $Config -Name 'shiftUnderrun' -Default 200
    $tempW = Get-RotaWeight -Config $Config -Name 'temporaryShift' -Default 300
    $isTemp = [bool](Get-RotaProperty -Object $Variable.Person -Name 'temporary' -Default $false)
    $weeks = $Variable.Weeks.Count
    $target = [int]$spec.shifts

    # Bits that cost: a shift in the slot the person would rather not work.
    $penaltyMask = 0
    foreach ($slot in @('Lunch', 'Dinner')) {
        $otherRule = if ($slot -eq 'Lunch') { $spec.dinner } else { $spec.lunch }
        if ($otherRule -ne 'PREF') { continue }
        for ($d = 0; $d -lt $Config.days.Count; $d++) {
            $penaltyMask = $penaltyMask -bor (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot))
        }
    }

    $costs = New-Object double[] $Masks.Count
    for ($i = 0; $i -lt $Masks.Count; $i++) {
        $m = $Masks[$i]
        $n = [System.Numerics.BitOperations]::PopCount([uint32]$m)
        $c = 0.0
        if ($isTemp) {
            # Every temporary shift is charged, so cover is used only where nothing else fits.
            $c = $tempW * $n
        }
        # Squared, matching Test-RotaShiftCount: spreading a shortfall beats concentrating it.
        elseif ($n -lt $target) { $d = $target - $n; $c = $underW * $d * $d }
        if ($penaltyMask) { $c += $prefW * [System.Numerics.BitOperations]::PopCount([uint32]($m -band $penaltyMask)) }
        # A repeating variable pays its cost in every week it covers.
        $costs[$i] = $c * $weeks
    }
    , $costs
}

function Search-RotaComponent {
    <#
    .SYNOPSIS
        Depth-first search over week patterns for one component and shift-count combination.
    .DESCRIPTION
        Coverage state is two bitmasks per week -- services covered once and twice -- so
        adding a person is a handful of bit operations and rejecting an over-filled week is
        one comparison. When the final variable covers a single week that must come out
        exactly full, its pattern is derived from the leftover capacity rather than searched.

        Days-off is deliberately not checked here: it spans the whole cycle, so it belongs
        to the stage that joins components together.
    .OUTPUTS
        Objects with Assign (hashtable of variable index -> mask) and Proxy, best first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Variables,
        [Parameter(Mandatory)]$Component,
        [Parameter(Mandatory)]$Domains,
        [Parameter(Mandatory)]$DomainCosts,
        [Parameter(Mandatory)][int[]]$Counts,
        [Parameter(Mandatory)]$Cap,
        [Parameter(Mandatory)][int]$Levels,
        [Parameter(Mandatory)][hashtable]$WeekCapacityTotal,
        [Parameter(Mandatory)][int]$TopN,
        [Parameter(Mandatory)]$Stopwatch,
        [Parameter(Mandatory)][double]$Budget
    )

    # Coverage is tracked as one bitmask per (level, week): level L holds the services
    # covered at least L+1 times. Adding a person cascades upwards through the levels, so
    # the cost is a few bit operations no matter how many shifts the pattern contains.
    Initialize-RotaSearchKernel
    $cycleWeeks = [int]$Config.meta.cycleWeeks

    # Smallest domain first, and among equals prefer the variable spanning more weeks: it is
    # constrained by both, so placing it early prunes harder and leaves a single-week
    # variable last, where it can often be derived outright.
    $order = [int[]]@($Component.VarIndexes |
            Sort-Object @{ Expression = { $Domains[$_].Count } }, @{ Expression = { - $Variables[$_].Weeks.Count } })

    # Can the last variable be derived instead of searched? Only if it owns a single week
    # whose capacity must be consumed entirely by this component.
    $lastIdx = $order[$order.Count - 1]
    $lastWeek = $Variables[$lastIdx].Weeks[0]
    $derivable = $Variables[$lastIdx].Weeks.Count -eq 1
    if ($derivable) {
        $assigned = 0
        foreach ($vi in $Component.VarIndexes) { if ($Variables[$vi].Weeks -contains $lastWeek) { $assigned += $Counts[$vi] } }
        $derivable = $assigned -eq $WeekCapacityTotal[$lastWeek]
    }
    # Marshal into the flat arrays the kernel expects. Variables outside this component get
    # an empty domain, which the kernel never visits because they are absent from $order.
    $varCount = $Variables.Count
    $domainArr = New-Object 'int[][]' $varCount
    $costArr = New-Object 'double[][]' $varCount
    $weekArr = New-Object 'int[][]' $varCount
    for ($i = 0; $i -lt $varCount; $i++) {
        if ($Component.VarIndexes -contains $i) {
            $domainArr[$i] = [int[]]$Domains[$i]
            $costArr[$i] = [double[]]$DomainCosts[$i]
            $weekArr[$i] = [int[]]@($Variables[$i].Weeks | ForEach-Object { $_ - 1 })
        }
        else {
            $domainArr[$i] = [int[]]@(); $costArr[$i] = [double[]]@(); $weekArr[$i] = [int[]]@()
        }
    }

    $capArr = New-Object 'int[][]' $Levels
    for ($L = 0; $L -lt $Levels; $L++) { $capArr[$L] = [int[]]$Cap[$L] }

    $remaining = [math]::Max(0.5, $Budget - $Stopwatch.Elapsed.TotalSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($remaining).Ticks

    $raw = [Racines.RotaSearch]::Run(
        $domainArr, $costArr, $weekArr, [int[]]$Counts, $capArr, $Levels, $order,
        $cycleWeeks, $varCount, $derivable, $lastIdx, ($lastWeek - 1), $TopN, $deadline)

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($sol in $raw.Solutions) {
        $assign = @{}
        foreach ($vi in $Component.VarIndexes) { $assign[$vi] = $sol.Masks[$vi] }
        $results.Add([pscustomobject]@{ Assign = $assign; Proxy = $sol.Cost })
    }

    [pscustomobject]@{
        Solutions = $results.ToArray()
        TimedOut  = $raw.TimedOut
        Nodes     = $raw.Nodes
    }
}

function Join-RotaComponents {
    <#
    .SYNOPSIS
        Combine independent component solutions into whole-cycle candidates.
    .DESCRIPTION
        Components are independent on coverage but not on days off, which is measured across
        the whole cycle ring. Combinations are tried cheapest-proxy-first and checked against
        the days-off rule, so the good candidates surface without enumerating the full cross
        product.
    .OUTPUTS
        Objects with Masks (person|week -> mask) and ProxyScore.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Variables,
        [Parameter(Mandatory)]$ComponentSolutions,
        [Parameter(Mandatory)][hashtable]$Office,
        [Parameter(Mandatory)][int]$MaxCombinations,
        [Parameter(Mandatory)][int]$WantedCandidates
    )

    $cycleWeeks = [int]$Config.meta.cycleWeeks
    $out = [System.Collections.Generic.List[object]]::new()

    # Build the cross product as (indices, combined proxy) pairs, then walk it best first.
    $combos = [System.Collections.Generic.List[object]]::new()
    $combos.Add([pscustomobject]@{ Picks = @(); Proxy = 0.0 })
    foreach ($solutions in $ComponentSolutions) {
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($partial in $combos) {
            foreach ($s in $solutions) {
                $next.Add([pscustomobject]@{ Picks = $partial.Picks + @($s); Proxy = $partial.Proxy + $s.Proxy })
            }
        }
        $combos = [System.Collections.Generic.List[object]](@($next | Sort-Object Proxy | Select-Object -First $MaxCombinations))
    }

    foreach ($combo in ($combos | Sort-Object Proxy)) {
        $masks = @{}
        foreach ($p in $Config.SolvedStaff) {
            for ($w = 1; $w -le $cycleWeeks; $w++) { $masks["$($p.name)|$w"] = 0 }
        }
        foreach ($pick in $combo.Picks) {
            foreach ($vi in $pick.Assign.Keys) {
                foreach ($w in $Variables[$vi].Weeks) { $masks["$($Variables[$vi].Name)|$w"] = $pick.Assign[$vi] }
            }
        }
        $ok = $true
        foreach ($p in $Config.SolvedStaff) {
            if (-not (Test-RotaMasksDaysOff -Config $Config -Masks $masks -Person $p)) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        $out.Add([pscustomobject]@{ Masks = $masks; Office = $Office; ProxyScore = $combo.Proxy })
        if ($out.Count -ge $WantedCandidates) { break }
    }
    , $out.ToArray()
}

function Invoke-RotaSolver {
    <#
    .SYNOPSIS
        Produce the best schedule this roster allows.
    .DESCRIPTION
        For each office-lunch arrangement, tries the fullest shift-count distributions first
        and stops descending once one yields solutions -- an assigned shift always outweighs
        any soft preference, so there is nothing better further down. Candidates are
        shortlisted by a fast proxy, then scored by the full constraint engine.
        Deterministic: the same config always yields the same result.
    .OUTPUTS
        An object carrying the winning Schedule, its Violations, Score and search stats.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [int]$ShortlistSize = 100,
        # Names forced to zero shifts. Used by the first pass to solve the permanent team
        # on its own, with no cover staff available.
        [string[]]$ExcludeStaff = @(),
        # "person|specWeek" -> minimum shifts. The second pass uses the first pass's result
        # as a floor, so cover can only ever be added on top of it.
        [hashtable]$ShiftFloors = @{},
        # Set on the inner passes to stop the two-pass orchestration recursing.
        [switch]$SinglePass
    )

    # Cover staff must never make the rota easier -- only fill what the permanent team
    # genuinely cannot reach. A cost alone cannot promise that: the solver would still trade
    # a contracted shift for a cover shift whenever the arithmetic happened to suit. So the
    # permanent team is solved first, on its own, and its shift counts become a floor for the
    # second pass. Cover can then only ever add to that result, never substitute for it.
    $temporaryStaff = @($Config.staff | Where-Object {
            $_.IsSolved -and (Get-RotaProperty -Object $_ -Name 'temporary' -Default $false)
        } | ForEach-Object name)

    if (-not $SinglePass -and $temporaryStaff.Count -gt 0 -and $ExcludeStaff.Count -eq 0) {
        $permanentOnly = Invoke-RotaSolver -Config $Config -ShortlistSize $ShortlistSize `
            -ExcludeStaff $temporaryStaff -SinglePass

        $floors = @{}
        foreach ($v in (New-RotaSolverVariables -Config $Config)) {
            if ($temporaryStaff -contains $v.Name) { continue }
            $floors["$($v.Name)|$($v.SpecWeek)"] = Get-RotaMaskPopCount -Mask $permanentOnly.Schedule.Masks["$($v.Name)|$($v.Weeks[0])"]
        }

        $withCover = Invoke-RotaSolver -Config $Config -ShortlistSize $ShortlistSize `
            -ShiftFloors $floors -SinglePass

        Add-Member -InputObject $withCover -NotePropertyName PermanentOnly -NotePropertyValue $permanentOnly -Force
        Add-Member -InputObject $withCover -NotePropertyName ShiftFloors -NotePropertyValue $floors -Force
        return $withCover
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $budget = [double](Get-RotaProperty -Object $Config.solver -Name 'timeBudgetSeconds' -Default 300)
    $cycleWeeks = [int]$Config.meta.cycleWeeks
    $vars = New-RotaSolverVariables -Config $Config
    $components = Get-RotaVariableComponents -Variables $vars
    $officeCombos = Get-RotaOfficeCombinations -Config $Config
    $officeGroups = Get-RotaOfficeCapacityGroups -Config $Config -OfficeCombinations $officeCombos

    $stats = [ordered]@{
        Variables = $vars.Count; Components = $components.Count; OfficeCombinations = $officeCombos.Count
        OfficeCapacityGroups = $officeGroups.Count
        PopcountCombinationsTried = 0; Nodes = [long]0; CandidatesFound = 0; ExactlyScored = 0
        BestTotalAssigned = 0; TimedOut = $false
    }
    $shortlist = [System.Collections.Generic.List[object]]::new()

    foreach ($group in $officeGroups) {
        $office = $group.Representative
        $probe = New-RotaSchedule -Config $Config
        Add-RotaFixedStaff -Schedule $probe -OfficeLunchDays $office | Out-Null

        # Capacity per week as one bitmask per level: level L holds the services still
        # wanting at least L+1 more people.
        $weekGaps = @{}
        $weekCapacityTotal = @{}
        $levels = 1
        for ($w = 1; $w -le $cycleWeeks; $w++) {
            $gaps = Get-RotaWeekGaps -Schedule $probe -Week $w
            $weekGaps[$w] = $gaps
            $total = 0
            foreach ($g in $gaps) { $total += $g; if ($g -gt $levels) { $levels = $g } }
            $weekCapacityTotal[$w] = $total
        }
        $cap = @()
        for ($L = 0; $L -lt $levels; $L++) {
            $m = New-Object int[] $cycleWeeks
            for ($w = 1; $w -le $cycleWeeks; $w++) {
                for ($i = 0; $i -lt 14; $i++) { if ($weekGaps[$w][$i] -ge ($L + 1)) { $m[$w - 1] = $m[$w - 1] -bor (1 -shl $i) } }
            }
            $cap += , $m
        }

        # Ceilings first, because how many shifts a week can absorb depends on what people
        # are allowed to work, not on what they are contracted for -- cover staff have a
        # target of zero and a ceiling well above it.
        $allowance = [int](Get-RotaProperty -Object $Config.solver -Name 'underrunAllowance' -Default 3)
        $minCount = @{}; $maxCount = @{}
        for ($i = 0; $i -lt $vars.Count; $i++) {
            $spec = $vars[$i].Person.WeekSpec[$vars[$i].SpecWeek]
            $ceiling = [int](Get-RotaProperty -Object $spec -Name 'maxShifts' -Default $vars[$i].Target)
            $floorKey = "$($vars[$i].Name)|$($vars[$i].SpecWeek)"

            if ($ExcludeStaff -contains $vars[$i].Name) {
                # First pass: this person is not available at all.
                $minCount[$i] = 0; $maxCount[$i] = 0
                continue
            }
            $minCount[$i] = [math]::Max(0, $vars[$i].Target - $allowance)
            $maxCount[$i] = $ceiling
            # Second pass: never fall below what the permanent team managed on its own.
            if ($ShiftFloors.ContainsKey($floorKey)) {
                $minCount[$i] = [math]::Max($minCount[$i], [int]$ShiftFloors[$floorKey])
                $maxCount[$i] = [math]::Max($maxCount[$i], $minCount[$i])
            }
        }

        $weekTarget = @{}
        for ($w = 1; $w -le $cycleWeeks; $w++) {
            $supply = 0
            for ($i = 0; $i -lt $vars.Count; $i++) { if ($vars[$i].Weeks -contains $w) { $supply += $maxCount[$i] } }
            $weekTarget[$w] = [math]::Min($weekCapacityTotal[$w], $supply)
        }

        # Enumerate each variable's legal patterns once, indexed by shift count, and cost them
        # once here rather than per shift-count combination.
        $patternsByVar = @()
        $costsByVar = @()
        for ($i = 0; $i -lt $vars.Count; $i++) {
            $byCount = Get-RotaWeekPatterns -Config $Config -Person $vars[$i].Person `
                -Week $vars[$i].SpecWeek -MinShifts $minCount[$i] -MaxShifts $maxCount[$i]
            # Days off is otherwise only checked once components are joined, long after the
            # search has paid for the branch. For a variable spanning the whole cycle it is
            # decidable right here, so the dead patterns never reach the kernel.
            $byCount = Select-RotaDaysOffFeasiblePatterns -Config $Config -Variable $vars[$i] -PatternsByCount $byCount
            $patternsByVar += , $byCount
            $costCache = @{}
            foreach ($c in $byCount.Keys) {
                # A shift count can come out with no legal pattern at all -- the count range
                # alone can do it, and filtering days off up front makes it commonplace.
                # Leave the domain empty rather than costing it: the combination loop below
                # already abandons any distribution that asks a variable for a count it
                # cannot supply.
                if ($byCount[$c].Count -eq 0) { $costCache[$c] = [double[]]@(); continue }
                $costCache[$c] = Get-RotaVariableCosts -Config $Config -Variable $vars[$i] -Masks ([int[]]$byCount[$c])
            }
            $costsByVar += , $costCache
        }

        # Assign first, then sort: the generator returns a wrapped array, which unwraps on
        # assignment but would pipe as a single item.
        $combos = Get-RotaPopcountCombinations -Variables $vars -WeekTarget $weekTarget -MinCount $minCount -MaxCount $maxCount
        $combos = @(Add-RotaComboCost -Config $Config -Variables $vars -Combinations $combos `
                -WeekCapacityTotal $weekCapacityTotal | Sort-Object -Property EstimatedCost)

        $foundForThisCapacity = $false
        $lastCost = $null
        # How far above the cheapest distribution to keep looking before giving up. Without
        # this an unsatisfiable roster grinds through every way of assigning fewer shifts.
        $maxDrop = [double](Get-RotaProperty -Object $Config.solver -Name 'maxCostDrop' -Default 2500)
        $maxCombinations = [int](Get-RotaProperty -Object $Config.solver -Name 'maxComponentCombinations' -Default 4000)
        $componentTopN = [int](Get-RotaProperty -Object $Config.solver -Name 'componentShortlist' -Default 150)
        $bestCost = if ($combos.Count -gt 0) { $combos[0].EstimatedCost } else { 0 }

        foreach ($combo in $combos) {
            # Stop as soon as a cheaper distribution has already produced answers.
            if ($foundForThisCapacity -and $combo.EstimatedCost -ne $lastCost) { break }
            if (($combo.EstimatedCost - $bestCost) -gt $maxDrop) { break }
            $lastCost = $combo.EstimatedCost
            if ($sw.Elapsed.TotalSeconds -gt $budget) { break }

            $domains = @()
            $domainCosts = @()
            $ok = $true
            for ($i = 0; $i -lt $vars.Count; $i++) {
                $pats = $patternsByVar[$i][$combo.Counts[$i]]
                if ($null -eq $pats -or $pats.Count -eq 0) { $ok = $false; break }
                $domains += , $pats
                $domainCosts += , $costsByVar[$i][$combo.Counts[$i]]
            }
            if (-not $ok) { continue }

            $stats.PopcountCombinationsTried++
            $componentSolutions = @()
            foreach ($component in $components) {
                $res = Search-RotaComponent -Config $Config -Variables $vars -Component $component `
                    -Domains $domains -DomainCosts $domainCosts -Counts $combo.Counts -Cap $cap -Levels $levels `
                    -WeekCapacityTotal $weekCapacityTotal -TopN $componentTopN -Stopwatch $sw -Budget $budget
                $stats.Nodes += $res.Nodes
                if ($res.TimedOut) { $stats.TimedOut = $true }
                if ($res.Solutions.Count -eq 0) { $ok = $false; break }
                $componentSolutions += , $res.Solutions
            }
            if (-not $ok) { continue }

            $candidates = Join-RotaComponents -Config $Config -Variables $vars `
                -ComponentSolutions $componentSolutions -Office $office `
                -MaxCombinations $maxCombinations -WantedCandidates $ShortlistSize
            # The masks answer the whole group, so give every arrangement in it its own
            # candidate. They differ only in which day the admin lunch falls on, which costs
            # nothing here and is settled by exact scoring below.
            foreach ($c in $candidates) {
                foreach ($o in $group.Offices) {
                    $shortlist.Add([pscustomobject]@{ Masks = $c.Masks; Office = $o; ProxyScore = $c.ProxyScore })
                }
            }

            if ($candidates.Count -gt 0) {
                $stats.CandidatesFound += $candidates.Count
                $foundForThisCapacity = $true
                if ($combo.Total -gt $stats.BestTotalAssigned) { $stats.BestTotalAssigned = $combo.Total }
            }
        }
    }

    # Exact scoring of the shortlist by the real constraint engine.
    $best = $null
    foreach ($cand in ($shortlist | Sort-Object ProxyScore | Select-Object -First $ShortlistSize)) {
        $schedule = New-RotaSchedule -Config $Config
        Add-RotaFixedStaff -Schedule $schedule -OfficeLunchDays $cand.Office | Out-Null
        foreach ($p in $Config.SolvedStaff) {
            for ($w = 1; $w -le $cycleWeeks; $w++) {
                Set-RotaWeekMask -Schedule $schedule -Person $p.name -Week $w -Mask $cand.Masks["$($p.name)|$w"]
            }
        }
        $violations = Test-RotaSchedule -Schedule $schedule
        $score = Get-RotaScore -Schedule $schedule -Violations $violations
        $stats.ExactlyScored++
        if ($null -eq $best -or $score -lt $best.Score) {
            $best = [pscustomobject]@{ Schedule = $schedule; Violations = $violations; Score = $score }
        }
    }

    $sw.Stop()
    if ($null -eq $best) {
        # A timeout and a genuine contradiction are very different answers, and reporting one
        # as the other would be a lie about the roster.
        if ($stats.TimedOut) {
            throw ("Search ran out of time after $([int]$sw.Elapsed.TotalSeconds)s without finding a schedule; " +
                "this does NOT mean the roster is impossible. Raise solver.timeBudgetSeconds, or lower " +
                "solver.maxCostDrop to narrow the search.")
        }
        throw ("No schedule satisfies the hard constraints -- the search completed and found nothing. " +
            "Compare each person's contracted shifts against the per-service gaps; the usual causes are a " +
            "consecutive-days-off requirement that cannot fit, or too few eligible people for a service.")
    }

    [pscustomobject]@{
        Schedule   = $best.Schedule
        Violations = $best.Violations
        Score      = $best.Score
        Stats      = [pscustomobject]$stats
        Elapsed    = $sw.Elapsed
    }
}
