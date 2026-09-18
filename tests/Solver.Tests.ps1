#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
#
# Solver.Tests.ps1 -- search structure, and the invariants the whole engine rests on.
#
# The end-to-end tests here use the small fixture so they run in seconds. The shipped roster
# is exercised separately in Integration.Tests.ps1, which is tagged Slow.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-RotaModuleForTests
}

Describe 'Search variables' {
    # Note the assign-then-count: these helpers return a comma-wrapped array so that a single
    # result survives the pipeline, which means @(Call-It) yields one element containing the
    # array rather than the array itself. Assigning first unwraps it, as production code does.
    It 'gives a one-week-cycle person a single variable spanning both weeks' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 1
        $vars = New-RotaSolverVariables -Config $cfg
        @($vars).Count | Should -Be 1
        $vars[0].Weeks | Should -Be @(1, 2)
    }

    It 'gives a two-week-cycle person one variable per week' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 2
        $vars = New-RotaSolverVariables -Config $cfg
        @($vars).Count | Should -Be 2
        $vars[0].Weeks | Should -Be @(1)
        $vars[1].Weeks | Should -Be @(2)
    }

    It 'decouples the weeks when enforcePersonCycleRepeat is off' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 1 -Rules @{ enforcePersonCycleRepeat = $false }
        $vars = New-RotaSolverVariables -Config $cfg
        @($vars).Count | Should -Be 2
    }
}

Describe 'Independent components' {
    It 'keeps everyone in one component when somebody spans both weeks' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 1
        $vars = New-RotaSolverVariables -Config $cfg
        $components = Get-RotaVariableComponents -Variables $vars
        @($components).Count | Should -Be 1
        $components[0].Weeks | Should -Be @(1, 2)
    }

    It 'REGRESSION: splits the weeks apart when nobody spans them' {
        # Searching the cross-product of two independent weeks multiplies the work by the size
        # of the other week for no benefit, and was what made the solver appear to hang.
        $cfg = New-TestRotaConfig -PersonCycleWeeks 2
        $vars = New-RotaSolverVariables -Config $cfg
        $components = Get-RotaVariableComponents -Variables $vars
        @($components).Count | Should -Be 2
        foreach ($c in $components) { $c.Weeks.Count | Should -Be 1 }
    }
}

Describe 'Pattern enumeration' {
    It 'never offers a pattern that breaks the weekend rule' {
        $cfg = New-TestRotaConfig -Weekend $false -SolvedShifts 3
        $person = $cfg.StaffByName['Solved']
        $weekendBits = 0
        foreach ($d in $cfg.WeekendDayIndexes) {
            foreach ($slot in 'Lunch', 'Dinner') { $weekendBits = $weekendBits -bor (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot)) }
        }
        $patterns = Get-RotaWeekPatterns -Config $cfg -Person $person -Week 1 -MinShifts 3 -MaxShifts 3
        foreach ($m in $patterns[3]) { ($m -band $weekendBits) | Should -Be 0 }
    }

    It 'never offers a double when doubles are forbidden' {
        $cfg = New-TestRotaConfig -Doubles $false -SolvedShifts 3
        $patterns = Get-RotaWeekPatterns -Config $cfg -Person $cfg.StaffByName['Solved'] -Week 1 -MinShifts 3 -MaxShifts 3
        foreach ($m in $patterns[3]) {
            foreach ($d in 0..6) { (Get-RotaDayLoad -Mask $m -DayIndex $d) | Should -BeLessOrEqual 1 }
        }
    }

    It 'offers only lunches when lunch is OBLIG' {
        $cfg = New-TestRotaConfig -Lunch 'OBLIG' -SolvedShifts 3
        $patterns = Get-RotaWeekPatterns -Config $cfg -Person $cfg.StaffByName['Solved'] -Week 1 -MinShifts 3 -MaxShifts 3
        foreach ($m in $patterns[3]) {
            foreach ($d in 0..6) { ($m -band (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot 'Dinner'))) | Should -Be 0 }
        }
    }

    It 'produces exactly the combinatorial count when nothing is restricted' {
        # 7 days, one shift each, choose 3 days of 7 and a slot for each: C(7,3) * 2^3.
        $cfg = New-TestRotaConfig -Doubles $false -SolvedShifts 3
        $patterns = Get-RotaWeekPatterns -Config $cfg -Person $cfg.StaffByName['Solved'] -Week 1 -MinShifts 3 -MaxShifts 3
        $patterns[3].Count | Should -Be (35 * 8)
    }
}

Describe 'Shift-count distribution' {
    It 'prefers contracted staff over cover when ranking distributions' {
        # A cover shift must never look cheaper than a shift the permanent team can work,
        # or the engine would reach for the temp to make its own job easier.
        $cfg = New-TestRotaConfig -SolvedShifts 4
        $cfg.staff[1] | Add-Member -NotePropertyName temporary -NotePropertyValue $true -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        $vars = New-RotaSolverVariables -Config $cfg

        $combos = @(
            [pscustomobject]@{ Counts = [int[]]@(0); Total = 0 }
            [pscustomobject]@{ Counts = [int[]]@(4); Total = 8 }
        )
        $scored = @(Add-RotaComboCost -Config $cfg -Variables $vars -Combinations $combos -WeekCapacityTotal @{ 1 = 0; 2 = 0 })
        $scored[0].EstimatedCost | Should -BeLessThan $scored[1].EstimatedCost
    }

    It 'charges coverage shortfall far above any other term' {
        $cfg = New-TestRotaConfig -SolvedShifts 4
        $vars = New-RotaSolverVariables -Config $cfg
        $combos = @([pscustomobject]@{ Counts = [int[]]@(4); Total = 8 })
        $scored = @(Add-RotaComboCost -Config $cfg -Variables $vars -Combinations $combos -WeekCapacityTotal @{ 1 = 5; 2 = 5 })
        # Two weeks, one short each, at 1000 apiece.
        $scored[0].EstimatedCost | Should -Be 2000
    }
}

Describe 'Days off is applied to cycle-spanning patterns up front' {
    # A person on a one-week cycle carries the same mask into every week, so whether they
    # get their consecutive days off is settled by that single pattern. Deciding it before
    # the search starts, rather than after components are joined, is what stops the kernel
    # walking subtrees that were never going to qualify.

    It 'keeps exactly the patterns the authoritative check accepts' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 1 -ConsecutiveDaysOff 2 -SolvedShifts 5
        $vars = New-RotaSolverVariables -Config $cfg
        $v = $vars[0]
        $v.Weeks.Count | Should -Be ([int]$cfg.meta.cycleWeeks)   # spans the cycle, so decidable

        $before = Get-RotaWeekPatterns -Config $cfg -Person $v.Person -Week $v.SpecWeek -MinShifts 5 -MaxShifts 5
        $after = Select-RotaDaysOffFeasiblePatterns -Config $cfg -Variable $v -PatternsByCount $before

        foreach ($mask in $before[5]) {
            $masks = @{}
            foreach ($w in $v.Weeks) { $masks["$($v.Name)|$w"] = $mask }
            $legal = Test-RotaMasksDaysOff -Config $cfg -Masks $masks -Person $v.Person
            # Survival and legality must agree in both directions, or the filter is either
            # discarding valid schedules or failing to save any work.
            (@($after[5]) -contains $mask) | Should -Be $legal
        }
    }

    It 'actually removes something, so the prune is not a no-op' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 1 -ConsecutiveDaysOff 2 -SolvedShifts 5
        $vars = New-RotaSolverVariables -Config $cfg   # assign first: the helper comma-wraps
        $v = $vars[0]
        $before = Get-RotaWeekPatterns -Config $cfg -Person $v.Person -Week $v.SpecWeek -MinShifts 5 -MaxShifts 5
        $after = Select-RotaDaysOffFeasiblePatterns -Config $cfg -Variable $v -PatternsByCount $before
        @($after[5]).Count | Should -BeLessThan @($before[5]).Count
        @($after[5]).Count | Should -BeGreaterThan 0
    }

    It 'leaves a single-week variable untouched, because its verdict is not its own' {
        # On a two-week cycle the person owns one week per variable, and the run that saves
        # them may lie in the other. Filtering here would discard legal schedules.
        $cfg = New-TestRotaConfig -PersonCycleWeeks 2 -ConsecutiveDaysOff 2 -SolvedShifts 4
        $vars = New-RotaSolverVariables -Config $cfg   # assign first: the helper comma-wraps
        $v = $vars[0]
        $v.Weeks.Count | Should -Be 1

        $before = Get-RotaWeekPatterns -Config $cfg -Person $v.Person -Week $v.SpecWeek -MinShifts 4 -MaxShifts 4
        $after = Select-RotaDaysOffFeasiblePatterns -Config $cfg -Variable $v -PatternsByCount $before
        @($after[4]).Count | Should -Be @($before[4]).Count
    }
}

Describe 'Days-off agreement between solver and constraint engine' {
    It 'the fast in-search check matches the authoritative evaluator' {
        # The solver builds day loads inline for speed. If the two ever disagree the search
        # discards good schedules or keeps illegal ones, and nothing else would notice.
        $cfg = New-TestRotaConfig -SolvedShifts 5
        $person = $cfg.StaffByName['Solved']

        foreach ($mask in @(
                (New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'L'; Mercredi = 'L'; Jeudi = 'L'; Vendredi = 'L' }),
                (New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mercredi = 'L'; Vendredi = 'L'; Dimanche = 'L' }),
                (New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'LD'; Mardi = 'LD'; Samedi = 'L' }),
                0
            )) {
            $masks = @{ 'Solved|1' = $mask; 'Solved|2' = $mask }
            $fast = Test-RotaMasksDaysOff -Config $cfg -Masks $masks -Person $person

            $schedule = New-RotaSchedule -Config $cfg
            Add-RotaFixedStaff -Schedule $schedule | Out-Null
            Set-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 1 -Mask $mask
            Set-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 2 -Mask $mask
            $slow = @(Test-RotaConsecutiveDaysOff -Schedule $schedule | Where-Object Person -eq 'Solved').Count -eq 0

            $fast | Should -Be $slow -Because "mask $mask must be judged the same by both"
        }
    }
}

Describe 'Solving end to end' {
    BeforeAll {
        # The fixture's Boss covers every service of every day, so he can never get two days
        # off. That is an artefact of the fixture, not of the engine, so the floor is lifted
        # here; Constraints.Tests.ps1 covers the floor itself.
        $script:FixtureRules = @{ minConsecutiveDaysOffForEveryone = 0 }
        $script:Fixture = New-TestRotaConfig -RequiredPerService 2 -SolvedShifts 10 -Rules $script:FixtureRules
        $script:Result = Invoke-RotaSolver -Config $script:Fixture -ShortlistSize 20
    }

    It 'returns a schedule, its violations and a score' {
        $script:Result.Schedule | Should -Not -BeNullOrEmpty
        $script:Result.Score | Should -BeGreaterOrEqual 0
    }

    It 'never breaks a hard rule other than coverage' {
        $hard = @($script:Result.Violations | Where-Object { $_.Severity -eq 'Hard' -and $_.Id -ne 'H1-Coverage' })
        $hard | Should -BeNullOrEmpty
    }

    It 'never exceeds anyone contracted ceiling' {
        @($script:Result.Violations | Where-Object Id -eq 'H4-ShiftCeiling') | Should -BeNullOrEmpty
    }

    It 'leaves the fixed staff exactly as configured' {
        @($script:Result.Violations | Where-Object Id -eq 'H3-Fixed') | Should -BeNullOrEmpty
    }

    It 'is deterministic: the same config gives the same schedule' {
        $again = Invoke-RotaSolver -Config (New-TestRotaConfig -RequiredPerService 2 -SolvedShifts 10 -Rules $script:FixtureRules) -ShortlistSize 20
        $again.Score | Should -Be $script:Result.Score
        foreach ($key in $script:Result.Schedule.Masks.Keys) {
            $again.Schedule.Masks[$key] | Should -Be $script:Result.Schedule.Masks[$key]
        }
    }

    It 'distinguishes an impossible roster from one it ran out of time on' {
        # Nobody can work 14 shifts and still get two days off, so the search completes and
        # correctly reports a contradiction rather than blaming the clock.
        $cfg = New-TestRotaConfig -RequiredPerService 2 -SolvedShifts 14 -ConsecutiveDaysOff 2 -Rules $script:FixtureRules
        { Invoke-RotaSolver -Config $cfg -ShortlistSize 5 } | Should -Throw '*completed and found nothing*'
    }
}

Describe 'Temporary cover is additive only' {
    It 'REGRESSION: cover never reduces what the permanent team works' {
        # Cover existed, so the solver traded a contracted shift for a cover shift because the
        # arithmetic happened to suit. The permanent team is now solved first and its counts
        # become a floor, so cover can only ever add on top.
        $cfg = New-TestRotaConfig -RequiredPerService 2 -SolvedShifts 8
        $cfg.staff += [pscustomobject]@{
            name = 'Cover'; contract = 'TEMP'; responsable = $false; mode = 'solved'
            temporary = $true; cycleWeeks = 2; consecutiveDaysOff = 0
            weeks = [pscustomobject]@{
                '1' = [pscustomobject]@{ doubles = $true; shifts = 0; maxShifts = 6; weekend = $true; lunch = 'ANY'; dinner = 'ANY' }
                '2' = [pscustomobject]@{ doubles = $true; shifts = 0; maxShifts = 6; weekend = $true; lunch = 'ANY'; dinner = 'ANY' }
            }
        }
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg

        $result = Invoke-RotaSolver -Config $cfg -ShortlistSize 20
        $result.PermanentOnly | Should -Not -BeNullOrEmpty

        foreach ($w in 1, 2) {
            $withCover = Get-RotaMaskPopCount -Mask $result.Schedule.Masks["Solved|$w"]
            $without = Get-RotaMaskPopCount -Mask $result.PermanentOnly.Schedule.Masks["Solved|$w"]
            $withCover | Should -BeGreaterOrEqual $without -Because 'cover must never take work off the permanent team'
        }
    }

    It 'leaves cover unused when the permanent team can manage alone' {
        $cfg = New-TestRotaConfig -RequiredPerService 1 -SolvedShifts 0
        $cfg.staff += [pscustomobject]@{
            name = 'Cover'; contract = 'TEMP'; responsable = $false; mode = 'solved'
            temporary = $true; cycleWeeks = 2; consecutiveDaysOff = 0
            weeks = [pscustomobject]@{
                '1' = [pscustomobject]@{ doubles = $true; shifts = 0; maxShifts = 6; weekend = $true; lunch = 'ANY'; dinner = 'ANY' }
                '2' = [pscustomobject]@{ doubles = $true; shifts = 0; maxShifts = 6; weekend = $true; lunch = 'ANY'; dinner = 'ANY' }
            }
        }
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg

        # Boss already covers every service on his own, so cover has nothing to do.
        $result = Invoke-RotaSolver -Config $cfg -ShortlistSize 10
        foreach ($w in 1, 2) {
            Get-RotaMaskPopCount -Mask $result.Schedule.Masks["Cover|$w"] | Should -Be 0
        }
    }
}

Describe 'Soft rules must be visible to the shortlist, not just the scorer' {
    # The solver shortlists candidates by a fast proxy and only then scores them exactly. A
    # soft rule the exact scorer honours but the proxy ignores is invisible in practice: the
    # schedules that satisfy it are never shortlisted, so they never reach scoring, and
    # raising its weight changes nothing at all. That is precisely what happened to the
    # days-off preference -- it was inert at every weight from 20 to 800.

    It 'REGRESSION: the shortlist scorer prices the preference at all' {
        # Two identical patterns bar the days off; the one that misses the preference must
        # cost more. If the proxy ignores S8 these come out equal and the ranking is blind.
        $cfg = New-TestRotaConfig -SolvedShifts 4 -ConsecutiveDaysOff 2 -PersonCycleWeeks 1
        $cfg.staff[1] | Add-Member -NotePropertyName preferredConsecutiveDaysOff -NotePropertyValue 3.5 -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        $vars = New-RotaSolverVariables -Config $cfg
        $v = $vars[0]
        $v.Weeks.Count | Should -Be 2   # spans the cycle, so days off is decidable per pattern

        # Four lunches in a block leaves a long run; four spread out does not.
        $blocked = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'L'; Mercredi = 'L'; Jeudi = 'L' }
        $spread = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mercredi = 'L'; Vendredi = 'L'; Dimanche = 'L' }
        $costs = Get-RotaVariableCosts -Config $cfg -Variable $v -Masks ([int[]]@($blocked, $spread))
        $costs[1] | Should -BeGreaterThan $costs[0]
    }
}
